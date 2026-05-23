---
title: Table Pipeline：Flux 查询模型如何落到内存执行
description: "介绍 Flux table stream、TableValue、logical tables、group key，以及 filter/map/group/window/join 等表算子的内存执行语义。"
date: 2026-05-23
categories: [programming]
tags: [flux, query-engine, table, cpp]
authors: ["liubang"]
draft: true
---

Flux 查询的核心不是单个表达式，而是 table stream。`filter`、`map`、`group`、`window`、`join` 这些操作都围绕表流展开。`cpp/pl/flux` 的内存执行路径以 `TableValue` 为中心，它既服务早期 eager interpreter，也作为 physical execution fallback 和最终输出 materialization 的承载格式。

## TableValue 的角色

`TableValue` 不是简单的 `vector<row>`。它需要表达 Flux 的逻辑表流：

- bucket 或来源信息。
- flatten 后的 rows，方便部分旧路径读取。
- 多个 logical table。
- 每个 logical table 的 group key。
- result name。

这种设计来自 Flux 的语义：`group(columns:)` 之后，输入不是“多了一列 group id”，而是真的被划分成多张逻辑表。后续 `count()`、`first()`、`last()`、`top()`、`bottom()` 都应该按逻辑表分别计算。

## Row 和 logical table 的双视图

`TableValue.rows` 是 flatten 视图，方便输出、inspect 和一部分旧路径直接访问。`TableValue.tables` 才是承载 Flux 语义的主视图：每个 logical table 有自己的 rows、group key 和 table id。

早期如果只保留 flatten rows，很容易把 `group` 做成“给每行打一个 `_group` 标签”。这种做法在简单展示时看起来可用，但一遇到 `count()`、`first()`、`join()`、`window(createEmpty:)` 就会出问题。因为这些算子的语义不是按 `_group` 列过滤，而是按 logical table 边界分别执行。

因此后续新增 table builtin 时，要优先思考它是否应该逐 logical table 执行。如果是，就不能只遍历 flatten rows。

## Pipe 如何连接表算子

典型查询：

```flux
csv.from(file: "cpu.annotated.csv")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r._value > 80)
    |> group(columns: ["host"])
    |> count()
```

从 runtime 看，pipe-forward 把左侧表值注入右侧 builtin 的 `tables` 参数。每个表算子返回新的 `TableValue`，继续被下一段 pipe 消费。

## Pipe 参数和普通参数的合并

Pipe 表达式执行时有一个细节：右侧调用可能已经有显式参数，左侧值需要合并进去。

例如：

```flux
data |> limit(n: 10, offset: 5)
```

runtime 需要把它变成类似 `{tables: data, n: 10, offset: 5}` 的参数对象。对于用户函数，如果声明的是 `<-tables`，则要绑定到对应参数名；如果函数不接受 pipe 参数，就应该报出可理解的错误。

这就是 parser 不应该提前把 pipe 脱糖成普通 call 的原因。注入规则依赖 callee 的参数模型，属于 runtime/analyzer 层语义。

## Row transform

`filter`、`map`、`keep`、`drop`、`rename`、`duplicate`、`set` 属于常见 row transform。

`filter` 对每行调用用户传入的 `fn`，返回 true 的保留。它还支持 `onEmpty: "keep"`，可以保留过滤后变空的逻辑表形状。

`map` 把每行映射成新对象。这个操作看似简单，但会影响列集合、group key 和后续输出形状，因此需要小心处理 record 返回值。

`keep/drop/rename` 属于列投影或列改写。它们在 SQL connector 上也具备下推潜力，所以后续在 lazy path 中会被翻译为 logical node，而不是永远只在内存里执行。

## 保持 chunk 和 group key 的语义

很多 transform 看起来只是改 row，但实际上会影响 group key。比如 `drop(columns:)` 删除了 group key 中的列，后续 logical table 的 key 就必须同步调整。`rename(columns:)` 如果改了 key 列名，也要更新 key。`map(fn:)` 如果返回对象不包含原来的 key 列，则 group key 可能失效。

当前实现优先保证常见路径行为稳定，复杂边界仍需要持续补测试。这里的难点是 Flux 的表流语义比普通 DataFrame 更严格：group key 是查询语义的一部分，不只是输出 metadata。

因此 table helper 的价值不仅是少写循环，而是把“逐表遍历、行变换、列投影、group key 更新、空表保留”这些重复语义统一起来。

## group 的语义

`group(columns: ["host"])` 会按指定列重分表。`mode: "by"` 表示使用给定列作为 group key；`mode: "except"` 表示排除给定列后，其余列作为 group key。

这一步对后续聚合影响很大：

```flux
data
    |> group(columns: ["host"])
    |> count()
```

输出应该是每个 host 一行，而不是全表一个 count。项目当前已经按 logical table 逐表执行 selector 和 aggregate，不再依赖旧式 `_group` 标签模拟。

## empty table 不是边角料

`filter`、`window`、`aggregateWindow` 都会遇到 empty table。官方 Flux 对空表有明确语义，例如 `filter` 默认 drop empty table，但可以通过 `onEmpty: "keep"` 保留；`aggregateWindow(createEmpty: true)` 会生成空窗口；selector 风格函数通常会丢弃空窗口。

这些行为如果不实现，很多 dashboard 类查询会在稀疏数据上出错。项目的 ops dashboard examples 专门覆盖了 sparse windows、createEmpty、selector empty window 等路径，就是为了防止这类语义退化。

## 聚合与选择器

聚合函数包括 `count`、`sum`、`mean`、`min`、`max`、`spread`、`quantile`、`median`、`reduce`、`distinct` 等。

选择器包括 `first`、`last`、`top`、`bottom`。它们和普通聚合的差异在于会返回原始行或排序后的行，而不是简单产生一个数值。

`aggregateWindow` 则把窗口拆分和聚合结合起来。当前实现支持固定时长窗口、部分 calendar window、`offset`、`period`、`timeSrc`、`timeDst`、`location`、`createEmpty` 等一批常用路径；selector 风格的 `first/last` 会丢弃空窗口。

## aggregate 和 selector 的输出形状不同

聚合通常把一张 logical table 压成一行或少量行，输出值写入目标列。选择器则返回符合条件的原始行。比如 `count()` 和 `first()` 都可能输出一行，但语义完全不同：`count()` 的 `_value` 是数量，`first()` 的 `_value` 来自原始第一行。

这会影响后续 join 和 pivot。如果输出列、时间列、group key 处理不一致，单个函数测试可能过，但组合查询会坏。项目中的 `selection_and_reduce.flux`、`window_join_rankings.flux` 这类示例就是用组合路径检查这些输出形状。

## Join 与多表语义

Flux join 不是简单把两个 flatten rows 做笛卡尔过滤。当前实现会按相同 group key 实例配对逻辑表，不同 measurement 或 field 的聚合结果通常需要先显式 regroup 再 join：

```flux
cpu = cpu |> group(columns: ["host", "region"])
mem = mem |> group(columns: ["host", "region"])

join(tables: {cpu: cpu, mem: mem}, on: ["_time", "host"])
```

重复非 `on` 列会按官方风格加后缀，如 `_value_cpu`、`_value_mem`。`join` 还支持 `inner`、`left`、`right`、`full`。

## 内存执行的价值与边界

即使引入 connector pushdown 和 Page-based physical executor，内存执行仍然有价值：

- array/csv 小数据输入直接构造内存表。
- 复杂 `map`、复杂 `filter`、跨源 join 等第一阶段无法下推的操作需要 fallback。
- CLI 输出、inspect 函数和 `yield` 需要 materialized rows。
- 单元测试更容易在内存表上构造稳定 fixture。

但内存执行不是所有场景的最终答案。全量 materialization 会带来拷贝和内存压力，所以 SQL connector 方向已经把 scan/filter/project/range 等路径推向 Page streaming。

## 小结

Table pipeline 是 Flux 查询语义的核心。项目当前的 `TableValue` 路径已经能表达多 logical table、group key、window、join 和一批常见 transform/aggregate。后续优化的重点不是抛弃它，而是把它放在正确边界：小数据和 fallback 用它，大数据 scan 和可下推前缀走 logical/physical plan。
