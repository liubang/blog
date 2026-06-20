---
title: "打造高效终端 IDE：我的 Neovim 完全配置指南"
description: "从架构设计、插件选型、LSP 生态到调试与工作流，全面介绍一套面向多语言开发的 Neovim 现代化配置——venux。"
date: 2026-06-10
categories: [工具与杂谈]
tags: [neovim, vim, ide, lsp, snacks, lazy.nvim, tools]
authors: ["liubang"]
lightgallery: true
---

> 一套好的编辑器配置，不是插件堆砌，而是对工作流的深度理解。

## 缘起

我最初接触 Vim 的动机非常简单——那会儿市面上没有一款让我满意的 C 语言开发工具。IDE 太重、启动慢，轻量编辑器又缺少代码导航和补全能力。Vim 的模态编辑理念和高度可定制性吸引了我，从一个简单的 `.vimrc` 开始，这门手艺一直打磨到了今天。

这套配置的 Git 仓库始于 **2017 年 12 月 13 日**，至今已有 2000+ 次提交，跨越了八年多时间。它的演进过程本身就是终端编辑器生态变迁的一个缩影：

| 时间 | 里程碑 | 说明 |
| :--- | :--- | :--- |
| 2017.12 | VimScript + vim-plug | 初始提交，纯 VimScript 配置，使用 vim-plug 管理插件 |
| 2018 ~ 2019 | 功能扩展期 | 逐步加入 ftplugin、代码补全（YouCompleteMe）、文件树、状态栏等，年度提交量 ~280 |
| 2020.06 | Lua 试水 | 第一批 `.lua` 文件出现，开始在文件类型检测和少量插件配置中使用 Lua |
| 2020.12 | init.lua 上线 | 正式用 `init.lua` 替代 `init.vim`，标志着全面转向 Neovim Lua 生态 |
| 2021.01 | packer.nvim | 从 vim-plug 迁移到 packer.nvim，享受 Lua-native 插件管理器的性能提升 |
| 2022.12 | lazy.nvim | 迁移到 lazy.nvim，全面采用懒加载策略，启动速度从 200ms+ 降至 100ms 以内 |
| 2023 | 深度优化期 | 大规模重构 LSP 配置、精细化 snippet 体系、引入 mini.nvim 生态替代大量独立插件 |
| 2025.03 | blink.cmp | 将 nvim-cmp 替换为 blink.cmp，补全性能获得质的飞跃（Rust 后端 + Frecency 算法） |
| 2026.03 | venux 命名 | 配置框架正式命名为 venux，提取独立的 UI 组件库和工具函数层 |
| 2026.05 | treesitter 升级 | 移除 nvim-treesitter，迁移到内置 treesitter + tree-sitter-manager.nvim 的轻量方案 |
| 2026.06 | Snacks.nvim | 核心工作流全面迁移到 Snacks.nvim：picker 替换 Telescope、dashboard 替换 alpha-nvim；格式化迁移到 conform.nvim；默认主题切换为 everforest；DAP 精简为 java 依赖 |

> 每一次迁移都不是追逐新潮，而是对旧方案的局限有了切肤之痛。

如今 Neovim 0.11+ 的 Lua 生态已经足够成熟，venux 在保持 60+ 个插件的同时，启动时间稳定在 **100ms 以内**。

这套配置托管在 [GitHub](https://github.com/liubang/nvim) 上，采用 Apache 2.0 协议开源。本文将从架构到细节，完整介绍它的设计思路与使用方式。

## 架构设计

### 整体结构

venux 采用模块化分层设计，所有配置以 Lua 组织：

```
nvim/
├── init.lua                    # 入口：启用 loader，加载 venux
├── after/                      # 自动加载的局部配置
│   ├── ftdetect/               # 文件类型检测
│   ├── ftplugin/               # 文件类型专属配置
│   └── syntax/                 # 自定义语法文件
└── lua/
    ├── venux/                  # 核心框架
    │   ├── init.lua            # 框架入口
    │   ├── options.lua         # 编辑器基础选项
    │   ├── autocmd.lua         # 自动命令
    │   ├── commands.lua        # 自定义命令
    │   ├── mappings.lua        # 全局键位映射
    │   ├── config.lua          # 全局配置（图标、kind 等）
    │   ├── lazy.lua            # lazy.nvim 初始化
    │   ├── treesitter.lua      # treesitter 配置
    │   ├── health.lua          # 健康检查
    │   ├── ui/                 # 自定义 UI 组件库
    │   │   ├── confirm.lua     # 确认弹窗
    │   │   ├── inputbox.lua    # 输入框
    │   │   ├── listbox.lua     # 列表选择
    │   │   ├── multi_select.lua # 多选组件
    │   │   └── textbox.lua     # 文本框
    │   └── utils/              # 工具函数
    │       ├── util.lua        # 通用工具
    │       ├── comment.lua     # 注释生成
    │       ├── doc.lua         # 文档生成
    │       └── fold.lua        # 代码折叠
    ├── plugins/                # 插件配置（按功能拆分）
    │   ├── lsp/                # LSP 子系统
    │   │   ├── defaults.lua    # 通用 on_attach 和 capabilities
    │   │   ├── config.lua      # LSP 配置入口
    │   │   ├── init.lua        # LSP 插件声明与 mason 集成
    │   │   └── servers/        # 各语言 LSP 配置
    │   ├── dap/                # DAP 调试子系统（精简为 java 依赖）
    │   ├── java/               # Java 专属配置
    │   └── snips/              # 代码片段
    └── snacks/                 # Snacks.nvim 自定义扩展
        ├── bazel.lua           # Bazel 构建集成
        └── tasks.lua           # 异步任务集成
```

这个结构的核心原则是：**关注点分离**。每一层、每一个文件只负责一件事：

- `venux/` 层负责编辑器原生行为（options、autocmd、mappings），不涉及插件
- `plugins/` 层负责插件声明与配置，每个插件独立文件
- `after/` 层利用 Neovim 的 runtimepath 机制，按需覆盖
- `snacks/` 层存放 Snacks.nvim 的自定义 picker 扩展

### 插件管理体系

venux 使用 [folke/lazy.nvim](https://github.com/folke/lazy.nvim) 作为插件管理器。lazy.nvim 的核心优势在于其精细的懒加载控制：

```lua
require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
  defaults = { lazy = true },     -- 全局默认懒加载
  concurrency = 6,                 -- 并发安装
  install = {
    missing = true,
    colorscheme = { "everforest" }, -- 默认主题
  },
  dev = {
    path = "~/workspace/liubang", -- 本地开发路径
    patterns = { "liubang" },      -- 按作者匹配本地插件
  },
  performance = {
    rtp = {
      reset = true,
      disabled_plugins = {         -- 禁用不需要的内置插件
        "netrwPlugin", "syntax", "tutor",
        "zipPlugin", "tarPlugin", "gzip",
        "matchit", "matchparen", ...
      },
    },
  },
})
```

几个关键设计决策：

1. **全局默认懒加载**：`defaults.lazy = true`，所有插件默认不加载，只在触发 `event`、`cmd`、`keys` 或 `ft` 时才加载
2. **rtp 重置**：`rtp.reset = true` 清空 Neovim 默认的 runtimepath 项，只保留必要的，减少启动时的扫描开销
3. **禁用内置插件**：Neovim 默认加载了许多你可能永远用不到的插件（如 netrw、tutor、tarPlugin），禁用它们可以节省启动时间
4. **dev 路径**：`dev.path` 指向本地工作区，开发自己的插件时可以自动从本地加载

这些优化使得 venux 在加载 60+ 个插件的情况下，启动时间仍然控制在 100ms 以内（dashboard 会显示精确的插件加载数量和时间）。

## 核心能力

### 基础编辑体验

#### Options：精心调校的默认值

`options.lua` 是经过多年使用沉淀下来的最佳实践配置，这里挑几个重点说明：

```lua
vim.opt.termguicolors = true       -- 启用 24 位真彩色
vim.opt.completeopt = "menuone,noinsert,noselect"
vim.opt.timeoutlen = 500           -- 键序列超时 500ms
vim.opt.ttimeoutlen = 10           -- 终端序列超时 10ms
vim.opt.updatetime = 300           -- swap 写入间隔 300ms（光标更灵敏）
vim.opt.scrolloff = 3              -- 滚动时保留 3 行上下文
vim.opt.splitright = true          -- 垂直分割在右侧打开
vim.opt.splitbelow = true          -- 水平分割在下方打开
vim.opt.grepprg = "rg --vimgrep"   -- 使用 ripgrep 替代 grep
vim.opt.textwidth = 100            -- 文本宽度 100 字符
vim.opt.foldmethod = "expr"        -- 使用表达式折叠
vim.opt.foldtext = 'v:lua.require("venux.utils.fold").foldtext()'
```

值得特别说明的是 `foldmethod = "expr"` 配合自定义 `foldtext`：venux 实现了一套基于 treesitter 语法的折叠系统，折叠行会展示该折叠区域的语法摘要，而不是简单的 `+-- 15 lines`。

`grepprg` 设置为 `rg --vimgrep`，确保 Neovim 原生的 `:grep` 和 `:vimgrep` 都走 ripgrep，享受其速度和 `.gitignore` 感知能力。

#### Keymaps：键盘就是最好的鼠标

全局键位设计遵循几个原则：

- `<Leader>` 设为空格键，操作区域大、好按
- 高频操作映射到字母键，无需按修饰键
- 相关功能聚合在同一个前缀下

```lua
-- 窗口管理 <Leader>w
<Leader>wh/j/k/l     -- 窗口间移动（类似 Vim 的 hjkl）
<Leader>ws           -- 水平分割
<Leader>wv           -- 垂直分割
<Leader>wd           -- 关闭窗口
<C-Up/Down/Left/Right> -- 调整窗口大小

-- 缓冲区 <Leader>b
<Leader>bp/bn        -- 上一个/下一个缓冲区
<Leader>bd/bD        -- 删除缓冲区

-- 代码跳转 <Leader>g（LSP，走 Snacks.picker）
<Leader>gd           -- 跳转到定义
<Leader>gr           -- 查找引用
<Leader>gi           -- 跳转到实现
<Leader>rn           -- 重命名
<Leader>ca           -- 代码操作

-- Git 操作 <Leader>g（Snacks.picker）
<Leader>gf           -- 列出 Git 文件
<Leader>gs           -- Git 状态
<Leader>gl           -- Git 日志
<Leader>gL           -- 当前文件的 Git 日志
<Leader>gh           -- 当前行的 Git 日志
<Leader>gv           -- Git diff（hunks）
<Leader>gb           -- 当前行 Git blame
<Leader>gB           -- Git 分支
```

另外一些人性化的映射：

```lua
-- 搜索历史更智能：始终朝同一个方向搜索
vim.keymap.set("n", "n", "'Nn'[v:searchforward]", { expr = true })
vim.keymap.set("n", "N", "'nN'[v:searchforward]", { expr = true })

-- 移动行
<S-j> / <S-k>        -- 将当前行向下/上移动

-- 视觉模式下保持选区
< / >                -- 缩进后保持选中
<Tab> / <S-Tab>      -- 缩进后保持选中

-- 输入模式下 Bash 风格快捷键
<C-a>                -- 跳到行首
<C-e>                -- 跳到行尾

-- 快速清除搜索高亮
<Esc><Esc>           -- 双击 Esc
```

#### 代码折叠

venux 实现了基于 treesitter 语法的智能折叠系统（`venux.utils.fold`）。相比于传统的 `foldmethod=indent` 或 `foldmethod=syntax`，treesitter 折叠能精确识别语言结构：

- 函数体、类体、if/for/while 块都会自动生成折叠点
- 折叠行会显示第一行的内容预览，而不是简单的 `+-- N lines`
- `foldnestmax = 3` 限制最大嵌套层级，避免过度折叠

对于大数据文件的性能问题，venux 使用 Snacks.nvim 的 `bigfile` 功能：超过 400KB 的文件会自动关闭 treesitter 高亮、诊断等重功能，确保编辑大文件时的流畅体验。

#### 终端集成

venux 使用 `akinsho/toggleterm.nvim` 提供内置终端：

- `<C-t>` 打开/关闭水平分割终端（覆盖 55% 的窗口高度，停靠在底部）
- 终端模式下再次 `<C-t>` 可返回普通模式并关闭终端
- 自动关闭行号、相对行号、signcolumn，保持干净的终端界面

terminal 的交互也做了优化：`<Esc>` 一键从终端模式切换到普通模式（映射为 `<C-\><C-N>`），不必再伸手去够那个别扭的原生组合键。

![toggleterm 水平分割终端](/images/neovim/terminal.png "终端集成")

### 代码智能（LSP）

#### 多语言 LSP 架构

venux 的 LSP 系统是最复杂的子系统，其架构如下：

```
Mason (LSP Server 管理)
   ↓
mason-lspconfig (LSP Server 安装桥接)
   ↓
nvim-lspconfig (LSP 客户端配置)
   ↓
┌──────────────────────────────────────┐
│ defaults.lua                          │
│ - on_attach (keymaps, Snacks.picker)  │
│ - capabilities (blink.cmp 集成)       │
│ - extend() / enable()                 │
│   (使用 vim.lsp.config() API)         │
└──────────┬───────────────────────────┘
           │
    ┌──────┴──────────────┐
    │ servers/            │
    │  ├── clangd.lua     │  ← C/C++
    │  ├── gopls.lua      │  ← Go
    │  ├── basedpyright.lua│ ← Python
    │  ├── lua_ls.lua     │  ← Lua
    │  ├── jsonls.lua     │  ← JSON
    │  ├── yamlls.lua     │  ← YAML
    │  ├── texlab.lua     │  ← LaTeX
    │  ├── lemminx.lua    │  ← XML
    │  └── flux_ls.lua    │  ← Flux
    └─────────────────────┘
```

目前已配置的 LSP 服务器分为两类：

**深度配置**（有独立 server 文件，调校过参数）：

| 语言/文件类型 | LSP Server | 特殊配置 |
| :--- | :--- | :--- |
| C/C++ | clangd | `--background-index`、`--header-insertion=never`、`--function-arg-placeholders=0` |
| Go | gopls | semantic tokens 启用、organize imports 自动、staticcheck 启用 |
| Python | basedpyright | typeCheckingMode = "standard" |
| Lua | lua_ls | 集成 lazydev 类型注解、第三方库路径配置 |
| Java | jdtls | Spring Boot 支持、自定义 UI（见 Java 专属配置） |
| JSON/YAML | jsonls / yamlls | schemastore 自动补全 |
| LaTeX | texlab | 双向搜索、chktex 集成 |
| XML | lemminx | |
| Flux | flux_ls | |

**基础配置**（使用 `defaults.enable(server)`，无额外参数）：

thriftls, taplo, ts_ls, eslint, bashls, protols, neocmake, intelephense, nginx_language_server, docker_language_server

venux 使用的是 Neovim 0.11+ 的新一代 LSP 配置 API——`vim.lsp.config()` + `vim.lsp.enable()`。相比传统的 `lspconfig.server.setup()` 方式，这个 API 更简洁、更符合 Neovim 内置设计，也减少了对 nvim-lspconfig 的依赖深度。

#### 通用 LSP 行为

`defaults.on_attach` 是所有 LSP 服务器的通用回调，负责设置统一的键位映射——所有导航操作都走 **Snacks.picker** 的 UI，而非 Neovim 原生的 quickfix 窗口：

```lua
-- 定义与引用（Snacks.picker）
<Leader>gd    -- 跳转到定义
<Leader>gr    -- 查找引用
<Leader>gi    -- 跳转到实现
<Leader>gD    -- 跳转到声明
<Leader>gy    -- 跳转到类型定义

-- 重构与操作
<Leader>rn    -- 重命名
<Leader>ca    -- 代码操作（quick fix / refactor）

-- 诊断（Snacks.picker）
<Leader>es    -- 当前文件诊断列表
<Leader>eS    -- 全局诊断列表
<Leader>ee    -- 当前行诊断详情浮窗

-- 悬浮文档
<C-k>         -- Hover 文档（大窗口，最大 140x20）
<C-h>         -- 函数签名帮助
```

Snacks.picker 的 LSP 导航自带 `auto_confirm = true`——当搜索词唯一匹配到目标时自动跳转，减少一次按键。所有 picker 都隐藏了预览面板（`hidden = { "preview" }`），让搜索列表占据全部空间，信息密度更高。

![LSP hover 文档浮窗 + 代码大纲侧边栏](/images/neovim/lsp-hover.png "LSP 悬浮文档与代码大纲")

#### 格式化：conform.nvim 统一管理

venux 的格式化系统在 2026.06 从 none-ls 迁移到了 [stevearc/conform.nvim](https://github.com/stevearc/conform.nvim)。conform.nvim 是一个专注于格式化的轻量级插件，相比 none-ls 更加聚焦、维护活跃：

```lua
-- 格式化键位
<Leader>fm    -- 格式化当前文件（或视觉选区）

-- 语言 → 格式化工具
lua   → stylua
go    → gofumpt
bzl   → buildifier
json/css/html/js/ts/vue/yaml/markdown → prettier
sh/bash/zsh → shfmt
sql   → sql_formatter
```

`format_on_save` 采用差异化策略：
- **Go**：保存时先执行 `source.organizeImports` 整理 import，再格式化
- **Lua**：保存时执行 stylua 格式化，失败则回退到 LSP formatting
- **其他语言**：不自动格式化，按需手动触发 `<Leader>fm`（避免 prettier 等工具在不期望的场合介入）

#### Linting：按需集成

配合 conform.nvim，venux 使用 `mfussenegger/nvim-lint` 提供 linting 支持：

```lua
bzl  → buildifier
yaml → actionlint
```

lint 在 `BufWritePost`、`BufReadPost`、`InsertLeave` 时自动触发，保持轻量——只在需要的地方提供 lint 反馈。

#### Java 特殊支持

Java 的 LSP 配置是整个 venux 中最复杂的部分之一。venux 使用 `nvim-java/nvim-java` 作为 Java 开发的入口，底层挂载 jdtls：

- **自动检测 JDK**：通过环境变量 `JAVA_25_HOME` 配置 JDK 路径
- **Spring Boot 智能检测**：向上遍历目录树查找 `pom.xml` 或 `build.gradle`，扫描其中是否包含 `spring-boot` 依赖，有则自动启用 Spring Boot Tools
- **自定义 UI**：将 nvim-java 的 `multi_select` 替换为 `venux.ui.multi_select`，提供更美观、键盘友好的浮动选择界面（Checkbox 风格）
- **兼容性修补**：自动检测 spring-boot.nvim 的 API 兼容性（`client.request` vs `client:request`），按需 monkey-patch

这种级别的定制正是 venux 所追求的：**每个工具都深度集成，而非简单安装**。

### 补全（blink.cmp）

venux 使用 [blink.cmp](https://github.com/saghen/blink.cmp) 作为补全引擎，这是 2025 年兴起的新一代补全插件，相较于 nvim-cmp 有以下显著优势：

- **Rust 实现的核心**：模糊匹配由 Rust 编写并预编译为动态库，性能远超纯 Lua
- **开箱即用**：不需要像 nvim-cmp 那样配置一长串 source，默认就支持 LSP、路径、buffer、snippet
- **Frecency 算法**：内置使用频率跟踪，高频使用的补全项会自动排在前面
- **更简洁的 UI**：默认的菜单渲染更干净
- **命令行补全**：`cmdline.enabled = true`，在命令行模式下也提供补全支持

```lua
sources = {
  default = { "lsp", "lazydev", "snippets", "buffer", "path" },
}
completion = {
  list = {
    selection = { preselect = true, auto_insert = true },
  },
  menu = {
    draw = {
      columns = { { "kind_icon" }, { "label", "label_description", gap = 1 } },
    },
  },
}
```

补全菜单的渲染采用两列布局：图标列 + 文本列，搭配 nerd font 的彩色图标，视觉效果干净且信息密度高。

键位方面，venux 采用 `enter` preset，`<CR>` 选择补全项，`<C-k>/<C-j>` 在候选项间导航。去掉了 ghost_text（行内预览），保持编辑区的清爽。

![blink.cmp 补全菜单：两列布局 + Nerd Font 图标](/images/neovim/completion.png "blink.cmp 补全")

### 导航与搜索

#### Flash.nvim：新一代快速跳转

venux 使用 [folke/flash.nvim](https://github.com/folke/flash.nvim) 替代了 hop、leap、easymotion 等传统插件。flash.nvim 的最大特点是**无需预先输入前缀键**，直接在目标位置高亮标签：

- `s` → 输入目标位置的**首字符**，flash 会自动在视野内的匹配位置显示标签（2 字符），再输入标签即可精确跳转
- `S` → treesitter 跳转：只跳转到 treesitter 节点（函数、类、if 块等）
- `r`（operator-pending 模式）→ 远程操作：先指定动作（d/c/y），再跳转到目标位置执行。例如 `dr` 两步即可删除到远处的某个单词
- `R` → treesitter 搜索：在 treesitter 节点的范围内搜索

相比传统方案，flash 将"搜索目标 → 确认位置"压缩为一步，特别是 `s` 映射到普通模式的原生 `s` 位置，覆盖了原生的 substitute 功能（用 flashes 替代 `cl` 的体验更好）。

#### Snacks.picker：一切皆可搜索

2026 年 6 月，venux 的核心搜索框架从 Telescope 全面迁移到了 [folke/snacks.nvim](https://github.com/folke/snacks.nvim) 的 picker 模块。Snacks.nvim 由 lazy.nvim 作者 folke 开发，与 lazy.nvim 设计理念一脉相承，且在功能覆盖面上远超单纯的 picker 插件——dashboard、bigfile、quickfile、rename 等模块替代了多个原本独立的插件。

这次迁移带来了几个关键收益：

- **减少依赖**：Telescope 依赖 plenary.nvim；Snacks 零额外运行时依赖
- **更快的启动**：Snacks 代码经过深度优化，picker 启动延迟更低
- **统一的 Git 集成**：Snacks 内置 git_files、git_status、git_log、git_diff、git_branches、git_blame 等完整 Git picker，不再需要 diffview.nvim 等额外插件
- **自由的扩展能力**：通过 `Snacks.picker()` API 可以轻松创建自定义 picker，venux 的 Bazel 和 Tasks 扩展均基于此 API

**核心 picker**：

| 按键 | 功能 | 说明 |
| :--- | :--- | :--- |
| `<Leader>ff` | 查找文件 | Snacks.picker.files |
| `<Leader>rf` | 最近文件 | Snacks.picker.recent |
| `<Leader>ag` | 全局搜索 | Snacks.picker.grep（忽略隐藏文件和 .gitignore） |
| `<Leader>Ag` | 搜索光标下单词 | Snacks.picker.grep_word |
| `<Leader>bb` | 缓冲区列表 | Snacks.picker.buffers（按最近使用排序） |
| `<Leader>sb` | 当前文件行 | Snacks.picker.lines |
| `<Leader>sk` | 搜索键位映射 | Snacks.picker.keymaps |
| `<Leader>ts` | 异步任务 | 自定义扩展 |

**Git picker**（新增）：

| 按键 | 功能 |
| :--- | :--- |
| `<Leader>gf` | Git 文件列表 |
| `<Leader>gs` | Git 状态 |
| `<Leader>gl` | Git 日志 |
| `<Leader>gL` | 当前文件的 Git 日志 |
| `<Leader>gh` | 当前行的 Git 日志 |
| `<Leader>gv` | Git diff（暂存/未暂存 hunks） |
| `<Leader>gb` | 当前行 Git blame |
| `<Leader>gB` | Git 分支列表 |

![Snacks.picker 文件搜索窗口](/images/neovim/picker-files.png "Snacks.picker 文件搜索")

Snacks.picker 的交互细节也做了精心调校：

- **智能布局**：窗口宽度 >= 120 列时使用默认布局（左右分栏 + 预览），窄屏自动切换为垂直布局
- **LSP 自动确认**：定义、引用、实现等 LSP 导航 picker 当结果唯一时自动跳转
- **窗口内快捷键**：`<C-s>/<C-v>/<C-t>` 在水平/垂直/标签页分割中打开文件，`<C-j>/<C-k>` 上下导航
- **文件搜索默认隐藏**：`find_files` 和 `grep` 默认忽略隐藏文件（`.hidden = true`）

**自定义扩展**：

venux 在 `lua/snacks/` 下维护了两个自定义 Snacks.picker 扩展，它们从原来的 Telescope 扩展迁移而来：

1. **bazel.lua**：与 Google 的 Bazel 构建系统集成
   - `BazelBuild`（`<Leader>bs`）：列出所有构建目标，选择后执行 bazel build
   - `BazelRun`（`<Leader>br`）：列出可执行目标（`*_binary`），选择后执行 bazel run
   - `BazelTests`（`<Leader>bt`）：列出测试目标（`*_test`），选择后执行 bazel test

   使用 `bazel query` 解析当前 Bazel 工作区的目标列表，选中后在 toggleterm 中执行。

2. **tasks.lua**：与 asynctasks.vim 集成，通过 `Snacks.picker()` API 展示任务列表，提供 Telescope 风格的任务选择体验

#### Grug-far：搜索与替换

日常的搜索替换使用 [grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim)，它的特点是：

- 自动预填当前文件的扩展名作为文件过滤条件
- transient 模式：执行替换后窗口自动关闭
- 所见即所得的替换预览

`<Leader>sr` 打开搜索替换窗口，如果有视觉选区则自动填充搜索词。

#### 文件管理：mini.files

venux 使用 `mini.files` 作为文件管理器（不再混用 oil.nvim，统一为 mini.files 单一方案）：

- `-` 在普通模式下打开父目录
- `<Leader>ft` 打开/关闭当前文件所在目录
- `<Leader>fT` 打开/关闭 cwd

mini.files 的独特之处在于它不是一个"sidebar"，而是一个导航器——移动、复制、删除文件后执行 `:w` 才会写入文件系统。支持：

- `h` / `l` 进入父目录 / 子目录
- `<C-s>` / `<C-v>` 在新水平/垂直分割窗口中打开文件
- `q` 关闭导航器
- 所有文件操作在 `:w` 时批量提交
- 重命名文件时自动触发 `Snacks.rename` 同步更新引用

#### 代码大纲

`<Leader>tl` 打开 `outline.nvim` 的侧边栏，显示当前文件的符号树（基于 LSP 的 document symbols）。支持按深度自动折叠（`autofold_depth = 5`），使用 mini.icons 提供统一的 Nerd Font 图标风格。对于大型文件的导航非常有帮助。

### 调试

venux 中 DAP（Debug Adapter Protocol）模块已经精简为 nvim-java 的依赖项。由于日常调试工作不再在 Neovim 中进行，所有 DAP 的键位映射和 UI 组件（如 nvim-dap-virtual-text）已被移除，仅保留 `nvim-dap` 和 `nvim-nio` 的基础安装以满足 nvim-java 的插件依赖。

如果你需要完整的 DAP 调试功能，可以参考 nvim-dap 的官方文档自行添加配置。

### Git 集成

Git 是日常开发中最高频的操作之一，venux 提供了多级 Git 集成：

**gitsigns**（行内标记）：在 signcolumn 显示每个修改行的 git 状态：

```lua
signs = {
  add    = { text = "▌", show_count = true },
  change = { text = "▌", show_count = true },
  delete = { text = "▐", show_count = true },
}
```

使用半宽块状符号而不是整行高亮，更克制、更融入编辑器风格。支持计数（`show_count = true`），多处修改的行会显示 `▌₂` 这样的标记。`diff_opts` 内置了 `patience` 算法、缩进启发式和 `linematch = 60` 的智能行匹配。

操作键位：
- `<Leader>hs`：暂存光标下的 hunk
- `<Leader>hr`：重置光标下的 hunk
- `]h` / `[h`：在 hunks 之间跳转

**Snacks.picker Git 集成**（主力）：完整的 Git 浏览体验现在由 Snacks.picker 提供。`<Leader>gl` 查看 Git 历史，`<Leader>gL` 查看当前文件的提交历史，`<Leader>gv` 以 hunks 形式浏览暂存/未暂存的 diff，`<Leader>gB` 切换分支。Snacks 的 Git picker 相比之前使用的 diffview.nvim，启动更快、UI 更一致。

**lualine 状态栏**：在状态栏显示当前分支名（`` 图标）和变更统计（diff 段显示增删行数），让你随时了解仓库状态。

### 主题与界面

#### Everforest

venux 在 2026.06 将默认主题从 gruvbox-material 切换为 [sainnhe/everforest](https://github.com/sainnhe/everforest)，选择的是 `hard` 变体的暗色模式：

```lua
vim.g.everforest_background = "hard"
vim.g.everforest_better_performance = 1
vim.g.everforest_enable_italic = 0
vim.g.everforest_disable_italic_comment = 1
```

Everforest 的色调偏绿，相比 gruvbox 的红黄暖色调，对长时间编码更友好——眼睛不容易疲劳。`better_performance = 1` 启用了主题的性能优化模式。

venux 保留了 gruvbox-material 的完整配置（懒加载），想切换主题只需要执行 `:Gruvbox`，切回来用 `:Everforest`。

#### Dashboard（启动页）

启动 Neovim 无参数时，Snacks.nvim 的 dashboard 模块会展示一个定制的启动页：

```
 ███▄    █ ▓█████  ▒█████   ██▒   █▓ ██▓ ███▄ ▄███▓
 ██ ▀█   █ ▓█   ▀ ▒██▒  ██▒▓██░   █▒▓██▒▓██▒▀█▀ ██▒
▓██  ▀█ ██▒▒███   ▒██░  ██▒ ▓██  █▒░▒██▒▓██    ▓██░
▓██▒  ▐▌██▒▒▓█  ▄ ▒██   ██░  ▒██ █░░░██░▒██    ▒██
▒██░   ▓██░░▒████▒░ ████▓▒░   ▒▀█░  ░██░▒██▒   ░██▒
░ ▒░   ▒ ▒ ░░ ▒░ ░░ ▒░▒░▒░    ░ ▐░  ░▓  ░ ▒░   ░  ░
░ ░░   ░ ▒░ ░ ░  ░  ░ ▒ ▒░    ░ ░░   ▒ ░░  ░      ░
   ░   ░ ░    ░   ░ ░ ░ ▒       ░░   ▒ ░░      ░
         ░    ░  ░    ░ ░        ░   ░         ░
                                ░
```

底部显示快捷按钮和启动时间统计：

```
  f → 查找文件
  b → 缓冲区列表
  r → 最近文件
  g → 全文搜索
  c → 打开配置
  e → 新建文件
  q → 退出
```

dashboard 的位置在窗口上方 20% 处（`row = 0.2`），而非居中，这样的布局给状态栏和快捷键区域留出了更多视觉空间。

![venux Dashboard 启动页](/images/neovim/dashboard.png "venux Dashboard 启动页")

这个启动时间统计是通过 Snacks 内置的 startup 模块实现的，让你对整个配置的性能有直观认识。

#### 状态栏

lualine 配置的亮点在于信息密度和动态展示：

- **A 段（左端）**：Vim 模式指示器（带  图标），支持 venn 绘图模式的特殊图标切换
- **B 段**：Git 分支 + diff 统计 + 诊断计数（带颜色）
- **C 段（中央）**：文件名（相对路径）+ 文件大小 + 代码上下文导航（navic breadcrumb）
- **X 段（右）**：行号:列号 + 百分比 + LSP 客户端列表
- **Y 段**：文件编码
- **Z 段**：文件格式（UNIX/DOS/MAC 带图标）

LSP 客户端列表尤为实用——它实时显示当前文件激活了哪些 LSP Server，并用缩写形式（如 `Go`、`Py`、`Rust`、`Lua`）以 `󰐘` 图标分隔，让你一目了然地知道当前文件的代码智能覆盖情况。

`venux.utils.util` 中维护了一个 `lsp_names` 缩写表，覆盖了 20+ 常用 LSP Server 的友好名称。

#### 其他 UI 细节

- **mini.tabline**：顶部的标签栏，由 mini.nvim 生态提供（替代了 bufferline），轻量且与 mini.icons 无缝集成
- **nvim-navic**：在状态栏显示代码导航路径（如 `Class > Method > line 42`），深度限制 3 层
- **fidget**：显示 LSP 加载进度，右下角浮动窗口展示
- **nvim-highlight-colors**：在 css/html 等文件中内联显示颜色预览
- **mini.cursorword**：高亮当前光标所在单词的所有出现（延迟 100ms，背景色 `#3b3b3b`）

![完整编辑界面：everforest 主题、lualine 状态栏、mini.tabline 标签栏](/images/neovim/editor-overview.png "完整编辑界面")

### 代码生成与工具

#### Snippets

venux 使用 LuaSnip 作为 snippet 引擎，在 `lua/plugins/snips/` 下维护了自定义 snippet：

- `all.lua`：所有语言通用 snippet
- `cpp.lua`：C++ 专属 snippet（包含常用的 class 定义、循环模板等）

#### Neogen

[neogen](https://github.com/danymat/neogen) 用于快速生成注释（函数文档、类文档等），支持多种语言的注释规范：

- Lua：生成 `---@param` / `---@return` 风格的 EmmyLua 注释
- C/C++：生成 Doxygen 风格注释
- Go/Python/Rust 等：生成对应语言的标准文档注释

#### 自定义命令

venux 注册了一系列便利命令：

| 命令 | 功能 |
| :--- | :--- |
| `:Filepath` | 以通知形式显示当前文件完整路径 |
| `:YankFilename` | 复制当前文件名到系统剪贴板 |
| `:YankFilepath` | 复制当前文件完整路径到系统剪贴板 |
| `:CopyRight` | 在文件头部插入 Apache 2.0 版权声明 |
| `:AddFileHeader` | 根据文件类型插入对应的文件头注释 |
| `:TrimWhiteSpace` | 清除文件中的行尾空白（保存时自动执行） |
| `:DocUpdate` | 更新文档 |
| `:Tasks` | 打开 asynctasks 任务列表（Snacks.picker 界面） |
| `:BazelBuild / :BazelRun / :BazelTests` | Bazel 构建相关命令 |

#### 其他实用插件

- **mini.comment**：`gc` 注释/取消注释，`gcc` 注释当前行
- **mini.surround**：`gsa` 添加包围符，`gsd` 删除包围符，`gsr` 替换包围符
- **mini.align**：`ga` 启动对齐模式，`gA` 启动对齐预览模式
- **vim-caser**：快速大小写转换
- **accelerated-jk**：`j`/`k` 长按时光标移动加速（自实现，不再依赖外部插件）
- **yank 高亮**：yank 时高亮被复制的区域（使用内置 `vim.highlight.on_yank`，不再依赖 smartyank 插件）
- **autoclose**：自动闭合括号、引号
- **vim-matchup**：增强的 `%` 匹配跳转

### 特殊语言支持

#### TLA+ 形式化验证

venux 集成了 [tla-nvim](https://github.com/liubang/tla-nvim)，这是一个作者自己开发的 TLA+ 语言支持插件：

- 语法高亮和自定义 filetype 检测
- 自定义 syntax 文件（`after/syntax/tla.lua`）
- 自定义 ftplugin（`after/ftplugin/tla.lua`）

这体现了 venux 的另一个设计理念：**对于小众语言，自己动手写支持比等待社区插件更可靠**。

#### LaTeX

使用 [VimTeX](https://github.com/lervag/vimtex) + texlab LSP，提供：

- 编译与 PDF 预览（支持 Skim.app on macOS）
- 双向搜索（代码 ↔ PDF）
- 命令和环境的自动补全

#### Markdown

- **peek.nvim**：`<Leader>mp` 在浏览器/webview 中实时预览 Markdown 文件，使用 Deno 作为运行环境
- 自动格式化：prettier 通过 conform.nvim 提供格式化

## 跨平台与 GUI 支持

venux 在设计时就考虑了跨平台：

```lua
-- util.lua 中的平台检测
M.is_win  = uname.sysname == "Windows_NT"
M.is_mac  = uname.sysname == "Darwin"
M.is_linux = uname.sysname == "Linux"
M.is_x86  = uname.machine == "x86_64"
M.is_arm  = uname.machine == "arm64" or uname.machine == "aarch64"
```

字体配置区分 macOS 和 Linux：

```lua
if u.is_linux then
  vim.o.guifont = "Operator Mono Lig,Hack Nerd Font:h15:h15"
else
  vim.o.guifont = "Operator Mono Lig,Hack Nerd Font:h18:h18"
end
```

[Neovide](https://neovide.dev/) 是目前最流行的 Neovim GUI 客户端，venux 对其做了专门的视觉调优：

```lua
vim.g.neovide_refresh_rate = 60
vim.g.neovide_cursor_vfx_mode = "railgun"     -- 光标拖尾特效
vim.g.neovide_cursor_animation_length = 0.03   -- 光标动画时长
vim.g.neovide_cursor_trail_length = 0.05       -- 拖尾长度
vim.g.neovide_cursor_antialiasing = true       -- 光标抗锯齿
```

## 安装与使用

### 依赖

- Neovim >= 0.11
- Git
- ripgrep（用于 Snacks.picker 的 grep）
- tree-sitter CLI（用于 treesitter parser 安装）
- C 编译器（用于编译部分插件的 native 模块）
- Nerd Font（图标显示）

### 安装步骤

```bash
# 1. 备份旧配置
mv ~/.config/nvim ~/.config/nvim.bak
mv ~/.local/share/nvim ~/.local/share/nvim.bak
mv ~/.local/state/nvim ~/.local/state/nvim.bak

# 2. 克隆配置
git clone https://github.com/liubang/nvim.git ~/.config/nvim

# 3. 启动 Neovim
nvim
```

首次启动时，lazy.nvim 会自动安装自身，然后根据 `plugins/` 下的声明自动安装所有插件。之后需要：

```vim
:Mason                    " 安装 LSP servers 和 formatters
:TSManager                " 安装 treesitter parsers (交互式 TUI)
:checkhealth              " 检查整体健康状态
```

### 后续自定义

venux 推荐通过以下方式进行个性化：

1. **修改主题**：默认使用 everforest，执行 `:Gruvbox` 可切换到 gruvbox-material，或编辑 `colorscheme.lua` 修改默认主题
2. **调整 LSP**：编辑 `lua/plugins/lsp/servers/init.lua`，增删需要的服务器
3. **添加语言支持**：在 `lua/plugins/lsp/servers/` 下新建对应文件
4. **修改键位**：在 `lua/venux/mappings.lua` 中调整全局键位
5. **本地插件**：将插件放在 `~/workspace/liubang/` 下，lazy.nvim 会自动识别
6. **自定义 picker**：参考 `lua/snacks/` 下的扩展示例，使用 `Snacks.picker()` API 创建自定义搜索

## 总结

venux 不是一个大而全的"发行版"（如 LazyVim、NvChad、LunarVim），而是一套**个人深度定制的配置框架**。发行版追求开箱即用和用户覆盖量，必然要在通用性上做妥协；venux 则追求**极致适配个人工作流**——每个键位、每个选项、每个插件的选择都有明确的理由。

这套配置的核心价值在于：

1. **性能优先**：禁用不必要插件、精细的懒加载策略、Rust 加速的补全引擎、Snacks 预编译模块
2. **深度的 LSP 集成**：20+ 个语言服务器配置，每个都经过调校
3. **统一流畅的搜索体验**：Snacks.picker 覆盖文件搜索、LSP 导航、Git 浏览、构建任务等所有选择场景
4. **自定义构建集成**：Snacks + Bazel 扩展，将构建系统融入编辑器
5. **内外一致的视觉体验**：Everforest 主题贯穿从编辑器到 picker 到状态栏的所有元素
6. **自建 UI 组件库**：confirm、inputbox、multi_select 等可复用的 UI 模块
7. **跨平台**：macOS / Linux 无缝切换，Neovide GUI 支持

配置会持续演进。如果你也对终端 IDE 感兴趣，欢迎 [Star & Fork](https://github.com/liubang/nvim)，一起交流讨论。

---

**相关链接**：

- venux 配置仓库：<https://github.com/liubang/nvim>
- lazy.nvim：<https://github.com/folke/lazy.nvim>
- Snacks.nvim：<https://github.com/folke/snacks.nvim>
- blink.cmp：<https://github.com/saghen/blink.cmp>
- conform.nvim：<https://github.com/stevearc/conform.nvim>
- Neovim 官方文档：<https://neovim.io/>
