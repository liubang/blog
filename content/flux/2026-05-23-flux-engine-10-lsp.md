---
title: LSP 支持：给自研语言补齐 IDE 体验
description: "介绍 Flux Language Server 的 JSON-RPC、文档同步、AST 缓存、补全、诊断、跳转、引用、重命名、语义高亮和测试策略。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, lsp, language-server, cpp]
authors: ["liubang"]
weight: 10
series: ["Flux"]
series_weight: 10
---

一个自研语言只提供 CLI 是不够的。CLI 证明语言能跑，LSP 才决定它能不能舒服地写。对 Flux 这种表达式、pipe、lambda 和 package builtin 很多的语言来说，编辑器体验不是锦上添花，而是降低使用成本的一部分。

`cpp/pl/flux/contrib/lsp` 的目标就是让 Flux 从“能执行”走到“能日常编辑”：打开文件时能诊断语法错误，输入 `array.` 时能补 package 函数，光标放在 lambda 参数上能跳回定义，rename 不会误改 shadowing 变量，semantic tokens 能区分 package、函数、参数和引用。

这一篇不按功能列表平铺，而是从一次编辑器请求开始，看 Flux Language Server 如何把 JSON-RPC、文档同步、AST 缓存、符号表和各类 feature handler 串起来。

## 一次编辑器请求如何流动

假设用户在编辑器里打开了这样一段 Flux：

```flux
import "array"

data = array.from(rows: [{host: "edge-1", usage: 91.2}])

data
    |> filter(fn: (r) => r.usage > 80.0)
    |> keep(columns: ["host", "usage"])
```

当用户输入 `array.`、保存文件、或者把光标放到 `r.usage` 上时，编辑器会通过 LSP 向 server 发请求或通知。server 不能每个功能都自己 parse 一遍，也不能把 completion、diagnostics、definition 写成彼此独立的临时逻辑。它需要一套共享的语言服务基础设施。

当前 Flux LSP 的核心路径大致如下：

![Flux LSP request flow](/images/flux/lsp-flow.svg "Flux LSP request flow")

图里最关键的是中间那层 versioned document services。所有 feature handler 都应该通过 `ensure_ast` 和 `ensure_symbols` 取共享状态，而不是自己维护一份语义世界。这样 diagnostics、completion、definition、references、rename、semantic tokens 才会对同一份文档给出一致答案。

## LSP server 的基础结构

LSP 本质上是 JSON-RPC 2.0 协议。编辑器通过 stdin/stdout 或其他 transport 发送消息，server 解析 `Content-Length` 帧，得到 JSON-RPC request、notification 或 response，再按 `method` 分发。

当前模块主要包括：

- `transport.*`：处理 LSP 消息帧，读写 `Content-Length` 和消息 body。
- `jsonrpc.*`：解析 JSON-RPC 的 `id/method/params`，构造 result/error/notification。
- `json_util.*`：统一 JSON 字符串 escape，避免手写响应时破坏协议。
- `server.*`：维护 server lifecycle、document store 和 feature method 分发。
- `symbol_table.*`：从 AST 构建定义、引用、作用域和诊断信息。
- `formatter.*`：格式化相关能力。

这里的工程原则是：协议层要薄，语义层要共享。`dispatch()` 只负责把 `textDocument/completion`、`textDocument/definition` 这类 method 分到对应 handler；handler 再通过 document cache 和 symbol table 完成语言功能。

早期遇到过 `INVALID_SERVER_JSON` 这类问题，本质不是 Flux 语义错了，而是 server 返回的 JSON 不合法。对编辑器来说，少一个逗号、字符串没有 escape、数组没有闭合，都等价于“language server 坏了”。所以 JSON 构造必须走统一 helper，不能在每个 handler 里随手拼字符串。

## Lifecycle 与能力声明

LSP server 的第一关是 lifecycle。编辑器会先发 `initialize`，server 返回能力声明，然后再收到 `initialized`。在 initialize 之前发来的普通请求，应该返回 `ServerNotInitialized`，而不是悄悄执行。

Flux LSP 当前能力覆盖面已经比较完整：

- `textDocumentSync`：增量文档同步。
- `completionProvider`：补全和 snippet。
- `hoverProvider`：悬浮说明。
- `documentFormattingProvider`：格式化。
- `documentSymbolProvider`：文档符号。
- `foldingRangeProvider`：折叠区间。
- `definitionProvider`：跳转定义。
- `referencesProvider`：查找引用。
- `renameProvider`：重命名。
- `signatureHelpProvider`：签名帮助。
- `documentHighlightProvider`：文档内高亮。
- `semanticTokensProvider`：语义高亮。
- `codeActionProvider`：quick fix。
- `inlayHintProvider`：内联提示。
- `selectionRangeProvider`：结构化选择。

这些 provider 看起来只是 JSON capabilities，但它们背后都依赖 parser location、AST 结构、符号表和 builtin metadata。能力声明不能比实现更激进，否则编辑器会开始调用 server 还没真正准备好的路径。

## 文档同步与版本化缓存

LSP server 不是 batch compiler。用户每敲一个字符，编辑器都可能发 `didChange`；用户也可能同时触发 diagnostics、completion、hover 和 semantic tokens。每次请求都全量 parse 并重建所有状态，体验会很快变差。

当前 `Document` 结构保存了这些状态：

```cpp
struct Document {
    std::string uri;
    std::string content;
    int version = 0;

    std::shared_ptr<File> ast;
    std::vector<std::string> parse_errors;
    int ast_version = -1;

    SymbolTable symbols;
    int symbols_version = -1;
};
```

这里的两个 version 字段很关键。`ast_version` 表示 AST 是在哪个文档版本上 parse 出来的；`symbols_version` 表示符号表是在哪个 AST 版本上构建的。`didChange` 更新 content 和 version 后，旧 AST 和旧符号表就不能继续被无条件使用。

`ensure_ast(Document&)` 和 `ensure_symbols(Document&)` 是统一入口。handler 不直接 parse，不直接 rebuild symbol table，而是请求“确保当前文档的 AST/符号表是最新的”。这让缓存失效策略集中在一个地方，也避免不同功能看到不一致的文档快照。

当前还不是完整 incremental parser，但版本化全量 AST 缓存已经很有价值。下一步如果做 incremental parse，也应该继续藏在 `ensure_ast` 背后，让 feature handler 不感知解析策略变化。

## Diagnostics：先语法，再语义

诊断通常分两层。

第一层是 parser diagnostics。比如：

```flux
x = + ;
```

parser 可以直接指出语法错误，LSP 再通过 `textDocument/publishDiagnostics` 推送给编辑器。这个路径依赖 AST location；如果错误范围不准确，编辑器只能在奇怪的位置画红线。

第二层是语义诊断。当前 Flux LSP 已经能做未定义标识符这类检查，因为符号表知道当前作用域里有哪些定义、哪些引用没有解析到 definition。例如：

```flux
y = missing + 1
```

`missing` 没有在当前作用域中定义，就可以产生 warning 或 error。这个能力不需要完整类型系统，但需要可靠的 scope tree。

需要注意的是，语义诊断不等于类型诊断。`array.map(arr: 1, fn: ...)` 这种 builtin 参数类型错误，最好由后续共享 analyzer/binder 或类型检查层处理，而不是散落在 LSP handler 里。否则 runtime 和 LSP 会逐渐形成两套语义规则，最终用户会遇到“编辑器说没问题，运行时报错”或反过来的不一致。

## 符号表：IDE 能力的地基

`SymbolTable` 是 LSP 的核心语义结构。它记录 definitions、references、imported packages 和 diagnostics。每个定义有 kind、name、location、parameters；每个引用记录它解析到的 definition id。

它要解决的核心问题不是“文件里有哪些单词”，而是“这个位置的名字绑定到了哪个定义”。

例如：

```flux
x = 1
f = (x) => x + 1
```

函数体里的 `x` 应该绑定到参数 `x`，不是顶层 `x`。如果 rename 光标落在参数 `x` 上，只能改函数参数和函数体里的引用，不能把顶层 `x` 一起改掉。

这也是为什么 LSP 不能靠文本搜索实现 definition/references/rename。它必须构建作用域：顶层 scope、函数 scope、lambda 参数 scope、block scope。每个 reference 都要先解析到具体 definition，再由 definition 反查同一绑定的 references。

曾经出现过一个很典型的 bug：

```flux
filter(fn: (r) => r.active == true)
```

这里的 `r` 跳转到了文档开头。根因是 lambda 参数的 source location 不准确，符号表把定义位置记录错了。修复这类问题不只是 LSP polish，它会反过来要求 parser/AST location 更严谨。

## Completion 不只是返回所有候选

补全最容易做成“能弹出来”，也最容易变成噪音。

Flux LSP 需要根据上下文返回不同候选：

- 文件开头可以补 `package`、`import`、`option`。
- `import "` 内可以补 package path。
- `array.` 后应该补 array package 函数。
- 普通表达式位置应该混合用户符号、builtin 和关键字。
- lambda 参数位置不应该弹出一大堆 package function。

比如：

```flux
import "array"

array.
```

这里最有价值的是 `array.map`、`array.filter`、`array.reduce`、`array.range`、`array.scan`、`array.unfold` 这类 package builtin。函数补全如果带 snippet，还可以直接展开参数模板，让用户少记一些命名参数。

用户定义符号补全也很重要：

```flux
threshold = 80.0

data
    |> filter(fn: (r) => r._value > th)
```

在 `th` 后触发 completion，应该能补出 `threshold`。这依赖当前文档的符号表，也依赖光标位置的 token 上下文。补全的目标不是“候选越多越好”，而是让候选列表尽量贴合当前位置。

## Hover 与 Signature Help

Hover 和 signature help 是低成本但高频的体验点。

Hover 可以回答“这个符号是什么”：变量、函数、参数、import package、builtin。它不一定一开始就要像成熟语言那样显示完整类型，但至少应该能告诉用户当前位置的绑定对象和大致含义。

Signature help 则解决函数调用过程中的记忆负担。Flux 有大量命名参数 builtin，例如：

```flux
array.map(arr: rows, fn: (x) => x)
```

当光标在参数列表里时，server 可以根据函数名和 builtin metadata 返回参数列表，让编辑器显示当前正在填写哪个参数。后续如果 builtin signature 和 runtime 参数校验能共享同一份 metadata，LSP 的签名帮助就会和真实执行保持一致。

这类功能看起来不像 definition/rename 那么“硬”，但它们直接决定语言是否顺手。尤其是 Flux 这种 pipeline 查询语言，用户经常在 builtin 参数之间切换，signature help 能显著降低查文档频率。

## Definition、References 与 Rename

跳转定义是符号表的第一场考试。

对顶层绑定：

```flux
threshold = 80.0
alert = (v) => v > threshold
```

光标放在 `threshold` 引用上，应该跳到顶层定义。对 lambda 参数：

```flux
filter(fn: (r) => r._value > 80.0)
```

光标放在函数体里的 `r` 上，应该跳到 `(r)` 参数定义。对 package 函数，后续也可以跳到 builtin 文档或标准库定义位置。

references 和 rename 在 definition 基础上继续扩展。references 不能只按名字找；rename 更不能按名字全局替换。它们必须围绕同一个 definition id 操作，避免误伤 shadowing。

一个合格的 rename 需要回答三个问题：

- 光标所在位置能不能解析到一个可重命名 definition？
- 这个 definition 的所有引用在哪里？
- 新名字是否会和同作用域已有绑定冲突？

当前实现已经具备 definition、references、rename 的主干。后续真正困难的是 workspace index：跨文件 import、跨 package reference、外部标准库文档，这些都需要从单文件符号表升级到工作区符号索引。

## Semantic Tokens 与基础语法高亮

项目里同时有 Vim syntax 和 LSP semantic tokens。它们不冲突，分工不同。

Vim syntax 是词法/正则层高亮，不依赖 server，启动成本低。即使 LSP 没有启动，用户也能获得基本可读性。

Semantic tokens 是语义层高亮。它可以区分：

- 定义和引用。
- 函数和变量。
- 参数和普通局部变量。
- package 和普通对象。
- builtin member 和用户字段。

当前 LSP 支持 `textDocument/semanticTokens/full`，并采用 LSP 所需的 delta 编码返回 token。难点不在编码本身，而在分类准确。错误分类会给用户错误暗示：一个变量被高亮成函数，一个 package 被当成普通对象，都会让编辑体验变得不可信。

所以 semantic tokens 应该复用 symbol table 和 AST visitor，而不是另起一套 token scanner。词法高亮可以宽松，语义高亮必须谨慎。

## Code Action、Inlay Hint 与 Selection Range

高级编辑功能看起来零散，但都依赖同一套语义基础。

`codeAction` 当前可以做 quick fix，例如自动补 import。这个功能需要 diagnostics 告诉它“哪里缺了什么”，也需要 package/builtin metadata 告诉它应该 import 哪个 package。

`inlayHint` 可以显示函数参数默认值或参数名提示。对命名参数语言来说，这类 hint 可以帮助用户读懂调用，尤其是在多参数 builtin 里。

`selectionRange` 则让编辑器支持结构化选择：从 word 到 expression，再到 statement。它看起来只是一个 UI 功能，但实现上需要 AST range 准确。如果 AST location 粗糙，selection range 就会选中奇怪的片段。

这些功能说明了一件事：LSP 的高级能力不是在 server.cpp 里多加几个 handler 就完了。真正的基础是 parser location、AST visitor、symbol table、builtin metadata 和统一 JSON 输出。

## Formatter 的边界

formatter 是另一个容易失控的模块。

格式化不应该改变语义，也不应该试图修复语法错误。它应该在 AST 可用时基于结构输出稳定格式；在 AST 不可用时，要么保守返回空 edits，要么做非常有限的文本级处理。

Flux 的格式化尤其要小心 pipe chain：

```flux
data
    |> range(start: start, stop: stop)
    |> filter(fn: (r) => r.host == "edge-1")
    |> keep(columns: ["_time", "host", "_value"])
```

用户对查询可读性的预期很强：pipe 缩进、lambda 参数、对象字面量、数组列名都要稳定。formatter 如果频繁制造无意义 diff，用户很快会关掉它。

因此 formatter 的验收标准不只是“输出合法 Flux”，还应该包括 diff 稳定、幂等、错误输入保守、和项目文档示例风格一致。

## 测试策略

LSP 测试不能只靠打开编辑器手测。真实编辑器验证高亮和交互体验很有必要，但协议正确性和语义行为必须用单测守住。

当前测试已经覆盖多层：

- JSON-RPC message 解析和错误响应。
- transport 的 `Content-Length` 帧读写。
- initialize / initialized / shutdown / exit 生命周期。
- initialize 前请求返回 `ServerNotInitialized`。
- didOpen / didChange 后发布 diagnostics。
- completion 返回结构化 items。
- documentSymbol、foldingRange、definition、references、rename。
- signatureHelp、documentHighlight、semanticTokens。
- codeAction、inlayHint、selectionRange。
- formatter 和 JSON escape helper。

这些测试有一个共同目标：不要让编辑器成为第一个发现协议崩坏的人。比如 `INVALID_SERVER_JSON` 这类问题，应该在 JSON helper 或 server response 单测里就被抓住；lambda 参数跳转错位，应该在 definition/rename 测试里固定下来。

后续更值得补的是场景测试：一段真实 Flux 查询，同时验证 diagnostics、completion、semantic tokens、definition 和 rename 是否围绕同一份 symbol table 给出一致结果。

## 与 runtime/analyzer 的关系

LSP 不应该成为第二套语言实现。

短期内，LSP 自己维护 parser、AST cache 和 symbol table 是合理的，因为它要快速响应编辑器请求。但随着类型检查、builtin signature、package registry、semantic diagnostics 变强，runtime 和 LSP 必须共享更多语义基础。

理想方向是：

- parser 和 AST location 由语言前端统一提供。
- analyzer/binder 负责绑定 import、变量、函数、lambda 参数和 builtin。
- builtin metadata 同时服务 runtime 参数校验、completion、signature help 和 hover。
- 类型诊断来自共享类型层，而不是 LSP handler 自己判断。
- formatter、semantic tokens、selection range 都复用 AST visitor 基础设施。

这样用户在编辑器里看到的错误、补全和签名，才会和实际执行保持一致。语言项目最容易积累的债之一，就是 CLI、LSP、文档各说各话；这条边界需要一开始就守住。

## 下一篇

下一篇会回到工程保障，讲 parser/runtime/connector/LSP/conformance/benchmark 如何分层测试，避免语言实现持续退化。

## 小结

Flux LSP 的价值不只是“支持补全”。它把自研语言的使用体验从命令行推进到日常编辑环境：文档同步让 server 跟上用户输入，版本化 AST 缓存避免重复 parse，符号表支撑 definition/references/rename，semantic tokens 提供语义高亮，code action、inlay hint 和 selection range 则把编辑器体验继续往前推。

当前实现已经具备完整雏形：JSON-RPC、transport、document store、AST cache、symbol table、diagnostics、completion、hover、formatting、navigation、rename、semantic tokens 和测试都在主干上。下一步最值得做的是 workspace index、incremental diagnostics、formatter polish，以及让 LSP 和 runtime 共享更完整的 analyzer/builtin metadata。
