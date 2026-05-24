---
title: 从 Logical Plan 到 Physical Plan：执行引擎的骨架
description: "介绍 Flux 查询引擎从 logical plan、RBO/CBO framework 到 physical plan、pipeline、driver、operator 和 Page 流的执行架构。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, query-engine, optimizer, execution, cpp]
authors: ["liubang"]
weight: 9
series: ["Flux"]
series_weight: 9
lightgallery: true
---

前面两篇分别讲了内存表执行和 connector pushdown。它们看上去像两条路径：一条是 `TableValue` 上的 builtin 解释执行，一条是 SQLite/MySQL 上的 Page streaming。第 08 篇要回答的就是中间那层问题：同一条 Flux 查询，如何先被表达成可优化的 logical plan，再落成真正可调度的 physical pipeline。

如果项目只有 eager interpreter，执行路径很直接：AST 调 builtin，builtin 操作 `TableValue`，然后把结果传给下一个 builtin。但 connector、pushdown、多 split、exchange、partial/final aggregate 和 profile 加进来后，直接解释 AST 就不够了。执行器必须先有一个“尚未执行、可以改写、可以解释”的查询表示。

这就是 logical/physical plan 的位置。Logical plan 负责保存用户查询语义，optimizer 负责改写语义等价的计划，physical plan 负责描述执行拓扑，scheduler 再把它变成 driver 和 operator。

## 一个贯穿全文的查询

先用一条查询做主线：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-01T01:00:00Z)
    |> filter(fn: (r) => r.host == "edge-1" and r._value > 80.0)
    |> keep(columns: ["_time", "host", "_value"])
    |> group(columns: ["host"])
    |> mean(column: "_value")
    |> sort(columns: ["_value"], desc: true)
    |> limit(n: 10)
```

这条查询里同时有 source scan、时间范围、谓词、projection、group aggregate、sort 和 limit。它足够小，但已经覆盖了查询引擎里最核心的几个问题：

- `range/filter/keep` 能不能下推到 SQLite？
- `group |> mean` 能不能变成 grouped accumulator？
- `sort |> limit` 是全局 top-n 还是 split 内局部 top-n？
- 哪些 operator 可以 streaming，哪些必须 blocking？
- 如果某个后缀不能下推，materialize boundary 应该插在哪里？

从用户视角看，这是一条 pipe chain。从引擎视角看，它会经历下面这条路径：

![Logical to Physical Plan](/images/flux/logical-to-physical.svg "Logical to Physical Plan")

图里最重要的边界有三个：Logical Plan 只表达语义，Optimizer 只做等价改写，Physical Plan 才开始描述执行形态。只要这三个边界守住，后续新增 connector、operator 或 profile 字段就不会把 builtin、optimizer 和 executor 搅在一起。

## 为什么要引入计划层

解释器最大的问题不是慢，而是太早做决定。

比如 `filter(fn:)` 这个调用，在内存数组上应该逐行执行；在 SQLite/MySQL 上，如果表达式足够简单，可以变成 SQL predicate；如果 filter 里调用用户函数，又必须留在 Flux runtime。单看 AST 上的 `filter` 调用，执行器无法知道它应该在哪里运行。

计划层的价值就是延迟决策。builtin 在语言层只负责把调用翻译成 logical node，例如 `FilterNode`、`ProjectNode`、`AggregateNode`。optimizer 再根据上下文判断：这个 filter 是否能下推？这个 projection 是否能裁剪源列？这个 aggregate 是否能变成 connector aggregate？这个 suffix 是否要 materialize 后 fallback？

因此 logical plan 不是为了模仿数据库术语，而是为了把“用户写了什么”和“系统怎么执行”拆开。没有这层拆分，pushdown 很容易变成散落在 builtin 里的 SQL 拼接逻辑，profile 也很难解释一条查询到底在哪里花了时间。

## Logical Plan 的职责

Logical plan 表达查询语义，不表达执行对象。一个健康的 logical node 应该能被复制、重写、打印、测试，而不依赖真实 SQLite statement、MySQL connection 或 C++ callback。

当前项目中，logical plan 至少要覆盖这些语义节点：

- `SourceScan`：数据源类型、表名、连接 handle、初始 schema 约束。
- `Range`：Flux 时间范围，尤其是 `_time` 半开区间语义。
- `Filter`：谓词表达式，不急着决定是在 SQL 还是 Flux runtime 执行。
- `Project`：`keep/drop` 之后的列集合和列顺序。
- `Rename`：Flux 层列名和源列名之间的映射。
- `Aggregate`：`count/sum/mean/min/max` 这类聚合语义。
- `Group`：逻辑表流的 group key 重分布。
- `Distinct`、`Sort`、`Limit`、`Join`：会影响全局语义或 blocking boundary 的节点。
- `Materialize`：显式 fallback 边界，把 Page 或 lazy plan 变成 `TableValue`。

这些节点不应该直接包含 SQL 字符串。SQL 是某个 connector 在 contract 通过后的执行形式，不是 Flux logical plan 的本体。Logical plan 也不应该保存已经打开的数据库连接；连接的生命周期属于 connector runtime 和 page source provider。

保持这条边界后，`explain()` 可以稳定打印计划，RBO 可以纯粹地做 rewrite，单测也可以直接构造 plan tree 验证规则，而不需要真的连一个数据库。

## Pipe Chain 如何变成 Plan

Flux 的 pipe 写法很适合用户阅读，但 runtime 不能把它只当成嵌套函数调用。下面两种写法在语言层接近：

```flux
data
    |> filter(fn: (r) => r._value > 80.0)
    |> keep(columns: ["_time", "_value"])
```

```flux
keep(
    tables: filter(tables: data, fn: (r) => r._value > 80.0),
    columns: ["_time", "_value"],
)
```

如果每个 builtin 被调用时都立刻执行，第二个 `keep` 看到的就已经是 filter 后的完整 `TableValue`。这对小数据没问题，但对外部表意味着已经错过 pushdown 机会。

因此数据源 builtin 会尽量返回 lazy table plan。后续表算子如果发现输入仍然是 plan，就把自己追加为 logical node；只有遇到输出、inspect、旧 builtin、复杂用户函数或不支持 lazy 的路径，才显式 materialize。

这让同一个 `filter` 有了多种可能的落点：

- simple predicate 可以合并进 `SourceScan`。
- Page-native filter 可以留在 physical pipeline。
- 调用用户函数的复杂 filter 可以在 materialize 后交给内存 evaluator。

关键是：落点选择不是 builtin 自己拍脑袋，而是 optimizer 和 physical planner 统一决定。

## RBO：当前阶段的主力

当前项目主要依赖 rule-based optimizer。RBO 做的是确定性 rewrite：只要语义等价且 contract 允许，就进行改写；不能证明等价，就保守保留或插入 fallback boundary。

典型规则包括：

- `range` 下推到 connector scan。
- simple `filter` 下推到 connector predicate。
- `keep/drop` 变成 projection pruning。
- `rename` 更新 column assignment。
- `sort + limit` 尝试变成 top-n。
- `group(columns:) |> aggregate(column:)` 尝试变成 grouped accumulator 或 connector aggregate。
- unsupported suffix 前插入 `Materialize`。

这些规则不需要复杂 cost model。例如 projection pruning 只要能减少读列，一般就应该做；simple filter 越靠近 source 越好；复杂 filter 不能下推时插入 materialize 是语义要求，不是成本选择。

RBO 的价值在于稳定和可解释。每条规则都应该有清楚的触发条件、输出计划和拒绝理由。这样 explain 才能告诉用户：哪些算子被下推了，哪些因为表达式复杂或 split 语义不安全而留在 runtime。

## CBO Framework 的位置

Cost-based optimizer 不是没有价值，只是当前阶段不能伪装成已经成熟。

CBO 真正适合解决的问题是：存在多个语义等价计划，但成本不同。例如 join order、join strategy、索引选择、split 数量、是否做两阶段 aggregate、是否选择 connector aggregate 还是 Page accumulator。要做这些选择，optimizer 需要 reliable statistics：row count、distinct count、column size、predicate selectivity、connector latency 等。

当前项目已经保留 statistics、cost 和 alternative plan 的框架方向，但缺统计时明确退化为 RBO。这是一个重要工程取舍。坏的 cost model 比没有 cost model 更危险，因为它会给错误选择披上一层“优化”的外衣。

所以当前策略是：确定性 rewrite 先做扎实，CBO 框架先把接口站住。等 SQLite/MySQL metadata、split profile、benchmark baseline 更稳定后，再让 cost model 参与真正决策。

## Physical Plan 描述执行形态

Logical plan 回答“这条查询是什么意思”，physical plan 回答“这条查询怎样执行”。

同样是 `Filter`，物理层可能有三种形态：

- connector scan 里的 pushed predicate。
- Page pipeline 里的 `FilterOperator`。
- fallback 后 `TableValue` 上的内存 filter builtin。

同样是 `Aggregate`，物理层也可能有多种形态：

- connector aggregate pushdown。
- Page-native grouped accumulator。
- partial/final 两阶段 accumulator。
- materialize 后的旧内存 aggregate。

Physical plan 需要把这些选择具体化。它不再只是语义树，而是执行拓扑：哪些 scan 会展开多个 split，哪些 pipeline 之间有 exchange，哪个 operator 是 blocking，哪些结果要进入 root output，哪些 boundary 要 materialize。

这里要特别注意：physical plan 仍然不应该直接“执行”。它只是执行说明书。真正的执行发生在 scheduler、driver 和 operator 里。

## ExecutionTask、Pipeline 与 Driver

当前主干已经进入 `ExecutionTask -> Pipeline -> Driver -> Operator -> Page` 的形态。

`ExecutionTask` 是一次查询执行的任务容器。它包含若干 pipeline，每个 pipeline 是一段可以按 Page 生产/消费的 operator 链。多 split scan 会展开多个 driver；每个 driver 运行同一段 operator pipeline，但绑定不同 split 或不同输入分区。

可以把关系粗略理解成：

```text
ExecutionTask
  -> Pipeline 1: connector scan -> filter -> project -> exchange sink
       -> Driver(split 0)
       -> Driver(split 1)
       -> Driver(split 2)
  -> Pipeline 2: exchange source -> aggregate final -> top-n -> output
       -> Driver(root)
```

这个模型即使在单机里也有价值。它让 split 并行、局部聚合、root 合并、取消传播和 profile 统计都有了自然位置。后续如果扩展更多 connector 或更复杂 exchange，也不用推翻执行骨架。

## Operator 的数据通道

Operator 之间的主通道是 `Page` / `PageChunk` / `ColumnVector`，而不是一行一个 object。

这条约束非常重要。row-by-row 可以作为某个 operator 内部实现细节，但不能成为跨层接口。跨层接口一旦退回对象行，scan、filter、project、aggregate、exchange 和 profile 的吞吐都会被限制在解释器模型里。

Page 化带来的收益有几个：

- scan 可以按批读取，减少函数调用和对象分配。
- filter/project 可以按列处理，避免反复查对象字段。
- connector page source 可以直接把外部数据转成列向量。
- profile 可以统一统计 pages、rows、bytes 和 operator 阶段耗时。
- exchange 可以用 Page 作为传输单元，而不是散碎 row。

当然，Page 不是魔法。复杂用户函数、动态对象构造、inspect 输出仍然可能需要回到行模型或 `TableValue`。但这种回退应该是显式边界，而不是整个执行主干的默认形态。

## Streaming 与 Blocking

不是所有 operator 都能 streaming。

可以自然 streaming 的路径包括：

- connector scan。
- range。
- simple filter。
- projection。
- 部分 root exchange。
- Page-native accumulator 的输入吸收阶段。

明确 blocking 的路径包括：

- 全局 sort。
- top-n 的 root 合并阶段。
- join。
- materialize。
- aggregate/distinct/group 的最终输出阶段。

当前 group、distinct、aggregate 已经是 Page-native streaming accumulator：输入逐 Page 吸收到 state，最终产出结果 Page。高基数 `group |> aggregate`、root `group` 和 root `distinct` 可以通过 hash partition exchange 拆成 partial/final 两阶段，final driver 按 key 分区并行合并。

这也是为什么 physical plan 必须显式标记 blocking boundary。blocking operator 需要内存预算，也需要 profile 暴露自身的等待、吸收、输出阶段。否则用户只看到“查询卡住了”，但不知道是 scan 慢、exchange 堵、aggregate state 过大，还是 sort 在等全量输入。

## Exchange 与并行

单机执行也需要 exchange。

multi-split connector scan 会产生多个 producer driver，它们不能都直接写最终输出。更常见的模式是 producer pipeline 把 Page 写入本地 exchange，root pipeline 再从 exchange 读取、合并、聚合或排序。

比如全局 top-n：

```text
split driver 0: scan -> local topN(10) -> exchange
split driver 1: scan -> local topN(10) -> exchange
split driver 2: scan -> local topN(10) -> exchange
root driver: exchange source -> global topN(10) -> output
```

split 内 top-n 只能减少数据量，不能代表全局结果。root 的 global top-n 才是语义边界。这个例子也说明了为什么 split manager、physical planner 和 operator pipeline 不能各自为政：split 是并行策略，global merge 才保证查询语义。

对 group/distinct/aggregate 来说，exchange 还可以按 key 做 hash partition。这样 partial accumulator 先在 producer driver 吸收局部 Page，final accumulator 再按 key 合并，避免所有状态都挤到单个 root driver。

## Materialize 是显式边界

`TableValue` fallback 没有消失，但它的位置变了。

在早期 eager interpreter 里，`TableValue` 是每个 builtin 之间的默认通道。现在它更像一个边界对象：当查询必须进入旧 builtin、输出、inspect、跨源 join 或复杂用户函数时，physical plan 显式插入 materialize，把 Page/lazy plan 转成内存表。

例如：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> range(start: 2024-01-01T00:00:00Z)
    |> filter(fn: (r) => r.host == "edge-1")
    |> map(fn: (r) => ({r with label: strings.toUpper(v: r.host)}))
```

这里 `range + simple filter` 可以在 source 或 Page pipeline 执行，但 `map` 调用了字符串函数并构造新对象，第一阶段不适合强行下推。正确计划应该是在可执行前缀之后 materialize，再交给内存 runtime。

显式 materialize 的好处是 explain/profile 都能看见它。用户可以知道为什么某段查询不再 streaming，也能知道内存峰值来自哪个 boundary。

## Memory 与取消

只要有 blocking operator，就必须有内存预算。

当前查询级 `QueryMemoryContext` 会暴露 used、peak、limit 和 limited 状态。项目暂不实现 spill；如果 blocking operator 超过预算，会返回 `ResourceExhausted`。这比悄悄把机器内存打满更符合查询引擎的工程边界。

取消传播同样重要。root 输出失败、用户中断、下游 error 都应该触发 upstream cancel。否则 producer driver 可能继续往 exchange buffer 写 Page，而 consumer 已经退出，最后卡在背压队列上。

所以 physical execution 里错误不是简单返回一个 status 就结束。它还要关闭 exchange、通知 operator cancel、回收 page source，并把错误带上足够的位置信息和 profile 信息。第 06 篇提到的 runtime statement location，在这里也能帮助用户把执行错误定位回 Flux 源码。

## Explain/Profile 如何落在计划层

计划层的另一个收益是 explain/profile 有了稳定对象。

`explain()` 可以展示：

- 原始 logical plan。
- RBO/CBO 后的 optimized logical plan。
- physical plan。
- pipeline plan。

对上面的示例查询，理想 explain 应该能看出：

- `range/filter/keep` 是否进入 connector scan request。
- `group |> mean` 是否融合为 grouped aggregate accumulator。
- `sort |> limit` 是否被规划成 top-n。
- 是否出现 exchange。
- 是否插入 materialize fallback。

profile 则给 runtime 事实：drivers、pages、rows、blocking、finished、error；connector split 的 pages/rows/bytes/wall time；metadata、split、connect、schema、sql、execute、read、decode、page-build 分段耗时；accumulator phase、key strategy、partial/final 耗时；query memory used/peak/limit。

没有计划层，profile 只能是一堆零散计数器。有了 logical/physical/pipeline 的层次，profile 才能回答“哪个计划节点花了时间”。

## 这套骨架带来的约束

Logical/physical plan 不只是新增几个类，它会反过来约束整个项目的代码组织。

几个原则需要长期遵守：

- builtin 只做语言入口和参数校验，不承载 optimizer 决策。
- logical node 保存可检查、可重写的语义，不保存数据库连接和执行对象。
- optimizer rule 独立测试，能说明触发条件和拒绝原因。
- connector 不把 SQL 字符串细节暴露给 planner，planner 只处理 handle、constraint 和 assignment。
- physical plan 描述 topology，不直接运行 operator。
- operator 之间传递 Page，不把 `TableValue` 当作高吞吐路径的跨层接口。
- materialize 只出现在输出、inspect、旧 builtin fallback、复杂用户函数和跨源边界。

这些约束听起来有点“架构洁癖”，但对查询引擎很实际。没有这些边界，新增一个 feature 就会在 builtin、optimizer、connector、executor 之间互相牵扯；有了边界，每层的问题都能单独测试和演进。

## 当前边界和下一步

当前实现已经不是纯 eager interpreter：`array.from`、`csv.from`、`sqlite.from`、`mysql.from` 仍然对外表现为 Flux table stream，但 SQL provider 的输出边界已经由 physical executor 接管。connector scan 走 metadata / split manager / page source provider，scan/filter/project/range 可以保持 Page streaming，多 split 可以展开多个 driver，本地 exchange 可以把 producer pipeline 接到 root pipeline。

但它也还不是完整 Presto/Trino。第一阶段不做 coordinator/worker，不做 distributed exchange，不做跨节点容错，也不做完整 join reorder。CBO 仍然是 framework，缺 statistics 时回到 RBO。spill 暂时不实现，blocking operator 超出内存预算直接失败。

下一步更值得做的是把现有主干做厚：让更多常见查询保持 Page-native，减少 connector 固定开销，完善 metadata/statistics 缓存，优化 MySQL page source 转换路径，继续补充 streaming/blocking boundary 的 profile，让 explain 输出足够稳定。

## 下一篇

下一篇会转向工具链，看 Flux LSP 如何复用 parser、AST cache 和 symbol table，为编辑器提供诊断、补全、跳转和语义高亮。

## 小结

Logical/physical plan 是 Flux 从解释器走向查询引擎的骨架。它把一条 pipe chain 拆成几个清晰阶段：AST 表达语法，logical plan 表达语义，optimizer 做等价改写，physical plan 描述执行拓扑，scheduler 把 pipeline 展开成 driver，operator 用 Page 流传递数据，必要时再显式 materialize 回 `TableValue`。

这个骨架的意义不在于术语完整，而在于边界清楚。只要 builtin、optimizer、connector 和 executor 各自守住职责，后续无论是增加 PostgreSQL/Parquet，还是增强 grouped accumulator、top-n、profile 和 benchmark，都可以沿着同一条主干往前长。
