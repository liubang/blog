---
title: Flux 子集语法导览：从变量、函数到 Pipe 查询
description: "面向使用者介绍当前 Flux 实现支持的文件结构、字面量、变量、option、函数定义、参数形式、运算符、对象/数组、条件表达式和 pipe 查询写法。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, syntax, language-guide, query-language]
authors: ["liubang"]
weight: 2
series: ["Flux"]
series_weight: 2
---

在进入 parser、runtime 和查询执行之前，先需要一张“这门 Flux 子集到底怎么写”的地图。

这个项目不是官方 Flux 的完整实现，而是一个可运行、可测试、可继续扩展的 Flux-like 子集。它已经覆盖常见查询、函数、标准库和 table pipeline，但仍有一些语法和语义边界需要明确。本文站在使用者视角，不讲 parser 怎么实现，只讲当前支持哪些写法、它们是什么意思，以及哪些地方暂时不要期待完整官方行为。

如果你已经熟悉 Flux，可以把这篇当作项目方言说明；如果你第一次接触 Flux，可以先读这篇，再去看后面的 parser 和 runtime 实现。

## 文件结构

一个 Flux 文件通常由 package、import、option、变量定义和表达式组成：

```flux
package demo

import "array"
import regexp "regexp"

option location = {zone: "UTC", offset: 0s}

threshold = 80.0

array.from(rows: [
    {_time: 2024-01-01T00:00:00Z, host: "edge-1", _value: 91.2},
])
    |> filter(fn: (r) => r._value > threshold)
```

当前实现支持：

- `package name`
- `import "path"`
- `import alias "path"`
- `option name = expr`
- `option a.b = expr`
- 变量定义：`name = expr`
- 表达式语句
- `builtin name : type`
- `testcase ... { ... }`
- block 中的 `return`

`package` 和 `testcase` 更多用于语法兼容、AST 和测试场景。日常运行查询时，最常见的是 `import`、`option`、变量定义和最后的查询表达式。

## 值与字面量

当前运行时支持这些核心值：

| 类型 | 示例 | 说明 |
| --- | --- | --- |
| `null` | `null` | 空值 |
| `bool` | `true`, `false` | 布尔值 |
| `int` | `42` | 有符号整数 |
| `uint` | `42u` | 无符号整数 |
| `float` | `3.14` | 浮点数 |
| `string` | `"cpu"` | 字符串 |
| `time` | `2024-01-01T00:00:00Z` | RFC3339 风格时间 |
| `duration` | `5m`, `1h`, `-30s` | 持续时间 |
| `regexp` | `/cpu.*/` | 正则字面量 |
| `array` | `[1, 2, 3]` | 数组 |
| `object` | `{host: "edge-1"}` | record/object |
| `function` | `(x) => x + 1` | 函数值 |
| `table` | `array.from(rows: [...])` | 表流值 |

字符串支持插值：

```flux
host = "edge-1"
message = "host=${host}"
```

数组和对象可以嵌套：

```flux
config = {
    hosts: ["edge-1", "edge-2"],
    threshold: 80.0,
    enabled: true,
}
```

字典字面量使用 `[key: value]` 形式：

```flux
labels = ["cpu": "CPU Usage", "mem": "Memory Usage"]
```

当前字典运行时语义仍是可用子集，不要把它理解成完整官方 Flux 字典能力。

## 变量与作用域

变量定义使用 `=`：

```flux
threshold = 80.0
host = "edge-1"
```

变量按词法作用域查找。函数内部可以访问外层变量：

```flux
threshold = 80.0

is_hot = (r) => r._value > threshold
```

函数参数会遮蔽外层同名变量：

```flux
x = 1
f = (x) => x + 1
```

这里函数体里的 `x` 指参数，不指外层 `x`。

当前实现没有完整类型检查层，因此变量类型主要在运行时由具体操作或 builtin 校验。

## Option

`option` 用来声明运行时配置，不完全等同于普通变量：

```flux
option task = {name: "rollup", every: 1m}
option location = {zone: "UTC", offset: 0s}
```

也支持成员形式：

```flux
option task.every = 5m
```

一些 builtin 会读取 option。例如 `aggregateWindow` 在没有显式传 `location` 时，可以回退到全局 `option location`。

普通查询里，如果只是定义中间值，用变量；如果要声明全局配置，用 option。

## Import 与 Package

显式导入 package 后，可以通过成员访问调用函数：

```flux
import "array"

array.map(arr: [1, 2, 3], fn: (x) => x * 2)
```

也可以使用 alias：

```flux
import re "regexp"

re.matchRegexpString(r: /edge-.*/, v: "edge-1")
```

当前常用 package 包括：

- `array`
- `csv`
- `date`
- `dict`
- `join`
- `json`
- `math`
- `regexp`
- `runtime`
- `sqlite`
- `strings`
- `system`
- `timezone`
- `types`

数据源入口也走 package：

```flux
import "array"
import "csv"
import "sqlite"
import "mysql"

array.from(rows: [])
csv.from(file: "metrics.csv")
sqlite.from(path: "metrics.db", table: "cpu")
mysql.from(dsn: "mysql://user:pass@127.0.0.1:3306/db", table: "cpu")
```

项目刻意不提供 universe 顶层 `from(bucket:)`。所有数据源都通过 provider package 进入。

## 函数定义

最常见的是 expression-bodied function：

```flux
double = (x) => x * 2
is_hot = (r) => r._value > 80.0
```

也支持 block-bodied function：

```flux
classify = (r) => {
    value = r._value
    return if value > 80.0 then "hot" else "normal"
}
```

函数是一等值，可以赋给变量、作为参数传入，也可以作为返回值：

```flux
make_filter = (threshold) => (r) => r._value > threshold

hot = make_filter(threshold: 80.0)
```

函数会捕获定义处环境，所以 `hot` 会记住对应的 `threshold`。

## 函数参数

当前支持几种参数形式。

位置参数：

```flux
add = (a, b) => a + b
add(1, 2)
```

命名参数：

```flux
add = (a, b) => a + b
add(a: 1, b: 2)
```

默认参数：

```flux
scale = (x, factor=2.0) => x * factor

scale(x: 3.0)              // 6.0
scale(x: 3.0, factor: 4.0) // 12.0
```

Pipe 参数：

```flux
only_hot = (<-tables, threshold=80.0) =>
    tables |> filter(fn: (r) => r._value > threshold)
```

Pipe 参数用于让用户函数进入查询管道：

```flux
data
    |> only_hot(threshold: 90.0)
```

如果函数没有声明 pipe 参数，却被放在 pipe 右侧，运行时会按当前函数调用规则尝试绑定；推荐对可 pipe 的用户函数显式写 `<-tables`，可读性更好。

## Lambda 与高阶函数

Flux 查询里最常见的函数，是作为参数传入的 lambda：

```flux
filter(fn: (r) => r._value > 80.0)
map(fn: (r) => ({r with hot: r._value > 80.0}))
```

数组 package 也大量使用高阶函数：

```flux
import "array"

array.filter(arr: [1, 2, 3, 4], fn: (x) => x > 2)
array.map(arr: [1, 2, 3], fn: (x) => x * 2)
array.reduce(arr: [1, 2, 3], identity: 0, fn: (x, acc) => acc + x)
```

不同高阶函数对 `fn` 的返回值有不同要求：

- `filter` 要求返回 bool。
- `map` 返回任意转换后的值。
- `flatMap` 要求返回 array。
- `reduce` 返回新的 accumulator。
- `unfold` 要求返回 `{value, state, done}` 结构。

这些约定目前主要由 runtime builtin 在执行时校验。

## 对象、成员访问与 Record Update

对象字面量：

```flux
r = {host: "edge-1", usage: 91.2}
```

成员访问：

```flux
r.host
r.usage
```

字符串索引形式也会规范化为成员访问：

```flux
r["host"]
```

数组索引：

```flux
values = [10, 20, 30]
values[0]
```

Record update：

```flux
updated = {r with hot: true, usage: r.usage + 1.0}
```

Record update 会基于原对象生成新对象，不建议把它理解成原地修改。

在 table `map` 中，record update 很常见：

```flux
data
    |> map(fn: (r) => ({r with hot: r._value > 80.0}))
```

## 条件表达式与 Exists

条件表达式使用：

```flux
if condition then expr1 else expr2
```

例如：

```flux
level = if usage > 90.0 then "critical" else "normal"
```

`exists` 用于检查字段是否存在：

```flux
if exists r.host then r.host else "unknown"
```

`exists` 常用于处理 schema 不稳定或 row 字段可能缺失的情况。配合短路逻辑，可以避免不必要的错误：

```flux
exists r.host and r.host == "edge-1"
```

## 运算符含义

当前常用运算符包括：

| 类别 | 运算符 | 示例 | 说明 |
| --- | --- | --- | --- |
| 算术 | `+ - * / %` | `a + b` | 数值运算 |
| 比较 | `< <= > >=` | `usage > 80.0` | 数值或可比较值 |
| 相等 | `== !=` | `host == "edge-1"` | 相等/不等 |
| 正则 | `=~ !~` | `host =~ /edge-.*/` | 字符串与正则匹配 |
| 逻辑 | `and or not` | `a and b` | 布尔逻辑 |
| 成员 | `.` | `r.host` | 对象字段访问 |
| 索引 | `[]` | `arr[0]` | 数组索引或对象字符串键 |
| Pipe | `|>` | `data |> filter(...)` | 管道传值 |
| Exists | `exists` | `exists r.host` | 字段存在性 |

`and` 和 `or` 是短路求值：

```flux
false and missing.field // 不会求值右侧
true or missing.field   // 不会求值右侧
```

正则匹配左侧通常是 string，右侧是 regexp：

```flux
"edge-1" =~ /edge-.*/
```

## 运算符优先级

从高到低可以大致理解为：

1. 成员访问和索引：`r.host`、`arr[0]`
2. 调用：`f(x: 1)`
3. 一元：`not x`、`-x`、`exists x`
4. 乘除取模：`* / %`
5. 加减：`+ -`
6. 比较和正则：`< <= > >= =~ !~`
7. 相等：`== !=`
8. 逻辑 `and`
9. 逻辑 `or`
10. pipe：`|>`

实际 parser 会按更细的层级处理。作为使用者，最重要的是：复杂表达式建议加括号，让意图更清楚。

```flux
filter(fn: (r) =>
    (r.region == "west" or r.region == "east") and r._value > 80.0
)
```

## Pipe 查询

Pipe 是 Flux 查询的主要组织方式：

```flux
data
    |> range(start: 2024-01-01T00:00:00Z, stop: 2024-01-02T00:00:00Z)
    |> filter(fn: (r) => r._value > 80.0)
    |> group(columns: ["host"])
    |> mean(column: "_value")
    |> yield(name: "mean_by_host")
```

可以把它理解为“左侧结果作为右侧函数的 pipe 参数”。

表查询常见模式：

```flux
source
    |> range(start: start, stop: stop)
    |> filter(fn: (r) => ...)
    |> keep(columns: [...])
    |> group(columns: [...])
    |> aggregate(...)
```

在内存数据上，pipe 会串联 `TableValue` 变换；在 SQLite/MySQL 数据源上，可下推的前缀可能会被 optimizer 合并进 connector scan。

所以 pipe 不只是语法好看，它也是查询优化识别线性前缀的重要结构。

## 表与数据源

内联表：

```flux
import "array"

array.from(rows: [
    {_time: 2024-01-01T00:00:00Z, host: "edge-1", _value: 91.2},
    {_time: 2024-01-01T00:01:00Z, host: "edge-2", _value: 64.0},
])
```

CSV：

```flux
import "csv"

csv.from(file: "metrics.csv")
```

SQLite：

```flux
import "sqlite"

sqlite.from(path: "metrics.db", table: "cpu")
```

MySQL：

```flux
import "mysql"

mysql.from(
    host: "127.0.0.1",
    user: "flux",
    password: "flux",
    database: "flux_test",
    table: "cpu",
)
```

数据源 package 不提供 raw query 入口。查询变换应该继续用 Flux pipe 表达，让 optimizer 判断哪些部分可以下推。

## 当前不支持或部分支持的语法

当前项目仍是可用子集，几个边界要明确：

- 没有传统 `for` / `while`。
- 没有完整静态类型检查和类型推断。
- 递归不是推荐路径，没有尾递归优化或深度控制。
- 不支持任意 Flux 函数到 SQL 的翻译。
- 不支持跨文件 workspace 级语义分析。
- 官方 Flux 标准库只实现了一部分常用 package。
- 某些 malformed 输入可以恢复，但容错 parser 仍不完整。
- 字典、类型语法、日历窗口等能力是部分支持。

如果需要表达有限循环，优先使用 `array.range`、`array.reduce`、`array.scan`、`array.unfold`。如果需要外部数据源，优先使用 provider package。复杂 SQL 逻辑不要塞进 raw query，而是先用 Flux pipe 表达，等 connector pushdown 能安全识别。

## 写法建议

为了让查询更容易被当前实现和后续 optimizer 理解，建议遵循几条规则：

- 数据源入口显式 import package。
- 表查询尽量写成线性 pipe。
- 复杂条件用括号提高可读性。
- 可复用谓词写成函数。
- `map` 中优先使用 `{r with ...}` 保留原 row 字段。
- 对可能缺失字段使用 `exists`。
- 用 `keep/drop` 尽早缩小列集合。
- 对用户函数写清楚参数名和默认值。
- 可 pipe 的用户函数显式声明 `<-tables`。
- 示例和测试尽量使用 `array.from` 构造最小输入。

这些建议不是语言硬限制，但能让查询更稳定、更可读，也更容易进入后续的 pushdown 和 Page pipeline。

## 下一篇

下一篇会进入实现层，看这些用户可见语法如何被 scanner 切成 token，又如何被 parser 组织成带位置的 AST。

## 小结

当前 Flux 子集已经足以表达常见的查询、数组处理、函数抽象和数据源 pipeline。它的语法核心可以概括为：用变量和 option 配置查询，用函数封装策略，用对象/数组组织数据，用运算符表达条件，用 pipe 串联表流。

下一篇会进入 parser 实现：这些用户可见语法如何被 scanner 切成 token，又如何被 parser 组织成 AST，并保留给 runtime、LSP 和 optimizer 使用。
