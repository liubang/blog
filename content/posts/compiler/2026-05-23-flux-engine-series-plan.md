---
title: Flux 查询引擎技术文章系列规划
description: "规划一组围绕 Flux 查询引擎项目的技术文章，覆盖功能、架构、运行时、执行计划、LSP 与工程化实践。"
date: 2026-05-23
categories: [programming]
tags: [flux, compiler, database, lsp, cpp]
authors: ["liubang"]
draft: true
---

这是一组围绕当前 Flux 查询引擎项目的技术文章规划草案。目标不是简单罗列模块，而是沿着“一个 Flux 程序如何被解析、执行、优化并获得 IDE 支持”这条主线，把项目的功能、架构、用法和工程化配套讲清楚。

## 系列总标题

从零实现一个 Flux 查询引擎：语言前端、运行时、查询执行与 LSP 工程实践

## 文章 01：为什么要做一个 Flux 查询引擎

**主题定位**：系列开篇。先从项目目标和能力边界讲起，让读者知道这个项目是什么、解决什么问题、现在能跑到什么程度。

**核心内容**：

- Flux 语言的特点：pipeline、record、function、table stream。
- 项目的整体目标：实现一个可执行、可扩展、可测试的 Flux-like 查询引擎。
- 当前支持的能力：parser、runtime、stdlib、table pipeline、SQLite/MySQL connector、LSP。
- 通过一个完整查询示例展示 CLI 使用方式和输出结果。
- 给出项目模块鸟瞰图，为后续文章铺垫。

## 文章 02：从源码到 AST：Flux Parser 的实现

**主题定位**：讲语言前端。重点解释源码如何经过 scanner/parser 变成 AST。

**核心内容**：

- scanner 如何识别 token，包括关键字、字符串、时间、duration、regex。
- parser 的整体结构与错误收集方式。
- 表达式优先级：pipe、call、member、index、算术、比较、`and`、`or`。
- import、package、option、function、block、return 等语法节点。
- AST location 对 LSP 诊断、跳转和高亮的重要性。

## 文章 03：表达式解释器：让 Flux 代码真正跑起来

**主题定位**：讲 runtime evaluator。把 AST 变成可执行语义。

**核心内容**：

- `Value` 的内部模型：int、float、bool、string、array、object、function、table。
- `Environment` 与作用域查找。
- literal、array、object、member、index 的执行。
- binary/unary/logical 表达式与短路求值。
- 函数调用、闭包、默认参数、命名参数。
- pipe-forward 如何把左侧结果注入右侧调用。
- 以 `x == 3` numeric equality bug 为例，讲 evaluator 分支设计中的边界问题。

## 文章 04：UDF 与高阶函数：Flux 中函数能力的边界

**主题定位**：专门讲用户自定义函数和高阶函数。回答“复杂函数能支持到什么程度”。

**核心内容**：

- expression-bodied function 与 block-bodied function。
- 函数作为值传递给 `map/filter/reduce/find/scan/unfold`。
- 闭包捕获外层变量。
- 参数默认值、命名参数与 pipe 参数。
- 当前不支持传统 `for/while`，如何用 array 高阶函数表达循环。
- 用 Fibonacci、阶乘、累加、状态机等例子说明可表达能力。
- 当前限制：递归、类型检查、尾递归优化、传统控制流等。

## 文章 05：标准库设计：从 array package 看 builtin 扩展机制

**主题定位**：讲 stdlib 与 builtin registry。array package 是最好的切入点。

**核心内容**：

- package import 如何映射到 runtime object。
- builtin function 的注册、参数检查、错误返回。
- array 基础函数：`from`, `concat`, `filter`, `map`, `reduce`, `contains`, `any`, `all`。
- 新增 sequence/helper 函数：`range`, `repeat`, `length`, `get`, `slice`, `sort`, `flatMap`, `find`, `findIndex`, `take`, `drop`, `reverse`, `unique`, `unfold`, `scan`, `zip`, `enumerate`。
- `array.range + reduce/scan/unfold` 和传统循环的关系。
- conformance examples 如何防止标准库行为回退。

## 文章 06：Table Pipeline：Flux 查询模型如何落到内存执行

**主题定位**：讲 table runtime。说明 pipeline 查询如何在内存表上执行。

**核心内容**：

- table、row、group key、logical table 的内部表示。
- pipeline operator 的执行模型。
- `filter`, `map`, `keep`, `drop`, `rename`, `duplicate`, `set`, `limit`, `sort`, `group` 等转换。
- selector 与 aggregate 的差异：`first/last/count/mean/sum` 等。
- empty table、group preservation、null value 等边界语义。
- 从示例查询追踪每一步 table shape 的变化。

## 文章 07：Connector 与 Pushdown：把 Flux 查询下推到 SQLite/MySQL

**主题定位**：讲数据源接入和查询下推。适合偏数据库执行引擎的读者。

**核心内容**：

- `sqlite.from` / `mysql.from` 的参数设计和连接模型。
- source scan plan 如何进入 logical plan。
- filter、projection、aggregate、sort、limit 的 pushdown。
- 什么时候可以 pushdown，什么时候 fallback 到 memory execution。
- pushdown 对性能的影响。
- explain 输出如何帮助定位执行路径。

## 文章 08：从 Logical Plan 到 Physical Plan：执行引擎的骨架

**主题定位**：讲 optimizer / planner / executor。解释从逻辑查询到物理执行的过渡。

**核心内容**：

- logical plan node 与 physical operator 的职责划分。
- materialize barrier 的作用。
- pipeline DAG 如何表达执行依赖。
- memory operator 与 connector scan 的组合。
- exchange、repartition、gather 的语义。
- streaming accumulator 与 grouped aggregate。
- join、distinct、topN 等典型算子的执行方式。

## 文章 09：LSP 支持：给自研语言补齐 IDE 体验

**主题定位**：讲开发体验。LSP 文章最容易和实际使用者产生连接。

**核心内容**：

- LSP server 的整体结构：JSON-RPC、document store、diagnostics。
- completion：关键字、package、builtin function、snippet。
- semantic tokens：import、变量、函数、成员、字符串等高亮。
- goto definition：变量绑定、lambda 参数、作用域与 location。
- hover/signature help 可以如何扩展。
- INVALID_SERVER_JSON 的排查经验。
- LSP 测试如何模拟编辑器请求。

## 文章 10：测试体系：如何保证一个语言实现不退化

**主题定位**：讲工程化质量保障。把长期开发中形成的测试结构系统化。

**核心内容**：

- parser unit test。
- runtime eval unit test。
- runtime exec unit test。
- CLI golden output。
- stdlib conformance examples。
- LSP unit test。
- clang-tidy 与静态检查。
- 为什么 examples 必须可执行，而不只是展示代码。

## 文章 11：性能优化：从解释执行到查询下推

**主题定位**：讲性能演进。把“哪里慢、怎么优化、如何验证”讲清楚。

**核心内容**：

- parser/evaluator 的性能特征。
- table pipeline 中容易产生拷贝的位置。
- builtin array 函数的复杂度分析。
- connector pushdown 带来的收益。
- streaming execution 与 materialization 的取舍。
- benchmark 设计：小数据正确性、大数据吞吐、connector 查询计划。
- 后续可优化方向：arena、copy-on-write、incremental parse、workspace index。

## 文章 12：项目路线图：从可用到好用

**主题定位**：系列收尾。总结项目现状，明确下一阶段值得做的能力。

**核心内容**：

- 当前项目已经具备的能力。
- 语言层：类型检查、递归、模式化错误信息、formatter。
- 标准库层：补齐更多 Flux package。
- 执行层：更完整的 optimizer、cost model、join strategy。
- LSP 层：workspace index、incremental diagnostics、rename symbol、references。
- 工程层：更完整 conformance suite、benchmark dashboard、文档站点。
- 对读者开放问题：如何参与、如何扩展一个 builtin 或 connector。

## 建议发布顺序

优先写 01、02、03、05、06，因为这几篇可以最快形成完整闭环：项目是什么，代码如何解析，如何执行，标准库如何扩展，查询如何跑起来。

之后再写 07、08、09，把数据库执行和 IDE 工具链展开。最后用 10、11、12 收束到工程质量、性能和路线图。
