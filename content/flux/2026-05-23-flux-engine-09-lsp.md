---
title: LSP 支持：给自研语言补齐 IDE 体验
description: "介绍 Flux Language Server 的 JSON-RPC、文档同步、AST 缓存、补全、诊断、跳转、引用、重命名、语义高亮和测试策略。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, lsp, language-server, cpp]
authors: ["liubang"]
weight: 9
series: ["Flux"]
series_weight: 9
---

一个自研语言只提供 CLI 是不够的。真正写起来舒服，还需要编辑器支持：诊断、补全、跳转、引用、重命名、语义高亮、签名帮助。`cpp/pl/flux/contrib/lsp` 就是为这个目标准备的 Flux Language Server。

## LSP server 的基础结构

LSP 本质上是 JSON-RPC 协议。server 通过 stdin/stdout 或其他 transport 接收请求，维护文档内容，然后对不同 method 返回结果。

当前模块主要包括：

- `jsonrpc.*`：JSON-RPC message 解析和响应。
- `transport.*`：LSP transport。
- `server.*`：method 分发和主要能力实现。
- `symbol_table.*`：符号表、作用域和定义/引用信息。
- `formatter.*`：格式化相关能力。
- `json_util.*`：JSON 构造辅助。

早期遇到过 `INVALID_SERVER_JSON` 这类问题，本质是响应 JSON 拼接不严谨。后来相关 JSON 生成路径统一用 helper，避免手写字符串造成协议层错误。

## JSON-RPC 层为什么要克制

LSP server 最底层处理的是协议帧：`Content-Length`、JSON-RPC request id、method、params、response、notification。这里最怕把业务逻辑和协议字符串拼接混在一起。

`INVALID_SERVER_JSON` 这类错误通常不是语言语义错了，而是响应体不是合法 JSON。比如少一个逗号、字符串没 escape、数组/object 没闭合，编辑器就会直接认为 server 坏了。

因此 JSON-RPC 层应该尽量只做三件事：解析消息、分发 method、封装响应。completion、diagnostics、semantic tokens 等业务逻辑应该返回结构化对象，再由统一 helper 序列化。这样协议层错误会少很多，单测也更容易覆盖。

## 文档同步与 AST 缓存

LSP 的性能基础是避免重复 parse。当前 server 支持增量文档同步，并通过 `ensure_ast` 这类入口管理 AST 缓存和 simdjson parser 实例复用。

编辑器里每敲一个字符都全量重建所有状态是不现实的。当前实现还不是完整 incremental parser，但文档缓存和增量同步已经能避免很多无谓工作。

## AST 缓存的失效策略

LSP 里的 AST 缓存不能只按 URI 保存。每次 `didChange` 后，文档 version 变了，旧 AST 就可能失效。安全做法是把缓存和当前 document version 绑定，只有版本一致时复用。

同时，很多请求会共享同一份 AST：diagnostics、completion、definition、semantic tokens、documentSymbol 都需要解析结果。`ensure_ast` 这类统一入口的价值就是避免每个 handler 自己 parse 一遍，也避免不同 handler 对错误文档产生不一致结果。

后续如果做 incremental parse，缓存粒度可以从整个 AST 细化到 subtree；但在此之前，版本化全量 AST 缓存已经能覆盖大部分性能收益。

## Diagnostics

诊断主要来自 parser errors 和语义分析层。parser 可以返回语法错误；符号表分析可以发现未定义标识符等问题。

诊断质量依赖 AST location。比如 import、变量定义、lambda 参数、成员访问都需要准确范围，否则编辑器只能在错误位置画红线。

## 语义诊断和类型诊断不是一回事

当前 LSP 可以做未定义标识符这类语义诊断，因为符号表知道当前作用域里有哪些绑定。但它还不能完整判断 `array.map(arr: 1, fn: ...)` 这种类型错误，因为项目还没有完整类型检查层。

这两类诊断应该分阶段推进。先做符号诊断，保证变量、函数、lambda 参数、import package 的绑定关系正确；再引入 builtin signature 和简单类型约束；最后才考虑更完整的 Flux 类型推断。

如果过早把类型判断散落在 LSP handler 中，后续 runtime 和 LSP 会出现两套不一致的语义规则。更好的方向是让 analyzer/binder 成为 runtime 和 LSP 共享的语义基础。

## Completion

补全覆盖几类内容：

- 关键字和常见语法。
- 已导入 package 的 builtin function。
- 用户定义符号。
- package function 的 detail。
- 函数补全 snippet。

例如 `import "array"` 后，`array.` 可以补出 `map/filter/reduce/range/scan/unfold` 等函数。函数补全如果带 snippet，编辑器可以直接展开参数模板，这是小功能，但对写查询很有帮助。

## Completion 的上下文判断

补全不是简单返回所有单词。不同光标位置应该给不同建议：

- 文件开头可以补 `package`、`import`、`option`。
- `import "` 内可以补 package path。
- `array.` 后应该补 array package 函数。
- `filter(fn: (` 的 lambda 参数位置不应该补 package 函数。
- 普通表达式位置应该混合用户符号、builtin 和关键字。

这要求 LSP 至少能拿到光标前后的 token/AST 上下文。当前实现已经能做用户定义符号补全和 package 函数补全，后续可以继续细化上下文，减少“什么地方都弹一堆候选”的噪音。

## Definition、References 与 Rename

goto definition 依赖符号表和作用域分析。全局变量、局部变量、函数参数和 lambda 参数都需要被收集成 symbol，并记录定义位置和引用位置。

曾经出现过这样的 bug：

```flux
filter(fn: (r) => r.active == true)
```

这里的 `r` 跳转到了文档开头。根因是 lambda 参数 source location 不准确，导致符号表把定义位置记录错了。修复后，lambda 参数可以跳回自己的参数定义处。

references 和 rename 在 definition 的基础上继续扩展：不仅要找到定义，还要找到同一作用域绑定下的所有引用，避免误改同名但不同作用域的变量。

## 符号表需要处理 shadowing

同名符号在不同作用域里可以代表不同东西：

```flux
x = 1
f = (x) => x + 1
```

函数体里的 `x` 应该跳到参数 `x`，而不是顶层 `x`。rename 也只能改同一绑定的引用，不能把顶层和局部一起改掉。

这就是为什么 LSP 不能只做文本搜索。它必须构建 scope tree：顶层 scope、函数 scope、lambda 参数 scope、block scope。每个 reference 都要解析到某个 definition，再由 definition 反查 references。

## Semantic Tokens

语义高亮和普通 Vim syntax 不同。普通 syntax 只看 token 形态，semantic tokens 可以区分定义和引用、函数和变量、package 和普通对象。

当前 LSP 已支持 `textDocument/semanticTokens/full`。这对 import、变量、函数、成员、字符串、参数等高亮都有帮助。语义高亮的难点不在颜色，而在分类准确：错误分类会让编辑器给用户错误暗示。

## Semantic tokens 和 Vim syntax 的边界

项目里同时有 `contrib/vim/syntax/flux.vim` 和 LSP semantic tokens。前者是词法/正则层的高亮，启动成本低，不依赖 server；后者是语义层高亮，能知道某个 token 是定义、引用、参数还是 package member。

两者不是互相替代。基础 syntax 负责没有 LSP 时的可读性；semantic tokens 负责 IDE 级准确性。真正的问题是分类一致性：如果 import path、package alias、用户函数和 builtin 在不同高亮系统里颜色含义冲突，用户会困惑。后续应该把 LSP token type 和 Vim syntax group 的意图文档化。

## 其他编辑体验

当前 roadmap 中已经完成的能力还包括：

- `documentSymbol`
- `foldingRange`
- `signatureHelp`
- `documentHighlight`
- `codeAction`
- `inlayHint`
- `selectionRange`

这些功能都不是单纯协议适配。它们共同依赖 parser、AST location、symbol table 和 builtin metadata。

## LSP 测试

LSP 单测会直接模拟 JSON-RPC 请求，验证响应结构和核心字段。相比手动打开编辑器测试，单测能稳定覆盖：

- 初始化能力声明。
- 文档打开/变更。
- completion item。
- diagnostics。
- definition/references/rename。
- semantic tokens。
- formatter 和 transport 边界。

真实编辑器仍然需要人工验证高亮观感，但协议和语义行为必须由测试守住。

## 小结

LSP 是语言项目从“能跑”到“好写”的关键。`cpp/pl/flux` 的 LSP 现在已经不只是诊断和补全，而是具备符号表、跳转、引用、重命名、签名帮助、语义高亮和 code action 的完整雏形。后续最值得继续做的是 workspace index、incremental diagnostics、formatter polish 和更丰富的 hover 文档。
