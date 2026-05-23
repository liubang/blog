---
title: 从 Logical Plan 到 Physical Plan：执行引擎的骨架
description: "介绍 Flux 查询引擎从 logical plan、RBO/CBO framework 到 physical plan、pipeline、driver、operator 和 Page 流的执行架构。"
date: 2026-05-23
categories: [programming]
tags: [flux, query-engine, optimizer, execution, cpp]
authors: ["liubang"]
draft: true
---

当项目只有 eager interpreter 时，执行路径很直接：AST 调 builtin，builtin 操作 `TableValue`。但 connector、pushdown、多 split 和 streaming execution 加进来后，需要一个更清晰的查询引擎骨架。`cpp/pl/flux` 当前的方向是把执行拆成 logical plan、optimizer、physical plan、scheduler 和 operator pipeline。

## 目标结构

目标结构可以概括为：

```mermaid
flowchart LR
    AST["Flux AST"] --> Binder["Analyzer / Binder"]
    Binder --> Logical["LogicalPlan"]
    Logical --> RBO["Rule-based optimizer"]
    RBO --> CBO["CBO framework"]
    CBO --> Physical["PhysicalPlan"]
    Physical --> Scheduler["Scheduler"]
    Scheduler --> Driver["Driver / Operator pipeline"]
    Driver --> Pages["Page / Chunk stream"]
    Pages --> Materialize["TableValue materialization"]
```

当前 analyzer/binder 还不是完整类型化语义层，但 connector、logical plan skeleton、RBO/CBO framework、physical plan 和 Page-based execution 主干已经落地。

## 为什么要引入计划层

如果查询永远是小数组，直接解释执行就够了。但一旦有外部数据源、下推、并发 split、partial/final 聚合和 profile，解释器就需要一个中间表示来承载“尚未执行的查询”。

计划层的价值在于延迟决策。`filter` 在内存表上是 row transform；在 SQLite 上可能是 SQL predicate；在复杂用户函数里又必须 fallback。只有把它先表示成 logical filter，optimizer 才有机会根据上下文选择执行位置。

因此 logical plan 不是为了看起来像数据库系统，而是为了把“用户写了什么”和“系统怎么执行”分开。

## Logical Plan 的职责

Logical plan 表达用户查询语义，不应该包含具体 SQL 字符串或 connector 执行对象。它关心的是：

- source scan。
- filter。
- project。
- range。
- aggregate。
- distinct。
- sort。
- limit。
- join。
- materialize boundary。

这样 optimizer 可以在逻辑层做 rewrite，例如 predicate pushdown、projection pruning、aggregate pushdown 和 barrier insertion。

## Logical node 应该避免携带执行对象

Logical plan 如果直接保存 SQLite statement、MySQL connection 或 C++ callback，就会失去可优化性。它应该保存可序列化、可检查、可重写的语义信息，例如 table handle、column assignment、predicate、limit、sort key。

这样 explain 可以展示计划，optimizer 可以复制和改写节点，unit test 可以构造计划做 rule 测试。执行对象应该在 physical planning 或 connector page source provider 阶段创建。

这个边界对长期维护很关键。否则 logical plan 会变成运行时对象的集合，既不方便测试，也很难跨 connector 复用 rule。

## RBO 与 CBO framework

当前主要依赖 rule-based optimizer。RBO 做确定性 rewrite：能下推的前缀下推，不能下推的位置插入 fallback/materialize 边界。

CBO framework 已经有 statistics、cost 和 alternative plan 的接口方向，但第一阶段不伪造精度。缺统计时明确退化为 RBO。这一点很重要：坏的 cost model 比没有 cost model 更危险，因为它会给错误选择披上“优化”的外衣。

## RBO 更适合当前阶段

当前项目里很多优化都是确定性规则：能下推 projection 就下推，能下推简单 filter 就下推，遇到复杂 map 就插入 materialize boundary。这些规则不需要 cost model。

CBO 真正有价值的场景是存在多个语义等价但成本不同的计划，例如 join order、join strategy、不同索引、不同 split 策略。没有可靠 statistics 时，CBO 的选择很可能只是猜测。

所以当前策略是先把 RBO 做扎实，同时保留 CBO framework。等 connector statistics、row count、distinct count、column size 这些信息更可靠之后，再让 cost model 参与真正决策。

## Physical Plan 与 Pipeline

Physical plan 描述执行形态，不直接执行。它会被 scheduler 转成 task、pipeline、driver 和 operator。

当前主干已经进入：

```text
ConnectorRuntime -> Split -> PageSource -> Pipeline -> Driver -> Operator -> Page
```

operator 之间的主通道是 `Page` / `PageChunk` / `ColumnVector`。row-by-row 可以作为某个 operator 内部实现细节，但不再作为长期跨层接口。

## Operator 接口的关键约束

Operator 的设计重点不是类层次多漂亮，而是数据通道一致。上游产生 Page，下游消费 Page；blocking operator 可以在内部累积状态，但对外仍然通过 Page 输出。

这个约束让 scan、filter、project、aggregate、exchange、sink 能组合成 pipeline。它也让 profile 可以统一统计 pages、rows、blocking、finished、error。

如果某个 operator 直接返回 `TableValue`，就会把执行主干拉回 eager interpreter。因此 materialize 应该是显式 operator 或边界，而不是每个算子随手做的事情。

## Streaming 与 Blocking

不是所有算子都能 streaming。

可以 streaming 的典型路径：

- scan。
- filter。
- project。
- range。
- root exchange 的一部分。

明确 blocking 的路径：

- sort。
- topN 的 root 合并阶段。
- join。
- materialize。
- 部分 aggregate/distinct/group 的最终输出阶段。

当前 group/distinct/aggregate 已经是 Page-native streaming accumulator：输入逐 Page 吸收到 state，最终产出结果 Page。高基数 `group |> aggregate`、root `group` 和 root `distinct` 可以通过 hash partition exchange 拆成 partial/final 两阶段。

## Exchange 与并行

单机执行也需要保留 exchange 边界。multi-split scan 会展开多个 driver；本地 exchange 把 producer pipeline 接到 root pipeline。全局 Top-N 使用两阶段执行：split 内 partial Top-N，root 再做全局 heap Top-N。

这不是为了现在就做分布式，而是为了避免将来加并发、跨源 join 或更多 connector 时推翻执行主干。

## Memory 与取消

blocking operator 需要内存预算。当前 query 级 `QueryMemoryContext` 会暴露 used、peak、limit 和 limited 状态。项目暂不实现 spill；超过预算时返回 `ResourceExhausted`。

执行错误也需要正确传播。root 输出失败时，会触发 operator cancel，关闭上游 exchange buffer，避免 producer 因背压队列而挂住。

## 小结

Logical/physical plan 是项目从解释器走向查询引擎的关键。当前实现仍保留 `TableValue` fallback，但高吞吐路径已经转向 split、page source、operator pipeline 和 streaming accumulator。这个骨架让后续优化可以发生在正确层次：builtin 负责语言入口，optimizer 负责计划改写，physical executor 负责执行形态，connector 负责数据源能力。
