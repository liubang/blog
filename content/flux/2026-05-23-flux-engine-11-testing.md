---
title: "Flux 11: 测试体系"
description: "介绍 Flux 项目的 parser/runtime/CLI/LSP/conformance/benchmark 测试分层，以及为什么示例必须可执行。"
date: 2026-05-23
categories: [语言与编译]
tags: [flux, testing, bazel, cpp]
authors: ["liubang"]
weight: 11
series: ["Flux"]
series_weight: 11
---

语言和查询引擎项目最容易出现一种慢性问题：功能越加越多，旧语义悄悄坏掉。今天修 parser，明天改 runtime，后天补 connector pushdown，再过几天优化 LSP；如果没有清晰的测试分层，每次改动都会变成“看起来没问题”的冒险。

`cpp/pl/flux` 现在已经有 scanner/parser、runtime evaluator、标准库、table pipeline、connector、optimizer、physical executor、CLI 和 LSP。它不是一个单点库，而是一条从源码到编辑器、从 AST 到查询执行、从语义到性能的链路。测试体系要守住的不是某个函数，而是这条链路的边界。

这一篇讲的不是“多写测试”这种泛泛建议，而是 Flux 项目当前如何分层：哪些 bug 应该落在 parser test，哪些应该落在 runtime eval，哪些必须进入 conformance，哪些只能靠 benchmark 观察趋势。

## 测试不是一类

当前测试大致分成这些层：

- scanner / strconv unit test。
- parser unit test 和 AST dump。
- runtime value/env/eval/page/exec unit test。
- connector runtime/source unit test。
- optimizer RBO/CBO unit test。
- CLI unit/smoke test。
- stdlib conformance test。
- cross-source 和 feature examples。
- LSP unit test。
- benchmark runner。
- 静态检查。

每一层守不同边界。parser test 不应该承担 runtime 正确性；runtime eval test 不应该依赖真实 MySQL；LSP test 不应该通过人工打开编辑器来证明 JSON-RPC 正确；benchmark 更不应该伪装成 correctness test。

语言项目最需要的是“窄测试 + 宽测试”同时存在。窄测试定位快，宽测试能覆盖真实组合路径。只有单元测试会漏掉模块组合后的语义漂移；只有端到端测试则失败时很难知道错在 scanner、parser、runtime 还是 CLI formatter。

## 缺陷应该落在哪一层

一个好用的测试体系，首先要回答“这个 bug 应该在哪一层被抓住”。

可以用几类例子来看：

- token 切错，比如 duration、regexp、string escape：优先落在 scanner/strconv。
- pipe 优先级错，AST 形状变了：优先落在 parser AST dump。
- `1 == 1.0` 这种数值相等语义错：落在 runtime eval。
- `filter |> keep |> group |> count` 输出表形状错：落在 runtime exec 或 conformance。
- SQLite pushdown 把 `sort |> limit` 做成 split 内局部 top-n：落在 connector/physical executor。
- `array.scan` 行为被重构改坏：落在 stdlib conformance。
- CLI JSON 表输出缺 `group` 或 `table` 字段：落在 CLI test。
- lambda 参数 definition 跳转到文档开头：落在 LSP server test。
- group aggregate 从 0.1s 退回 20s：落在 benchmark regression，而不是普通单测。

这个映射很重要。它让每个新 bug 都能反哺测试结构，而不是只在最上层补一个大而慢的回归用例。

## Scanner 与 Parser 测试

scanner/parser 是语言实现的第一道门。这里的测试目标不是“能跑某个查询”，而是源码如何被结构化。

scanner 测 token：标识符、关键字、字符串、正则、duration、time literal、operator、注释和错误字符。strconv 测 literal 转换：转义、数字、时间和 duration 的边界。

parser 测 AST：函数、pipe、record update、成员访问、数组/对象字面量、import、option、attribute、testcase、默认参数、条件表达式、正则匹配、exists、调用优先级等。AST dump 在这一层非常有价值，因为它直接显示源码被解析成什么结构。

比如 pipe precedence 这种问题，用执行结果测反而绕远。下面的源码：

```flux
data
    |> filter(fn: (r) => r._value > 80.0)
    |> keep(columns: ["_time", "_value"])
```

parser test 应该确认它是连续 pipe chain，而不是某个调用参数被错误吞进去。这个层级只关心结构，不关心 `filter` 最终怎样执行。

## Golden Dump 的边界

AST golden dump 很好用，但不能滥用。

它适合固定关键结构，比如 pipe、function、record update、import alias、lambda 参数位置。它不适合把每个 debug 字符串细节都变成契约。否则 AST printer 稍微调整缩进，测试就会大面积失败，最后大家会对 golden 产生疲劳。

更合理的取舍是：

- 语法结构用 AST dump。
- 运行语义用执行结果。
- 标准库公开行为用 conformance JSON。
- CLI 输出格式用 CLI golden。
- 性能趋势用 benchmark baseline。

例如 `aggregateWindow(createEmpty:)` 的空窗口语义，不应该靠 AST dump 验证；它应该在 runtime/conformance 中看真实输出。反过来，parser 的错误恢复也不应该等到 runtime 才发现。

## Runtime Eval：表达式语义

`runtime_eval_unit_test` 更接近表达式解释器。它覆盖 literal、member/index、exists、字符串插值、正则、函数调用、闭包、默认参数、pipe 参数、array helper、table helper 等。

这层测试应该尽量小，不依赖 CLI，不读外部文件，不启动 connector。它要回答的是：给 evaluator 一段表达式或小程序，运行时值是否符合 Flux 语义。

前面修过的 numeric equality bug 就应该落在这里：

```flux
import "array"

array.filter(arr: [1, 2, 3, 4], fn: (x) => x == 3)
```

如果 evaluator 把 int/float/uint 的比较做错，这个测试能快速定位到运行时值和运算符语义，而不是让问题一路穿过 CLI、JSON formatter 和 conformance 才暴露。

这一层也适合覆盖闭包和默认参数：

```flux
make = (base) => (x=1) => base + x
add10 = make(base: 10)
add10(x: 5)
```

如果词法作用域或默认参数求值时机错了，runtime eval 应该第一时间失败。

## 负例测试同样重要

语言测试不能只测成功路径。很多回归最先体现在错误路径：错误没有报、报错层级错、错误位置丢失、状态码不对。

应该有负例覆盖：

- 未定义变量。
- 缺少必填参数。
- 多传未知参数。
- 类型不符合 builtin 要求。
- 数组越界或对象字段不存在。
- 除零。
- parser malformed 输入恢复。
- connector 参数非法。
- LSP initialize 前请求。

负例不一定要固定完整错误文案。错误文本如果过度 golden 化，后续改善提示时会很痛苦。更好的策略是固定错误类别、关键片段和 source location。比如“未定义变量”必须包含变量名和位置，但不必固定每个标点。

最近 runtime statement execution error 会附带 `SourceLocation`，这类能力也应该有 CLI 或 exec 测试守住。错误定位是语言体验的一部分，不能只在成功路径里验证语义。

## Runtime Exec：文件和查询执行

`runtime_exec_unit_test` 比 eval 更接近真实执行。它覆盖 import、option、声明、结果收集、查询 pipeline、table transform、connector pushdown、physical execution、profile 等。

这一层适合测试完整文件：

```flux
import "array"

array.from(rows: [
    {_time: 2024-01-01T00:00:00Z, host: "edge-1", _value: 91.2},
    {_time: 2024-01-01T00:01:00Z, host: "edge-2", _value: 64.0},
])
    |> filter(fn: (r) => r._value > 80.0)
    |> keep(columns: ["_time", "host", "_value"])
```

它不只是测 evaluator，还测 table stream、pipe 参数、builtin registry、结果收集和输出边界。第 06 篇讲到的多 logical table、group key、empty table、aggregate/selector 输出形状，都应该在 exec 或 conformance 中有覆盖。

这一层也是 connector 和 physical executor 的主要回归网之一。比如 pushdown 是否生效、fallback boundary 是否正确、profile 是否暴露 split/pages/rows、root output error 是否取消上游 exchange，都不适合只放在表达式 eval 里。

## Page 与 Pipeline 测试

第 08 篇讲过，当前执行主干已经从 `TableValue` 默认通道转向 `Page / PageChunk / ColumnVector`。这意味着测试也要覆盖 Page-native 路径，而不是只看最终行结果。

Page 层测试要关心：

- Page chunk 的列类型和行数一致。
- filter/project/range 能逐 Page streaming。
- accumulator 能逐 Page 吸收输入并最终产出结果。
- high-cardinality group/distinct/aggregate 能通过 partial/final 合并。
- blocking operator 的 profile 和 memory 统计正确。
- materialize boundary 不会悄悄出现在 streaming path 中。

最终结果相同，不代表执行路径相同。一个查询从 Page streaming 退回整表 `TableValue`，correctness 可能不变，但性能和内存语义已经退化。所以执行层测试需要同时看结果、profile 和 plan/explain。

## Connector 测试

connector 测试分几类。

第一类是 connector runtime conformance。它验证 metadata、split manager、page source provider 这三层边界，而不是只验证某个 SQL 字符串。

第二类是具体数据源测试。SQLite 适合作为默认真实 connector，因为它可以在测试中临时构造数据库，确定性强，不依赖外部服务。SQLite 可以覆盖 table scan、rowid split、pushdown、Page source、materialization 等主路径。

第三类是 MySQL 测试。MySQL 更接近真实远端 connector，有连接池、网络、协议解码和 range split。但它不能要求每个开发环境都有同一套数据库，所以需要通过环境变量控制：有 DSN 就跑，没有就 skip。

这种可降级策略很重要。外部依赖测试既不能被完全 mock 掉，否则没有意义；也不能让所有本地开发都被远端服务绑架。SQLite 守默认确定性，MySQL 守真实集成路径，这是比较平衡的组合。

## Optimizer 测试

optimizer 测试不应该只验证“结果对了”。RBO/CBO 的核心是计划改写，结果正确只是最低要求。

RBO 单测应该覆盖：

- simple filter 是否下推。
- projection pruning 是否保留必要列。
- rename 后 column assignment 是否正确。
- unsupported suffix 是否插入 materialize。
- `sort + limit` 是否规划成 top-n 或拒绝不安全 split。
- `group |> aggregate` 是否进入 grouped accumulator 或 connector aggregate。

CBO 单测则应该更谨慎。当前 CBO 还是 framework，缺 statistics 时应该退化为 RBO，而不是假装能做精确选择。测试应该固定这种行为：unknown cost 不应该导致随机 plan choice。

optimizer 测试的关键是可解释。每条 rule 最好能说明为什么触发、为什么拒绝。后续 explain 才能把这些信息传递给用户。

## CLI 测试

CLI 是用户真正触碰项目的入口之一。它要守住的不是 Flux 语义本身，而是“命令行契约”。

CLI 测试应该覆盖：

- 输入文件执行。
- `--output-format json`、human/csv 等输出。
- `--result` 选择特定结果。
- 多 result / `yield`。
- 错误状态码。
- 错误位置输出。
- table JSON 输出的 `table` index 和 `group` flag。
- explain/profile 输出中的关键字段。

为什么这层不能省？因为 runtime 结果对了，CLI 仍然可能把 JSON 格式输出错。对脚本用户来说，CLI JSON 就是 API；字段缺失或形状变化都可能破坏下游自动化。

## Stdlib Conformance：示例即契约

`examples/stdlib_conformance` 是整个测试体系里很重要的一层。它把示例和公开行为契约合在一起。

这里的规则很明确：

- 每个已实现 builtin 都必须有一个主覆盖点。
- 一个 builtin 只在一个文件里作为主覆盖点，避免职责分散。
- `syntax.flux` 只覆盖 parser 和 runtime 都能实际执行的语法形态。
- `system.time()` 这种非确定输出用正则匹配形状，不固定具体时间。
- 测试脚本会检查每个 `.flux` 文件都登记进测试，防止新增样例没有被跑。

脚本的核心行为是执行每个 conformance `.flux`：

```bash
flux --output-format json --result _result examples/stdlib_conformance/array.flux
```

然后把 JSON 输出和 golden 比对。这样示例不是装饰性文档，而是会被持续执行的契约。

这层覆盖了 array、csv、date、dict、join、json、math、regexp、runtime、sqlite、strings、syntax、system、timezone、types、universe core/transform/aggregate/window/inspect/join 等公开能力。新增 `timezone.utc/fixed/location` 这类 builtin 时，就应该同步补 conformance，而不只是写一个单元测试。

Conformance 的另一个价值是防文档漂移。示例如果不能执行，测试会失败；标准库行为如果变了，golden 会提醒我们判断这是刻意变更还是回归。

## 示例分层：Conformance、Gallery、Dashboard

项目里的示例不止 conformance。

`stdlib_conformance` 偏契约，小而确定，适合做 golden。

`feature_gallery` 偏能力展示，会把函数、数组、时间、join、pivot、inspection helpers 等能力组合成更像用户会写的查询。它适合验证“功能组合起来还能读、还能跑”。

`ops_dashboard` 偏场景叙事，用 CPU/memory、窗口、top、gap fill、calendar、union、pivot 等查询模拟运维仪表盘。它的价值是让引擎不只在 toy case 上正确，也能覆盖更接近真实使用的查询形态。

这三类示例最好不要混在一起。契约测试要小而稳定；展示示例可以更丰富；场景示例要追求可读性和业务连贯。分层清楚，维护成本才不会互相污染。

## LSP 测试

LSP 测试的目标是别让编辑器成为第一个发现问题的人。

当前 LSP 单测直接模拟 JSON-RPC 请求和响应，覆盖：

- initialize / initialized / shutdown / exit。
- initialize 前请求返回 `ServerNotInitialized`。
- didOpen / didChange 后发布 diagnostics。
- completion items。
- documentSymbol 和 foldingRange。
- definition、references、rename。
- signatureHelp 和 documentHighlight。
- semanticTokens/full。
- codeAction、inlayHint、selectionRange。
- formatter。
- JSON escape 和 transport frame。

这类测试特别适合抓协议级错误。比如响应 JSON 少一个逗号，semantic token delta 编码错，completion item 字段 shape 不对，编辑器会直接报 server 错。单测应该在这些问题到达编辑器前就拦住。

LSP 还有一个特别值得测的方向：同一份文档的不同 handler 是否共享一致语义。比如 diagnostics 认为某个变量未定义，completion 却把它当已定义；definition 跳到一个位置，rename 又改了另一组引用。这类不一致通常说明 AST cache、symbol table 或版本失效策略出了问题。

## Benchmark 不是 Correctness Test

benchmark 的目标是观察性能趋势，不是证明语义正确。

当前 benchmark 分几类：

- 内存执行基准：CSV、table builtin、window、pivot、join 等。
- SQLite connector scan：真实 SQLite 表、多 split page source、Top-N、group/distinct accumulator。
- MySQL connector scan：真实 MySQL 表、range split、Boost.MySQL page source、远端协议解码。

benchmark 输出 samples、median、mean、drivers、pages、split bytes、split wall time、blocking、accumulator profile、query memory 等信息。它用于同机同口径前后对比，不能拿不同机器、不同网络、冷热缓存不同的数字硬比。

比如 SQLite 1M rows 的 grouped accumulator 优化，从整表 row-object 中间态退到 Page-native two-stage accumulator 后，性能可能从几十秒降到百毫秒级。这个结论不能靠“感觉快了”写进 PR；需要 runner 输出 baseline、repeat samples 和 profile 分段。

如果要把 benchmark 变成回归门禁，也要谨慎。适合用 release build、固定数据、固定 warmup/repeat、允许一定阈值，比如 median 超过 10% 才认为 regression。性能测试太敏感会制造噪音，太宽松又抓不住退化。

## 静态检查与构建门禁

静态检查不能替代测试，但它能把很多 C++ 层面的粗糙问题提前拦住：不必要拷贝、生命周期风险、可疑移动、现代 C++ 风格问题、未使用变量等。

对查询引擎项目来说，静态检查的价值在 review 前。它不理解 Flux 语义，也不知道 group key 是否正确，但它能帮助代码保持在一个可维护的 C++ 基线之上。

构建门禁也很重要。一次完整回归通常应该至少跑：

```bash
bazel test //cpp/pl/flux/... --test_output=errors
```

这条命令覆盖 Flux 主干下的单元、CLI、LSP 和 conformance 测试。性能相关改动再额外跑 benchmark；MySQL 相关改动如果有 DSN，再跑 MySQL connector 路径。

## 测试新增功能的顺序

给项目加一个新能力时，测试顺序可以按风险递进。

比如新增一个标准库 builtin：

1. runtime eval 或 runtime exec 先覆盖成功路径和典型负例。
2. 如果涉及表语义，补 table pipeline 或 exec case。
3. 如果是公开 stdlib，补 `stdlib_conformance` 主覆盖点。
4. 如果 CLI 输出会变，补 CLI test。
5. 如果 LSP 要补 completion/signature/hover，同步补 LSP test。
6. 如果可能影响性能，补 benchmark case 或至少跑相关 baseline。

比如新增一个 connector pushdown：

1. optimizer rule test 固定计划改写。
2. connector contract test 固定支持和拒绝条件。
3. SQLite source test 覆盖确定性真实数据。
4. runtime exec 测 fallback boundary。
5. explain/profile 测关键字段。
6. benchmark 观察是否真的减少 rows/pages/materialization。

这个顺序的好处是，每一层都只负责自己的边界。后续失败时，测试名字基本能告诉我们问题在哪。

## 下一篇

下一篇会讨论性能优化：如何用 profile 找瓶颈，如何从 `TableValue` 走向 Page streaming、connector pushdown 和 two-stage accumulator。

## 小结

测试体系的核心不是“测试越多越好”，而是每层测试守住自己的职责。scanner/parser 守源码结构，runtime eval 守表达式语义，runtime exec 守完整查询，connector/optimizer 守计划和数据源边界，CLI 守命令行契约，stdlib conformance 守公开标准库行为，LSP test 守编辑器协议和语义服务，benchmark 守性能趋势。

对一个语言和查询引擎项目来说，真正可靠的测试体系应该像执行架构一样分层。它让新功能可以持续加入，也让每次重构都有回声：如果语法变了，parser test 会说话；如果语义变了，conformance 会说话；如果性能退化，benchmark 会说话。这样项目才不会在功能增长中慢慢失去可信度。
