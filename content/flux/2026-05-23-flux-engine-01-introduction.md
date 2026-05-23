---
title: 从零实现一个 Flux 查询引擎：项目目标与整体能力
description: "介绍 Flux C++ Playground 的项目定位、使用方式、当前能力边界，以及一个 Flux 查询从源码到输出经过的主要模块。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, compiler, database, cpp]
authors: ["liubang"]
weight: 1
series: ["Flux"]
series_weight: 1
---

这几年我一直在写一个 C++20 实现的 Flux 查询语言实验项目：`cpp/pl/flux`。它不是为了完整复刻 InfluxData 官方 Flux，也不是为了立刻做成生产级数据库，而是为了回答一个更工程化的问题：如果从零实现一个可运行、可调试、可测试的 Flux 子集，需要哪些模块，它们之间应该如何分层？

目前这个项目已经不只是一个 parser。它包含 scanner、parser、AST dump、表达式解释器、运行时值模型、标准库 package、表流执行、SQLite/MySQL connector、查询计划、Page-based physical executor、CLI、REPL、LSP 和 conformance examples。换句话说，它已经有了一个小型语言运行时和单机查询引擎的骨架。

## 为什么选择 Flux

Flux 的语法很适合拿来做查询引擎实验。它既有脚本语言的表达能力，也有面向数据流的 pipeline 模型：

```flux
import "array"

array.from(rows: [
    {_time: 2024-01-01T00:00:00Z, host: "edge-1", region: "east", usage: 91},
    {_time: 2024-01-01T00:01:00Z, host: "edge-2", region: "west", usage: 42},
])
    |> filter(fn: (r) => r.usage > 80)
    |> keep(columns: ["host", "usage"])
    |> yield(name: "hot_hosts")
```

这段代码同时覆盖了几个关键点：导入 package、构造内存表、使用 record、使用 lambda、高阶函数、pipe-forward、表变换和结果输出。为了让它真正跑起来，项目至少需要完成词法分析、语法分析、AST 表达、作用域、函数调用、运行时值、表模型、builtin 注册和输出格式化。

## 当前项目是什么

项目当前更准确的定位是：

> 一个 Flux-native single-node federated query engine 的实验场。

这里有几个限定词很重要。

首先，它是 Flux-native。用户入口是 Flux 语言，而不是 SQL。SQL 数据源只是 connector 的一种实现，SQLite 和 MySQL 会在可以安全下推时生成 SQL，但上层语义仍然是 Flux 的 table stream、group key、pipe、window 和 function。

其次，它是 single-node。项目借鉴了 Presto/Trino 的 connector、split、page source、operator、pipeline 这些边界，但第一阶段不做 coordinator/worker、分布式 shuffle 或跨节点容错。

最后，它是实验场。实现优先保证结构清晰、测试可回归和行为可观察，不急着把官方 Flux 的全部标准库一次性补满。

## 一个查询如何流动

从源码到输出，大致路径如下：

![Flux 查询执行路径](/images/flux/query-flow.svg)

早期路径更接近 eager interpreter：builtin 直接操作 `TableValue`。现在 SQL provider 入口已经能携带 lazy logical plan，由 optimizer 和 physical executor 决定哪些前缀可以下推，哪些后缀需要 materialize 后回到内存执行。

## 当前支持的能力

语言前端支持常见 Flux 文件结构：`package`、`import`、变量赋值、`option`、`builtin` 声明、`testcase`、表达式语句和 block 中的 `return`。表达式层支持字面量、数组、对象、字典、record update、成员访问、索引访问、一元/二元/逻辑运算、条件表达式、字符串插值、正则、函数表达式和 pipe 表达式。

运行时支持 `null/bool/int/uint/float/string/time/duration/regexp/array/object/function/table` 等值类型。函数方面支持闭包、默认参数、命名参数、pipe 参数、expression-bodied function 和 block-bodied function。

数据源入口采用 package 形态：`array.from`、`csv.from`、`sqlite.from`、`mysql.from`。项目刻意没有实现 universe 顶层 `from(bucket:)`，避免把数据源能力塞进默认命名空间。

标准库已经包含 `array`、`csv`、`date`、`dict`、`join`、`json`、`math`、`regexp`、`runtime`、`sqlite`、`strings`、`system`、`types` 等 package。universe builtin 覆盖常见表变换、聚合、窗口、join、检查和输出函数。

## 模块边界为什么这样切

这个项目一开始最容易走偏的地方，是把所有东西都塞进 builtin 回调里。比如 `sqlite.from |> filter |> keep |> limit`，最直接的实现是每个 builtin 都拿到上一阶段的 `TableValue`，然后立即执行并返回新的 `TableValue`。这种模型很适合早期验证语义，但它有两个明显问题。

第一个问题是性能。只要数据来自 SQLite/MySQL，全量读入再过滤就会浪费数据源的索引、排序和聚合能力。第二个问题是职责混乱。builtin 如果既负责参数解析，又负责优化判断，又负责 SQL 生成，还负责物理执行，那么后续新增 connector 或 optimizer rule 时就会不断改同一层代码。

所以当前架构逐渐形成了几条边界：

- `syntax/*` 只负责源码到 AST。
- `runtime_eval` 负责表达式语义，不负责数据源执行策略。
- builtin 负责把语言级调用变成运行时值或 logical node。
- optimizer 负责 pushdown、rewrite 和 materialize boundary。
- connector 负责 metadata、split 和 page source。
- execution 负责 pipeline、driver、operator 和 Page 流。

这个切法的核心是让“语言语义”和“执行策略”分离。Flux 用户看到的是同一段查询；至于它走内存表、SQLite 下推、MySQL split scan 还是 fallback materialization，应该由计划和执行层决定。

## 可用子集和完整实现的区别

项目文档里经常说“Flux-like 子集”，这是一个刻意保守的说法。支持一个语言的 parser，并不等于完整支持这门语言；支持一个 builtin 名称，也不等于完整复刻官方所有边界语义。

以 `aggregateWindow` 为例，当前实现已经覆盖固定时长窗口、部分日历窗口、`offset`、`period`、`timeSrc`、`timeDst`、`location`、`createEmpty` 和 selector 空窗口行为。这个能力已经足够跑很多真实运维查询。但如果说“完整支持官方 aggregateWindow”，就必须逐项对齐官方 Flux 在所有 duration、timezone、empty table、selector、aggregate 函数、group key 组合下的行为，这不是当前项目的声明范围。

同样，LSP 已经支持 definition、references、rename、semantic tokens 等核心功能，但它还没有完整 workspace index 和跨文件类型分析。因此文章里应该用“当前已支持”“部分支持”“后续路线”这样的表述，避免把工程演进中的能力写成已经完成的承诺。

## 如何读这个项目的代码

如果想从代码角度理解项目，我建议按执行路径读，而不是按目录字母顺序读。

第一步看 `syntax/scanner.rl`、`syntax/parser.cpp`、`syntax/ast.h`。这能建立语言前端的模型：源码如何变成 AST，AST 节点如何保存 source location。

第二步看 `runtime/runtime_value.h`、`runtime/runtime_env.*`、`runtime/runtime_eval.cpp`。这能理解运行时值、作用域和表达式求值。

第三步看 `runtime/runtime_builtin_package.cpp` 和各类 `runtime_builtin_*` 文件。这里能看到 universe builtin、package registry、array/csv/date/math/strings 等标准库如何暴露给 Flux。

第四步看 `runtime/runtime_builtin_universe_transform.cpp`、`runtime/runtime_builtin_universe_aggregate.cpp`、`runtime/runtime_builtin_universe_window.cpp` 和 table helper。这里是内存表流语义最集中的地方。

第五步看 `connector/*`、`optimizer/*`、`plan/*`、`execution/*`。这条线是从数据源、logical/physical plan 到 Page execution 的查询引擎主干。

最后看 `contrib/lsp/*`。LSP 会反过来验证 parser location、symbol table 和 builtin metadata 是否足够稳定。

## 如何运行

构建 CLI：

```bash
bazel build //cpp/pl/flux:flux
```

执行内联表达式：

```bash
./bazel-bin/cpp/pl/flux/flux -e 'sum([1, 2, 3])'
```

输出 AST：

```bash
./bazel-bin/cpp/pl/flux/flux ast -e 'data |> filter(fn: (r) => r._value > 10)'
```

执行示例：

```bash
./bazel-bin/cpp/pl/flux/flux cpp/pl/flux/examples/feature_gallery/function_pipelines.flux
```

输出 JSON 并筛选结果：

```bash
./bazel-bin/cpp/pl/flux/flux \
  --output-format json \
  --result _result \
  cpp/pl/flux/examples/stdlib_conformance/array.flux
```

## 系列文章会怎么展开

这个系列会沿着执行路径向下讲。先讲 parser 和 AST，再讲 evaluator 和函数模型，然后讲标准库和 table pipeline。接着进入 connector、pushdown、logical/physical plan、Page-based execution。最后讲 LSP、测试体系、性能优化和路线图。

这个顺序的好处是，每一篇都对应项目中的一个真实边界。它不是按照目录名机械介绍，而是回答一个具体问题：源码如何变成 AST，AST 如何执行，表流如何变换，SQL 数据源如何下推，IDE 如何理解这门语言，以及我们如何确认这些能力没有在后续开发中退化。
