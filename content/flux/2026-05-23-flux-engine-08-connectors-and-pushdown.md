---
title: Connector 与 Pushdown：把 Flux 查询下推到 SQLite/MySQL
description: "介绍 Flux 查询引擎的数据源入口、connector runtime、split/page source、SQLite/MySQL pushdown 规则和 fallback 边界。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, sqlite, mysql, query-optimizer, cpp]
authors: ["liubang"]
weight: 8
series: ["Flux"]
series_weight: 8
lightgallery: true
---

前面几篇文章已经把 Flux 的词法语法、类型值模型、执行器和表流管线串起来了。到这里，查询引擎终于要碰到一个更现实的问题：数据不一定在内存里，也不一定来自小 CSV，它可能在 SQLite 文件中，也可能在远端 MySQL 实例里。

如果还沿用最朴素的解释器思路，`sqlite.from()` 先把整张表读成 `TableValue`，再让 `range`、`filter`、`keep`、`sort` 在内存里慢慢跑，那么这个实现虽然容易写，却很难称为查询引擎。真正有意义的边界是：Flux 仍然是统一查询语言，但能够把安全、明确、可证明等价的一段计划下推到数据源附近执行。

这一篇就专门讲 `cpp/pl/flux` 当前的 connector 与 pushdown 设计。它不是“把 Flux 翻译成任意 SQL”，而是一套更保守的执行模型：provider package 负责建立数据源入口，optimizer 识别可下推前缀，connector runtime 按 metadata、split、page source 三层执行，unsupported suffix 则可靠 fallback 回内存执行器。

先看一条典型查询：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r.host == "edge-1" and r._value > 80.0)
    |> keep(columns: ["_time", "host", "_value"])
    |> sort(columns: ["_time"])
    |> limit(n: 10)
```

从用户视角看，这就是一条普通 Flux pipeline。从引擎内部看，它可以被拆成两段：前缀部分能变成 SQL `SELECT ... WHERE ... ORDER BY ... LIMIT ...`，后缀部分如果还有复杂 Flux 算子，则继续由内存 runtime 接管。这个“能不能下推”的判断，就是本文的核心。

## Provider package 入口

项目当前没有提供 universe 顶层的 `from(bucket:)`。所有外部数据源都通过 provider package 进入，例如 SQLite：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
```

MySQL 也一样，可以用显式连接参数：

```flux
import "mysql"

mysql.from(
    host: "127.0.0.1",
    user: "flux",
    password: "flux",
    database: "flux_test",
    table: "cpu",
    port: 3306,
)
```

也可以用 DSN：

```flux
mysql.from(dsn: "mysql://flux:flux@127.0.0.1:3306/flux_test", table: "cpu")
```

这个入口看起来很薄，但它决定了后续优化器能看到什么。`sqlite.from` 和 `mysql.from` 都不是 eager scan；它们不会立即把整张表读出来，而是构造一个 lazy table plan。实现上大致对应：

```cpp
return Value::table_plan("sqlite", plan::MakeSourceScan(...));
```

这一步非常重要。只要 source 仍然是 plan，后面的 `range/filter/keep/sort/limit` 就还有机会被 optimizer 合并进 scan request。反过来，如果 `from` 一开始就 materialize 成完整 `TableValue`，connector 之后再想 pushdown 就太晚了。

provider package 还负责 API 层面的参数校验。比如 SQLite 要求 `path` 和 `table`，并且不接受 raw query；MySQL 支持 DSN 或显式连接参数，但同样要求最终落到明确的 `table`。这样做不是因为 raw SQL 难实现，而是为了保护查询模型的可优化性。

## 为什么不暴露 raw query

暴露 `sqlite.query(sql:)` 或 `mysql.query(sql:)` 很诱人。短期看，用户能写任意 SQL，引擎也省去了很多 optimizer 工作。但这会把 Flux 查询模型打穿。

一旦 source 变成一段 opaque SQL 字符串，引擎很难回答几个关键问题：

- 这个 scan 真实输出了哪些列？
- 哪些列是原始字段，哪些列是表达式别名？
- 后续 `filter` 能不能继续合并到同一个 `WHERE`？
- 后续 `keep/drop/rename` 是否还能做 projection pruning？
- `sort/limit/distinct/group` 是否已经被 SQL 内部消费过？
- `explain` 和 `profile` 应该怎样展示这个 source 的语义？

查询引擎最怕的不是不能优化，而是优化器以为自己理解了计划，实际上只看见了一段黑盒 SQL。当前实现选择只暴露 `from(table:)`，然后用 Flux pipeline 表达变换。connector 可以基于 metadata、logical plan 和 pushdown contract 决定 SQL 形态，而不是把用户 SQL 当作不可见的内部世界。

这个选择牺牲了一些灵活性，但换来三个长期收益：计划透明、优化可组合、fallback 可控。后续要支持 PostgreSQL、Parquet、HTTP table API 时，也可以沿用同一套边界。

## 从 Flux 到 Connector Scan

下图是当前 connector pushdown 的主路径。绿色路径表示已经确认能下推的查询前缀，红色路径表示 contract 判断不成立后进入 fallback。

![Flux pushdown flow](/images/flux/pushdown-flow.svg "Flux pushdown flow")

整体流程可以拆成七步：

1. `sqlite.from` 或 `mysql.from` 构造 `SourceScan`，把数据源类型、连接参数和表名放进 logical plan。
2. 后续 pipe builtin 不立刻执行，而是继续扩展 logical plan，例如 `Range`、`Filter`、`Project`、`Sort`、`Limit`。
3. RBO 规则识别线性前缀，把可下推算子聚合成 connector scan request。
4. pushdown contract 校验 projection、predicate、rename、group、aggregate、sort、limit 等组合是否安全。
5. contract 通过后，connector runtime 使用 metadata 解析 schema/capability/statistics。
6. split manager 决定 single split、multi split，或在部分场景下交给 partial/final pipeline。
7. page source provider 把每个 split 读成 Page 流，交给后续 physical pipeline。

如果第 3 或第 4 步失败，引擎不会强行拼 SQL。它会在可执行边界处 materialize，把后续计划交给 `TableValue` 内存 builtin。这样 connector 路径可以逐步变强，但不会为了快一点而让语义漂移。

## Connector runtime 分层

当前 SQLite、MySQL 和 memory connector 都走类似分层：

![connector runtime 分层](/images/flux/connector-runtime.svg "connector runtime 分层")

第一层是 metadata provider。它负责把外部表描述成 Flux 能理解的 schema，并提供必要统计信息和 capability。SQLite 的 metadata 主要来自本地文件和表结构，MySQL 的 metadata 则需要经过连接、认证和协议交互。统计信息不一定总是完整，所以 optimizer 不能假设自己永远能拿到可靠 cardinality。

第二层是 split manager。它不读数据，只决定怎么切扫描任务。SQLite 可以利用 `rowid` 做多 split；MySQL 可以在主键或整型列上做 range split。split manager 同时也要看 scan request 的语义：有些查询能拆，有些查询必须保持 single split。

第三层是 page source provider。它拿到 split 和 scan request 后，真正访问 SQLite/MySQL，把结果编码成 Page。Page 里是 `PageChunk` 和列式 `ColumnVector`，不是一行行 Flux object。这样 scan、filter、project、range、root exchange 这些路径可以保持 page streaming，而不是退回“每行一个对象”的解释器模型。

这套分层的好处是职责边界很清楚：metadata 回答“表是什么样”，split manager 回答“能不能并行读”，page source 回答“怎样把某个 split 读成 Page”。SQL 生成也不再散落在每个 builtin 里，而是围绕 scan request 和 contract 统一处理。

## Split 不是简单并发读表

很多查询引擎问题看上去像性能问题，本质上是语义问题。split 就是典型例子。

下面这类 pipeline 可以比较自然地 multi-split：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r.host == "edge-1")
    |> keep(columns: ["_time", "host", "_value"])
```

因为 scan、range、simple filter、projection 都是逐行语义。每个 split 独立读一段数据，最后拼接起来，结果仍然等价。

但下面这类查询就要小心：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> sort(columns: ["_time"])
    |> limit(n: 10)
```

如果每个 split 都执行 `ORDER BY _time LIMIT 10`，再把结果直接拼起来，这不是全局前 10 行，而是“每个 split 的前 10 行”。除非 physical pipeline 有 root global top-n 合并，否则 split manager 必须退回 single split 或者禁止这段组合下推。

`distinct`、`group`、`aggregate` 也类似。split 内可以算 partial result，但 partial 之后必须有 final merge。当前实现对这些场景采取保守策略：能证明等价时才允许下推或两阶段执行；遇到全局 order、offset、aggregate、distinct、group 等容易跨 split 改变语义的请求，会回退 single split 或更保守的执行路径。

这里的原则很朴素：并行是执行策略，不是语义捷径。split manager 必须先证明拆分不会改变结果，再谈吞吐。

## 当前支持的 pushdown

SQLite/MySQL 当前支持的是保守线性前缀下推。所谓线性前缀，是指从 source 开始连续出现、能够合并进同一个 connector scan 的一段算子：

- `range`
- simple `filter`
- `keep`
- `drop`
- `rename`
- `sort`
- `limit`
- `distinct`
- 简单 `group(columns:) |> count/sum/mean/min/max(column:)`

这份列表刻意不追求大而全。比如 `map` 看上去也常见，但它可能构造新列、调用用户函数、改变类型，直接翻成 SQL 表达式风险很高。`join` 也只在非常有限的同源、同语义情况下才有讨论空间；当前更稳妥的方式是让跨源 join 进入内存或后续 physical pipeline。

pushdown 的目标不是覆盖所有 Flux，而是覆盖最值得覆盖、最容易证明正确的前缀。真实查询里，`from |> range |> filter |> keep |> aggregate` 已经是非常高频的路径。先把这条路径做稳，比急着支持任意复杂表达式更有价值。

## Simple Filter 如何识别

simple `filter` 不是指源码短，而是指表达式可以安全变成数据源 predicate。典型可下推表达式包括字段访问、字面量、比较运算和有限的布尔组合：

```flux
filter(fn: (r) => r._value > 80.0 and r.host == "edge-1")
```

这类表达式可以变成：

```sql
WHERE _value > 80.0 AND host = 'edge-1'
```

另一个常见例子是时间范围。Flux 里的 `range(start:, stop:)` 不是普通 filter；它有 `_time` 列和半开区间语义，所以应该由专门规则生成时间谓词，而不是让 SQL 生成器猜测用户意图。

下面这种 filter 就不应该在第一阶段下推：

```flux
filter(fn: (r) => normalizeHost(r.host) == "edge-1")
```

`normalizeHost` 是 Flux 用户函数，SQLite/MySQL 不知道它的语义。即使某些函数名字碰巧能映射到 SQL 函数，也不能默认二者在空值、类型转换、大小写、时区和错误处理上完全一致。

再比如：

```flux
filter(fn: (r) => strings.containsStr(v: r.host, substr: "edge"))
```

它理论上可能映射成 `LIKE`，但这需要明确处理转义、大小写规则和 collation。当前实现宁可不下推，也不做含糊翻译。

## Pushdown Contract

SQL 生成前有一层统一 contract。它不是优化器的装饰品，而是 connector pushdown 的安全闸门。

contract 至少要验证这些内容：

- projection 是否只引用了源表存在的列。
- predicate 是否只包含 connector 支持的表达式。
- rename 后的列名能否正确映射回源列或 SQL 表达式。
- distinct/group/aggregate 的组合是否能由目标数据源等价执行。
- sort/limit 是否需要全局语义，当前 split 策略能否保证结果正确。
- 输出列名、列顺序和 Flux 后续算子期望是否一致。

`keep/drop/rename` 是最容易低估的部分。比如：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> rename(columns: {_value: "usage"})
    |> filter(fn: (r) => r.usage > 80.0)
    |> keep(columns: ["_time", "host", "usage"])
```

Flux 后续算子看到的是 `usage`，但 SQL 侧真实列可能仍然是 `_value`。如果没有统一列映射，SQL 生成器很容易拼出 `WHERE usage > 80.0`，而源表根本没有 `usage` 列。

因此 contract 需要维护 assignment：Flux 层列名对应数据源列或表达式。projection、predicate、sort、aggregate 都必须通过这张映射表解析。这个设计比“每个 builtin 自己会拼一点 SQL”复杂一些，但它能避免 rename + filter + aggregate 这种组合查询里的隐蔽错误。

## SQLite 与 MySQL 的差异

SQLite 和 MySQL 都走 connector runtime，但它们的成本模型完全不同。

SQLite 是本地文件数据库，连接成本低，读取路径短，最自然的 split 方式是 `rowid` 范围。它适合用来验证 connector runtime 的最小闭环：schema 读取、scan request、rowid split、page source、pushdown SQL、fallback 边界。

MySQL 是远端服务。它有连接池、认证、网络往返、协议解码和服务器端执行计划。当前实现中，metadata、statistics、split manager 使用 Boost.MySQL pool；page source 在某些路径下使用独立 direct connection，是为了绕开 ASAN 相关问题。这类细节说明 connector runtime 不能假设所有数据源都是“本地文件 + 同步读”。

MySQL 的 range split 也更受约束。理想情况下可以基于主键或整型列拆范围，但如果查询带有全局 order、offset、distinct、group 或 aggregate，就必须重新审视 multi-split 是否仍然等价。远端数据库还有一个额外变量：有时候把更多工作推给 MySQL 更快，有时候过度拆 split 反而会放大连接和网络开销。

这也是为什么 CBO 框架有价值。即使当前很多规则仍然偏 RBO，connector metadata 和 statistics 的形状已经为后续代价估算留好了入口。

## Fallback 边界

fallback 不是失败路径，而是混合执行模型的一部分。connector pushdown 只负责可证明安全的前缀，剩下的 Flux 语义继续交给内存 runtime。

例如：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z)
    |> filter(fn: (r) => r.host == "edge-1")
    |> map(fn: (r) => ({r with level: if r._value > 90.0 then "hot" else "normal"}))
```

这里 `range + simple filter` 可以下推，`map` 则作为后缀在内存里执行。执行器会在边界处 materialize，得到 `TableValue` 或等价的表流表示，再复用已有 builtin。

更复杂的场景也类似：

- 调用用户函数的 `filter`。
- 构造对象或数组的 `map`。
- 跨 SQLite/MySQL/CSV 的 join。
- inspect/output 这类有调试或输出副作用的 builtin。
- connector 暂不支持的字符串、正则或时间函数。

fallback 的关键是边界必须清楚。一个算子要么在 contract 中被完整声明并下推，要么留在 Flux runtime；不能一半语义在 SQL，一半语义靠后续补丁修正。那种实现短期能跑 demo，长期一定会在边界场景里产生错结果。

## Explain 与 Profile

pushdown 如果没有 explain/profile，就很容易变成黑箱。用户看到查询变快了，但不知道哪些算子被推下去了；查询变慢了，也不知道瓶颈在 metadata、split、SQL 执行、网络读取还是 Page 构造。

当前 `explain()` 可以展示 logical、optimized logical、physical 或 pipeline plan。对于 connector 查询，最需要看的信息包括：

- source scan 是否仍然是 connector plan，而不是过早 materialize。
- `range/filter/project/sort/limit` 是否进入 scan request。
- unsupported suffix 从哪里开始 fallback。
- physical pipeline 中有没有 exchange、partial/final aggregate、blocking operator。

profile 则从执行角度回答问题。它会暴露 drivers、pages、rows、blocking/finished/error 状态，也会记录 connector split 的 pages/rows/bytes/wall time，以及 metadata、split、connect、schema、sql、execute、read、decode、page-build 等阶段耗时。

对 group/aggregate 这类算子，profile 还会记录 accumulator phase、key strategy、partial/final 耗时。对内存敏感查询，它也会给出 query memory used/peak/limit。没有这些数据，优化器改动只能靠感觉；有了这些数据，才能知道“pushdown 生效了，但瓶颈其实在 decode”或者“split 太多导致远端连接开销超过收益”。

## 不是任意 Flux 到 SQL

这一点值得单独强调：当前实现不是 arbitrary Flux-to-SQL compiler。

它明确不追求几个目标：

- 不提供 raw SQL API 作为主要入口。
- 不把用户函数、复杂对象构造、任意 package 调用翻译成 SQL。
- 不做跨数据源 join pushdown。
- 不在缺少语义保证时强行 multi-split。
- 不假设所有 connector 都有完整统计信息。
- 不依赖 spill 来兜住所有 blocking operator。

这些“不做”反而让主干更稳。查询引擎最重要的是可解释、可验证、可扩展。只要 connector contract 足够清楚，后面新增 PostgreSQL、Parquet 或云对象存储时，工作量主要落在 metadata/split/page source 和 capability 描述上，而不是重写 Flux runtime。

## 测试策略

connector 和 pushdown 的测试不能只测 SQL 字符串。SQL 看起来对，不代表结果一定等价；结果对，也不代表 split、profile、fallback 边界正确。

当前更合理的测试层次包括：

- provider package 参数校验：缺少 `path/table`、非法 DSN、拒绝 raw query。
- optimizer 单测：确认可下推前缀被合并，复杂后缀保留在 Flux runtime。
- SQL contract 单测：覆盖 rename + filter、keep/drop + aggregate、sort + limit 等组合。
- connector runtime 单测：metadata、split manager、page source 分别验证。
- SQLite/MySQL source 集成测试：用真实表校验结果等价。
- CLI example 和 conformance：确认 explain/profile/JSON table 输出稳定。
- benchmark：观察 pushdown 和 page streaming 是否真的减少 rows/pages/materialization。

尤其是 split 相关测试，要同时覆盖 multi-split 与 single-split fallback。很多 bug 只会在数据跨 split 分布时出现，比如每个 split 局部 top-n 正确，但全局 top-n 错误。

## 下一篇

下一篇会继续往执行引擎内部走，看 logical plan 如何经过 optimizer 变成 physical plan、pipeline、driver 和 Page operator。

## 小结

Connector 与 pushdown 是这个 Flux 实现从“解释执行语言”走向“查询引擎”的关键一步。它的核心并不是会拼 SQL，而是建立了一条可验证的链路：provider package 产生 lazy source plan，optimizer 识别可下推前缀，contract 阻止语义漂移，connector runtime 用 metadata/split/page source 执行，unsupported suffix 则回到内存 runtime。

这个架构现在还很保守，但保守是有意为之。只要边界稳，后续增强就会很自然：更多 predicate 函数、更细的 projection pruning、更好的 statistics、更成熟的 partial/final 聚合、更丰富的数据源 connector。下一篇我们可以继续往下看 logical/physical plan 如何把这些 source scan、exchange、blocking operator 组织成真正可调度的执行图。
