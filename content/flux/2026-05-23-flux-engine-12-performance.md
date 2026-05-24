---
title: 性能优化：从解释执行到查询下推
description: "介绍 Flux 查询引擎的性能热点、内存执行成本、Page streaming、connector pushdown、two-stage accumulator 和 benchmark 方法。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, performance, query-engine, benchmark, cpp]
authors: ["liubang"]
weight: 12
series: ["Flux"]
series_weight: 12
---

性能优化不能脱离架构。`cpp/pl/flux` 早期是 eager interpreter，所有数据尽量变成 `TableValue`，再由 builtin 一步步处理。这条路径简单、可测、适合小数据，也非常适合把语言语义先跑通。

但查询引擎一旦开始面对 SQLite/MySQL、大表 scan、group aggregate、top-n、join 和 profile，性能问题就不再是“某个函数慢一点”。真正的瓶颈往往来自执行模型：整表 materialization、row object 中间态、重复 key 构造、connector 读了太多列、blocking operator 没有内存边界。

这一篇讲 Flux 性能优化的主线：先用 profile 定位瓶颈，再把热路径从 `TableValue` 推向 Page streaming，通过 connector pushdown 减少数据移动，用 partial/final accumulator 降低 root 阶段压力，最后用 benchmark 固定同机同口径的比较方法。

## 一条查询背后的成本

先看一条典型查询：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r.region == "west" and r._value > 80.0)
    |> keep(columns: ["_time", "host", "_value"])
    |> group(columns: ["host"])
    |> mean(column: "_value")
    |> sort(columns: ["_value"], desc: true)
    |> limit(n: 10)
```

它看起来只是几行 pipe，但执行时至少有几类成本：

- source scan：SQLite 打开表、生成 SQL、读取 rows。
- decode/build：把外部数据转成 runtime 能消费的 Page 或 row。
- filter/project：丢弃无用行和无用列。
- group key：构造 group key、hash、查找 accumulator state。
- aggregate update：更新 count/sum/min/max 等状态。
- top-n：维护 heap 或排序结果。
- output：把结果转成 JSON/CSV/human 格式。

如果所有数据先进入 `TableValue`，这些成本会被 row object 构造和 materialization 放大。比如 filter 本来可以在 SQLite 的 `WHERE` 里完成，projection 本来可以减少读取列，group aggregate 本来可以逐 Page 吸收，但 eager 路径会先把很多本不该进入 runtime 的数据搬进来。

性能优化的第一步不是写更快的循环，而是确认数据有没有在正确层级被处理。

## 性能热点在哪里

当前项目的热点大致分成几类：

- parser/evaluator 的重复工作。
- table pipeline 中 row/object 的构造和拷贝。
- `group/distinct/aggregate` 的 key 构造、hash 和 state update。
- `sort/topN/join/materialize` 这类 blocking operator。
- connector metadata、split discovery、SQL 执行、协议 decode 和 page build。
- Page 流转回 `TableValue` 的 materialize boundary。
- CLI output formatter 的 JSON/CSV/human 序列化成本。

这些热点分布在不同层。前端重复 parse 是 LSP 和 CLI 的问题；row/object 拷贝是内存执行器问题；split、SQL、decode 是 connector 问题；accumulator 和 top-n 是 physical pipeline 问题。把所有慢都归因于“C++ 不够快”没有意义。

更重要的是，不同查询的瓶颈不同。`filter_project` 可能主要受 pushdown 和 page source 影响；`group_count` 可能主要受 key/hash/update 影响；`pivot_wide` 可能死在宽表对象属性更新；远程 MySQL scan 可能慢在网络和协议 decode。

## 先 Profile，再优化

性能优化最怕凭感觉。

看到一个查询慢，至少要分几层看：

- CLI 总耗时：用户看到的端到端延迟。
- explain plan：算子有没有下推，是否插入 materialize。
- pipeline profile：drivers、pages、rows、blocking、finished、error。
- connector split profile：pages、rows、bytes、wall time。
- connector phase profile：metadata、split、connect、schema、sql、execute、read、decode、page-build。
- accumulator profile：input rows、output rows、groups、key/hash/update/result build、partial/final。
- query memory：used、peak、limit、limited。

没有这些指标时，优化很容易走偏。例如 `group_count` 慢，直觉可能会去优化 count 自身；但真实瓶颈可能是整表 row-object materialization，或者 string key 构造，或者 final 阶段吞了所有 split 输出。

Profile 的作用不是把数字堆出来，而是给出下一步优化位置。如果 split read 很慢，就看 connector；如果 key/hash 很高，就看 group key 表示；如果 pages 很少但 wall time 很高，可能是 blocking operator；如果 materialize 出现在不该出现的地方，说明执行计划退回了旧路径。

## 从 TableValue 到 Page

`TableValue` 是 Flux table stream 的自然表示。它能表达多 logical table、group key、rows、tables 和输出边界，非常适合把语义先实现正确。

但它不是高吞吐路径的理想跨层格式。每一行都变成 object，意味着字段查找、属性向量、字符串列名、Value 包装、对象复制都会进入热路径。对小数据没问题，对百万行 scan 或 grouped aggregate 就很贵。

Page-based execution 把 operator 之间的主通道改成：

```text
Page
  -> PageChunk
      -> ColumnVector
```

这样 scan/filter/project/range 可以逐 Page streaming，connector page source 可以直接把外部数据写成列向量，accumulator 可以从 Page 中批量吸收输入，exchange 可以传递 Page 而不是散碎 row。

Page 化的收益主要来自三点：

- 减少 row object 中间态。
- 批量处理降低函数调用和分配成本。
- 为后续 typed vector、SIMD、批量 decode 留接口。

它不是为了抽象而抽象。只要中间某个环节无理由 materialize 成 `TableValue`，整个 streaming 主干就被打断了。

## Page 化的边界

Page 化也不是要消灭 `TableValue`。

这些场景仍然适合或必须 materialize：

- CLI/JSON/CSV/human 输出。
- `yield` 结果收集。
- inspect helper，例如 `findRecord`、`findColumn`。
- 不支持 lazy/Page 的旧 builtin fallback。
- 复杂用户函数、动态对象构造、跨源 join。
- 调试和小规模 conformance 示例。

性能优化的关键不是把所有东西都 Page 化，而是让 materialize 成为显式边界。只要 explain/profile 能看到这个 boundary，用户和开发者就能判断它是合理 fallback，还是性能退化。

这也是第 08 篇强调 physical plan 的原因。一个查询是否走 Page pipeline，不应该由某个 builtin 随手决定，而应该在 physical planning 阶段明确表达。

## Connector Pushdown 的收益

SQLite/MySQL 的保守 pushdown 是最直接的性能来源之一。

能在数据源执行的前缀，就尽量不要搬到 runtime：

- `range` 变成 `_time` 约束。
- simple `filter` 变成 SQL predicate。
- `keep/drop` 变成 projection pruning。
- `rename` 维护 column assignment。
- `sort/limit` 在安全时变成 order/top-n。
- 简单 `group |> count/sum/mean/min/max` 可以进入 aggregate pushdown。

Pushdown 的收益常常不是“数据库算得更快”这么简单，而是减少数据移动：

- filter 下推后，被过滤掉的行不需要 decode。
- projection 下推后，不需要读取无用列。
- limit 下推后，page source 可以更早结束。
- aggregate 下推后，runtime 不需要吸收全量输入。
- 对 MySQL 来说，网络传输和协议 decode 都会减少。

但 pushdown 不能牺牲语义。复杂 Flux 函数、正则/字符串函数、跨源 join、不确定 group/window 语义都应该 fallback。性能优化的底线是结果正确。

## Pushdown 与 Split 必须一起看

Pushdown 和 split planning 不能分开。

比如：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> sort(columns: ["_time"])
    |> limit(n: 10)
```

如果每个 split 都执行 `ORDER BY _time LIMIT 10`，然后直接拼起来，结果不是全局前 10 行。正确策略要么 single split，要么 split 内 partial top-n，再由 root pipeline 做 global top-n。

同理，`distinct/group/aggregate` 如果分 split 执行，就必须考虑 partial/final 合并。否则局部结果看起来对，全局语义会错。

所以性能优化不能只说“多 split 更快”或“下推更多更快”。split 是并行策略，global merge 才是语义保证。Profile 也要能告诉我们 drivers 数量、split pages/bytes/wall time、root pipeline 是否 blocking。

## Two-stage Accumulator

`group/distinct/aggregate` 是查询引擎里最值得优化的路径之一。旧路径如果先把输入 materialize 成 row object，再按字符串 group key 聚合，成本会非常高。

当前高基数 `group |> aggregate`、root `group` 和 root `distinct` 可以走 partial/final 两阶段：

```text
split driver: Page -> partial accumulator -> partial Page
root driver:  partial Page -> final accumulator -> result Page
```

这一刀的收益来自两个方向。

第一，输入逐 Page 被吸收到 accumulator state，不再需要整表 row-object 中间态。

第二，root 阶段处理的是 partial 结果，而不是原始 100 万行。低基数 group 场景尤其明显：每个 split 可能只输出几十个 group，root final 合并的数据量会小很多。

Benchmark 里有一个很有代表性的结果：1M rows 的 `group_count`，旧路径曾经在二十多秒量级，Page-native two-stage grouped accumulator 的 release baseline 约 `0.094s`。这不是某个小函数快了 200 倍，而是执行形态从整表 materialization 变成了流式 partial/final。

## Two-stage 也有代价

两阶段聚合不是免费午餐。

Partial 阶段要维护每个 split 的 hash state，final 阶段要合并 partial 输出。如果 group 基数很低，它通常非常划算；如果 group 基数接近行数，partial 输出仍然很大，hash table 和内存压力也会升高。

所以不能只看总耗时，还要看 accumulator profile：

- `accumulator_input_rows`
- `accumulator_output_rows`
- `accumulator_groups`
- `accumulator_key_ms`
- `accumulator_hash_ms`
- `accumulator_update_ms`
- `accumulator_result_build_ms`
- `accumulator_partial_input_rows`
- `accumulator_final_input_rows`

如果 key/hash 耗时占比很高，下一步可能要优化 typed key/hash state；如果 final input rows 很高，可能需要更好的 partition strategy；如果 result build 很高，可能是输出 Page 构造或 Value 转换成本。

性能优化要避免把“一个 benchmark 变快”误读成“所有场景都变快”。两阶段策略需要和 cardinality、driver 数、memory limit 一起看。

## Typed Key 与字符串成本

Flux 的很多表操作都绕不开 key：group key、join key、pivot row identity、distinct key、window bucket key。

早期实现里，为了简单，很多 key 会被序列化成字符串。这样容易调试，也容易放进 `unordered_map`，但热路径上会带来大量分配、拼接和比较成本。

优化方向有两类：

- 减少重复构造：预建 `unordered_set`，复用列名，直接往目标 buffer 写。
- 避免字符串化：用 typed key/hash state 保存列值类型和 hash。

这类优化不如 connector pushdown 那么显眼，但对 `group/pivot/join` 很关键。比如宽表 `pivot` 中，重复构造 pivot 列名、每次更新都线性扫描输出属性，都会在字段基数变宽后迅速放大。

性能文章里最该警惕的就是“看上去只是字符串”。在查询引擎里，字符串 key 往往就是热点。

## Top-N 与 Blocking Boundary

`sort |> limit` 是另一个典型例子。

全量 sort 的成本很高，而且必须看到所有输入才能输出。Top-N 可以把它改成 heap 维护前 N 个元素，进一步在 multi-split 场景中做两阶段：

```text
split driver 0: scan -> partial topN(10) -> exchange
split driver 1: scan -> partial topN(10) -> exchange
root driver: exchange -> global topN(10) -> output
```

这样 root 阶段不需要处理所有原始行，只需要处理各 split 的候选集。

但 top-n 仍然是 blocking boundary。它不是普通 streaming transform。它需要内存预算，需要 profile 标出 blocking，需要在 root 阶段保证全局语义。

这类优化的正确姿势是：承认 blocking，然后缩小 blocking 输入规模，而不是假装它可以无状态 streaming。

## Memory 比平均耗时更重要

性能不只是平均耗时。

对查询引擎来说，内存峰值往往比均值更危险。`sort`、`join`、`distinct`、高基数 `group`、`pivot_wide` 都可能积累大量状态。一次 benchmark 的 median 很好看，不代表大输入下不会打爆内存。

当前项目选择 query 级 memory context：

- `query_memory_used_bytes`
- `query_memory_peak_bytes`
- `query_memory_limit_bytes`
- `query_memory_limited`

暂不实现 spill。超过预算时，blocking query 返回 `ResourceExhausted`。

这个策略保守，但边界清楚。Spill 不是在某个 sort 里临时写个文件那么简单，它会影响 external sort、join、aggregate、resource manager、profile、错误恢复和测试。等 Page pipeline、memory accounting 和 blocking boundary 更稳定后，再做 spill 才不会把复杂度压到错误层。

## Connector 成本不是只有 SQL

对 SQLite/MySQL 来说，SQL 执行只是成本的一部分。

Connector profile 至少要拆出：

- metadata：表结构、统计信息、capability。
- split：rowid/range split discovery。
- connect：连接建立或连接池取连接。
- schema：列类型解析。
- sql：SQL 生成和准备。
- execute：执行语句。
- read：从数据源读取 batch。
- decode：协议或 SQLite value 解码。
- page-build：写入 Page/ColumnVector。

SQLite 是本地文件，很多成本集中在本地扫描和 page build。MySQL 是远端服务，网络、连接池、prepared statement、协议 decode 都可能成为瓶颈。

所以 MySQL 优化不能只盯 SQL 文本。`rows_per_page`、目标 split 数、连接池、range split、prepared statement 与 direct connection 路径，都会影响 profile。没有分段 profile，就很难知道是数据库慢，还是 runtime decode 慢。

## Benchmark 的正确打开方式

项目里的 benchmark 分三类：

- 内存执行基准：`run_benchmarks.py` 生成 annotated CSV，覆盖 table builtin、window、pivot、join 等。
- SQLite connector scan：临时构造真实 SQLite 表，覆盖 multi-split page source、Page sink、Top-N、group/distinct accumulator。
- MySQL connector scan：读取真实 MySQL 表，覆盖 range split、Boost.MySQL page source、远端服务和协议 decode。

运行内存基准：

```bash
bazel build //cpp/pl/flux:flux
python3 cpp/pl/flux/benchmark/generate_benchmark_data.py
python3 cpp/pl/flux/benchmark/run_benchmarks.py
```

运行 SQLite connector baseline：

```bash
python3 cpp/pl/flux/benchmark/run_connector_benchmarks.py \
  --build \
  --bazel-config release \
  --connector sqlite \
  --sqlite-rows 1000000 \
  --warmup 1 \
  --repeat 3 \
  --output /tmp/flux_sqlite_baseline.json
```

做回归对比：

```bash
python3 cpp/pl/flux/benchmark/run_connector_benchmarks.py \
  --connector sqlite \
  --sqlite-rows 1000000 \
  --warmup 1 \
  --repeat 3 \
  --compare-baseline /tmp/flux_sqlite_baseline.json \
  --regression-threshold 0.10
```

这些数字默认只用于同机同口径前后对比。不同机器、不同 release/debug 配置、冷热缓存、远程 MySQL 网络条件都不能直接比较。

正式解读时优先看 median，不要看单次最好值；同时看 samples 是否稳定。如果 samples 抖动很大，先找环境噪音，不要急着给代码下结论。

## 读 Benchmark 不要只看秒数

一个健康的 benchmark 输出，应该能回答“为什么这个秒数是这样”。

比如 SQLite 1M rows，8 drivers，release build 的一组 baseline 里：

- `scan` 输出 1M rows，约 984 pages。
- `filter_project` 输出 50 万 rows，约 496 pages。
- `topn` 输出 100 rows，只有少量 pages，但它是 blocking。
- `group_count/group_sum/group_mean` 输出 64 rows，最终输出前只交换 partial pages 和 final page。

这些信息比单个 seconds 更重要。`topn` 快，不代表它 streaming；它快是因为 partial top-n 缩小了 root 输入。`group_count` 快，不代表 group 没成本；profile 里 key/hash/update 仍然是主要开销。`filter_project` 快，说明 pushdown 和 projection 减少了 decode 和 runtime 处理。

性能结论要带着 plan/profile 一起说，不能只贴一个耗时数字。

## 不做什么也很重要

性能优化里，“暂时不做”也是设计。

当前几个边界很明确：

- 不为了快而下推不确定 Flux 语义。
- 不伪造成熟 CBO；缺 statistics 时退化为 RBO。
- 不做 spill；超过 memory budget 返回 `ResourceExhausted`。
- 不把 raw SQL API 当作 pushdown 替代品。
- 不让 benchmark 单次数字替代 correctness test。
- 不把所有旧 builtin 一次性重写成 Page-native。

这些边界让优化节奏更慢，但也更稳。查询引擎最怕的是“快但不确定”。一旦用户不能相信结果，性能数字就没有意义。

## 后续优化方向

后续值得继续推进的方向包括：

- 进一步减少 `Value` / object row 拷贝。
- 更多 table transform 的 Page-native 实现。
- metadata/statistics 缓存。
- MySQL page source decode 路径优化。
- typed key/hash state 继续细化。
- 高基数 group 的 partition/final 策略。
- 更细的 memory accounting 和 blocking profile。
- parser/LSP incremental parse。
- workspace index 缓存。
- benchmark baseline 纳入回归门禁。

这里面最有价值的不是某一个单点，而是形成持续闭环：profile 发现问题，设计选择正确层级，测试锁住语义，benchmark 复验趋势，文档记录原因。

## 下一篇

下一篇是系列收束，会把当前能力、技术边界和后续路线图放在一张更完整的工程蓝图里。

## 小结

Flux 的性能演进不是单点微优化，而是执行模型升级：从 eager `TableValue` 到 lazy plan，从全量 materialization 到 Page streaming，从单阶段聚合到 partial/final accumulator，从盲目执行到 connector pushdown，从单次耗时到 plan/profile/benchmark 的组合判断。

这条路比“哪里慢改哪里”更慢，但结构更稳。它让每一次性能变化都能被解释：少读了哪些列，少解码了多少行，少 materialize 了哪个边界，partial/final 把 root 输入缩小到多少，memory peak 是否还安全。对查询引擎来说，能解释的性能，才是可以长期维护的性能。
