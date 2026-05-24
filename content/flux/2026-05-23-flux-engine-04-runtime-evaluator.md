---
title: 表达式解释器：让 Flux 代码真正跑起来
description: "介绍 Flux 运行时值模型、Environment、表达式求值、函数调用、闭包、pipe 参数和一次 numeric equality bug 的修复。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, runtime, interpreter, cpp]
authors: ["liubang"]
weight: 4
series: ["Flux"]
series_weight: 4
---

Parser 负责把源码变成 AST，但 AST 本身不会执行。`cpp/pl/flux` 的执行入口主要在 `runtime/runtime_eval.cpp` 和 `runtime/runtime_exec.cpp`：前者处理表达式求值，后者处理文件级语句执行、结果收集和顶层环境。

这一层是语言项目从“能解析”到“能运行”的分水岭。Parser 可以只关心结构，runtime evaluator 必须处理值、作用域、函数调用、错误传播、短路逻辑、pipe 参数、闭包捕获和 builtin 约定。只要这里的边界不稳，后面的标准库、table pipeline、LSP 诊断和 CLI 输出都会跟着变脆。

本文会沿着一条执行路径讲：Value 如何承载运行时数据，Environment 如何处理词法作用域，表达式如何逐步求值，用户函数和 builtin 为什么不同，以及一个 numeric equality bug 为什么必须在 evaluator 层修。

## Value：运行时的统一数据模型

解释器首先需要一个统一的运行时值类型。当前 `Value` 覆盖了 Flux 子集执行所需的主要类型：

- `null`
- `bool`
- `int`
- `uint`
- `float`
- `string`
- `time`
- `duration`
- `regexp`
- `array`
- `object`
- `function`
- `table`

这些值不是孤立存在的。数组承载 `array.map/filter/reduce` 这类高阶函数；对象既表示普通 record，也表示 package object、函数命名参数和 table row；函数值既可以是用户函数，也可以是 C++ builtin；table 值既可以是已 materialize 的 `TableValue`，也可以携带 lazy plan。

`Value` 的核心设计是一个明确的 type enum 加 variant storage。调用方通过 `type()` 判断，再使用 `as_int()`、`as_array()`、`as_object()` 这类访问器取值。这个设计比到处使用 `std::any` 更可控，也比一开始引入完整静态类型系统更轻。

## Value 的工程取舍

动态值模型最大的问题是边界容易变松。只要 `Value` 什么都能装，builtin 就很容易假设“调用者传的一定对”，最后把错误变成崩溃或奇怪结果。

所以 `Value` 需要配合几条工程约束：

- 每个访问器都要验证当前类型。
- builtin 参数解析必须检查缺参、类型和默认值。
- array/object/table 的内部结构不能被随意跨层修改。
- table plan 和 materialized table 要有明确状态。
- equality、string conversion、JSON output 要有一致规则。

当前实现把数组、对象、表和函数放在 `shared_ptr` 中，避免 `Value` 复制时深拷贝整个结构。这个选择让运行时更轻，但也要求上层小心可变状态。比如 `TableValue` 有 `materialized` 和 `plan` 字段，表示它可能是 lazy plan，也可能已经变成内存表。执行层必须显式处理这个边界。

从后续演进看，`Value` 不应该承担静态类型推断职责。类型检查应该在 analyzer/binder 层完成；`Value` 保持 runtime 表示即可。否则 evaluator 会同时变成解释器、类型检查器和错误诊断器，后面很难维护。

## Table Value 是特殊值

`table` 是项目中特别重要的一类值。它不是单张二维表的简单包装，而是 Flux table stream 的内存表示，包含 bucket、rows、logical tables、group key、range、result name、lazy plan 等信息。

早期 runtime 里，所有表算子都直接消费 `TableValue`：

```text
TableValue -> filter -> TableValue -> keep -> TableValue
```

这个模型简单，但对 SQLite/MySQL 大表不友好。现在 `Value::table_plan(...)` 可以让数据源入口返回 lazy logical plan，后续算子再决定追加 plan node、下推到 connector，还是 materialize 回内存表。

这意味着 evaluator 不能把 `table` 只当成普通对象。它既是语言值，也是查询执行主干和旧内存 fallback 之间的桥。

第 06 篇会专门讲 `TableValue` 和 table pipeline；第 08 篇会讲 lazy plan 如何落成 Page pipeline。这里先记住一点：runtime value model 必须给后续执行架构留出口。

## Environment：词法作用域

解释器中的 `Environment` 负责变量绑定和作用域查找。

顶层执行时，默认 prelude 会安装 universe builtin；显式 `import` 会从 package registry 载入内置包：

```flux
import "array"

xs = [1, 2, 3]
array.map(arr: xs, fn: (x) => x * 2)
```

这里至少有三类绑定：

- `array`：import 产生的 package object。
- `xs`：顶层变量。
- `x`：lambda 参数，只在函数体内可见。

函数调用时会创建新的子环境。参数绑定、默认值、闭包捕获和局部变量都依赖这条作用域链。查找时从当前环境向父环境走，直到顶层环境。

## Option 不是普通变量

Flux 里 `option` 不是普通变量赋值的完全同义词。它更像运行时配置入口，例如：

```flux
option task = {name: "rollup", every: 1m}
option location = timezone.utc
```

当前实现会把 option 绑定纳入环境，使后续表达式和 builtin 可以读取。比如 `aggregateWindow` 未显式传 `location` 时，可以回退到全局 `option location`。

这和普通变量的差异在于语义预期。普通变量是用户程序中的值；option 是对执行环境或查询配置的声明。Parser 已经把 `OptionStatement` 和普通 assignment 分开，runtime 也应该继续保留这条边界。

用户函数调用时，参数绑定发生在新的局部环境中；闭包保存定义处环境。这样同名变量会按词法作用域解析，而不是动态作用域解析。

这对 LSP 也有影响。Runtime 能正确查找变量，不代表 LSP 自动能正确跳转。LSP 需要独立构建符号表，并尽量模拟同样的作用域规则。否则就会出现运行时没问题、编辑器跳错位置的割裂体验。

## 表达式求值

表达式 evaluator 直接消费 AST 节点。常见路径包括：

- literal 求值：整数、浮点、字符串、time、duration、regex、bool、null。
- 标识符查找：从当前环境向父环境查找。
- 数组和对象构造。
- 字典 key 转换。
- record update：`{base with enabled: true}`。
- member/index：`r.host`、`arr[0]`、`obj["host"]`。
- unary/binary/logical：`not`、`-`、`+`、`==`、`=~`、`and`、`or`。
- conditional：`if cond then a else b`。
- function value 和 call expression。

一个简单表达式：

```flux
if exists r.usage then r.usage > 80.0 else false
```

runtime 需要先判断 `exists r.usage`，再根据条件选择分支。它不能提前求值两个分支，因为未被选择的分支可能包含不存在的字段或会触发错误的调用。

这类求值顺序是解释器语义的一部分，不是实现细节。

## 求值顺序和错误传播

解释器里的每一步基本都返回 `absl::StatusOr<Value>`。这种模式让错误传播很直接：子表达式失败，父表达式立即返回失败状态。它比异常更适合这个项目，因为 CLI、unit test 和未来更完整的 diagnostics 都可以显式检查 status code 和 message。

二元表达式的求值顺序是先左后右。普通 binary operator 会求值两侧；logical operator 则有自己的短路逻辑：

```flux
false and missing.field
true or missing.field
```

这两个表达式都不应该因为右侧 `missing.field` 报错。虽然当前 Flux 子集基本是无副作用表达式，但短路语义仍然必须准确，因为它影响错误可见性。

正则匹配也是 runtime 层处理的典型例子。Parser 只知道 `/cpu.*/` 是 regex literal，runtime 才会在 `=~` 或 `!~` 上检查左侧是 string、右侧是 regex，并调用 C++ regex 引擎执行匹配。

## 函数调用与命名参数

Flux 调用大量使用命名参数：

```flux
array.filter(arr: [1, 2, 3, 4], fn: (x) => x > 2)
```

Runtime 需要把调用参数解释成两类形态：

- positional arguments：按顺序绑定。
- named arguments：按名字绑定，通常在 AST 中以 object-like argument 表达。

对 builtin 来说，命名参数通常会被组织成对象，由 builtin 自己取字段和校验类型。对用户函数来说，runtime 要按照函数参数列表绑定：必填参数、可选参数、默认值、pipe 参数都要逐项处理。

默认参数也有求值时机问题：

```flux
f = (x=base) => x
```

默认值应该在调用缺参时求值，并且能访问函数定义时或调用时需要的环境边界。这里的规则必须稳定，否则闭包和默认参数组合起来会很难预测。

## Pipe 参数如何注入

Pipe-forward 是 Flux 查询的核心：

```flux
array.from(rows: rows)
    |> filter(fn: (r) => r.active)
```

Parser 保留 `PipeExpr`，runtime 在执行 pipe 时会先求左侧值，再把它注入右侧调用。Builtin 通常约定 pipe 参数名为 `tables`；用户函数也支持 `<-tables` 形态：

```flux
myLimit = (<-tables, n=10) => tables |> limit(n: n)
```

这个规则不能写死成“永远把左侧塞进第一个参数”。Flux 的函数参数有名字、有默认值，还有显式 pipe 参数。Runtime 必须尊重函数签名。

Pipe 参数也是 lazy plan 的入口。如果左侧是 table plan，右侧是可延迟表算子，runtime 可以追加 logical node；如果右侧是复杂用户函数或旧 builtin，就可能触发 materialize fallback。第 07/08 篇会继续展开这条路径。

## Builtin Call 和 User Function Call 的差异

从 AST 看，builtin 和用户函数都是 call expression。但 runtime 执行时，两者完全不同。

Builtin 是 C++ 函数包装出来的 `Value::function`。它通常接收一个参数数组，其中命名参数会被组织成对象，然后由 builtin 自己校验字段。这样做的好处是扩展 package 很方便；缺点是参数错误多在 runtime 暴露。

用户函数则需要按照 Flux 参数列表绑定。默认值在缺参时求值；命名参数按名字匹配；pipe 参数从 pipe 左侧注入；函数体可能是 expression，也可能是 block。block-bodied function 需要处理局部语句和 `return`。

因此 call evaluator 的关键不是“调用一个函数指针”，而是把 Flux 的参数语义完整落到 environment 和 `Value` 上。

这也是为什么后续 LSP 的 signature help、completion、diagnostics 最好和 runtime 共享 builtin metadata。否则编辑器提示的参数和 runtime 真正接受的参数可能不一致。

## Closure：函数捕获外层变量

函数值创建时会保存定义处环境，因此可以捕获外层变量：

```flux
threshold = 80

is_hot = (r) => r.usage > threshold
```

后续调用 `is_hot` 时，即使调用点在别处，`threshold` 仍然从函数定义时的环境链中解析。这也是 UDF 能成为项目一等能力的关键。

闭包和 shadowing 也要一起看：

```flux
x = 1
f = (x) => x + 1
```

函数体里的 `x` 应该绑定到参数，而不是外层变量。Runtime 靠 environment 链解决这个问题；LSP 靠 symbol table 解决这个问题。两者使用不同实现，但语义必须一致。

## Block-bodied Function

Flux 函数不只有 expression body，也可以有 block body：

```flux
normalize = (r) => {
    value = r.usage
    return if value > 80 then "hot" else "normal"
}
```

执行 block body 时，runtime 会创建 block environment，按顺序执行语句。表达式语句更新 last value，变量赋值写入 block scope，`return` 立即结束函数执行。

这比 expression body 复杂，因为 evaluator 必须临时承担一部分 statement execution 的职责。但它仍然不应该变成完整文件执行器。文件级 import、package、testcase 和结果收集仍然属于 `runtime_exec.cpp`。

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

这两个地方都应该由同一套 binary evaluator 决定。因此修复必须发生在 numeric binary evaluator，而不是某个 builtin 内部。

这也是定位 runtime bug 时很重要的判断：看起来是某个标准库函数坏了，实际可能是语言核心语义分支漏了。

## 语句执行

文件执行由 statement executor 负责。它会按顺序执行 import、option、变量赋值、表达式语句、testcase 等，并维护命名结果。

CLI 的 `--result`、`--list-results`、human/csv/json 输出都依赖结果收集层。REPL 则复用同一个运行时环境，所以可以做到：

```text
flux> x = 40
40
flux> x + 2
42
```

文件级语句执行还负责给错误补上下文。最近 runtime statement execution error 会附带 statement `SourceLocation`，让用户知道是哪个语句触发失败。这条信息来自 parser location，也说明前端和 runtime 的边界必须配合。

## Runtime Eval 测试应该覆盖什么

Evaluator 测试最适合小而确定。它不需要启动 CLI，也不需要真实 connector。

这一层应该覆盖：

- literal 和基础 value 转换。
- member/index/exists/record update。
- unary/binary/logical/conditional。
- 短路求值和错误传播。
- 正则匹配。
- 函数调用、默认参数、命名参数。
- closure 和 shadowing。
- pipe 参数注入。
- array helper 调用用户函数。
- numeric equality 这类核心操作符回归。

如果一个 bug 可以在 expression evaluator 层复现，就不要把它写成大型端到端测试。小测试失败时定位更快，也更能说明语义边界。

## 下一篇

下一篇会把函数能力单独展开，重点看 UDF、高阶函数、闭包、默认参数和没有传统循环时如何表达状态。

## 小结

`runtime_eval` 把 AST 变成了可执行语义。它目前覆盖了常见表达式、函数、闭包、pipe 和标准库调用，已经足以运行相当复杂的 Flux 示例。

但 evaluator 不应该无限膨胀。它负责执行，不负责完整静态类型推断；它可以处理当前运行时错误，但不应该替代 analyzer/binder；它可以 materialize 旧 builtin fallback，但不应该承担 optimizer 决策。后续如果要引入更完整的类型检查和语义分析，最好增加共享 analyzer 层，让 evaluator 专注于把已经绑定好的语义真正跑起来。
