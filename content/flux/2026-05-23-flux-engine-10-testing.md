---
title: 测试体系：如何保证一个语言实现不退化
description: "介绍 Flux 项目的 parser/runtime/CLI/LSP/conformance/benchmark 测试分层，以及为什么示例必须可执行。"
date: 2026-05-23
categories: [programming]
tags: [flux, testing, bazel, cpp]
authors: ["liubang"]
weight: 10
series: ["Flux"]
series_weight: 10
---

语言和查询引擎项目最容易出现一种问题：功能越加越多，某个旧语义悄悄坏掉。`cpp/pl/flux` 现在已经有 parser、runtime、stdlib、table pipeline、connector、physical executor 和 LSP，如果没有测试分层，维护成本会很快失控。

## 测试不是一类

当前测试大致分成几层：

- scanner unit test。
- parser unit test。
- runtime value/env/eval/exec unit test。
- connector unit test。
- optimizer unit test。
- CLI smoke/unit test。
- stdlib conformance test。
- LSP unit test。
- benchmark runner。

每一层守不同边界。parser test 不应该承担 runtime 正确性；runtime eval test 不应该依赖真实 MySQL；LSP test 不应该通过人工打开编辑器来验证协议结构。

## 测试分层的一个原则

越底层的测试越应该小而确定，越上层的测试越应该接近真实用户路径。scanner/parser 测 token 和 AST；runtime eval 测表达式语义；runtime exec 测完整文件和查询管道；conformance 测标准库公开行为；benchmark 测性能趋势。

如果把所有东西都写成端到端测试，失败时定位会很慢。如果只写单元测试，又很容易漏掉模块组合后的行为变化。语言项目最需要的是“窄测试 + 宽测试”同时存在。

## Parser 测试

parser 测试关注语法覆盖、AST dump 和 malformed 输入恢复。对于语法项目，AST dump 是非常有价值的快照，因为它直接反映源码如何被结构化。

例如函数、pipe、record update、属性、类型语法、正则、字符串插值这些都需要有独立覆盖。否则后续改表达式优先级时，很容易让某类查询的 AST 形状改变而不自知。

## Golden dump 的取舍

AST dump 快照很有用，但也有维护成本。只要 AST debug 输出稍微调整，很多 golden 就会变。因此 golden 应该覆盖关键结构，而不是每个微小格式都强绑定。

当前比较合理的方式是：核心语法用 AST dump 验形状，复杂 runtime 行为用执行结果验语义。比如 pipe precedence 适合 AST 测试；`aggregateWindow(createEmpty:)` 更适合 runtime/exec 测试。

## Runtime Eval 测试

`runtime_eval_unit_test` 更偏表达式级执行。它覆盖 literal、member/index、exists、字符串插值、正则、函数调用、闭包、默认参数、pipe 参数、array helper、table helper 等。

前面提到的 numeric equality bug 就适合放在这一层：

```flux
array.filter(arr: [1, 2, 3, 4], fn: (x) => x == 3)
```

这个测试不需要完整 CLI，也不需要文件执行；它只关心 evaluator 是否正确处理数值 `==` / `!=`。

## 负例测试同样重要

解释器测试不能只测成功路径。类型错误、缺参数、未知变量、除零、数组越界、builtin 返回值类型错误都应该有负例。

负例的目标不是固定每个错误文案的标点，而是确保错误发生在正确层级，并返回合理 status code。这样后续改错误信息时不会被过细 golden 绊住，但真正的行为回归仍然能被发现。

## Runtime Exec 测试

`runtime_exec_unit_test` 更接近文件执行和查询执行。它覆盖 import、option、声明、结果收集、查询 pipeline、connector pushdown、physical execution、profile 等更大粒度行为。

这一层适合测试：

- `array.from` / `csv.from` / `sqlite.from` / `mysql.from`。
- table transform 和 aggregate。
- explain 输出。
- physical planner 和 executor。
- 多 logical table 语义。
- MySQL 在有 DSN 时的集成路径。

某些测试会因本地环境缺少 DSN 而 skip，这是合理的；真实外部依赖不应该让所有本地开发都变脆。

## 外部依赖测试要可降级

MySQL 这类测试不能要求每个开发者本机都有同一套数据库。当前做法是通过环境变量控制，有 DSN 就跑集成路径，没有就 skip。这比在单测里 mock 掉所有 connector 更真实，也比强制依赖外部服务更友好。

SQLite 则适合作为默认 connector 测试数据源，因为它可以在本地临时构造数据库，确定性更强。很多 pushdown、split、profile 行为可以先用 SQLite 覆盖，再用 MySQL 做补充验证。

## Stdlib Conformance

`examples/stdlib_conformance` 是我认为非常重要的一层。它把“示例”和“测试契约”合在一起。

规则是每个已实现 builtin 都应该有一个主覆盖点，同一个 builtin 不要在多个示例里重复承担主覆盖职责。测试脚本会执行 `.flux` 文件并对 JSON output 做 golden check。

这解决了两个问题：

第一，文档不会漂移。示例如果不能执行，测试会失败。

第二，标准库不会无声退化。比如 `array.scan`、`array.unfold`、`join.full`、`date.truncate` 这类函数只要行为变化，conformance 快照会提醒我们重新审视。

## LSP 测试

LSP 测试直接模拟请求和响应。它应该覆盖协议结构、capabilities、diagnostics、completion、definition、references、rename、semantic tokens、formatting 等。

这类测试的价值在于防止“编辑器里才发现”的问题。例如 JSON-RPC 响应格式错误、completion item 缺逗号、semantic token delta 编码错误，都可以在单测层提前抓到。

## Benchmark 不是 correctness test

benchmark 主要用于同机同口径前后对比，不应该当成严格正确性测试。当前 benchmark 覆盖内存执行、SQLite connector scan 和 MySQL connector scan。

它会输出 samples、median、mean、drivers、pages、split bytes、wall time、accumulator profile、query memory 等信息。对于性能优化，它的作用是给出可复现证据，而不是凭感觉判断“变快了”。

## 静态检查

项目也使用 clang-tidy 做静态扫描。静态检查不能替代测试，但能提前发现一些明显问题，比如不必要拷贝、可疑生命周期、现代 C++ 风格问题等。

对于 C++ 查询引擎项目，静态检查尤其适合作为 review 前置工具：它不理解 Flux 语义，但很擅长发现 C++ 代码层面的粗糙点。

## 小结

测试体系的核心不是“测试越多越好”，而是每层测试守住自己的边界。parser 守 AST，eval 守表达式语义，exec 守文件和查询执行，conformance 守标准库契约，LSP test 守协议和 IDE 行为，benchmark 守性能趋势。只有这种分层清楚的测试结构，才能支撑项目继续加功能而不失控。
