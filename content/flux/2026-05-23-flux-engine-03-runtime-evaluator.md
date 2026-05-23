---
title: 表达式解释器：让 Flux 代码真正跑起来
description: "介绍 Flux 运行时值模型、Environment、表达式求值、函数调用、闭包、pipe 参数和一次 numeric equality bug 的修复。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, runtime, interpreter, cpp]
authors: ["liubang"]
weight: 3
series: ["Flux"]
series_weight: 3
---

Parser 负责把源码变成 AST，但 AST 本身不会执行。`cpp/pl/flux` 的执行入口主要在 `runtime/runtime_eval.cpp` 和 `runtime/runtime_exec.cpp`：前者处理表达式求值，后者处理文件级语句执行、结果收集和顶层环境。

## Value：运行时的统一数据模型

解释器首先需要一个统一的运行时值类型。当前 `Value` 覆盖了 Flux 子集执行所需的主要类型：

- `null`
- `bool`
- `int` / `uint` / `float`
- `string`
- `time`
- `duration`
- `regexp`
- `array`
- `object`
- `function`
- `table`

数组和对象是很多高级能力的基础。数组承载 `array.map/filter/reduce` 这类高阶函数；对象既表示普通 record，也表示 package object、函数命名参数和 table row。

`table` 是项目中特别重要的一类值。它不是单张二维表的简单包装，而是 Flux table stream 的内存表示，包含 rows、logical tables、group key、bucket、result name 等信息。后续查询执行文章会单独展开。

## Value 的工程取舍

`Value` 是解释器最核心的数据结构之一。它需要在两个方向之间取平衡：一方面要足够通用，能承载 Flux 的动态值；另一方面不能变成“什么都能塞”的无约束容器。

当前实现把类型枚举和具体 payload 绑定在一起，调用方通过 `type()` 判断，再使用 `as_int()`、`as_array()`、`as_object()` 这类访问器取值。这种设计比到处使用 `std::any` 更可控，也比一开始引入复杂类型系统更轻量。

它的代价是 runtime 需要大量显式类型检查。例如 builtin 取参数时必须确认字段存在、类型正确、数组元素符合预期。项目里很多 helper 的价值就在这里：把重复的参数检查、错误信息和 `StatusOr` 返回模式收敛起来，避免每个 builtin 都手写一套脆弱逻辑。

从后续演进看，`Value` 不应该承担静态类型推断职责。类型检查应该在 analyzer/binder 层完成；`Value` 保持 runtime 表示即可。

## Environment：词法作用域

解释器中的 `Environment` 负责变量绑定和作用域查找。顶层执行时，默认 prelude 会安装 universe builtin；显式 `import` 会从 package registry 载入内置包，例如：

```flux
import "array"

xs = [1, 2, 3]
array.map(arr: xs, fn: (x) => x * 2)
```

函数调用时会创建新的子环境。参数绑定、默认值、闭包捕获和局部变量都依赖这条作用域链。

## 作用域模型和 option 绑定

Flux 里 `option` 不是普通变量赋值的完全同义词。它更像运行时配置入口，例如 `option task = {...}` 或 `option location = {...}`。当前实现会把 option 绑定纳入环境，使后续表达式和 builtin 可以读取。

用户函数调用时，参数绑定发生在新的局部环境中；闭包保存定义处环境。这样同名变量会按词法作用域解析，而不是动态作用域解析。

这对 LSP 也有影响。runtime 能正确查找变量，不代表 LSP 自动能正确跳转。LSP 需要独立构建符号表，并尽量模拟同样的作用域规则。否则就会出现运行时没问题、编辑器跳错位置的割裂体验。

## 表达式求值

表达式 evaluator 直接消费 AST 节点。常见路径包括：

- literal 求值：整数、浮点、字符串、time、duration、regex、bool、null。
- 标识符查找：从当前环境向父环境查找。
- 数组和对象构造。
- record update：`{base with enabled: true}`。
- member/index：`r.host`、`arr[0]`、`obj["host"]`。
- unary/binary/logical：`not`、`-`、`+`、`==`、`=~`、`and`、`or`。
- conditional：`if cond then a else b`。
- function value 和 call expression。

`and` / `or` 做短路求值。比如 `a and b` 在 `a` 为 false 时不会求值 `b`；`a or b` 在 `a` 为 true 时不会求值 `b`。这不仅符合语言直觉，也避免了右侧表达式可能触发的无意义错误。

## 求值顺序和错误传播

解释器里的每一步基本都返回 `absl::StatusOr<Value>`。这种模式让错误传播很直接：子表达式失败，父表达式立即返回失败状态。它比异常更适合这个项目，因为 CLI、unit test 和未来 LSP runtime diagnostics 都可以显式检查 status code 和 message。

二元表达式的求值顺序是先左后右。普通 binary operator 会求值两侧；logical operator 则有自己的短路逻辑。这个差异不能只靠 operator 枚举处理，因为 `and/or` 的右侧可能包含未定义变量、除零或函数调用副作用。虽然当前 Flux 子集基本是无副作用表达式，但短路语义仍然必须准确。

正则匹配也是 runtime 层处理的典型例子。parser 只知道 `/cpu.*/` 是 regex literal，runtime 才会在 `=~` 或 `!~` 上检查左侧是 string、右侧是 regex，并调用 C++ regex 引擎执行匹配。

## 函数调用与命名参数

Flux 调用大量使用命名参数：

```flux
array.filter(arr: [1, 2, 3, 4], fn: (x) => x > 2)
```

运行时会把命名参数组织成对象传给 builtin，或者按用户函数参数列表绑定到局部环境。对于 pipe-forward：

```flux
array.from(rows: rows)
    |> filter(fn: (r) => r.active)
```

左侧结果会被注入到右侧调用的 pipe 参数。builtin 通常约定 pipe 参数名为 `tables`；用户函数也支持 `<-tables` 形态。

## Builtin call 和 user function call 的差异

从 AST 看，builtin 和用户函数都是 call expression。但 runtime 执行时，两者完全不同。

builtin 是 C++ 函数包装出来的 `Value::function`。它通常接收一个参数数组，其中命名参数会被组织成对象，然后由 builtin 自己校验字段。这样做的好处是扩展 package 很方便；缺点是参数错误多在 runtime 暴露。

用户函数则需要按照 Flux 参数列表绑定。默认值在缺参时求值；命名参数按名字匹配；pipe 参数从 pipe 左侧注入；函数体可能是 expression，也可能是 block。block-bodied function 需要处理局部语句和 `return`。

因此 call evaluator 的关键不是“调用一个函数指针”，而是把 Flux 的参数语义完整落到环境和 `Value` 上。

## Closure：函数捕获外层变量

函数值创建时会保存定义处环境，因此可以捕获外层变量：

```flux
threshold = 80

is_hot = (r) => r.usage > threshold
```

后续调用 `is_hot` 时，即使调用点在别处，`threshold` 仍然从函数定义时的环境链中解析。这也是 UDF 能成为项目一等能力的关键。

## 一次真实 bug：numeric equality

解释器有一个典型 bug：数值二元表达式会优先进入 `eval_binary_numeric` 分支，这个分支最初处理了算术和大小比较：

```text
+ - * / % < <= > >=
```

但漏掉了 `==` 和 `!=`。结果是：

```flux
array.filter(arr: [1, 2, 3, 4], fn: (x) => x == 3)
```

会被识别为 numeric binary operator，却在 numeric 分支里返回 unsupported。修复方式很直接：在 numeric evaluator 中补上 `EqualOperator` 和 `NotEqualOperator`，并加回归测试覆盖 `x == 3` 和 `x != 3`。

这个 bug 很小，但说明了 evaluator 分层的一个原则：只要某个分支提前接管了一类值组合，就必须完整覆盖这类组合下合法的 operator，否则后面的通用分支根本没有机会处理它。

## 为什么这个 bug 不适合只在 array 层修

`x == 3` 最先是在 array 高阶函数里暴露出来的，但根因不在 array。`array.filter` 只是调用用户传入的函数；函数体里的 comparison expression 由通用 evaluator 执行。

如果在 `array.filter` 里特殊处理 equality，会让同一个表达式在不同上下文行为不一致：

```flux
x = 3 == 3
array.filter(arr: [1, 2, 3], fn: (v) => v == 3)
```

这两个地方都应该由同一套 binary evaluator 决定。因此修复必须发生在 numeric binary evaluator，而不是某个 builtin 内部。这也是定位 runtime bug 时很重要的判断：看起来是某个标准库函数坏了，实际可能是语言核心语义分支漏了。

## 语句执行

文件执行由 statement executor 负责。它会按顺序执行 import、option、变量赋值、表达式语句、testcase 等，并维护命名结果。

CLI 的 `--result`、`--list-results`、human/csv/json 输出都依赖结果收集层。REPL 则复用同一个运行时环境，所以可以做到：

```text
flux> x = 40
40
flux> x + 2
42
```

## 小结

`runtime_eval` 把 AST 变成了可执行语义。它目前覆盖了常见表达式、函数、闭包、pipe 和标准库调用，已经足以运行相当复杂的 Flux 示例。后续如果要引入类型检查，最好不要把类型逻辑继续塞进 evaluator，而是增加 analyzer/binder 层，让 evaluator 专注于执行。
