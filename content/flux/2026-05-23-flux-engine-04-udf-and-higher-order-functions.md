---
title: UDF 与高阶函数：Flux 中函数能力的边界
description: "系统说明当前 Flux 实现支持的用户自定义函数、闭包、默认参数、pipe 参数、高阶函数，以及如何用 array 函数表达循环。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, udf, functional-programming, cpp]
authors: ["liubang"]
weight: 4
series: ["Flux"]
series_weight: 4
---

Flux 查询的一个重要特点是函数无处不在。`filter(fn:)`、`map(fn:)`、`reduce(fn:)` 都要求用户把函数作为参数传进去。对这个项目来说，UDF 和高阶函数不是锦上添花，而是让查询语言真正可组合的核心能力。

## 当前支持的函数形态

当前实现支持 expression-bodied function：

```flux
double = (x) => x * 2
```

也支持 block-bodied function：

```flux
classify = (usage) => {
    if usage > 80 then {
        return "hot"
    }
    return "normal"
}
```

函数可以有默认参数：

```flux
score = (usage, factor=2) => usage * factor
```

也可以使用命名参数调用：

```flux
score(usage: 42, factor: 3)
```

对于 pipeline 场景，函数参数可以声明 pipe 参数：

```flux
only_hot = (<-tables, threshold=80) =>
    tables |> filter(fn: (r) => r.usage > threshold)
```

这样用户函数就能像 builtin 一样进入 pipe 链。

## 函数值的内部语义

用户函数在 runtime 中不是“源码字符串”。parser 会把参数列表、默认值、pipe 参数和函数体保存到 `FunctionExpr`，runtime 创建函数值时再捕获定义处环境。

调用时大致有几步：

1. 创建以闭包环境为父级的新环境。
2. 根据实参对象绑定命名参数。
3. 对缺失参数求默认值。
4. 如果存在 pipe 参数，把 pipe 左侧值绑定进去。
5. 执行 expression body 或 block body。
6. 如果 block 中遇到 `return`，提前结束函数体。

这个流程看起来和普通脚本语言类似，但在 Flux 查询里尤其重要，因为很多 builtin 都把函数当参数。`filter(fn:)` 的 `fn` 不是 callback 语法糖，而是真正的一等函数值。

## 默认参数的求值时机

默认参数容易被写错。一个常见问题是：默认值应该在函数定义时求值，还是调用时求值？

当前实现更接近调用时按环境求值的模型。这样默认值可以引用函数定义处可见的绑定，也能跟闭包行为保持一致。后续如果引入类型检查，需要明确默认参数表达式的作用域、依赖和错误诊断。

例如：

```flux
base = 10
add = (x, step=base) => x + step
```

`step` 的默认值不是简单字面量，而是一个表达式。runtime 必须在正确环境中求值，否则闭包和默认参数会出现不一致。

## 闭包捕获

函数会捕获定义时的环境：

```flux
threshold = 80

is_hot = (r) => r.usage > threshold
```

这使配置驱动的查询非常自然。例如可以先构造 watchlist 数组，再在后续 filter/map 中引用它。

```flux
import "array"

watchlist = ["edge-1", "edge-3"]

array.from(rows: rows)
    |> filter(fn: (r) => array.contains(arr: watchlist, value: r.host))
```

## 闭包在查询配置中的价值

闭包让 Flux 查询可以把“策略”和“数据流”分离。比如告警阈值、白名单、字段映射、区域配置都可以在前面定义，然后被多个 pipeline 复用。

```flux
threshold = 80
watch = ["edge-1", "edge-2"]

is_target = (r) =>
    r.usage > threshold and array.contains(arr: watch, value: r.host)

data |> filter(fn: is_target)
```

如果没有闭包，用户只能把所有配置硬塞进每个 lambda，查询很快会变得不可维护。对于一个查询语言来说，闭包的价值不在于展示“语言很强”，而在于让真实查询可以结构化。

## 高阶函数

array package 已经支持一批高阶函数：

- `array.filter(arr:, fn:)`
- `array.map(arr:, fn:)`
- `array.reduce(arr:, identity:, fn:)`
- `array.any(arr:, fn:)`
- `array.all(arr:, fn:)`
- `array.flatMap(arr:, fn:)`
- `array.find(arr:, fn:)`
- `array.findIndex(arr:, fn:)`
- `array.scan(arr:, identity:, fn:)`
- `array.unfold(seed:, fn:, limit:)`

这些函数覆盖了过滤、映射、折叠、搜索、状态展开和中间状态保留。

## 高阶函数的参数约定

不同高阶函数对 `fn` 的参数约定不同。

`array.map`、`array.filter`、`array.any`、`array.all`、`array.find`、`array.findIndex` 通常传入当前元素：

```flux
array.filter(arr: [1, 2, 3], fn: (x) => x > 1)
```

`array.reduce` 和 `array.scan` 需要当前元素和 accumulator：

```flux
array.reduce(arr: [1, 2, 3], identity: 0, fn: (x, acc) => acc + x)
```

`array.unfold` 则反过来：用户函数接收当前 state，返回下一步的 `{value, state, done}`。这类协议必须在 builtin 中严格校验，否则错误会变成很难理解的 member access 失败。

高阶函数实现时还有一个隐含要求：用户函数返回值必须符合当前函数语义。`filter` 要 bool，`flatMap` 要 array，`unfold` 要 object。对这些返回值的错误信息越具体，用户越容易定位查询问题。

## 没有 for/while 时如何写循环

当前实现不支持传统 `for` / `while` 语法。Flux 本身也更鼓励通过数据流和函数组合表达迭代。对于有限序列，可以使用 `array.range` 构造索引，再用 `map/reduce/scan` 处理：

```flux
import "array"

sum10 = array.reduce(
    arr: array.range(start: 1, stop: 11),
    identity: 0,
    fn: (x, acc) => acc + x,
)
```

这相当于传统语言中的：

```text
acc = 0
for x in 1..10:
    acc += x
```

如果需要保留每一步状态，可以用 `scan`：

```flux
prefix = array.scan(
    arr: [1, 2, 3, 4],
    identity: 0,
    fn: (x, acc) => acc + x,
)
```

结果是每一步的累加值。

## 用 unfold 表达状态机

`array.unfold` 用一个 seed 和一个状态转移函数生成序列。函数返回 `{value, state, done}`，当 `done` 为 true 时停止。

```flux
import "array"

fib = array.unfold(
    seed: {a: 0, b: 1, i: 0},
    fn: (s) => ({
        value: s.a,
        state: {a: s.b, b: s.a + s.b, i: s.i + 1},
        done: s.i >= 10,
    }),
)
```

这类写法可以表达 Fibonacci、分页游标、有限状态机、重试计划等场景。它和 `while` 的区别是：循环状态显式变成 record，停止条件也显式成为返回值的一部分。

## 用 scan 表达动态规划的前缀状态

`scan` 和 `reduce` 的区别是，`reduce` 只返回最终 accumulator，`scan` 返回每一步 accumulator。很多算法如果需要观察中间状态，`scan` 更合适。

例如计算前缀和：

```flux
prefix = array.scan(
    arr: [3, 1, 4, 1, 5],
    identity: {sum: 0},
    fn: (x, acc) => ({sum: acc.sum + x}),
)
```

如果要实现更复杂的状态，例如“到当前位置为止的最大值”“连续失败次数”“滑动状态”，都可以把 accumulator 设计成 record。Flux 当前没有可变变量，record accumulator 就是显式状态。

这也是 functional style 和 imperative style 的核心差异：状态不是隐藏在循环体里的可变局部变量中，而是作为函数输入输出被显式传递。

## 能力边界

当前函数能力仍有边界。

首先，没有类型检查层。函数参数类型和返回类型主要靠 runtime 检查，错误会在执行时暴露。

其次，不支持传统 `for` / `while`。大多数有限循环可以用 `array.range + reduce/scan/map` 表达，但不是所有 imperative loop 都适合这样改写。特别是提前 break、多层嵌套循环和复杂副作用，目前不是项目目标。

再次，递归不是当前重点路径。即使能在某些场景下表达，也没有尾递归优化或递归深度控制，不适合作为推荐写法。

## 小结

当前 UDF 实现已经足以支撑真实查询中的函数抽象：闭包、默认参数、命名参数、pipe 参数和高阶函数都可用。它的设计倾向是 functional data processing，而不是通用 imperative 编程语言。后续如果要进一步增强函数能力，优先级应该是类型检查、错误诊断和更完整的标准库组合，而不是急着加入传统循环语句。
