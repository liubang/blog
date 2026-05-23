---
title: 标准库设计：从 array package 看 builtin 扩展机制
description: "以 array package 为主线，介绍 Flux 运行时的 builtin registry、package import、参数校验、错误处理和 conformance examples。"
date: 2026-05-23
categories: [programming]
tags: [flux, stdlib, builtin, cpp]
authors: ["liubang"]
draft: true
---

一个语言运行时真正变得可用，往往不是因为表达式求值器支持了多少 operator，而是因为标准库让用户能完成真实任务。`cpp/pl/flux` 当前已经有一批 package：`array`、`csv`、`date`、`dict`、`join`、`json`、`math`、`regexp`、`runtime`、`sqlite`、`strings`、`system`、`types` 等。

其中 `array` 最适合用来讲 builtin 扩展机制，因为它既有普通函数，也有高阶函数，还和“如何替代传统循环”这个问题直接相关。

## Package import 如何工作

用户写：

```flux
import "array"
```

运行时会从 `BuiltinRegistry` 中加载 package object，并在当前环境中绑定 `array`。之后：

```flux
array.map(arr: [1, 2, 3], fn: (x) => x * 2)
```

本质上是 member lookup 找到 `array` 对象上的 `map` builtin function，然后通过 call evaluator 执行。

未知 package 不会直接导致 parser 失败。运行时会保留 metadata object，例如 `{path: "experimental/foo"}`，这对调试 import 信息和逐步扩展标准库比较友好。

## Registry 的价值不只是查表

`BuiltinRegistry` 看起来像一个从名字到函数的 map，但它在项目里承担了更重要的边界作用。

首先，它把 universe builtin 和显式 import package 分开。`filter`、`map`、`range` 这类默认可见函数属于 universe；`array.map`、`csv.from`、`sqlite.from` 则必须显式 import。这能避免数据源入口污染顶层命名空间。

其次，它让 runtime 可以在执行 import 时统一处理未知 package。未知 package 保留 metadata object，而不是直接让 parser 或 runtime 崩溃，后续调试 import path、别名和 LSP completion 都更容易。

第三，它为 LSP 提供 builtin metadata 的来源。completion、signatureHelp、inlayHint 如果完全靠硬编码，很快会和 runtime 脱节。长期更好的做法是让 package registry 成为 runtime 和工具链共享的能力描述。

## Builtin 的职责

一个 builtin 不应该什么都做。当前较健康的职责划分是：

- 解析和校验参数。
- 把 Flux `Value` 转换为 C++ 内部需要的数据。
- 执行当前函数的确定逻辑。
- 返回 `absl::StatusOr<Value>`。

错误处理尽量通过 status 返回，而不是抛异常。这样 CLI、测试和 LSP 相关工具都能拿到结构化错误。

对于 connector 和查询计划，长期方向是 builtin 只把语言级调用翻译成 logical node，不在 builtin 里做 optimizer 或 physical executor 决策。

## 参数校验比函数主体更重要

标准库函数最容易写成“快乐路径”。例如 `array.get(arr:, index:, default:)` 主逻辑只是取数组元素，但真正复杂的是边界语义：

- `arr` 必须是 array。
- `index` 必须是整数。
- 负数 index 是否允许。
- 越界时是报错，还是返回 `default`。
- `default` 没传时错误信息应该指向哪个函数。

这些问题如果每个 builtin 各写各的，错误信息会很不一致。项目里逐渐抽出了一批 helper，用于读取 object 参数、读取可选字段、做数字转换、检查函数参数和构造 status。这样标准库扩展速度会更快，也更不容易出现“同类错误不同报法”。

另外，`array.sort`、`array.unique` 这类函数还涉及 `Value` 比较语义。支持 int/uint/float/string/bool 和支持任意 object 排序不是一个难度级别。当前实现选择保守支持明确可比较的类型，不把复杂对象比较伪装成已经完整支持。

## array package 当前能力

基础函数包括：

- `array.from(rows:, bucket:)`
- `array.concat(arr:, v:)`
- `array.filter(arr:, fn:)`
- `array.map(arr:, fn:)`
- `array.contains(arr:, value:)`
- `array.reduce(arr:, identity:, fn:)`
- `array.any(arr:, fn:)`
- `array.all(arr:, fn:)`

最近又补齐了一批 sequence/helper 函数：

- `array.range(start:, stop:, step:)`
- `array.repeat(value:, n:)`
- `array.length(arr:)`
- `array.get(arr:, index:, default:)`
- `array.slice(arr:, start:, end:)`
- `array.sort(arr:, desc:)`
- `array.flatMap(arr:, fn:)`
- `array.find(arr:, fn:, default:)`
- `array.findIndex(arr:, fn:)`
- `array.take(arr:, n:)`
- `array.drop(arr:, n:)`
- `array.reverse(arr:)`
- `array.unique(arr:)`
- `array.unfold(seed:, fn:, limit:)`
- `array.scan(arr:, identity:, fn:)`
- `array.zip(left:, right:)`
- `array.enumerate(arr:)`

这些函数组合起来，已经能覆盖大量配置处理、序列生成、状态推进和查询辅助逻辑。

## array.from 为什么属于数据源入口

`array.from` 表面上是 array package 的函数，但在查询模型里它其实是一个 provider：它把内联 record 数组转换成 table stream。

这和 `array.map` 这类普通数组函数不同。`array.map` 输入输出都是 array；`array.from` 输入是 rows，输出是 table。它承担了小数据构造、单测 fixture、示例查询和跨源 join 中维表构造的作用。

这种设计也解释了为什么项目不提供顶层 `from(bucket:)`。所有数据源都使用 provider package 入口：`array.from`、`csv.from`、`sqlite.from`、`mysql.from`。这样新增数据源时有清晰命名空间，runtime prelude 也不会越来越臃肿。

## unfold 的安全阀

`array.unfold` 很强，但也最容易写出无限序列。因此它需要 `limit` 作为安全阀。用户函数每次返回 `{value, state, done}`，如果永远不返回 `done: true`，runtime 不能无限执行下去。

这个设计反映了标准库的一个原则：表达能力和资源边界要一起设计。只给用户一个通用循环构造，却没有上限、超时或内存控制，会让 CLI、测试和 LSP 试运行都很危险。

对于当前项目，`unfold` 的定位是生成有限序列和状态机，而不是构造无界流。真正的流式数据源应该走 connector/page source，而不是用 array 函数模拟。

## 一个 conformance 示例

`examples/stdlib_conformance/array.flux` 用一个文件覆盖 array package 的主行为。它不是展示文档，而是可执行契约：

```flux
import "array"

numbers = [1, 2, 3]
extended = array.concat(arr: numbers, v: [4])

{
    total: array.reduce(arr: extended, identity: 0, fn: (x, acc) => acc + x),
    found: array.find(arr: extended, fn: (x) => x == 3),
    range: array.range(start: 0, stop: 6, step: 2),
    zipped: array.zip(left: ["a", "b"], right: [1, 2]),
}
```

测试脚本会以 JSON golden output 约束结果。一旦后续改动破坏了 array 行为，conformance test 会立即暴露。

## 文档、补全和测试要一起更新

补一个 builtin 时，只改 runtime 是不够的。这个项目现在至少需要同步几处：

- runtime package registry。
- runtime unit test。
- stdlib conformance 示例和 golden output。
- `SUPPORT_MATRIX.md`。
- `README.md` 中的用户可见函数表。
- LSP known package completion。

这看起来麻烦，但它能避免“函数能跑但用户不知道”“LSP 不补全”“文档说没有”“后续改坏没人发现”这些实际问题。标准库越大，这种同步越重要。

## array.range 能不能替代 for

它可以替代一部分传统 for 循环，尤其是“在有限整数区间上做纯计算”的场景：

```flux
array.reduce(
    arr: array.range(start: 0, stop: 10),
    identity: 0,
    fn: (x, acc) => acc + x,
)
```

但它不是完整替代。传统 for 可以依赖可变状态、break、continue、多层嵌套和副作用；当前 Flux 子集更偏向不可变值和高阶函数组合。要表达状态生成，应该用 `unfold`；要保留中间状态，应该用 `scan`；要做过滤映射，应该组合 `filter/map/flatMap`。

## 标准库扩展原则

我现在更倾向于用 conformance 反推标准库设计。每补一个 builtin，就必须回答：

- 参数形态是否和 Flux 心智模型一致？
- 错误是否可诊断？
- 是否有正例和负例测试？
- 是否有 conformance example 主覆盖？
- 是否影响 LSP completion 和文档支持矩阵？

这能避免标准库“看起来很多函数，实际不可用”的问题。

## 小结

标准库是 runtime 面向用户的主要表面。`array` package 已经从最初的几个 helper 发展成可以表达循环、搜索、状态推进和表构造的核心包。后续继续扩展标准库时，重点不是简单堆函数数量，而是让每个函数有稳定语义、测试契约和文档边界。
