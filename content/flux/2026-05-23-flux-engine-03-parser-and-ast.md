---
title: "Flux 03: Parser 与 AST"
description: "拆解 Flux 查询引擎的语言前端：scanner、token、parser、AST、表达式优先级和源码位置。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, compiler, parser, cpp]
authors: ["liubang"]
weight: 3
series: ["Flux"]
series_weight: 3
lightgallery: true
---

语言实现的第一层，是把源码变成结构化数据。对 `cpp/pl/flux` 来说，这一层由 `syntax/scanner.rl`、生成的 scanner、`syntax/parser.cpp` 和 `syntax/ast.h` 组成。它的目标不是只让正确程序通过，而是尽量为后面的 runtime、CLI、formatter、LSP 和测试提供稳定、可定位的 AST。

Parser 的质量会向后传导。表达式优先级错了，runtime 会执行错；source location 粗糙，LSP 会跳转错；错误恢复太脆，用户在编辑器里输入半截代码时 diagnostics 就会崩；AST 结构过早脱糖，formatter 和 analyzer 又会丢掉用户写法。

所以这一篇不只讲“递归下降怎么写”，而是讲 Flux 前端需要守住哪些边界：token 上下文、pipe 语法、AST 结构、节点所有权、source location 和 malformed 输入恢复。

## Scanner：把字符流切成 token

Scanner 的职责是把字符流切成 token，并尽量保留位置信息。Flux 的词法不只是普通标识符和数字。当前 scanner 覆盖了：

- 关键字：`package`、`import`、`option`、`builtin`、`testcase`、`return`、`if/then/else`。
- 字面量：int、uint、float、string、duration、RFC3339 time、regexp。
- 复合语法：字符串插值、属性注解、record/object、array/dict、函数箭头。
- 运算符：算术、比较、正则匹配、逻辑、pipe-forward。
- 类型语法 token：函数类型、record 类型、vector/stream 类型、`where` 约束。
- 注释和换行位置信息。

其中最容易低估的是 `/`。它既可能是除法操作符，也可能是正则字面量开头：

```flux
matched = r.host =~ /edge-.*/
ratio = used / total
```

Scanner 不能只看单个字符决定 token 类型。当前实现会维护“此处是否期待表达式”的上下文，在可能接受表达式的位置允许 regexp literal，在普通二元运算位置按除法处理。这个细节如果做错，parser 后面看到的 token 就已经错了。

另一个细节是 line/column。很多语言项目一开始只关心 token type，后来做 LSP 才发现 location 才是基础设施。Parser error、AST dump、diagnostics、goto definition、semantic tokens、selection range 都需要准确位置。

## Token 设计里几个容易低估的点

第一个点是关键字分类。`import`、`option`、`builtin`、`testcase` 在文件级语法和语句语法里有特殊入口。如果 scanner 把它们都当 ident，parser 就必须到处做字符串判断，错误恢复也会更难。

第二个点是 numeric literal 的后缀。`1h`、`5m`、`42u` 看起来都是“数字 + 后缀”，但语义完全不同。duration 后续会参与 `range`、`window`、`aggregateWindow`；uint 是普通 numeric value。AST 层必须把它们分开。

第三个点是字符串插值。`"host ${user}"` 不是普通 string；parser 需要保留其中的表达式，让 runtime 在当前 environment 下求值。

第四个点是属性注解。Flux 支持形如：

```flux
@edition("2022.1")
package demo
```

属性可能挂在 package、import、statement 或 block statement 上。Parser 需要在语句列表中保存 pending attributes，并在下一条可附着语句出现时绑定它们。

第五个点是 EOF 和坏 token。错误恢复能否继续，很多时候取决于 scanner 是否能把“坏东西”封装成一个可消费 token，而不是让 parser 卡死在同一个位置。

## Parser：递归下降与优先级分层

项目使用手写 parser。手写 parser 的好处是便于贴合 Flux 的高频语法，也便于做局部错误恢复。代价是需要非常清楚地维护优先级和递归边界。

表达式解析按优先级分层，大致关系如下：

![表达式优先级分层](/images/flux/expr-precedence.svg "表达式优先级分层")

这保证下面的表达式按预期组合：

```flux
data
    |> filter(fn: (r) => r.usage > 80 and r.host =~ /edge.*/)
    |> keep(columns: ["host", "usage"])
```

其中 `r.usage > 80 and r.host =~ /edge.*/` 会被解析为 logical expression，左右两边是 comparison/binary expression；整个 `filter(...)` 又作为 pipe 右侧调用，连接左侧表流。

如果优先级错了，错误不会停在 AST。它会继续传导到 runtime：filter 谓词可能变成另一种表达式，pushdown 识别也可能误判。

## Pipe 表达式不是普通函数调用语法糖

`a |> f(x: 1)` 表面上可以理解为 `f(tables: a, x: 1)`，但 parser 不应该直接把它改写成普通 call。更稳的做法是保留 `PipeExpr` 的 AST 形态，让 runtime 或后续 analyzer 明确决定左侧值如何注入右侧调用。

原因有两个。

第一，Flux 同时有 builtin 和用户函数。builtin 可能约定 pipe 参数名为 `tables`，用户函数则可能显式声明 `<-tables`。注入规则依赖 callee 的参数模型，parser 阶段并不知道完整语义。

第二，LSP 和 formatter 需要保留用户写法。AST 如果过早脱糖，formatter 就很难重建原始 pipe 链，goto definition 和 semantic tokens 也会失去一些语法上下文。

第三，optimizer 也需要知道查询是以 pipeline 组织的。后续 `from |> range |> filter |> keep` 能不能形成可下推前缀，和用户写成普通嵌套调用相比，虽然语义接近，但 source-level 结构对 explain 和错误定位很有帮助。

因此 parser 的职责是忠实表达语法结构，而不是急着优化或重写。

## AST 不是语法糖字符串

AST 的价值是让后续模块不再处理源码文本。比如：

- `PackageClause` 保存 package 名称。
- `ImportDeclaration` 保存 import path、alias 和 attributes。
- `FunctionExpr` 保存参数列表、默认值、pipe 参数和函数体。
- `CallExpr` 保存 callee 和 argument list。
- `MemberExpr` 和 `IndexExpr` 区分成员访问和索引访问。
- `LogicalExpr` 与 `BinaryExpr` 分开表达 `and/or` 和普通二元运算。
- `ObjectExpr` 支持普通 record，也支持 `{base with x: 1}` 这种 record update。
- `BadExpr` / `BadStmt` 表示局部无法解析但仍可继续的输入。

这种结构化表达使 runtime 可以做直接求值，LSP 可以做符号收集，formatter 可以重建布局，测试可以对 AST dump 做快照。

一个很重要的原则是：debug string 不能成为语义来源。`dump_ast` 是观察工具，不是 IR。runtime 和 LSP 应该消费结构化字段，而不是反解析 dump 文本。

## AST 节点的所有权模型

当前 AST 主要使用 `std::unique_ptr` 表达树形所有权，用 `std::shared_ptr` 承载某些列表元素或跨结构引用。这个选择偏 C++ 工程实用主义：AST 生命周期由 `File` 根节点持有，解析完成后整体交给 runtime、dump、LSP 等消费者。

这种模型的优点是简单，不需要复杂 arena 就能保证节点释放。缺点是节点分配较多，parser 高频运行时会有一定开销。对于 CLI 执行单个文件，这不是大问题；对于 LSP 高频 parse，则需要 AST 缓存来抵消成本。

后续如果引入 incremental parser 或 arena allocator，应该优先从 LSP 热路径出发评估，而不是为了性能预期过早重写整个 AST 存储。Parser 的首要目标仍然是结构正确、location 准确、错误可恢复。

## 文件级语法

当前 parser 支持常见 Flux 文件结构：

```flux
package demo

import "array"
import regexp "regexp"

option task = {name: "rollup", every: 1m}

normalize = (r) => ({r with host: regexp.findString(r: /edge-[0-9]+/, v: r.host)})

array.from(rows: [{host: "edge-1", value: 10}])
    |> map(fn: normalize)
```

文件体可以混合 package、import、option、变量赋值、表达式语句、builtin 声明和 testcase。`return` 主要用于 block-bodied function 或 testcase block。

`builtin` 语句还会涉及类型语法：

```flux
builtin sum : (<-tables: [int], ?n: int) => int where A: Addable
```

这要求 parser 既能解析表达式语言，也能解析一部分 Flux 类型语言。当前支持基础类型、数组、字典、record、function、dynamic、vector/stream 和 `where` 约束。类型系统还没有完整落地，但 AST 必须能承载 builtin signature 和后续 analyzer 需要的信息。

## Option 和 Import 的特殊性

`import` 和 `option` 都不是普通赋值。

`import "array"` 会影响后续 package namespace，`import regexp "regexp"` 还会引入 alias。Parser 需要保留 path 和 alias，让 runtime/LSP 能知道 `regexp.findString` 来自哪个 package。

`option` 更特殊。它既有普通形式：

```flux
option location = timezone.utc
```

也有成员赋值：

```flux
option task.every = 1m
```

Parser 不能把它简化成普通 assignment，否则 runtime 就无法区分“普通变量绑定”和“全局 option 更新”。后面 `aggregateWindow` 读取全局 `option location` 时，就依赖这个边界。

## 错误恢复的现实边界

Parser 已经有 `BadStmt`、`BadExpr` 这类节点，也在条件表达式、调用参数、数组、字典、对象属性和部分类型语法上做了恢复。但这还不是完整的容错 parser。

错误恢复的目标不是“坏程序也正常运行”，而是三件事：

- CLI 能给出尽量局部的错误。
- LSP 能在用户输入半截代码时继续提供 diagnostics/completion。
- Parser test 能固定已知恢复行为，避免重构后退化。

最近一个具体改进是未闭合数组遇到下一条语句时的恢复。例如：

```flux
bad = [1, 2
next = 3
```

旧实现容易把后续 `next = 3` 吞进坏数组上下文，导致整个文件后半段丢失。现在 parser 会识别“看起来像新语句”的 token 组合，例如 `Ident + Assign`、`import`、`option`、`return` 等，在缺失 delimiter 时尽量恢复到下一条语句。这对 LSP 尤其重要，因为用户经常在未闭合数组、对象或调用参数中间触发请求。

## AST Location 为什么重要

前期实现语言时，容易把 source location 当成“调试附属品”。实际开发到 LSP 阶段后会发现，它是基础设施。

例如 lambda 参数：

```flux
filter(fn: (r) => r.active == true)
```

如果 `r` 的定义位置没有正确记录，goto definition 可能跳到文档开头，或者把引用绑定到错误的外层符号。这个项目后来专门修复过 lambda parameter 的 source location，就是因为 parser 的位置精度会直接影响 IDE 行为。

Location 也影响 runtime 错误。文件级语句执行失败时，如果能附带 statement `SourceLocation`，CLI 用户就能知道是哪一行触发错误，而不是只看到一段运行时异常。

所以 AST location 应该覆盖 file、package、import、statement、expression、block、function parameter 等关键节点。不是每个节点都要一开始完美，但每次修 LSP 或 diagnostics bug，都应该顺手补相应测试。

## Parser 测试应该测什么

Parser 测试不能只测“成功/失败”。对语言实现来说，更有价值的是验证 AST 形状和 location。

一个好的 parser test 至少应该覆盖：

- scanner token 边界：注释、regex、duration、time、uint、字符串插值。
- 表达式优先级：`a + b * c`、`a > b and c > d`、`exists x.y`。
- pipe 链：左结合、右侧 call、lambda 参数。
- 文件级语法：package/import/option/builtin/testcase。
- 类型语法：function type、record type、vector/stream、where constraint。
- malformed 输入：未闭合数组/对象/调用、坏类型、坏语句。
- AST location：lambda 参数、成员访问、语句范围。
- dump 输出：关键结构可读，但不过度绑定无意义格式。

例如 parser 单测里会检查 `ParsesPackageImportsAndPipeExpression`、`ParsesBuiltinFunctionTypeWithConstraints`、`ParsesRecordTypeAndConditionalExpression`、`ParsesStringInterpolationAndRegexMatch`、`ParsesBooleanRecordUpdateAndIndexExpressions` 等路径。测试名称本身就应该说明它守的语法边界。

## Parser 和后续模块的关系

Parser 不是孤立模块。

Runtime 依赖 AST 判断表达式类型、函数参数、调用参数、record update、pipe chain。Optimizer 依赖 source plan 的结构判断前缀下推。LSP 依赖 AST location 和 symbol structure 做 diagnostics、completion、definition、rename、semantic tokens。Formatter 依赖 AST 形状重建用户可读布局。

因此 parser 的一些“看似内部”的决策，会变成后续模块的长期成本。比如 pipe 是否保留为独立节点，string interpolation 是否保留表达式结构，index string 是否规范化为 member，bad syntax 是否产出 BadExpr，这些都会影响后面的实现方式。

一个好的 parser 不只是能接受正确程序，还要能为错误程序、编辑器请求、debug 输出和测试快照提供稳定结构。

## 下一篇

下一篇会进入 runtime evaluator：有了 AST 之后，解释器如何让表达式、函数、作用域和 pipe 真正执行起来。

## 小结

`cpp/pl/flux` 的 parser 当前已经覆盖常见 Flux 查询子集，并且 AST 能同时支撑 CLI、runtime、formatter 和 LSP。它还不是完整 Flux parser，但已经具备继续扩展的关键条件：结构清晰、优先级明确、节点位置可追踪、错误可以被收集。

下一篇会进入 runtime evaluator：有了 AST 之后，解释器如何让表达式、函数、作用域和 pipe 真正执行起来。
