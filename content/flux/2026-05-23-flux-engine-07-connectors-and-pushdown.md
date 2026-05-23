---
title: Connector 与 Pushdown：把 Flux 查询下推到 SQLite/MySQL
description: "介绍 Flux 查询引擎的数据源入口、connector runtime、split/page source、SQLite/MySQL pushdown 规则和 fallback 边界。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, sqlite, mysql, query-optimizer, cpp]
authors: ["liubang"]
weight: 7
series: ["Flux"]
series_weight: 7
lightgallery: true
---

当查询只跑内存数组和 CSV 时，eager interpreter 足够简单。但一旦数据源变成 SQLite 或 MySQL，全量读入再过滤就不再合理。`cpp/pl/flux` 现在的 connector 架构目标，是让 Flux 仍然作为统一查询入口，同时把能安全下推的算子推到数据源附近执行。

## Provider package 入口

项目不提供 universe 顶层 `from(bucket:)`。所有数据源都通过 provider package 进入：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r.usage > 80)
    |> keep(columns: ["_time", "host", "usage"])
```

MySQL 也一样：

```flux
import "mysql"

mysql.from(
    host: "127.0.0.1",
    user: "flux",
    password: "flux",
    database: "flux_test",
    table: "cpu",
)
```

或者使用 DSN：

```flux
mysql.from(dsn: "mysql://flux:flux@127.0.0.1:3306/flux_test", table: "cpu")
```

用户 API 不提供 raw SQL/query 入口，这是刻意的边界：Flux 负责表达查询，connector 负责在安全条件下把一部分语义翻译到数据源。

## 为什么不暴露 raw query

暴露 `sqlite.query(sql:)` 或 `mysql.query(sql:)` 很容易，但它会绕开 Flux 查询模型。用户一旦可以把任意 SQL 塞进数据源，optimizer 就很难理解这个 scan 的列、谓词、排序和 group 语义，后续 pushdown、projection pruning、explain 和 profile 都会变得不透明。

当前项目选择只暴露 `from(table:)`，然后让 Flux pipeline 表达后续变换。这样 connector 可以基于表 metadata、logical plan 和 pushdown contract 决定 SQL 形态。这个选择牺牲了一些短期灵活性，但换来了更稳定的查询引擎边界。

## Connector runtime 分层

当前 SQLite、MySQL 和 memory runtime 都走类似边界：

![connector runtime 分层](/images/flux/connector-runtime.svg "connector runtime 分层")

这比早期直接 scan factory 更接近真实查询引擎。metadata 负责表结构和统计信息；split manager 负责把扫描拆成多个 split；page source provider 负责把 split 读成 Page 流。

SQLite 可以按 `rowid` 做 multi-split。MySQL 可以按主键或整型列做保守 range split。遇到全局 order、offset、aggregate、distinct、group 等容易跨 split 改变语义的请求时，会回退 single split 或进入更保守的执行路径。

## Split 的语义约束

Split 不是简单地“多线程读表”。如果把一个 SQL 查询随便拆成多个 range 并发执行，结果可能会变。

例如没有全局合并逻辑的 `sort |> limit`，每个 split 取前 10 行再拼起来，并不等于全局前 10 行。`distinct`、`group`、`aggregate` 也有类似问题：split 内局部结果必须经过 final 合并才能代表全局结果。

所以 split manager 必须知道哪些计划可以 multi-split，哪些要 single split，哪些需要 partial/final 两阶段。这个判断不属于用户函数，也不应该散落在 SQL 字符串拼接里，而应该是 connector runtime 和 physical planner 的共同约束。

## 当前支持的 pushdown

SQLite/MySQL 当前支持保守线性前缀下推：

- `range`
- simple `filter`
- `keep`
- `drop`
- `rename`
- `sort`
- `limit`
- `distinct`
- 简单 `group(columns:) |> count/sum/mean/min/max(column:)`

这里的 simple `filter` 很关键。任意 Flux 函数不可能都翻译成 SQL。例如：

```flux
filter(fn: (r) => r.usage > 80 and r.host == "edge-1")
```

这种比较简单，可以转换为 SQL predicate。但如果 filter 中调用用户函数、正则函数、复杂对象构造或 array package，就不适合盲目下推。

## 简单 filter 如何识别

所谓 simple filter，不是指源码短，而是指表达式可以安全翻译为数据源谓词。通常包括字段访问、字面量、比较运算和有限的 `and/or` 组合：

```flux
filter(fn: (r) => r.usage > 80 and r.host == "edge-1")
```

这类表达式可以转成类似：

```sql
WHERE usage > 80 AND host = 'edge-1'
```

但下面这种就不适合第一阶段下推：

```flux
filter(fn: (r) => normalize(r.host) == "edge-1")
```

因为 `normalize` 是 Flux 用户函数，SQL 数据源并不知道它的语义。项目当前宁可 fallback 到内存执行，也不尝试危险翻译。

## Pushdown contract

SQL 生成前有统一 contract 校验。它会确认 projection、predicate、distinct、group、aggregate、sort、limit 等组合是否能被目标 connector 安全执行。

这一步比“能拼 SQL 就拼 SQL”重要得多。查询优化最怕语义漂移：看起来快了，但结果悄悄变错。项目当前宁可保守 fallback，也不把不确定的 Flux 语义硬翻译成 SQL。

## Projection 和 rename 的下推细节

`keep/drop/rename` 下推并不是简单拼 `SELECT` 列表。它还涉及列名映射：后续 Flux 算子看到的是 rename 后的列名，但 connector SQL 可能需要读取原始列名。

因此 pushdown contract 需要维护 assignment：Flux 层列名对应数据源列或表达式。后续 filter/sort/aggregate 如果引用 rename 后的列，就要能映射回正确的 SQL 表达式。

这也是为什么 pushdown 应该有统一 contract 校验。只在每个 builtin 里临时拼 SQL，很快会在 rename + filter + aggregate 组合场景下出错。

## Fallback：旧内存执行器没有被推倒

如果某个后缀不能下推，会 materialize 成 `TableValue`，再复用内存 builtin 执行。例如复杂 `map`、复杂 `filter`、跨源 join、inspect 函数或输出边界，都可能触发 materialization。

这个设计让迁移过程更稳：connector 路径逐步变强，但旧内存执行器仍然是可靠 fallback，而不是被一次性重写。

## Explain 与 Profile

`explain()` 可以展示 logical、optimized logical、physical 或 pipeline plan。pipeline/profile 输出会包含：

- drivers/pages/rows。
- blocking/finished/error。
- connector split pages/rows/bytes/wall time。
- metadata/split/connect/schema/sql/execute/read/decode/page-build 分段耗时。
- accumulator phase、key strategy、partial/final 耗时。
- query memory used/peak/limit。

这些信息对调试 pushdown 是否生效非常重要。没有 explain/profile，优化器很容易变成黑箱。

## 小结

Connector 与 pushdown 让这个项目从“能解释执行 Flux”向“能作为查询引擎处理外部数据”迈出关键一步。当前实现不追求任意 Flux 到 SQL 的翻译，而是坚持保守前缀下推、明确 contract、Page streaming 和可靠 fallback。这个边界决定了项目后续扩展 PostgreSQL、Parquet 或 HTTP 数据源时不会推翻主干。
