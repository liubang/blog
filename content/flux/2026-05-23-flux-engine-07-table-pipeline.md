---
title: Table Pipeline：Flux 查询模型如何落到内存执行
description: "介绍 Flux table stream、TableValue、logical tables、group key，以及 filter/map/group/window/join 等表算子的内存执行语义。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, query-engine, table, cpp]
authors: ["liubang"]
weight: 7
series: ["Flux"]
series_weight: 7
---

Flux 查询真正有意思的地方，不在单个表达式求值，而在 table stream。`filter`、`map`、`group`、`window`、`aggregateWindow`、`join` 这些算子处理的都不是一张普通二维表，而是一组带有 group key 的 logical tables。

这篇文章专门讲 `cpp/pl/flux` 里 table pipeline 的内存执行模型。它是早期 eager interpreter 的核心，也是 connector / physical executor fallback 到 materialized output 时的共同承载格式。理解这一层，后面的 connector pushdown、logical/physical plan 和性能优化才有上下文。

## 一个贯穿全文的查询

先看一个 dashboard 查询。它从 CSV 读入 CPU 数据，按时间过滤，再按主机分组，最后做窗口聚合：

```flux
import "csv"

csv.from(file: "cpp/pl/flux/examples/ops_dashboard/data/cpu_usage.annotated.csv")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T00:05:00Z)
    |> filter(fn: (r) => r.region == "us-west")
    |> group(columns: ["host"])
    |> aggregateWindow(every: 1m, fn: mean, createEmpty: true)
```

从用户角度看，这是一条线性的 pipe。从执行器角度看，每一步都在转换一个 table stream：输入可能包含多张 logical table，输出也可能包含多张 logical table，并且每张表都有自己的 group key、列集合和行集合。

如果把这个模型简化成 `vector<Row>`，很多查询一开始能跑，但会在 `group`、`count`、`first`、`window(createEmpty:)`、`join` 这些地方悄悄错掉。

## TableValue 的角色

当前运行时的核心表值是 `TableValue`。它不是简单的行数组，而是同时承载两个视图：

```cpp
struct TableValue {
    std::string bucket;
    std::vector<std::shared_ptr<ObjectValue>> rows;
    std::vector<TableChunk> tables;
    std::optional<std::string> range_start;
    std::optional<std::string> range_stop;
    std::optional<std::string> result_name;
};
```

其中 `rows` 是 flatten 视图，主要服务 CLI 输出、`findRecord`、`findColumn` 和一些历史路径。`tables` 是语义视图，每个 `TableChunk` 表示一张 logical table：

```cpp
struct TableChunk {
    std::string bucket;
    std::vector<std::string> columns;
    std::shared_ptr<ObjectValue> group_key;
    std::vector<std::shared_ptr<ObjectValue>> rows;
};
```

这个双视图是一个工程折中。早期只用 flatten rows 写 builtin 会很快，但 Flux 的语义不是“全表 + `_group` 标签”。后续要兼容 logical table，不能一次性推翻所有已工作的路径，于是 `TableValue` 同时保留 flatten 视图和 chunk 视图：旧路径可以逐步迁移，新路径优先消费 `tables`。

## 为什么不能只用 `_group` 标签

早期最容易写出的实现是：`group(columns: ["host"])` 给每行加一个 `_group` 对象，后续算子再按这个字段区分。这个方案看起来直觉，但有几个问题。

第一，空表无法表达。过滤后某个 group 没有行，如果只靠 row 上的 `_group` 标签，这张 logical table 会直接消失。但 Flux 里 `filter(onEmpty: "keep")`、`window(createEmpty: true)` 都需要保留空表形状。

第二，selector 和 aggregate 的边界会模糊。`first()`、`last()`、`top()`、`bottom()` 应该逐 logical table 处理。如果只遍历 flatten rows，很容易把不同 group 的行混在一起排序或选择。

第三，join 语义会变形。Flux join 不是把左右两边所有行做笛卡尔过滤，而是先按 group key 实例配对 logical table，再在配对表内匹配 join key。

因此当前实现要求：任何 table builtin 只要涉及分组、窗口、聚合、选择器或 join，都必须优先考虑 `TableValue.tables`。

## Pipe 如何连接表算子

Parser 会保留 `PipeExpr`，不会提前把：

```flux
data |> limit(n: 10, offset: 5)
```

改写成普通函数调用。原因是 pipe 参数注入属于 runtime 语义。builtin 通常约定 pipe 参数名为 `tables`，用户函数则可能显式声明 `<-tables`：

```flux
sample = (<-tables, n=10) => tables |> limit(n: n)
```

运行时调用 builtin 时，如果右侧是命名参数对象，会把左侧值合并进去，形成类似：

```flux
limit(tables: data, n: 10, offset: 5)
```

但这个合并不是 parser 的职责。Parser 只负责表达用户写了 pipe；Evaluator 才知道 callee 是 builtin 还是 user function，pipe 参数应该叫什么，是否允许注入。

这个分层让 formatter/LSP 可以保留用户写法，也让 runtime 能对错误情况给出更准确的诊断，比如“函数不接受 pipe input”。

## Row transform：逐行改写不等于语义简单

`filter`、`map`、`keep`、`drop`、`rename`、`duplicate`、`set` 都可以归为 row transform。它们看起来只是逐行处理，但在 Flux 中仍然要维护 logical table 和 group key。

`filter` 的关键点是 `onEmpty`：

```flux
data
    |> group(columns: ["host"])
    |> filter(fn: (r) => r._value > 80.0, onEmpty: "keep")
```

默认 `onEmpty: "drop"` 会丢弃过滤后为空的 logical table；`onEmpty: "keep"` 则保留空表、列集合和 group key。CLI human 输出会显示 empty logical table，JSON 输出也会保留 chunk metadata。

`map` 的风险更隐蔽。用户函数返回的是一个新 record：

```flux
|> map(fn: (r) => ({r with usage_pct: r._value / 100.0}))
```

如果返回对象删除了 group key 列，后续 group key 是否还有效？如果重命名了 key 列，logical table 的 key 是否也要更新？这些不是 UI 细节，而是查询语义。当前实现优先覆盖常见路径，并把列投影、排序、pivot、group key 处理抽到 `runtime_builtin_table_helpers.h`，避免每个 builtin 自己复制一套不完整逻辑。

## group：真正重分 logical table

`group(columns: ["host"])` 的输出不是原表多了一列，而是 table stream 被重新分区。可以把它理解成：

```text
input table stream
  table 0: rows=[edge-1, edge-2, edge-1]

group(columns: ["host"])

output table stream
  table 0: group_key={host: "edge-1"}, rows=[edge-1, edge-1]
  table 1: group_key={host: "edge-2"}, rows=[edge-2]
```

`mode: "by"` 使用给定列作为 group key；`mode: "except"` 使用“除给定列之外的列”作为 group key。这个细节很重要，因为很多 dashboard 查询会先去掉 `_measurement` 或 `_field` 的分组影响，再 join 两条流。

例如 CPU 和 MEM 两边原本可能有不同 `_measurement`，如果直接 join，group key 实例不相同就不会配对。正确写法通常是先显式 regroup：

```flux
cpu = cpu |> group(columns: ["host", "region"])
mem = mem |> group(columns: ["host", "region"])

join(tables: {cpu: cpu, mem: mem}, on: ["_time", "host"])
```

这个设计让 join 的行为可解释：不是“为什么没有结果”，而是“左右 logical table 的 group key 是否匹配”。

## Empty table 不是边角料

空表在 Flux 里不是异常情况，而是时间序列查询的常态。稀疏数据、窗口边界、selector 函数都会制造空表。

`window(createEmpty: true)` 会在没有数据的窗口里生成空 logical table。`aggregateWindow(createEmpty: true)` 在聚合函数和 selector 函数上还要区分行为：

- 聚合类函数可以为窗口输出聚合结果或空值语义。
- selector 类函数，例如 `first` / `last`，通常会丢弃空窗口。

这就是为什么项目里会有 `cpu_selector_sparse_windows.flux`、`aggregatewindow_advanced.flux`、`window_join_rankings.flux` 这些 examples。它们不是展示用花活，而是在锁定稀疏窗口、空表保留、selector drop-empty 这些高风险语义。

## aggregate 和 selector 的输出形状不同

`count()` 和 `first()` 都可能把一张 logical table 变成一行，但它们语义完全不同。

`count()` 是 aggregate：输出行的 `_value` 是计数结果。`first()` 是 selector：输出行来自原始输入，只是选择了第一行。`top()` / `bottom()` 也是 selector 或 ranking 风格，输出通常保留原始行的更多列。

这个区别会传递到后续算子。比如：

```flux
data
    |> group(columns: ["host"])
    |> first()
    |> keep(columns: ["host", "_time", "_value"])
```

这里 `_time` 来自原始第一行。如果把 `first()` 当成普通 aggregate，只输出 `{_value: ...}`，这个查询就会丢失时间列。

`aggregateWindow` 更复杂，因为它同时处理窗口切分、时间列写回、聚合/selector 输出形状、`timeSrc`、`timeDst`、`period`、`offset` 和 `location`。当前实现已经支持固定窗口、部分 calendar window、负 `period`、`every != period` 的重叠窗口、命名时区和 `timezone` package 返回的 location record。

## Join：先配 table，再配 row

当前实现里，顶层 `join()` 和显式 `import "join"` 的 package API 都遵守一个原则：先按 group key 实例配对 logical table，再在表内匹配行。

旧版 universe 风格：

```flux
join(tables: {cpu: cpu, mem: mem}, on: ["_time", "host"], method: "inner")
```

package 风格：

```flux
import "join"

join.inner(
    left: cpu,
    right: mem,
    on: (l, r) => l._time == r._time and l.host == r.host,
    as: (l, r) => ({_time: l._time, host: l.host, cpu: l._value, mem: r._value}),
)
```

列数组形式会处理重名列。非 `on` 的重复列默认按 `<column>_<table>` 输出，例如 `_value_cpu`、`_value_mem`。新补的 `leftName` / `rightName` 可以控制后缀：

```flux
join.inner(
    left: cpu,
    right: mem,
    on: ["_time", "host"],
    leftName: "cpu",
    rightName: "mem",
)
```

predicate + `as` 风格则把输出形状交给用户函数，适合更接近官方 `join` package 的写法。outer join 会用 null row 填充缺失一侧，因此 `as` 函数必须能接受缺失字段或 null 值。

## Window 与 location

窗口边界不能只用字符串比较。当前实现会解析 RFC3339 时间，按秒级时间戳计算边界。固定 duration 窗口比较直接，calendar window 则要处理月份、年份、时区和 DST。

`location` 的输入是一个 record：

```flux
{zone: "America/Los_Angeles", offset: 0s}
```

现在也可以通过 `timezone` package 构造：

```flux
import "timezone"

option location = timezone.location(name: "America/Los_Angeles")
```

如果 `aggregateWindow` 没有显式传 `location`，运行时会查找全局 `option location`。这让任务类查询可以把时区配置放在 option 层，而不是每个窗口函数都重复传参。

## CLI 输出为什么也属于语义边界

表流执行完成后，CLI 输出不是随便打印 rows。human、annotated CSV、JSON 都需要表达 logical table 信息。

human 输出会显示 logical table 数量和 empty table。annotated CSV 会按逻辑表输出 `#datatype`、`#group`、`#default` 和 header。JSON 输出则包含：

- `columns`：当前 logical table 的列集合。
- `group`：与 columns 对齐的布尔数组，表示哪些列属于 group key。
- `groupKey`：结构化 group key record。
- `rows`：该 logical table 的行。

这就是为什么输出层也有单元测试。输出格式一旦丢掉 logical table metadata，CLI 看起来还能打印表，但用户已经无法判断 group/window/join 的真实结果结构。

## 内存执行的价值与边界

引入 connector pushdown 和 Page-based physical executor 后，`TableValue` 仍然不能消失。它有几个稳定职责：

- `array.from` 和 `csv.from` 小数据输入直接构造内存表。
- 复杂 `map`、复杂 `filter`、跨源 join 等不能下推的操作需要 materialized fallback。
- `columns`、`keys`、`findColumn`、`findRecord` 这类 inspect helper 直接消费表流。
- CLI 输出、JSON/CSV 序列化和 conformance examples 需要稳定 materialized 结果。
- 单元测试需要便宜、确定、无外部依赖的 fixture。

但 `TableValue` 不适合作为大表扫描的全程数据通道。SQLite/MySQL 路径已经把 scan/filter/project/range、部分 Top-N、group aggregate 推到 connector / Page pipeline。这个边界可以概括为：小数据、调试、fallback 和输出用 `TableValue`；大数据、可下推前缀和 blocking operator 优先走 plan/page/executor。

## 测试如何锁住语义

Table pipeline 的测试不能只测单个函数返回值。更重要的是组合语义：

- `runtime_eval_unit_test.cpp` 覆盖表达式级 table builtin。
- `runtime_exec_unit_test.cpp` 覆盖文件级 pipe、import、yield 和多结果。
- `flux_cli_unit_test.cpp` 覆盖 human/CSV/JSON 输出是否保留 logical table metadata。
- `examples/feature_gallery` 和 `examples/ops_dashboard` 覆盖真实查询组合。
- `examples/stdlib_conformance` 用快照约束每个已实现 builtin 的主行为。

最近补的几个点也属于这类语义锁定：`timezone` location 参与 `aggregateWindow`、JSON 输出暴露 `group` flags、join package 的 `leftName/rightName`、运行时错误带 statement source location。这些看起来不大，但都是“组合查询可解释性”的一部分。

## 下一篇

下一篇会把数据源从内存推到 SQLite/MySQL，讲 connector runtime、pushdown contract、split/page source 和 fallback 边界。

## 小结

Table pipeline 是 `cpp/pl/flux` 查询语义的脊梁。`TableValue` 的双视图让项目能在 eager interpreter、fallback、inspect 和 CLI 输出之间共享一个稳定表示；`TableChunk` 和 group key 则让 `group`、empty table、aggregateWindow、selector 和 join 不退化成普通行数组操作。

后续性能优化不会推翻这一层，而是把它放在正确的位置：小数据和结果边界继续 materialize，大数据扫描和可下推前缀交给 connector runtime、logical/physical plan 和 Page streaming。下一篇讲 connector 与 pushdown 时，这个边界会继续发挥作用。
