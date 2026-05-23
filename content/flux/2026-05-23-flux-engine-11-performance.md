---
title: 性能优化：从解释执行到查询下推
description: "介绍 Flux 查询引擎的性能热点、内存执行成本、Page streaming、connector pushdown、two-stage accumulator 和 benchmark 方法。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, performance, query-engine, benchmark, cpp]
authors: ["liubang"]
weight: 11
series: ["Flux"]
series_weight: 11
---

性能优化不能脱离架构。`cpp/pl/flux` 早期是 eager interpreter，所有数据尽量变成 `TableValue` 再由 builtin 处理。这条路径简单、可测、适合小数据，但对于 SQLite/MySQL 这类外部表扫描，全量 materialization 很快会成为瓶颈。

## 性能热点在哪里

当前项目的性能热点大致分几类：

- parser/evaluator 的重复工作。
- table pipeline 中 row/object 的构造和拷贝。
- group/distinct/aggregate 的 key 构造和 hash。
- sort/topN/join 这类 blocking operator。
- connector metadata、split discovery、SQL 执行、协议解码和 page build。
- materialize boundary 把 Page 流转回 `TableValue` 的成本。

不同阶段的优化重点不同。语言前端更关注避免重复 parse；执行引擎更关注数据通道和内存布局；connector 更关注下推和流式读取。

## 先定位瓶颈，再选择优化层

性能问题不能只看总耗时。一个查询慢，可能慢在 parser 重复解析，可能慢在 CSV decode，可能慢在 SQLite page source，也可能慢在 group key hash 或最终 materialization。

所以 profile 需要分层：

- CLI 总耗时适合观察用户体验。
- connector split profile 适合观察读数据成本。
- pipeline profile 适合观察 driver、page、row 和 blocking 状态。
- accumulator profile 适合观察 key 构造、hash、update、result build。
- query memory profile 适合观察 blocking operator 风险。

没有这些分层指标时，优化很容易变成猜测。比如看到 `group_count` 慢，真正瓶颈可能不是 count，而是把所有输入先 materialize 成 row object。

## 从 TableValue 到 Page

`TableValue` 很适合表达 Flux table stream，但不是高吞吐扫描的理想跨层数据格式。Page-based execution 使用 `Page`、`PageChunk`、`ColumnVector` 作为 operator 之间的主通道，可以减少 row object 中间态。

当前 scan/filter/project/range 和 root exchange 已经可以逐 Page 执行。group/distinct/aggregate 是 streaming accumulator：输入逐 Page 吸收，最终产出结果。

这意味着很多查询不再需要先把 100 万行全部拼成对象数组，再做聚合。

## Page 化不是为了抽象而抽象

Page 的价值在于批量和列式边界。即使内部还不是完整列式执行，只要 operator 之间按 Page 传递，就可以减少函数调用次数、降低对象分配压力，并为后续 SIMD、向量化或批量 decode 留空间。

更重要的是，Page 是 connector 和 executor 之间的共同语言。SQLite/MySQL page source 读出 Page，filter/project operator 消费 Page，accumulator 吸收 Page，sink 输出 Page。如果中间某个环节回到 `TableValue`，整个流式主干就被打断。

当然，Page 化也会提高实现复杂度。小数据、调试输出和复杂 fallback 仍然可以 materialize 成 `TableValue`。性能优化不是消灭 `TableValue`，而是让它出现在正确边界。

## Connector Pushdown

SQLite/MySQL 的保守 pushdown 是最直接的性能来源。能在数据源执行的 filter、projection、sort、limit、distinct 和简单 aggregate，就不要搬到运行时再做。

但 pushdown 不能牺牲语义。复杂 Flux 函数、跨源 join、不确定 group/window 语义都应该 fallback。性能优化的底线是结果正确。

## 下推收益来自减少数据移动

很多时候 pushdown 的收益不只是数据库执行更快，而是减少了数据移动和 runtime 解码成本。

例如 `keep(columns:)` 下推后，connector 不必读取不需要的列；`filter` 下推后，runtime 不必解码被过滤掉的行；`limit` 下推后，page source 可以更早结束。对于远程 MySQL，网络传输和协议 decode 成本也会明显下降。

但如果下推导致 split 失效或破坏全局语义，收益就不成立。因此 pushdown 和 split planning 必须一起看。

## Two-stage accumulator

高基数 grouped aggregate、root group 和 root distinct 已经可以走 partial/final 两阶段。split 内先做 partial，root 再合并 partial 结果。

这类优化的收益非常明显。benchmark 文档中记录过，1M rows 的 `group_count` 从旧路径的二十多秒降到 release baseline 约 0.1 秒量级。核心原因不是某个小函数快了，而是数据通道从整表 row-object materialization 转成了 Page-native accumulator，并减少了 final 阶段输入规模。

## partial/final 的代价

两阶段聚合不是免费午餐。partial 阶段需要为每个 split 维护状态，final 阶段需要合并 partial 输出。如果 group 基数很低，这通常很划算；如果 group 基数接近行数，partial 输出可能仍然很大，hash 和内存成本也会上升。

所以 profile 里要看 partial input rows、partial output rows、final input rows、groups、key/hash/update 耗时。只看总耗时，很难判断下一步应该优化 key 构造、hash table、page decode 还是 final merge。

## Top-N 与 blocking boundary

`sort |> limit` 如果全量排序，成本很高。当前 Top-N 可以两阶段执行：split 内做 partial Top-N，root pipeline 再做全局 heap Top-N。这可以显著减少 root 阶段需要处理的数据量。

但 sort/topN 仍然是 blocking boundary。优化的关键是承认它 blocking，并在 profile、memory context 和 executor 中明确表达，而不是假装它是普通 streaming transform。

## 内存预算比平均耗时更重要

blocking operator 的风险不只在慢，还在内存峰值。sort、join、distinct、高基数 group 都可能积累大量状态。平均耗时看起来稳定，不代表线上或大输入下安全。

当前项目选择超过预算直接 `ResourceExhausted`，暂不做 spill。这个策略比较保守，但语义清楚。等执行主干和 memory accounting 更稳定后，再考虑外部排序或落盘会更稳。

## Benchmark 方法

项目中的 benchmark 分三类：

- 内存执行基准：覆盖 table builtin、window、pivot、join 等。
- SQLite connector scan：构造真实 SQLite 表，覆盖 multi-split page source、Page sink、Top-N、group/distinct accumulator。
- MySQL connector scan：读取真实 MySQL 表，覆盖 range split、Boost.MySQL page source 和远程协议成本。

benchmark 输出 median、mean、samples，也会输出 drivers、pages、rows、split bytes、wall time、accumulator 分段耗时和 query memory。正式比较时必须同机、同数据、同构建配置、同 warmup/repeat 口径。

## 不做什么也很重要

当前不实现 spill。blocking operator 超过查询内存预算时返回 `ResourceExhausted`。这比仓促做一个不完整 spill 更稳，因为 spill 会影响 sort、join、aggregate、resource manager 和 profile，不能只在单点补一个临时文件。

当前 CBO 也不伪造精确 cost。缺 statistics 时退化为 RBO。优化器最重要的是可解释和可回归，不能为了“看起来智能”引入不可预测选择。

## 后续优化方向

后续值得做的方向包括：

- 进一步减少 `Value` / object row 拷贝。
- metadata/statistics 缓存。
- MySQL page source 解码路径优化。
- typed key/hash state 继续细化。
- 更细的 memory accounting。
- parser/LSP incremental parse。
- workspace index 缓存。
- benchmark baseline 纳入回归门禁。

## 小结

这个项目的性能演进不是单点微优化，而是执行模型升级：从 eager `TableValue` 到 lazy plan，从全量 materialization 到 Page streaming，从单阶段聚合到 partial/final accumulator，从盲目执行到 connector pushdown。这样的优化路径更慢，但结构更稳，也更容易解释每一次性能变化来自哪里。
