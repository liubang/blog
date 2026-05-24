---
title: 项目路线图：从可用到好用
description: "总结 Flux 查询引擎当前能力，并从语言、标准库、执行引擎、LSP、测试和文档几个方向规划后续演进。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, roadmap, query-engine, lsp, cpp]
authors: ["liubang"]
weight: 13
series: ["Flux"]
series_weight: 13
---

到目前为止，这个系列已经从用户语法、parser、runtime、UDF、标准库、table pipeline、connector、physical plan、LSP、测试和性能几个角度拆开了 `cpp/pl/flux`。它已经越过了“玩具 parser”的阶段，更像一个小型 Flux 查询引擎实验场：能解析、能执行、能导入标准库、能跑表流查询、能接 SQLite/MySQL、能做部分 pushdown、能输出 explain/profile，也有 LSP、conformance 和 benchmark。

最后一篇不继续加新模块，而是做一次收束：当前能力到底覆盖到哪里？哪些边界是刻意选择？接下来从“可用”到“好用”，优先级应该怎么排？

我的判断是：下一阶段最重要的不是继续堆更多 builtin 或更多数据源，而是把共享基础设施做厚。比如 analyzer/binder、类型诊断、metadata/statistics、Page execution profile、workspace index、conformance 和 benchmark 门禁。这些能力一旦稳定，会同时改善 runtime、LSP、optimizer 和文档。

## 当前能力总览

先给一张总表，帮助读者快速建立项目现状。

| 领域 | 当前状态 | 说明 |
| --- | --- | --- |
| 语法前端 | 可用子集稳定 | scanner/parser/AST 覆盖常见 Flux 文件、表达式、函数、pipe、类型语法和部分错误恢复 |
| 用户语法 | 有完整导览 | 当前支持变量、option、import、函数、默认参数、pipe 参数、对象/数组、运算符、table pipe |
| Runtime | 主干可用 | `Value`、`Environment`、expression evaluator、statement executor、closure、pipe 参数可运行 |
| UDF/高阶函数 | 主路径可用 | 支持 expression/block body、闭包、默认参数、array 高阶函数、有限状态表达 |
| 标准库 | 常用 package 覆盖 | `array/csv/date/dict/join/json/math/regexp/runtime/sqlite/strings/system/timezone/types/mysql` 等 |
| 表流模型 | 已形成主干 | `TableValue`、logical tables、group key、empty table、aggregate/selector、join/window 已覆盖 |
| Connector | SQLite/MySQL 可用 | metadata/split/page source，保守 pushdown，复杂语义 fallback |
| Optimizer | RBO 主力，CBO 框架 | 支持安全前缀下推、projection pruning、barrier insertion，CBO 暂不伪造精度 |
| Physical execution | Page pipeline 主干 | `ExecutionTask -> Pipeline -> Driver -> Operator -> Page`，支持 exchange、accumulator、profile |
| LSP | 完整雏形 | diagnostics、completion、hover、definition、references、rename、semantic tokens、code action 等 |
| 测试 | 分层可回归 | parser/runtime/connector/optimizer/CLI/LSP/conformance/benchmark 均有覆盖 |
| 性能 | 有 benchmark 方法 | 内存执行、SQLite/MySQL connector scan、profile、baseline compare 已建立 |
| 文档 | 系列文章成形 | 已有架构、语法、实现、测试、性能和 roadmap 说明 |

这张表背后的重点不是“都完成了”，而是“主干已经有了”。项目现在的价值在于边界清楚：语法归语法，运行时归运行时，标准库归标准库，查询计划归查询计划，connector 归 connector，工具链归工具链。

## 语法覆盖与边界

当前语法层已经支持常见 Flux 查询所需的大部分结构：

- 文件结构：`package`、`import`、`option`、变量定义、表达式语句。
- 表达式：literal、array、object、dict、record update、member/index、condition、call、function、pipe。
- 函数：expression body、block body、默认参数、命名参数、pipe 参数。
- 运算符：算术、比较、相等、正则、逻辑、`exists`。
- 类型语法：基础类型、数组、字典、record、function、dynamic、vector/stream、`where` 约束。
- 错误恢复：部分 malformed array/object/call/type 能继续产出 AST。

暂时不追求的能力也应该明确：

- 不做完整官方 Flux parser 声明。
- 不支持传统 `for/while`。
- 递归不是推荐路径。
- 类型语法能解析，不代表完整类型检查已经实现。
- 错误恢复还不是完整容错 parser。

下一步语法层最值得做的不是加语法糖，而是提升坏程序体验：更一致的 `BadExpr/BadStmt`、更准确的 source location、更好的 LSP 实时输入恢复。

## Runtime 与语义路线

Runtime 当前已经能执行相当复杂的表达式和查询，但它仍然承担了过多“运行时报错”的职责。比如参数类型不对、字段不存在、函数返回值不符合 builtin 约定，很多都要到 evaluator 或 builtin 执行时才暴露。

下一步最值得补的是 analyzer/binder：

- 绑定 import、package、builtin、变量和函数。
- 为用户函数、lambda 参数和 block scope 建立共享符号信息。
- 给常见 builtin 建立 signature。
- 对明显错误提前诊断。
- 为 LSP hover、signatureHelp、completion 提供统一语义来源。

这个 analyzer 不必一开始就是完整类型系统。第一阶段先做 binding 和 signature validation 就很有价值。它能减少 runtime 和 LSP 各写一套语义规则的风险。

## 类型系统分阶段落地

完整 Flux 类型系统很复杂，不适合一口吃下。更现实的路线是分阶段。

第一阶段：符号绑定和 builtin signature。

- 知道 `array.map` 需要 `arr` 和 `fn`。
- 知道 `filter` 的 `fn` 应该返回 bool。
- 知道 `range(start:, stop:)` 接受 time/duration 相关值。
- 知道 `sqlite.from` 需要 `path/table`，不接受 raw `query`。

第二阶段：局部表达式类型。

- `1 + "x"` 应该提前报错。
- `r._value > 80.0` 可以被识别为 bool predicate。
- `array.length(arr:)` 可以推断返回 int。
- `strings.toUpper(v:)` 可以要求 string。

第三阶段：表流和 record 类型。

- row record 的字段约束。
- `map` 后输出 record 形状。
- `keep/drop/rename` 对列集合的影响。
- `group(columns:)` 对 group key 的影响。
- stream/table 类型与 connector schema 的连接。

第四阶段再考虑更完整的泛型、row polymorphism 和官方 Flux 类型约束。这样 LSP 和 CLI 可以尽早得到实用诊断，而不是长期等待一个完美类型系统。

## 标准库路线图

标准库应该继续按 package 边界扩展，而不是把函数都塞进 universe。

当前已有 package 覆盖面已经不错：

- 数据和数组：`array`、`csv`
- 时间和字符串：`date`、`timezone`、`strings`、`regexp`
- 数值和类型：`math`、`types`
- 结构和编码：`dict`、`json`
- 查询和数据源：`join`、`sqlite`、`mysql`
- 系统信息：`runtime`、`system`

下一步标准库的重点不是“继续加很多函数”，而是让已实现 package 更可靠：

- 给 `array` 补更多边界测试和负例。
- 扩展 `date/strings/math` 中行为明确、实现成本低的函数。
- 继续完善 `timezone` 与 window/aggregateWindow 的交互。
- 评估 `generate`、`sampledata`、`interpolate` 这类纯内存 package。
- 评估官方 schema 探索类能力，但不要过早污染顶层命名空间。

外部副作用类 package，例如 `http`、`kafka`、`socket`、`slack`、`pagerduty`，暂时不适合作为优先项。它们需要副作用模型、配置、安全、超时、重试和测试环境支持，不能只实现一个函数壳。

## 标准库扩展的退出标准

每个新 builtin 或 package 都应该有 done definition：

- Runtime registry 已注册。
- 参数校验清楚，错误能定位到 package/function/argument。
- 正例和负例测试覆盖主要行为。
- `examples/stdlib_conformance` 有主覆盖点。
- conformance shell 和 README 已登记。
- README 和 SUPPORT_MATRIX 说明支持范围。
- LSP completion/signature/hover 能看到它。
- 未实现的官方边界明确说明。

没有这些配套，新函数越多，用户越难判断哪些能力可靠。

这里可以坚持一个朴素原则：没有 conformance 的 builtin 不是完整交付。它可能已经能跑，但还没有进入公开行为契约。

## Table Pipeline 路线图

内存表流路径仍然很重要。即使 connector 和 Page execution 越来越强，`TableValue` 仍然是 fallback、调试、输出和小数据场景的基础。

下一步 table pipeline 值得继续补：

- 更多 logical table 和 group key 组合测试。
- selector 与 aggregate 的空表行为。
- `window/aggregateWindow` 的更多日历边界。
- `join` 在多 group、多表、多列重名下的行为。
- CLI JSON/CSV 对多表、group flag、empty table 的保真。
- `TableValue` 与 Page materialize 之间的边界测试。

这条路径不一定是最高性能路径，但它是语义锚点。Page pipeline 和 connector pushdown 的结果最终都要和这条语义锚点对齐。

## Connector 路线图

SQLite/MySQL connector 已经证明了当前抽象可行：metadata、split manager、page source provider、pushdown contract、fallback boundary 都能跑起来。

下一步先不要急着加很多数据源，而是把 connector 主干做厚：

- metadata/statistics 缓存。
- split discovery profile 和缓存。
- MySQL page source decode 路径优化。
- 更清楚的 connector capability 描述。
- 更好的 SQL dialect 边界。
- 更完整的 pushdown refusal reason。
- connector scan benchmark 纳入稳定回归口径。

新增数据源可以考虑 PostgreSQL、Parquet、HTTP table API，但前提是主干能力足够稳。没有稳定 connector/runtime/planner 边界时，数据源越多，维护成本越高。

## Optimizer 路线图

Optimizer 下一步不只是加规则。

RBO 仍然应该是当前主力：predicate pushdown、projection pruning、limit/top-n、aggregate pushdown、materialize barrier insertion 这些都是确定性规则。

CBO 框架可以继续保留，但不要伪造精度。缺少 statistics 时，退化为 RBO 是正确选择。真正让 CBO 参与决策之前，需要更多可靠信息：

- row count
- distinct count
- column size
- predicate selectivity
- connector latency
- split cost
- memory estimate

更重要的是 explain 可解释性。用户看到一个查询没有下推时，应该能知道原因：filter 太复杂、rename assignment 不安全、aggregate 不满足 contract、sort/limit 需要全局语义、connector statistics 不足，还是 CBO 没有可用 alternative。

一个好的 optimizer 不只是会改写计划，还应该能说明为什么改、为什么不改。

## Physical Execution 路线图

执行层重点应该继续做厚 Page pipeline 主干：

- 更多 table transform Page-native 化。
- streaming/blocking boundary 的 profile 继续细化。
- query memory accounting 更精确。
- high-cardinality group 的 partition/final 策略。
- Top-N、sort、join 的 memory profile。
- root exchange 和取消传播继续打磨。
- materialize boundary 在 explain/profile 中更显眼。

Spill 暂时不应该急着做。外部排序、落盘 hash join、spill aggregate 都会牵动 operator 生命周期、resource manager、profile、错误恢复和测试。当前更应该先把 memory budget、blocking boundary 和 Page 主通道做稳。

分布式执行也不是第一阶段目标。单机保留 pipeline/driver/exchange 边界，是为了未来不推翻架构，不是为了现在就做 coordinator/worker。

## LSP 路线图

LSP 已经具备完整雏形：diagnostics、completion、hover、definition、references、rename、signatureHelp、documentHighlight、semanticTokens、codeAction、inlayHint、selectionRange、formatting。

后续更有价值的是质量提升：

- workspace index。
- incremental diagnostics。
- hover 文档接入 builtin metadata。
- signatureHelp 使用共享 signature。
- rename 冲突检测。
- references 跨文件能力。
- semantic token 分类更准确。
- formatter 幂等和真实文件快照。
- auto import quickfix 扩展。

LSP 的好坏会反过来暴露 parser 和 symbol table 的问题。它不是周边工具，而是一种语言实现质量检测器。用户在编辑器里最先感受到的，不是 optimizer 多聪明，而是诊断准不准、补全吵不吵、跳转对不对、rename 安不安全。

## 测试路线图

测试体系已经有分层，但后续可以继续加强几个方向：

- Parser malformed 输入和 location 快照。
- Runtime negative tests：缺参、错参、未知变量、错误 source location。
- Table pipeline 多 logical table fixture。
- Connector pushdown refusal case。
- Optimizer rule trace test。
- CLI JSON/CSV 输出 shape test。
- LSP 多 handler 语义一致性 test。
- Conformance 不重不漏自动检查继续保持。

一个很值得补的方向是“场景级一致性测试”：同一段 Flux 查询，同时验证 AST、runtime result、explain/profile 和 CLI JSON shape。它不需要很多，但可以覆盖跨层契约。

## Benchmark 路线图

Benchmark 当前已经能做本地同机同口径对比，但还可以继续工程化：

- 固定 release build baseline。
- 稳定 warmup/repeat 策略。
- 关键 scenario 纳入 regression threshold。
- 输出更清楚的 profile summary。
- 区分 cold/warm cache。
- MySQL benchmark fixture 自动化继续完善。
- benchmark 结果和优化记录继续绑定。

Benchmark 不应该替代 correctness test，但可以成为性能回归门禁。尤其是 Page pipeline、connector decode、group accumulator、Top-N、pivot/join 这些路径，肉眼 review 很难判断性能是否退化。

## 文档路线图

除了这个系列文章，还需要三类长期文档。

第一类是用户文档：

- 当前 Flux 子集怎么写。
- CLI 怎么运行。
- 如何接 array/csv/sqlite/mysql。
- 输出格式怎么理解。
- 常见错误怎么定位。

第二类是开发文档：

- 如何新增 builtin。
- 如何新增 package。
- 如何新增 connector。
- 如何新增 optimizer rule。
- 如何新增 Page operator。
- 如何给 LSP 加能力。

第三类是支持矩阵：

- 已支持。
- 部分支持。
- 明确不支持。
- 后续计划。

支持矩阵很重要，因为这个项目不是完整官方 Flux。只要边界说清楚，用户就知道哪些能力可靠，维护者也知道下一步该补什么。

## 什么暂时不要做

暂时不要追求完整官方 Flux。目标太大，容易让项目失去工程节奏。

暂时不要做分布式执行。当前单机 pipeline/driver/operator 边界已经为未来留了空间，但 coordinator/worker、distributed exchange、fault tolerance 不是第一阶段目标。

暂时不要做不完整 spill。内存预算和 blocking operator 语义稳定之后，再考虑外部排序或落盘。

暂时不要把 optimizer 逻辑写回 builtin。builtin 应该保持语言入口职责，优化决策属于 optimizer 和 planner。

暂时不要引入外部 IO package 来撑能力列表。没有副作用模型和测试环境，外部集成只会让 runtime 变得不确定。

暂时不要让 LSP、runtime 和文档各维护一份 builtin 事实。短期能跑，长期一定漂移。

## 推荐执行顺序

如果把后续工作排成一个现实路线，我会这样做：

1. 先做 analyzer/binder 和 builtin signature metadata。
2. 让 runtime、LSP、docs 逐步共享这份 metadata。
3. 补强 stdlib conformance 和 negative tests。
4. 继续把 table transform 和 accumulator 做 Page-native。
5. 完善 explain/profile 的 refusal reason 和 blocking/memory 信息。
6. 做 metadata/statistics 缓存，为 CBO 准备真实输入。
7. 把 benchmark baseline 接进稳定回归流程。
8. 再评估新增 connector 和更复杂 package。

这个顺序看起来慢，但每一步都会强化多个模块，而不是只增加一个孤立功能。

## 系列收束

回头看这 13 篇，主线其实很清楚：

- 用户如何写 Flux 子集。
- Parser 如何把源码变成 AST。
- Runtime 如何让 AST 执行。
- UDF 和标准库如何扩展语言能力。
- Table pipeline 如何表达 Flux table stream。
- Connector 和 optimizer 如何把查询推到数据源附近。
- Physical execution 如何把计划变成 Page pipeline。
- LSP 如何让语言好写。
- 测试和 benchmark 如何让项目不退化。
- Roadmap 如何决定下一步做什么。

这套结构的价值在于，它没有把 Flux 实现写成一堆函数列表，而是把语言和查询引擎的边界拆开了。一个项目能不能长大，很多时候不取决于第一版功能多全，而取决于边界是否允许它继续长。

## 小结

`cpp/pl/flux` 已经具备了一个小型 Flux 查询引擎的主干：语言、运行时、标准库、表流、connector、计划、执行、LSP、测试和性能验证都已经形成骨架。

下一阶段最值得投入的是共享语义层、类型/诊断、执行主干性能、LSP 质量、标准库契约、benchmark 门禁和文档化。把这些做好，比继续堆新功能更能让项目从可用走向好用。
