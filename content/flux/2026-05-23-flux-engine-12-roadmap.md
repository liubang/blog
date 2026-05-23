---
title: 项目路线图：从可用到好用
description: "总结 Flux 查询引擎当前能力，并从语言、标准库、执行引擎、LSP、测试和文档几个方向规划后续演进。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, roadmap, query-engine, lsp, cpp]
authors: ["liubang"]
weight: 12
series: ["Flux"]
series_weight: 12
---

到目前为止，`cpp/pl/flux` 已经具备一个语言项目和查询引擎项目的基本骨架：能解析、能执行、能导入标准库、能跑表流查询、能接 SQLite/MySQL、能做部分 pushdown、能输出 explain/profile，也有 LSP 和 conformance tests。

接下来真正重要的问题不是“还能加什么功能”，而是“哪些功能能让它从可用走向好用”。

## 当前已经稳定的主干

语言前端方面，scanner/parser/AST 已经覆盖常见 Flux 查询语法。表达式优先级、函数、pipe、record、array、object、regex、datetime、duration、类型语法都有测试覆盖。

运行时方面，`Value`、`Environment`、expression evaluator、statement executor、function closure、pipe 参数、标准库 package 和 table pipeline 已经形成闭环。

查询执行方面，内存 `TableValue` 路径仍然可用；SQLite/MySQL connector 已经走 metadata/split/page source；optimizer 和 physical executor 主干已经存在；Page streaming、exchange、accumulator 和 profile 能覆盖越来越多真实查询。

工具链方面，CLI、REPL、AST dump、JSON/CSV/human 输出、LSP 和 conformance examples 都已经可用。

## 路线图的排序原则

后续路线不能只按“哪个功能酷”排序，而要看它是否强化主干。

优先级最高的是会被多个模块共享的基础能力，例如 analyzer/binder、类型诊断、metadata/statistics、Page execution profile、标准库 conformance。这些能力一旦补好，会同时改善 runtime、LSP、optimizer 和文档。

优先级较低的是孤立能力，例如临时加一个外部 IO package、支持某个少见语法糖、或者为一个 demo 写特殊 builtin。它们看起来能快速增加功能列表，但不一定提升项目整体质量。

## 语言层路线图

最值得补的是语义分析和类型检查。当前很多错误要到 runtime 才暴露，例如参数类型不匹配、函数返回值不符合 builtin 预期、对象字段不存在等。

类型检查不一定要一开始追求完整 Hindley-Milner。更现实的方式是先做 binder：

- 绑定 import、package、builtin、变量和函数。
- 给常见 builtin 建立参数/返回形状。
- 对明显错误给出诊断。
- 为 LSP hover/signatureHelp 提供类型信息。

其次是 formatter。LSP 已经有 formatter 模块，但要达到日常可用，还需要更多真实文件快照和格式风格约束。

传统 `for/while` 暂时不应作为优先项。当前语言更适合通过 `array.range/reduce/scan/unfold` 表达有限迭代。真正缺的是类型和诊断，而不是 imperative 控制流。

## 类型系统可以分阶段落地

完整 Flux 类型系统不是一口能吃下的。更现实的路线是分阶段：

第一阶段做符号绑定和 builtin signature。先知道 `array.map` 需要 `arr` 和 `fn`，`filter` 的 `fn` 应该返回 bool，`range` 的 `start/stop` 应该是 time/duration 相关值。

第二阶段做局部表达式类型。能判断 `1 + "x"`、`r.usage > 80`、`array.length(arr:)` 这类常见表达式。

第三阶段再考虑函数泛型、record row polymorphism、stream/table 类型和更复杂约束。这样能让 LSP 和 CLI 尽早获得实用诊断，而不是长期卡在完整类型系统设计上。

## 标准库路线图

标准库应继续按 package 边界扩展。已实现 package 包括 `array/csv/date/dict/join/json/math/regexp/runtime/sqlite/strings/system/types/mysql` 等。

下一步可以优先考虑：

- 补齐 `array` 的更多边界测试，而不是继续盲目加函数。
- 扩展 `date`、`strings`、`math` 中实现成本低、行为明确的函数。
- 评估 `timezone`。
- 评估 `generate`、`sampledata`、`interpolate` 这类纯内存包。

外部副作用类 package，例如 `http`、`kafka`、`slack`、`pagerduty`，暂时不适合作为优先项。它们需要副作用模型、配置、安全和测试环境支持，不能只实现一个函数壳。

## 标准库扩展要有退出标准

每个新 package 都应该有明确的 done definition：

- README 和 SUPPORT_MATRIX 说明支持范围。
- LSP completion 能看到函数。
- 正例和负例测试覆盖主要行为。
- conformance example 有主覆盖点。
- 错误信息能定位到 package/function/argument。
- 对未实现的官方边界有明确说明。

没有这些配套，新函数越多，用户越难判断哪些能力可靠。

## 执行引擎路线图

执行层重点应该继续做厚现有主干：

- 减少 SQL connector 固定开销。
- metadata/statistics 缓存。
- MySQL page source 转换路径优化。
- 更完整的 streaming blocking boundary profile。
- 更细的 query memory accounting。
- 更系统的 CBO alternatives。
- join strategy 和跨源 join 执行改进。

新增数据源可以做，但不应该压过执行主干质量。没有稳定的 connector/runtime/planner 边界时，数据源越多，维护成本越高。

## Optimizer 下一步不只是加规则

优化器后续需要的不只是更多 rule，还包括 rule trace 和 explain 可解释性。用户看到一个查询没有下推时，应该能知道原因：是 filter 太复杂、rename 破坏 assignment、aggregate 不满足 contract，还是 connector statistics 不足。

这类解释能力对开发也很重要。否则每次性能回退都要从代码里猜 optimizer 做了什么。一个好的 optimizer 不只是会改写计划，还应该能说明为什么改、为什么不改。

## LSP 路线图

LSP 已经具备 diagnostics、completion、definition、references、rename、signatureHelp、semanticTokens、codeAction、inlayHint、selectionRange 等能力。后续更有价值的是质量提升：

- workspace index。
- incremental diagnostics。
- hover 文档。
- 更准确的 semantic token 分类。
- rename 的冲突检测。
- references 的跨文件能力。
- formatter polish。
- 自动 import quickfix 扩展。

LSP 的好坏会反过来暴露 parser 和 symbol table 的问题，所以它不只是周边工具，也是一种语言实现质量检测器。

## 测试与文档路线图

conformance examples 应继续坚持“不重不漏”。每个新 builtin 都要有主覆盖点，示例必须可执行。

benchmark 可以进一步变成回归门禁。当前 runner 已支持 baseline compare 和 regression threshold，后续可以在稳定机器或 CI 环境里固化关键场景。

文档方面，除了这个系列文章，还应该维护三类文档：

- 用户文档：怎么写 Flux、怎么跑 CLI、怎么接数据源。
- 开发文档：如何新增 builtin、connector、optimizer rule。
- 支持矩阵：哪些已支持、哪些部分支持、哪些明确不支持。

## 什么暂时不要做

暂时不要追求完整官方 Flux。目标太大，容易让项目失去工程节奏。

暂时不要做分布式执行。当前单机 pipeline/driver/operator 边界已经为未来留了空间，但 coordinator/worker、distributed exchange、fault tolerance 不是第一阶段目标。

暂时不要做不完整 spill。内存预算和 blocking operator 语义稳定之后，再考虑外部排序或落盘。

暂时不要把 optimizer 逻辑写回 builtin。builtin 应该保持语言入口职责，优化决策属于 optimizer 和 planner。

## 小结

这个项目已经越过了“玩具 parser”的阶段。它现在更像一个小型 Flux 查询引擎实验场：语言、运行时、标准库、表流、connector、计划、执行、LSP 和测试体系都已经形成骨架。下一阶段最值得投入的是类型/诊断、执行主干性能、LSP 质量、标准库契约和文档化。把这些做好，比继续堆新功能更能让项目从可用走向好用。
