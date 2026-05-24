---
title: "Flux 01: 项目目标与整体架构"
description: "介绍 Flux C++ Playground 的项目定位、使用方式、当前能力边界，以及一个 Flux 查询从源码到输出经过的主要模块。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, compiler, database, cpp]
authors: ["liubang"]
weight: 1
series: ["Flux"]
series_weight: 1
lightgallery: true
---

这几年我一直在写一个 C++20 实现的 Flux 查询语言实验项目：`cpp/pl/flux`。它不是为了完整复刻 InfluxData 官方 Flux，也不是为了立刻做成生产级数据库，而是为了回答一个更工程化的问题：如果从零实现一个可运行、可调试、可测试的 Flux 子集，需要哪些模块，它们之间应该如何分层？

很多语言项目会停在 parser demo：能把源码解析成 AST，能打印一棵树，已经很有成就感。但查询语言更麻烦。它不仅要理解表达式，还要处理表流、group key、窗口、聚合、数据源、输出格式、IDE 体验和性能退化。只要其中一个边界没想清楚，后面就很容易把优化逻辑、运行时逻辑和标准库逻辑搅在一起。

目前这个项目已经不只是一个 parser。它包含 scanner、parser、AST dump、表达式解释器、运行时值模型、标准库 package、表流执行、SQLite/MySQL connector、查询计划、Page-based physical executor、CLI、REPL、LSP 和 conformance examples。换句话说，它已经有了一个小型语言运行时和单机查询引擎的骨架。

这一篇是整个系列的入口。我会先讲项目目标和能力边界，再讲一条 Flux 查询从源码到输出会经过哪些层，最后给出代码阅读和运行方式。后面的文章会沿着这些边界逐层展开。

## 为什么选择 Flux

Flux 很适合拿来做查询引擎实验，因为它同时具备三种特征。

第一，它是一门表达式语言。它有字面量、对象、数组、函数、闭包、条件表达式、正则、字符串插值和命名参数。实现它时，必须认真处理 scanner、parser、AST、runtime value、environment 和 function call。

第二，它是一门 pipeline 查询语言。`|>` 不是普通装饰语法；它决定了用户如何把数据源、过滤、投影、聚合和输出串起来。实现 pipe 后，运行时必须决定：一个表算子是立即执行，还是追加到 lazy logical plan 等待 optimizer 处理？

第三，它围绕 table stream 建模。Flux 查询不是简单返回一个数组，而是返回一组 logical table，每张表有 group key、列、行和结果名。这让它天然适合探索查询引擎里的 table pipeline、window、aggregate、join 和 connector pushdown。

一段很小的 Flux 查询就能覆盖这些问题：

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

为了让它真正跑起来，项目至少需要完成这些事情：

- 词法分析：识别 `import`、time literal、object、array、pipe、lambda。
- 语法分析：把 pipe chain、function call、record literal 组织成 AST。
- 作用域：导入 `array` package，并绑定用户定义变量。
- 函数调用：支持命名参数、lambda、pipe 参数。
- 表模型：让 `array.from` 产生 table stream。
- builtin registry：让 `filter`、`keep`、`yield` 能被查到并执行。
- 输出格式：把结果以 human、CSV 或 JSON 形式呈现。

这就是 Flux 的价值：一个小查询足以逼出语言实现和查询执行的完整骨架。

## 当前项目是什么

项目当前更准确的定位是：

> 一个 Flux-native single-node federated query engine 的实验场。

这里有几个限定词很重要。

首先，它是 Flux-native。用户入口是 Flux 语言，而不是 SQL。SQL 数据源只是 connector 的一种实现。SQLite 和 MySQL 会在可以安全下推时生成 SQL，但上层语义仍然是 Flux 的 table stream、group key、pipe、window 和 function。

其次，它是 single-node。项目借鉴了 Presto/Trino 的 connector、split、page source、operator、pipeline 这些边界，但第一阶段不做 coordinator/worker、分布式 shuffle 或跨节点容错。单机也需要 split、driver、exchange 和 Page 流，因为这些边界能让后续扩展不推翻主干。

最后，它是实验场。实现优先保证结构清晰、测试可回归和行为可观察，不急着把官方 Flux 的全部标准库一次性补满。很多能力会明确标为“部分支持”，这不是谦虚，而是对用户和维护者负责。

如果用一句话概括，它不是“Flux 官方兼容实现”，而是“用 Flux 这门语言做查询引擎分层实验”。

## 一个查询如何流动

从源码到输出，大致路径如下：

![Flux 查询执行路径](/images/flux/query-flow.svg "Flux 查询执行路径")

早期路径更接近 eager interpreter：builtin 直接操作 `TableValue`。这条路径简单、直观、非常适合把语义先跑通。比如 `array.from |> filter |> keep` 可以直接变成内存表上的逐行变换。

现在 SQL provider 入口已经能携带 lazy logical plan。`sqlite.from`、`mysql.from` 不需要立刻把整张表读成 `TableValue`；它们可以先构造 `SourceScan`，再让 `range/filter/keep/sort/limit` 有机会被 optimizer 合并进 scan request。

完整路径可以分成几段：

1. Scanner 把源码切成 token。
2. Parser 把 token 组织成 AST，并尽量保留 source location。
3. Statement executor 处理 package/import/option/assignment/expression。
4. Expression evaluator 执行标量表达式、函数、闭包和普通 builtin。
5. 表算子遇到 lazy plan 时追加 logical node，遇到旧路径时操作 `TableValue`。
6. Optimizer 识别可下推前缀，并插入 materialize fallback boundary。
7. Physical planner 生成 pipeline、driver、operator 和 Page 流。
8. Connector runtime 负责 metadata、split、page source。
9. Output formatter 把结果转成 human、CSV 或 JSON。

这个路径的核心思想是：语言语义先稳定表达，执行策略再根据上下文选择。

## 当前支持的能力

语言前端支持常见 Flux 文件结构：`package`、`import`、变量赋值、`option`、`builtin` 声明、`testcase`、表达式语句和 block 中的 `return`。表达式层支持字面量、数组、对象、字典、record update、成员访问、索引访问、一元/二元/逻辑运算、条件表达式、字符串插值、正则、函数表达式和 pipe 表达式。

运行时支持 `null/bool/int/uint/float/string/time/duration/regexp/array/object/function/table` 等值类型。函数方面支持闭包、默认参数、命名参数、pipe 参数、expression-bodied function 和 block-bodied function。

数据源入口采用 provider package 形态：

- `array.from`：构造内存表。
- `csv.from`：读取 raw/annotated CSV。
- `sqlite.from`：扫描 SQLite 表，支持保守 SQL pushdown。
- `mysql.from`：扫描 MySQL 表，支持 range split 和保守 SQL pushdown。

项目刻意没有实现 universe 顶层 `from(bucket:)`。这是一个架构边界：数据源入口应该通过 provider package 显式进入，避免把外部系统能力塞进默认命名空间。

标准库已经包含 `array`、`csv`、`date`、`dict`、`join`、`json`、`math`、`regexp`、`runtime`、`sqlite`、`strings`、`system`、`timezone`、`types` 等 package。universe builtin 覆盖常见表变换、聚合、窗口、join、检查和输出函数。

执行层已经进入 Page-based 主干：scan/filter/project/range 可以逐 Page 执行；group/distinct/aggregate 有 streaming accumulator；Top-N 可以 split 内 partial、root 全局合并；connector split profile 会输出 rows/pages/bytes/wall time。

LSP 也已经具备雏形：诊断、补全、hover、definition、references、rename、signature help、semantic tokens、code action、inlay hint、selection range 和 formatter 都有基础实现和测试。

## 模块边界为什么这样切

这个项目一开始最容易走偏的地方，是把所有东西都塞进 builtin 回调里。

比如：

```flux
sqlite.from(path: "metrics.db", table: "cpu")
    |> filter(fn: (r) => r.host == "edge-1")
    |> keep(columns: ["_time", "host", "_value"])
    |> limit(n: 10)
```

最直接的实现是每个 builtin 都拿到上一阶段的 `TableValue`，立即执行并返回新的 `TableValue`。这种模型适合早期验证语义，但它有两个明显问题。

第一个问题是性能。只要数据来自 SQLite/MySQL，全量读入再过滤就会浪费数据源的索引、排序和聚合能力。第二个问题是职责混乱。builtin 如果既负责参数解析，又负责优化判断，又负责 SQL 生成，还负责物理执行，那么后续新增 connector 或 optimizer rule 时就会不断改同一层代码。

所以当前架构逐渐形成了几条边界：

- `syntax/*` 只负责源码到 AST。
- `runtime_eval` 负责表达式语义，不负责数据源执行策略。
- builtin 负责语言级参数解析，并在合适时构造 runtime value 或 logical node。
- optimizer 负责 pushdown、rewrite 和 materialize boundary。
- connector 负责 metadata、split 和 page source。
- execution 负责 pipeline、driver、operator 和 Page 流。
- CLI/LSP/conformance 负责用户可观察行为和回归保护。

这个切法的核心是让“语言语义”和“执行策略”分离。Flux 用户看到的是同一段查询；至于它走内存表、SQLite 下推、MySQL split scan 还是 fallback materialization，应该由计划和执行层决定。

## 可用子集和完整实现的区别

项目文档里经常说“Flux-like 子集”，这是一个刻意保守的说法。支持一个语言的 parser，并不等于完整支持这门语言；支持一个 builtin 名称，也不等于完整复刻官方所有边界语义。

以 `aggregateWindow` 为例，当前实现已经覆盖固定时长窗口、部分日历窗口、`offset`、`period`、`timeSrc`、`timeDst`、`location`、`createEmpty` 和 selector 空窗口行为。这个能力已经足够跑很多真实运维查询。但如果说“完整支持官方 aggregateWindow”，就必须逐项对齐官方 Flux 在所有 duration、timezone、empty table、selector、aggregate 函数、group key 组合下的行为，这不是当前项目的声明范围。

再比如 connector pushdown。当前 SQLite/MySQL 支持保守线性前缀下推，但不做任意 Flux 函数到 SQL 的翻译，也不做跨源 join 下推。这个边界不是能力不足的借口，而是避免语义漂移的必要约束。

同样，LSP 已经支持 definition、references、rename、semantic tokens 等核心功能，但它还没有完整 workspace index 和跨文件类型分析。因此文章里应该用“当前已支持”“部分支持”“后续路线”这样的表述，避免把工程演进中的能力写成已经完成的承诺。

## 如何读这个项目的代码

如果想从代码角度理解项目，我建议按执行路径读，而不是按目录字母顺序读。

第一步看 `syntax/scanner.rl`、`syntax/parser.cpp`、`syntax/ast.h`。这能建立语言前端的模型：源码如何变成 AST，AST 节点如何保存 source location。

第二步看 `runtime/runtime_value.h`、`runtime/runtime_env.*`、`runtime/runtime_eval.cpp`。这能理解运行时值、作用域和表达式求值。

第三步看 `runtime/runtime_builtin_package.cpp` 和各类 `runtime_builtin_*` 文件。这里能看到 universe builtin、package registry、array/csv/date/math/strings/timezone 等标准库如何暴露给 Flux。

第四步看 `runtime/runtime_builtin_universe_transform.cpp`、`runtime/runtime_builtin_universe_aggregate.cpp`、`runtime/runtime_builtin_universe_window.cpp` 和 table helper。这里是内存表流语义最集中的地方。

第五步看 `connector/*`、`optimizer/*`、`plan/*`、`execution/*`。这条线是从数据源、logical/physical plan 到 Page execution 的查询引擎主干。

第六步看 `cli/*`、`examples/stdlib_conformance/*` 和 `benchmark/*`。这里能看到用户入口、公开行为契约和性能验证方式。

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

运行 Flux 模块完整测试：

```bash
bazel test //cpp/pl/flux/... --test_output=errors
```

运行 conformance：

```bash
bazel test //cpp/pl/flux:stdlib_conformance_test --test_output=errors
```

## 如何判断一个能力该放在哪层

写这个项目时，我经常用一个简单问题约束设计：这个能力是语言语义，还是执行策略？

如果它描述用户代码是什么意思，它应该靠近 parser、runtime evaluator、builtin registry 或 logical plan。例如闭包捕获、默认参数、`group(columns:)` 的逻辑表语义，都属于语言和查询语义。

如果它描述怎样更快地执行，它应该靠近 optimizer、connector 或 physical executor。例如 filter pushdown、projection pruning、split planning、partial/final aggregate、Top-N root merge，都属于执行策略。

如果它影响用户可观察行为，它必须被 CLI、conformance、LSP 或 benchmark 守住。例如 JSON 输出字段、错误 source location、completion item、semantic token 分类、profile 字段，都不是内部细节。

这条判断不一定每次都能给出完美答案，但能防止最常见的架构滑坡：在某个 builtin 里顺手加一点 optimizer，在某个 formatter 里顺手补一点语义，在某个 connector 里顺手吞掉 Flux runtime 的边界。

## 系列文章会怎么展开

这个系列会沿着执行路径向下讲。

第 02 篇先补一张用户语法地图，讲当前 Flux 子集如何写变量、函数、参数、运算符、对象、数组、pipe 查询和数据源入口。第 03 篇讲 scanner、parser、AST、表达式优先级和错误恢复。第 04 篇讲 runtime value、environment、表达式求值、函数调用和 numeric equality bug。第 05 篇讲用户自定义函数、高阶函数、闭包和没有循环语法时如何用 array helper 表达状态机。

第 06 篇讲标准库、package registry、builtin 参数校验和 conformance。第 07 篇进入 table pipeline，讲 `TableValue`、logical table、group key、aggregate/selector、join/window 和 CLI 输出语义。第 08 篇讲 connector、SQLite/MySQL、pushdown contract 和 fallback。第 09 篇讲 logical plan、physical plan、pipeline、driver、operator 和 Page。第 10 篇讲 LSP。第 11 篇讲测试体系。第 12 篇讲性能优化和 benchmark。第 13 篇会回到 roadmap，梳理从可用到好用还要补哪些能力。

这个顺序的好处是，每一篇都对应项目中的一个真实边界。它不是按照目录名机械介绍，而是回答一个具体问题：源码如何变成 AST，AST 如何执行，表流如何变换，SQL 数据源如何下推，IDE 如何理解这门语言，以及我们如何确认这些能力没有在后续开发中退化。

## 下一篇

下一篇会先切到使用者视角，系统梳理当前 Flux 子集的语法：变量、option、函数、参数、运算符、对象、数组、pipe 查询和数据源入口。

## 小结

`cpp/pl/flux` 的意义不在于它已经完整实现了 Flux，而在于它把一门查询语言从源码、运行时、标准库、表流、connector、执行计划、IDE 到测试性能的主要边界都走了一遍。

这让它成为一个很适合研究语言实现和查询引擎分层的项目：足够小，可以读懂；足够完整，能暴露真实工程问题。后面的文章会逐层拆开这些问题，看每一层为什么这样设计，以及哪些地方仍然只是阶段性答案。
