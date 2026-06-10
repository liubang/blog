---
title: "打造高效终端 IDE：我的 Neovim 完全配置指南"
description: "从架构设计、插件选型、LSP 生态到调试与工作流，全面介绍一套面向多语言开发的 Neovim 现代化配置——venux。"
date: 2026-06-10
categories: [工具与杂谈]
tags: [neovim, vim, ide, lsp, dap, lazy.nvim, tools]
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

> 2011 次提交，八年持续打磨。一套好的编辑器配置，不是插件堆砌，而是对工作流的深度理解。

如今 Neovim 0.10+ 的 Lua 生态已经足够成熟，venux 在保持 100+ 插件规模的同时，启动时间稳定在 **100ms 以内**。

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
    │   │   ├── format.lua      # 格式化逻辑
    │   │   ├── save_actions.lua # 保存时的自动操作
    │   │   ├── config.lua      # LSP 配置聚合
    │   │   └── servers/        # 各语言 LSP 配置
    │   ├── dap/                # DAP 调试子系统
    │   ├── java/               # Java 专属配置
    │   └── snips/              # 代码片段
    └── telescope/
        └── _extensions/        # 自定义 Telescope 扩展
            ├── bazel.lua       # Bazel 构建集成
            └── tasks.lua       # 异步任务集成
```

这个结构的核心原则是：**关注点分离**。每一层、每一个文件只负责一件事：

- `venux/` 层负责编辑器原生行为（options、autocmd、mappings），不涉及插件
- `plugins/` 层负责插件声明与配置，每个插件独立文件
- `after/` 层利用 Neovim 的 runtimepath 机制，按需覆盖

### 插件管理体系

venux 使用 [folke/lazy.nvim](https://github.com/folke/lazy.nvim) 作为插件管理器。lazy.nvim 的核心优势在于其精细的懒加载控制：

```lua
require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
  defaults = { lazy = true },     -- 全局默认懒加载
  concurrency = 6,                 -- 并发安装
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

这些优化使得 venux 在加载 100+ 插件的情况下，启动时间仍然控制在 100ms 以内（dashboard 会显示精确的插件加载数量和时间）。

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

-- 代码跳转 <Leader>g (LSP)
<Leader>gd           -- 跳转到定义
<Leader>gr           -- 查找引用
<Leader>gi           -- 跳转到实现
<Leader>rn           -- 重命名
<Leader>ca           -- 代码操作
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

对于大数据文件的性能问题，venux 在 `util.bigfile()` 中做了专门处理：超过 400KB 的文件或超过 10240 行的 C/C++ 文件会自动关闭 treesitter 高亮等重功能。

#### 终端集成

venux 使用 `akinsho/toggleterm.nvim` 提供内置终端：

- `<C-t>` 打开浮动终端（覆盖整个窗口宽度，高度 70%，停靠在底部）
- `<Leader>th` 打开水平分割终端
- `<Leader>tf` 打开浮动终端
- `<Leader>tt` 在多个终端实例间切换

浮动终端的设计尤其用心——它不是居中的小窗口，而是从屏幕底部弹起的大面积面板，顶部有 `Floaterm` 标题栏。这种布局兼顾了代码浏览和命令执行。

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
│ - on_attach (keymaps, format setup)   │
│ - capabilities (blink.cmp 集成)       │
│ - extend() / enable()                 │
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

目前已配置的 LSP 服务器多达 20+：

| 语言/文件类型 | LSP Server | 特殊配置 |
| :--- | :--- | :--- |
| C/C++ | clangd | `--background-index`、`--header-insertion=never` |
| Go | gopls | semantic tokens 启用、organize imports 自动 |
| Python | basedpyright | typeCheckingMode = "standard" |
| Lua | lua_ls | 集成 lazydev 类型注解 |
| Rust | rust-analyzer | 自动格式化 |
| Java | jdtls | Spring Boot 支持、自定义 UI |
| JSON/YAML | jsonls / yamlls | schemastore 集成 |
| LaTeX | texlab | 双向搜索 |
| XML | lemminx | |
| Docker | dockerls | |
| Bash | bashls | |
| TOML | taplo | |
| PHP | intelephense | |

#### 通用 LSP 行为

`defaults.on_attach` 是所有 LSP 服务器的通用回调，负责设置统一的键位映射：

```lua
-- 定义与引用
<Leader>gd    -- 跳转到定义
<Leader>gr    -- 查找引用
<Leader>gi    -- 跳转到实现
<Leader>gD    -- 跳转到声明

-- 重构与操作
<Leader>rn    -- 重命名
<Leader>ca    -- 代码操作（quick fix / refactor）

-- 诊断
<Leader>es    -- 当前文件诊断列表（Telescope）
<Leader>ee    -- 当前行诊断详情浮窗

-- 悬浮文档
<C-k>         -- Hover 文档（大窗口）
<C-h>         -- 函数签名帮助
```

所有导航操作（gd、gr、gi）都使用 Telescope 的 UI，而非 Neovim 原生的 quickfix 窗口。这带来了更好的预览体验和模糊筛选能力。

#### 格式化：智能多源策略

venux 的格式化系统（`lsp.format.lua`）采用了一套智能调度策略：

1. **优先使用 none-ls 提供的 formatter**：none-ls（null-ls 的维护者 fork）用于挂载那些不是 LSP 的外部格式化工具
2. **fallback 到 LSP 的 formatting 能力**：如果 none-ls 没有对应的 formatter，就使用 LSP server 自带的
3. **避免双重格式化**：通过 filter 函数确保同一时间只有一个源在工作

```lua
-- 格式化键位
<Leader>fm    -- 格式化当前文件（或视觉选区）

-- 自动格式化（保存时触发）
-- 目前对 Rust 和 Lua 启用
```

`save_actions.lua` 提供了保存文件时的自动操作。例如对于 Go 文件，保存时会：
1. 执行 `source.organizeImports`（自动整理 import）
2. 调用格式化

这比 gopls 自带的 organize imports 更可靠，因为它是在本地缓冲区修改完成后统一调用。

#### Java 特殊支持

Java 的 LSP 配置是整个 venux 中最复杂的部分之一。venux 使用 `nvim-java/nvim-java` 作为 Java 开发的入口，底层挂载 jdtls：

- **自动检测 JDK**：通过环境变量 `JAVA_25_HOME` 配置 JDK 路径
- **Spring Boot 智能检测**：向上遍历目录树查找 `pom.xml` 或 `build.gradle`，扫描其中是否包含 `spring-boot` 依赖，有则自动启用 Spring Boot Tools
- **自定义 UI**：将 nvim-java 的 `multi_select` 替换为 `venux.ui.multi_select`，提供更美观、键盘友好的浮动选择界面（Checkbox 风格）
- **兼容性修补**：自动检测 spring-boot.nvim 的 API 兼容性（`client.request` vs `client:request`），按需 monkey-patch

这种级别的定制体现了 venux 的核心哲学：**不是安装插件就完事，而是让每个工具真正融入工作流**。

### 补全（blink.cmp）

venux 使用 [blink.cmp](https://github.com/saghen/blink.cmp) 作为补全引擎，这是 2025 年兴起的新一代补全插件，相较于 nvim-cmp 有以下显著优势：

- **Rust 实现的核心**：模糊匹配由 Rust 编写并预编译为动态库，性能远超纯 Lua
- **开箱即用**：不需要像 nvim-cmp 那样配置一长串 source，默认就支持 LSP、路径、buffer、snippet
- **Frecency 算法**：内置使用频率跟踪，高频使用的补全项会自动排在前面
- **更简洁的 UI**：默认的菜单渲染更干净

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

键位方面，venux 采用 `enter` preset，`<CR>` 选择补全项，`<C-k>/<C-j>` 在候选项间导航。

### 导航与搜索

#### Flash.nvim：新一代快速跳转

venux 使用 [folke/flash.nvim](https://github.com/folke/flash.nvim) 替代了 hop、leap、easymotion 等传统插件。flash.nvim 的最大特点是**无需预先输入前缀键**，直接在目标位置高亮标签：

- `s` → 输入目标位置的**首字符**，flash 会自动在视野内的匹配位置显示标签（2 字符），再输入标签即可精确跳转
- `S` → treesitter 跳转：只跳转到 treesitter 节点（函数、类、if 块等）
- `r`（operator-pending 模式）→ 远程操作：在一个位置执行动作，在另一个位置执行操作
- `R` → treesitter 搜索：在 treesitter 节点的范围内搜索

相比传统方案，flash 将"搜索目标 → 确认位置"压缩为一步，特别是 `s` 映射到普通模式的原生 `s` 位置，取代了那个几乎没人用的原生功能。

#### Telescope：一切皆可搜索

Telescope 是 Neovim 生态中最强大的模糊搜索框架。venux 对其做了深度定制：

**自定义样式**：Telescope 窗口的背景色、边框、选中项都使用 Gruvbox Material 配色精心调整过，与整体主题融为一体。

**核心 picker**：

| 按键 | 功能 | 说明 |
| :--- | :--- | :--- |
| `<Leader>ff` | 查找文件 | Telescope find_files |
| `<Leader>rf` | 最近文件 | oldfiles |
| `<Leader>ag` | 全局搜索 | live_grep_args（支持 `--iglob` 过滤） |
| `<Leader>Ag` | 搜索光标下单词 | grep_string |
| `<Leader>bb` | 缓冲区列表 | buffers |
| `<Leader>ts` | 异步任务 | asynctasks |

**自定义扩展**：

venux 包含两个自研的 Telescope 扩展，在 `lua/telescope/_extensions/` 下：

1. **bazel.lua**：与 Google 的 Bazel 构建系统集成
   - `BazelBuild`（`<Leader>bs`）：列出 BUILD 文件中的构建目标，选择后执行 bazel build
   - `BazelRun`（`<Leader>br`）：列出可执行目标，选择后执行 bazel run
   - `BazelTests`（`<Leader>bt`）：列出测试目标，选择后执行 bazel test

   这些命令会解析当前目录的 BUILD 文件，提取 `name` 属性生成候选列表，选中后自动在 toggleterm 中执行。

2. **tasks.lua**：与 asynctasks.vim 集成，提供任务列表的 Telescope UI

此外还集成了社区扩展：
- `telescope-fzf-native.nvim`：使用 fzf 的 C 扩展做排序，更快
- `telescope-ui-select.nvim`：覆盖 `vim.ui.select`，让所有选择行为使用 Telescope 界面
- `telescope-live-grep-args.nvim`：支持在 grep 时追加 `--iglob` 和 `-t` 参数
- `telescope-undo.nvim`：撤销历史以 Telescope 界面展示

#### Grug-far：搜索与替换

日常的搜索替换使用 [grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim)，它的特点是：

- 自动预填当前文件的扩展名作为文件过滤条件
- transient 模式：执行替换后窗口自动关闭
- 所见即所得的替换预览

`<Leader>sr` 打开搜索替换窗口，如果有视觉选区则自动填充搜索词。

#### 文件管理：双轨制

venux 提供两套文件浏览方案：

**mini.files**（主力）：`<Leader>ft` 打开当前文件所在目录，`<Leader>fT` 打开 cwd。mini.files 的独特之处在于它不是一个"sidebar"，而是一个导航器——移动、复制、删除文件后执行 `:w` 才会写入文件系统。支持：

- `h` / `l` 进入父目录 / 子目录
- `<C-s>` / `<C-v>` 在新水平/垂直分割窗口中打开文件
- `q` 关闭导航器
- 所有文件操作在 `:w` 时批量提交

**oil.nvim**（辅助）：`-` 在普通模式下打开父目录的浮动窗口，`<Leader>-` 强制以浮动模式打开。oil.nvim 以"像编辑普通 buffer 一样编辑文件系统"著称，适合快速对文件重命名、创建目录等操作。

#### 代码大纲

`<Leader>tl` 打开 `outline.nvim` 的侧边栏，显示当前文件的符号树（基于 LSP 的 document symbols）。支持按深度自动折叠（`autofold_depth = 5`），对于大型文件的导航非常有帮助。

### 调试

venux 集成了 [nvim-dap](https://github.com/mfussenegger/nvim-dap) 作为调试框架，搭配 `nvim-dap-virtual-text` 在代码行尾显示变量值。

所有调试操作的键位以 `<Leader>d` 为前缀：

| 按键 | 功能 |
| :--- | :--- |
| `<Leader>db` | 切换断点 |
| `<Leader>dB` | 条件断点 |
| `<Leader>dc` | 继续执行 |
| `<Leader>da` | 带参数运行 |
| `<Leader>dl` | 重复上一次运行 |
| `<Leader>di` | Step Into |
| `<Leader>do` | Step Out |
| `<Leader>dO` | Step Over |
| `<Leader>dC` | 运行到光标处 |
| `<Leader>dt` | 终止调试 |
| `<Leader>dj/k` | 调用栈向下/上 |
| `<Leader>dr` | 打开 REPL |
| `<Leader>dw` | 查看当前变量（hover） |

断点符号使用了 nerd font 的图标：`` 断点、`` 条件断点、`` 停止点、`` 被拒绝的断点，视觉效果直观。

### Git 集成

Git 是日常开发中最高频的操作之一，venux 提供了三级 Git 集成：

**gitsigns**（行内标记）：在 signcolumn 显示每个修改行的 git 状态：

```lua
signs = {
  add    = { text = "▌", show_count = true },
  change = { text = "▌", show_count = true },
  delete = { text = "▐", show_count = true },
}
```

使用半宽块状符号而不是整行高亮，更克制、更融入编辑器风格。支持计数（`show_count = true`），多处修改的行会显示 `▌₂` 这样的标记。

操作键位：
- `<Leader>hs`：暂存光标下的 hunk
- `<Leader>hr`：重置光标下的 hunk
- `<Leader>hb`：显示当前行的 blame 信息（浮动窗口）
- `<Leader>hd`：对当前文件执行 vimdiff

**diffview.nvim**：提供完整的 diff 浏览体验。`DiffviewFileHistory %` 查看当前文件的 Git 历史，可以选中任意两个 commit 进行对比。venux 对 diffview 的默认键位做了大量裁剪，只保留最常用的操作，并用 `?` 打开帮助面板（替代默认的 `g?`）。

**lualine 状态栏**：在状态栏显示当前分支名（`` 图标）和变更统计（diff 段显示增删行数），让你随时了解仓库状态。

### 主题与界面

#### Gruvbox Material

venux 默认使用 [gruvbox-material](https://github.com/sainnhe/gruvbox-material)，选择的是 `hard` 变体的暗色模式：

```lua
vim.g.gruvbox_material_background = "hard"
vim.g.gruvbox_material_foreground = "material"
vim.g.gruvbox_material_better_performance = 1
```

Gruvbox Material 相比原版 gruvbox，颜色对比度更高，更适合长时间编码。`better_performance = 1` 启用了该主题的性能优化模式。

venux 也保留了 [Catppuccin](https://github.com/catppuccin/nvim) 的完整配置（`enabled = false`），包含自定义的色彩覆盖和所有集成的 hl_group 调整。想切换主题只需要将两个主题的 `enabled` 状态互换即可。

#### Dashboard（启动页）

启动 Neovim 无参数时，alpha-nvim 会展示一个定制的 dashboard：

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
Space ff → 查找文件
Space bb → 缓冲区列表
Space rf → 最近文件
Space ag → 全文搜索
c        → 打开配置
e        → 新建文件
q        → 退出

󰏗 Neovim loaded X plugins in XXms
```

这个启动时间统计是通过 hook `LazyVimStarted` 事件实现的，精确到百分位毫秒，让你对整个配置的性能有直观认识。

#### 状态栏

lualine 配置的亮点在于信息密度和动态展示：

- **A 段（左端）**：Vim 模式指示器（带  图标），支持 venn 绘图模式的特殊图标切换
- **B 段**：Git 分支 + diff 统计 + 诊断计数（带颜色）
- **C 段（中央）**：文件名（相对路径）+ 文件大小 + 代码上下文导航（navic breadcrumb）
- **X 段（右）**：行号:列号 + 百分比 + LSP 客户端列表
- **Y 段**：文件编码
- **Z 段**：文件格式（UNIX/DOS/MAC 带图标）

LSP 客户端列表尤为实用——它实时显示当前文件激活了哪些 LSP Server，并用缩写形式（如 `Go`、`Py`、`Rust`、`Lua`）以 `󰐘` 图标分隔，让你一目了然地知道当前文件的代码智能覆盖情况。

`venux.utils.util` 中维护了一个 `lsp_names` 缩写表，覆盖了 20+ 常用 LSP Server 的友好名称。

#### 其他 UI 细节

- **bufferline**：顶部标签栏，支持 `<Leader>1-9` 快速切换可见标签，`<Leader>bo` 关闭其他标签
- **nvim-navic**：在状态栏显示代码导航路径（如 `Class > Method > line 42`）
- **fidget**：显示 LSP 加载进度
- **indent-blankline**：缩进辅助线（颜色与主题融为一体）
- **highlight-colors**：在 css/html 等文件中内联显示颜色预览

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

#### 其他实用插件

- **mini.comment**：`gc` 注释/取消注释，`gcc` 注释当前行
- **mini.surround**：`gsa` 添加包围符，`gsd` 删除包围符，`gsr` 替换包围符
- **mini.align**：`ga` 启动对齐模式，`gA` 启动对齐预览模式
- **mini.cursorword**：高亮当前光标所在单词的所有出现（延迟 100ms，背景色 `#3b3b3b`）
- **vim-caser**：快速大小写转换
- **accelerated-jk**：`j`/`k` 长按时光标移动加速
- **smartyank**：yank 时高亮被复制的区域
- **autoclose**：自动闭合括号、引号

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
- 自动格式化：prettier 通过 none-ls 提供格式化

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

[Neovide](https://neovide.dev/) 是目前最好的 Neovim GUI 客户端，venux 对其做了专门的视觉调优：

```lua
vim.g.neovide_refresh_rate = 60
vim.g.neovide_cursor_vfx_mode = "railgun"     -- 光标拖尾特效
vim.g.neovide_cursor_animation_length = 0.03   -- 光标动画时长
vim.g.neovide_cursor_trail_length = 0.05       -- 拖尾长度
vim.g.neovide_cursor_antialiasing = true       -- 光标抗锯齿
```

## 安装与使用

### 依赖

- Neovim >= 0.10
- Git
- ripgrep（用于 Telescope 的 live_grep）
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

1. **修改主题**：将 `colorscheme.lua` 中 catppuccin 的 `enabled` 改为 `true`，gruvbox-material 改为 `false`
2. **调整 LSP**：编辑 `lua/plugins/lsp/servers/init.lua`，增删需要的服务器
3. **添加语言支持**：在 `lua/plugins/lsp/servers/` 下新建对应文件
4. **修改键位**：在 `lua/venux/mappings.lua` 中调整全局键位
5. **本地插件**：将插件放在 `~/workspace/liubang/` 下，lazy.nvim 会自动识别

## 总结

venux 不是一个大而全的"发行版"（如 LazyVim、NvChad、LunarVim），而是一套**个人深度定制的配置框架**。发行版追求开箱即用和用户覆盖量，必然要在通用性上做妥协；venux 则追求**极致适配个人工作流**——每个键位、每个选项、每个插件的选择都有明确的理由。

这套配置的核心价值在于：

1. **性能优先**：禁用不必要插件、精细的懒加载策略、Rust 加速的补全引擎
2. **深度的 LSP 集成**：20+ 语言服务器配置，每个都经过调校
3. **完整的调试工作流**：DAP 按键体系覆盖所有调试操作
4. **自定义构建集成**：Telescope + Bazel 扩展，将构建系统融入编辑器
5. **内外一致的视觉体验**：从主题到 Telescope 到状态栏，配色统一
6. **自建 UI 组件库**：confirm、inputbox、multi_select 等可复用的 UI 模块
7. **跨平台**：macOS / Linux 无缝切换，Neovide GUI 支持

配置会持续演进。如果你也对终端 IDE 感兴趣，欢迎 [Star & Fork](https://github.com/liubang/nvim)，一起交流讨论。

---

**相关链接**：

- venux 配置仓库：<https://github.com/liubang/nvim>
- lazy.nvim：<https://github.com/folke/lazy.nvim>
- blink.cmp：<https://github.com/saghen/blink.cmp>
- Neovim 官方文档：<https://neovim.io/>
