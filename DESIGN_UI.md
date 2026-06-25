# AI Terminal 完整 UI/UX 设计方案 v2.0

> 版本：v2.0（细化版）
> 日期：2026-06-25
> 范围：LOGO 设计、设计系统、页面重构、组件状态、交互动效、实现指引

---

## 1. 设计思路总览

### 1.1 我们面对什么问题

当前 AI Terminal 的功能已经完整，但视觉上存在三个核心矛盾：

1. **"黑方块"问题**：终端区域是 `#000000`，而 UI 是 `#111118`，两块深色区域之间缺乏过渡，看起来像两个应用硬拼在一起。
2. **"临时感"问题**：AI 面板的橙色分隔线、命令块的红黄绿"窗口按钮"、拥挤的输入区，都给人"功能先上了再优化"的临时感。
3. **"无品牌"问题**：标题栏直接显示 `ai_terminal`，LOGO 复杂且带生成水印，用户难以建立品牌记忆。

### 1.2 设计策略

围绕三个关键词：**一体感、专业性、智能感**。

| 策略 | 具体做法 | 预期效果 |
|------|----------|----------|
| **统一背景色域** | 终端背景从纯黑改为深蓝灰 `#0D0D12`，与 UI 背景 `#0A0A0F` 处于同一色系 | 消除视觉断层，应用像整体 |
| **用边框代替分隔线** | AI 面板与终端之间取消橙色线，改用 1px 细边框 | 更克制、更现代 |
| **强化品牌锚点** | 新 LOGO + 顶部栏品牌区 + 启动页 + 空状态 | 建立"AI Terminal"的品牌识别 |
| **语义化颜色条** | 命令块用左侧 3px 色条表达安全等级 | 保留 SafetyGuard 语义，但视觉更干净 |
| **简化输入区** | 合并低频按钮到二级菜单，突出 Agent 状态和模型选择 | 降低认知负荷 |

### 1.3 设计原则

1. **一体感**：终端与 UI 共享同一深色背景色系，减少视觉断层。
2. **克制用色**：主色仅用于关键操作与品牌元素，信息展示以中性色为主。
3. **清晰层级**：通过背景色、边框、字重、字号建立明确的信息层级。
4. **开发者气质**：等宽字体仅用于代码/终端，界面使用现代无衬线字体。
5. **即时反馈**：所有可交互元素都有 hover/focus/pressed 状态与微动画。
6. **AI 可视化**：AI 思考、执行、完成等状态通过颜色、动效、图标清晰表达。

---

## 2. LOGO 与品牌设计

### 2.1 设计思路

为什么用 `>_` + 闪光点？

- `>` 是终端提示符，全世界开发者一眼可识别。
- `_` 是光标，代表"等待输入、正在交互"。
- 闪光点是 AI 的抽象表达，比具象的"大脑"更现代、更简洁。
- 整体轮廓是一个圆角矩形，像 App 图标本身，天然适合做启动图标。

这个 LOGO 解决了旧 LOGO 的三个问题：
1. **复杂度过高**：旧 LOGO 有大脑纹理、窗口边框、高光阴影，16×16 时完全糊掉。
2. **风格不匹配**：旧 LOGO 是插画风格，不适合开发者工具。
3. **水印问题**：新 LOGO 是纯 SVG 矢量，无水印，可无限缩放。

### 2.2 三种形态

| 形态 | 使用场景 | 文件 |
|------|----------|------|
| Mark | App 图标、启动页、系统托盘、空状态 | [design/logo_mark.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_mark.svg) |
| Wordmark | 官网、README、关于页、品牌展示 | [design/logo_wordmark.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_wordmark.svg) |
| Light Mark | 浅色背景、打印、白底 PPT | [design/logo_mark_light.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_mark_light.svg) |

### 2.3 品牌色应用

- **电光蓝 `#3B7DFF`**：品牌主色，用于主按钮、链接、选中态、终端提示符。
- **莱姆绿 `#6ECC54`**：Agent/成功色，用于 AI 光标、在线状态、safe 命令、执行成功。
- **爱马仕橙 `#EB5C20`**：警告色，用于 warn 命令、待确认操作。
- **中国红 `#C8161D`**：危险色，用于 blocked 命令、错误、删除。

### 2.4 启动页

```
+----------------------------------+
|                                  |
|                                  |
|          [LOGO 64×64]            |
|                                  |
|         AI Terminal              |
|         v1.0.0                   |
|                                  |
|                                  |
+----------------------------------+
```

- 背景：`cBg` #0A0A0F
- LOGO：64×64px，带动画缩放 0.9 → 1.0
- 应用名：fHero / 500 / cTextMain
- 版本号：fMicro / cTextSub
- 显示 1.5 秒后淡入主界面

---

## 3. 设计系统（与现有代码对齐）

### 3.1 颜色系统

当前 `constants.dart` 已有一套命名，本次设计尽量复用现有命名，只调整值和补充新 Token。

#### 背景色板（深色模式）

| Token | 当前值 | 建议值 | 用途 | 调整原因 |
|-------|--------|--------|------|----------|
| `cBg` | `#0A0A0F` | `#0A0A0F` | 页面最底层背景 | 保持，足够深 |
| `cCard` | `#111118` | `#13131B` | 卡片、面板背景 | 略微提亮，增加与 cBg 的区分 |
| `cCardElevated` | `#1A1A24` | `#1A1A24` | 悬浮卡片、弹窗 | 保持 |
| `cSurface` | `#22222E` | `#1F1F2B` | 输入框、按钮背景 | 略微降低明度，更沉稳 |
| `cTerminalBg` | `#000000` | `#0D0D12` | 终端区域背景 | 从纯黑改为深蓝灰，与 UI 融合 |
| `cTerminalOutput` | 无 | `#0A0A0F` | 命令块/结果块背景 | 新增，用于 AI 面板中的命令块 |

#### 中性色板

| Token | 当前值 | 建议值 | 用途 | 调整原因 |
|-------|--------|--------|------|----------|
| `cTextMain` | `#F0F0F5` | `#F0F0F5` | 主要文字、标题 | 保持 |
| `cTextSub` | `#8888A0` | `#9CA3AF` | 次要说明、时间戳 | 提高明度，改善可读性 |
| `cTextMuted` | `#5C5C72` | `#6B7280` | 占位符、禁用态 | 提高明度，满足无障碍对比度 |
| `cBorder` | `#2A2A38` | `#272735` | 默认边框 | 微调，更融入背景 |
| `cBorderHover` | `#363648` | `#3F3F50` | hover 边框 | 微调 |

#### 品牌与语义色（保持不变）

| Token | 色值 | 用途 |
|-------|------|------|
| `cPrimary` | `#3B7DFF` | 主按钮、链接、选中态 |
| `cPrimaryLight` | `#5A9AFF` | 主按钮 hover |
| `cPrimaryDark` | `#2060D0` | 主按钮 pressed |
| `cSuccess` | `#6ECC54` | 在线、成功、safe 命令 |
| `cWarning` | `#EB5C20` | 警告、warn 命令 |
| `cDanger` | `#C8161D` | 错误、blocked 命令、删除 |
| `cInfo` | `#3B7DFF` | 信息提示 |
| `cAgentGreen` | `#6ECC54` | AI Agent 专属色 |
| `cViolet` | `#7C5CFF` | AI 相关元素强调 |

#### 浅色模式映射

| Token | 建议值 | 用途 |
|-------|--------|------|
| `cBgLight` | `#F8F9FC` | 页面背景 |
| `cCardLight` | `#FFFFFF` | 卡片背景 |
| `cCardElevatedLight` | `#F1F5F9` | 悬浮卡片 |
| `cSurfaceLight` | `#EEEEF5` | 输入框背景 |
| `cTextMainLight` | `#111827` | 主要文字 |
| `cTextSubLight` | `#64748B` | 次要文字 |
| `cTextMutedLight` | `#9CA3AF` | 占位符 |
| `cBorderLightTheme` | `#E2E8F0` | 默认边框 |
| `cBorderLightHover` | `#CBD5E1` | hover 边框 |
| `cTerminalBgLight` | `#F0F0F5` | 终端背景 |

### 3.2 字体系统

当前 `constants.dart` 字体层级偏小，建议整体提升一级，让终端和正文更舒展。

| Token | 当前值 | 建议值 | 字重 | 行高 | 用途 |
|-------|--------|--------|------|------|------|
| `fHero` | 无 | 28px | 700 | 1.2 | 启动页应用名 |
| `fDisplay` | 24px | 24px | 600 | 1.3 | 页面大标题 |
| `fTitle` | 18px | 18px | 600 | 1.4 | 卡片标题、分组标题 |
| `fBody` | 14px | 14px | 400 | 1.5 | 正文、列表内容 |
| `fSmall` | 12px | 13px | 400 | 1.5 | 辅助说明、状态标签 |
| `fMicro` | 11px | 12px | 500 | 1.4 | 徽章、时间戳 |
| `fMono` | 14px | 14px | 400 | 1.45 | 命令、代码、终端输出 |

字体栈：
- 界面：`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif`
- 代码：`JetBrainsMono, "SF Mono", Menlo, Monaco, "Courier New", monospace`

### 3.3 间距与圆角

复用现有 `constants.dart` 的命名，统一应用：

| Token | 值 | 用途 |
|-------|-----|------|
| `rXSmall` | 4px | 标签、徽章 |
| `rSmall` | 6px | 按钮、输入框 |
| `rMedium` | 10px | 命令块、结果块、消息气泡 |
| `rLarge` | 16px | 卡片、列表项 |
| `rXLarge` | 24px | 页面容器、底部 Sheet |
| `rFull` | 999px | 胶囊、头像 |
| `pStandard` | 16px | 标准内边距 |
| `pCompact` | 12px | 紧凑内边距 |

### 3.4 阴影与边框

深色模式：**不用明显阴影**，主要靠背景色差异 + 1px 边框建立层级。

浅色模式：使用极淡阴影：
```dart
const shadowLightSubtle = BoxShadow(
  color: Color(0x0A000000),
  blurRadius: 8,
  offset: Offset(0, 2),
);
```

聚焦态统一规范：
- 边框：`cPrimary, width: 1.5`
- 外发光：`cPrimary.withOpacity(0.15), blurRadius: 4`

---

## 4. 组件规范

### 4.1 按钮

#### 主按钮 Primary

```
┌─────────────────────────┐
│  执行命令                 │
└─────────────────────────┘
```

- 高度：36px（标准）/ 32px（紧凑）
- 背景：`cPrimary`
- 文字：白色，fBody，500
- 圆角：`rSmall`
- Padding：左右 16px
- Hover：`cPrimaryLight`
- Pressed：`cPrimaryDark`
- 聚焦：外发光 `shadowGlow`
- 禁用：背景 `cPrimary.withOpacity(0.4)`，文字白色 60%

#### 次要按钮 Secondary

- 高度：36px
- 背景：`cSurface`
- 文字：`cTextBody`，fBody
- 边框：1px `cBorder`
- Hover：背景 `cCardElevated`，边框 `cBorderHover`
- Pressed：背景 `cSurface`，亮度降低 5%

#### 幽灵按钮 Ghost

- 背景：透明
- 文字：`cTextSub`
- Hover：背景 `cSurface`
- Pressed：背景 `cSurface`，文字 `cTextBody`

#### 图标按钮 IconButton

- 尺寸：32px × 32px
- 圆角：`rSmall`
- 图标：20px，颜色 `cTextSub`
- Hover：背景 `cSurface`，图标 `cTextBody`
- Pressed：背景 `cCardElevated`

### 4.2 输入框

```
┌──────────────────────────────────────────┐
│ 请输入主机地址...                          │
└──────────────────────────────────────────┘
```

- 高度：44px（标准）/ 36px（紧凑）
- 背景：`cSurface`
- 边框：1px `cBorder`，圆角 `rSmall`
- 文字：`cTextMain`，fBody
- Placeholder：`cTextMuted`
- 聚焦：边框 `cPrimary` 1.5px，外发光
- 错误：边框 `cDanger`
- 前缀/后缀图标：20px，`cTextSub`

### 4.3 卡片

```
+------------------------------------------+
|  卡片标题                                  |
|  辅助说明文字                              |
+------------------------------------------+
```

- 背景：`cCard`
- 边框：1px `cBorder`
- 圆角：`rLarge`
- Padding：`pStandard`（16px）
- Hover：边框 `cBorderHover`
- 选中：边框 `cPrimary`

### 4.4 标签/徽章

| 类型 | 背景 | 文字 | 使用场景 |
|------|------|------|----------|
| Safe | `cSuccess.withOpacity(0.12)` | `cSuccess` | 可安全执行的命令 |
| Warn | `cWarning.withOpacity(0.12)` | `cWarning` | 需要确认的命令 |
| Blocked | `cDanger.withOpacity(0.12)` | `cDanger` | 已拦截的命令 |
| Info | `cInfo.withOpacity(0.12)` | `cInfo` | 普通信息 |
| Agent | `cAgentGreen.withOpacity(0.12)` | `cAgentGreen` | Agent 模式 |

规范：
- 高度：20px
- 圆角：`rFull`
- 字号：fMicro
- 字重：500
- Padding：左右 8px

### 4.5 列表项

- 高度：64px（紧凑）/ 72px（标准）
- 背景：`cCard`
- 圆角：`rLarge`
- Padding：`pStandard`
- 间距：列表项之间 8px
- Hover：背景 `cCardElevated`
- 选中：边框 `cPrimary`
- 头像：40px，圆角 `rFull`

---

## 5. 页面级设计方案

### 5.1 主机列表页

#### 桌面端布局

```
+-------------------------------------------------------------+
|  [LOGO] AI Terminal     搜索主机...                          |
|  ───────────────────────────────────────────────────────   |
|  全部分组 (12)     |  ┌─────────────────────────────────┐  |
|  ├ 生产环境 (4)    │  │ [A] api-prod    ● 在线    [▸][≡]│  |
|  ├ 测试环境 (3)    │  │     root@1.2.3.4:22             │  |
|  ├ 本地 (2)        │  │     最后连接: 2分钟前             │  |
|  ├ 最近连接 (3)    │  └─────────────────────────────────┘  |
|                    │  ┌─────────────────────────────────┐  |
|  [ + 添加服务器 ]  │  │ [D] db-primary  ● 离线    [▸][≡]│  |
|                    │  │     ubuntu@5.6.7.8:22           │  |
|                    │  │     最后连接: 3天前              │  |
|                    │  └─────────────────────────────────┘  |
|                    │                                       |
|                    │        [ + 添加第一台服务器 ]          |
+-------------------------------------------------------------+
```

- 左侧边栏：固定宽度 280px，包含 Logo/搜索/分组树/添加按钮。
- 右侧内容区：主机卡片网格或列表，最大宽度 960px，居中。
- 卡片宽度：桌面端两列，每列最小 320px。

#### 主机卡片

```
┌─────────────────────────────────────────┐
│ [A]  服务器名称              [脉冲绿点]  │
│      root@1.2.3.4:22        [终端][SFTP]│
│      最后连接: 2分钟前                   │
└─────────────────────────────────────────┘
```

- 卡片高度：80px
- 左侧 3px 色条表示标签颜色
- 头像：名称首字母 + 哈希背景色
- 状态点：在线显示脉冲动画，离线 `#6B7280`
- 快捷操作：终端连接、SFTP、更多菜单
- 更多操作：编辑、复制、删除（在二级菜单中）

#### 空状态

中央显示：
- 插图：[design/empty_state_host.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/empty_state_host.svg)
- 标题："还没有服务器"
- 说明："添加第一台服务器，开始 AI 辅助的远程管理"
- CTA：主按钮 "+ 添加服务器"

#### 移动端布局

- 顶部：搜索栏 + 分组筛选下拉。
- 主体：单列卡片列表。
- 长按卡片：底部弹出快捷操作菜单。
- 右下角 FAB：圆形 `cPrimary` "+" 按钮。

### 5.2 终端页

#### 顶部栏

```
+-------------------------------------------------------------+
| [●] AI Terminal  |  [首页▸] [web-1×] [db-1] [+]  |  [● 已连接] [AI] [⚙] [⋮] |
+-------------------------------------------------------------+
```

三段式结构：
1. **左侧品牌区**：LOGO Mark（20px）+ "AI Terminal" 文字，点击返回主页。
2. **中间标签区**：当前打开的标签页，支持拖拽排序。
3. **右侧操作区**：连接状态徽章、AI 面板开关、设置、更多菜单。

顶部栏规范：
- 高度：52px
- 背景：`cBg`
- 底边框：1px `cBorder`
- 品牌文字：fSmall，500，`cTextMain`
- 标签高度：34px
- 标签间距：4px
- 标签默认：背景透明，文字 `cTextSub`
- 标签激活：背景 `cCardElevated`，文字 `cTextMain`，底部 2px `cPrimary` 指示线
- 标签关闭按钮：hover 时显示，8px 图标

#### 终端区域

```
+-------------------------------------------------------------+
│ $ ls -la                                                    │
│ total 128                                                   │
│ drwxr-xr-x  12 user  staff   384 Jun 25 10:00 .             │
│ ...                                                         │
│ _                                                           │
+-------------------------------------------------------------+
```

- 背景：`cTerminalBg` #0D0D12
- 字体：JetBrains Mono，fMono
- 光标：`cAgentGreen`，块状，闪烁动画 1.2s
- 选中：`cPrimary.withOpacity(0.3)`
- 内边距：12px
- 滚动条：默认 4px，hover 8px，颜色 `cBorderHover`

#### AI 面板

桌面端：右侧固定宽度 420px（可拖拽 320px ~ 600px）。
移动端：底部抽屉，默认高度 45%，可上滑展开。

```
+--------------------------------------------------+
|  Agent 正在执行任务...                    [停止]  │  ← 运行时状态条
+--------------------------------------------------+
|                                                  │
|  ┌────────────────────────────────────────────┐ │
│  │ 帮我查看一下 Docker 版本                     │ │  ← 用户消息
│  └────────────────────────────────────────────┘ │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │ 好的，我来执行 docker --version。            │ │  ← AI 消息
│  │                                              │ │
│  │  █ 可执行                        [复制][执行]│ │  ← 命令块
│  │  │ $ docker --version                       │ │
│  │  █                                         │ │
│  │                                              │ │
│  │  ✓ 执行成功                       24 行    │ │  ← 结果块
│  │  Docker version 24.0.7...                  │ │
│  └────────────────────────────────────────────┘ │
│                                                  │
+--------------------------------------------------+
|  ⚠ 该命令会修改系统文件，请确认后执行              │  ← 警告横幅
+--------------------------------------------------+
|  [Agent] [日志] [历史]            [运行中 ▼]     │
|  ┌────────────────────────────────────────────┐ │
|  │ 输入指令或问题...  /                 [➤]   │ │
|  └────────────────────────────────────────────┘ │
+--------------------------------------------------+
```

AI 面板规范：
- 背景：`cCard`
- 左/上边框：1px `cBorder`
- 消息列表内边距：16px
- 消息气泡间距：16px
- 拖拽手柄：5px 宽，颜色 `cBorder`，hover `cPrimary`

#### 命令块详细规范

```
+--------------------------------------------------+
|█| 可执行                               [📋][▸]   │
|█| $ docker --version                              │
+--------------------------------------------------+
```

- 背景：`cTerminalOutput`
- 边框：1px `cBorder`
- 圆角：`rMedium`
- 左侧 3px 色条：
  - safe = `cSuccess`
  - warn = `cWarning`
  - blocked = `cDanger`
  - info = `cInfo`
- 顶部栏高度：32px
- 顶部栏内边距：左右 12px
- 状态标签：Safe/Warn/Blocked/Info 徽章
- 操作按钮：复制（ghost icon）、执行（primary icon）
- 命令文本：等宽字体，前缀 `$`

命令块状态：

| 状态 | 左侧色条 | 标签 | 操作按钮 | 说明 |
|------|----------|------|----------|------|
| Safe | 绿 | "可执行" | [复制] [执行] | 可直接执行 |
| Warn | 橙 | "需确认" | [复制] [确认执行] | 点击后弹出确认 |
| Blocked | 红 | "已拦截" | [复制] [禁用] | 不可执行 |
| Executing | 绿（流动光效） | "执行中" | [停止] | 显示进度指示 |
| Chained | 蓝 | "链式命令" | [复制] | 提示手动复制到终端 |

#### 结果块详细规范

```
+--------------------------------------------------+
| ✓ 执行成功                              24 行    │
+--------------------------------------------------+
| Docker version 24.0.7, build ...                 │
| ...                                              │
+--------------------------------------------------+
```

- 背景：`cTerminalOutput`
- 顶部状态条高度：28px
- 顶部状态条背景：
  - 成功：`cSuccess.withOpacity(0.08)`
  - 失败：`cDanger.withOpacity(0.08)`
- 左侧图标：成功 ✓，失败 ✕
- 状态文字：fSmall，成功 `cSuccess`，失败 `cDanger`
- 右侧：行数、耗时
- 输出区：等宽字体，`cTextBody`

#### 输入区详细规范

```
+--------------------------------------------------+
| [Agent] [日志] [历史]            [运行中 ▼]     │
| ┌────────────────────────────────────────────┐   │
| │ 输入指令或问题...  /                 [➤]   │   │
| └────────────────────────────────────────────┘   │
+--------------------------------------------------+
```

- 工具栏高度：36px
- 工具栏左侧：模式切换胶囊（Agent / 辅助）、日志按钮、历史按钮
- 工具栏右侧：运行状态、模型选择器
- 输入框：
  - 高度：44px，最大高度 120px（多行时自动扩展）
  - 背景：`cSurface`
  - 圆角：`rSmall`
  - placeholder：`cTextMuted`
- 发送按钮：
  - 圆形，36px
  - 禁用：背景 `cTextMuted`
  - 可用：背景 `cAgentGreen`
  - 发送中：显示 `CircularProgressIndicator`

### 5.3 AI 聊天页

聊天页是独立页面，用于不关联终端的通用 AI 对话。

#### 消息气泡

```
+--------------------------------------------------+
|                                          ┌──────┐│
|                                          │用户问 ││
|                                          │题    ││
|                                          └──────┘│
|  ┌──────┐                                        │
|  │AI 回 │                                        │
|  │复    │                                        │
|  └──────┘                                        │
+--------------------------------------------------+
```

- 用户消息：右对齐，背景 `cPrimary`，白色文字，圆角 12px（左下 0）
- AI 消息：左对齐，背景 `cCard`，`cTextBody` 文字，圆角 12px（右上 0）
- 头像：用户首字母/头像，AI 使用 LOGO Mark
- 时间戳：fMicro，`cTextMuted`
- 最大宽度：70% 容器宽度

#### 代码块

```
┌──────────────────────────────────────────────────┐
│ bash                                    [复制]   │
├──────────────────────────────────────────────────┤
│ docker --version                                 │
└──────────────────────────────────────────────────┘
```

- 背景：`cTerminalOutput`
- 边框：1px `cBorder`
- 圆角：`rMedium`
- 顶部栏：左侧语言标签，右侧复制按钮
- 字体：JetBrains Mono

### 5.4 设置页

采用分组卡片布局：

```
+--------------------------------------------------+
| 返回  设置                                        |
+--------------------------------------------------+
| 连接管理                                          |
| ┌────────────────────────────────────────────┐  |
| │ 服务器列表                             >    │  |
| │ 快捷命令                               >    │  |
| └────────────────────────────────────────────┘  |
| AI 与智能                                         |
| ┌────────────────────────────────────────────┐  |
| │ AI 模型配置                            >    │  |
| │ Agent 设置                             >    │  |
| │ 命令手册知识库                         >    │  |
| └────────────────────────────────────────────┘  |
| 外观与体验                                        |
| ┌────────────────────────────────────────────┐  |
| │ 主题模式                               深色  │  |
| │ 终端字体大小                           14   │  |
| │ 语言                                   中文  │  |
| └────────────────────────────────────────────┘  |
+--------------------------------------------------+
```

- 每个分组一个卡片
- 分组标题在卡片外，fTitle，`cTextMain`
- 列表项高度：48px
- 列表项 hover：背景 `cCardElevated`
- 图标使用语义色

### 5.5 主机编辑页

- 使用分组卡片表单：基本信息、认证、高级设置。
- 认证方式切换：使用 AnimatedSwitcher 过渡条件字段。
- 标签颜色选择器：6 色圆形，选中时显示 2px 白色描边。
- 底部固定操作栏：左侧"取消"（secondary），右侧"保存"（primary）。

---

## 6. 图标系统

统一使用 **Phosphor Icons** 或 **Lucide Icons** 风格的线性图标：
- 线宽 1.5px
- 端点圆角
- 颜色：`cTextSub`（默认）/ `cTextMain`（激活）/ 语义色（状态）

推荐图标映射：

| 功能 | 图标 | 说明 |
|------|------|------|
| 终端 | `terminal` | 主机卡片快捷操作 |
| SFTP | `folder-tree` | 文件传输 |
| 添加 | `plus` | 添加服务器 |
| 设置 | `settings` | 设置入口 |
| AI/Agent | `sparkles` | Agent 模式开关 |
| 复制 | `copy` | 复制命令/结果 |
| 执行 | `play` | 执行命令 |
| 停止 | `square` | 停止执行 |
| 历史 | `history` | 历史会话 |
| 日志 | `file-text` | 日志面板 |
| 删除 | `trash-2` | 删除主机 |
| 编辑 | `pencil` | 编辑主机 |
| 更多 | `more-vertical` | 更多菜单 |
| 警告 | `alert-triangle` | 警告提示 |
| 成功 | `check-circle` | 成功状态 |
| 错误 | `x-circle` | 错误状态 |

---

## 7. 交互与动效

### 7.1 动画时间规范

| 动画类型 | 时长 | 缓动曲线 | 说明 |
|----------|------|----------|------|
| 按钮状态 | 150ms | `Curves.ease` | hover/pressed |
| 页面切换 | 200ms | `Curves.easeOut` | 淡入 + 轻微上滑 |
| 卡片出现 | 250ms | `Curves.easeOutCubic` | 列表加载 |
| 底部 Sheet | 300ms | `Curves.easeOutQuart` | 从底部滑入 |
| 弹窗 | 200ms | `Curves.easeOutBack` | 缩放淡入 |
| AI 流式光标 | 1000ms | 阶跃 | 闪烁 |
| 脉冲动画 | 1200ms | `Curves.easeInOut` | 在线状态点 |
| 命令执行光效 | 1500ms | 线性 | 左侧色条流动 |

### 7.2 微交互

- **按钮 hover**：背景色变化 + 150ms。
- **卡片 hover**：边框从 `cBorder` 变为 `cBorderHover`，无阴影。
- **标签切换**：底部指示线使用 AnimatedPositioned 滑动。
- **开关/复选框**：选中时有轻微缩放弹跳（0.95 → 1.0）。
- **输入框聚焦**：边框颜色变化 + 外发光。

### 7.3 AI 状态动效

- **思考中**：顶部状态条显示 `CircularProgressIndicator`（线宽 2px，`cAgentGreen`）+ 脉冲绿点。
- **流式输出**：消息气泡右下角显示闪烁光标 `|`（`cPrimary`）。
- **命令执行中**：命令块左侧色条有从 top 到 bottom 的流动光效，顶部标签显示"执行中"。
- **任务完成**：完成卡片从上方滑入（-8px → 0），图标有轻微弹跳。
- **高风险确认**：警告横幅从顶部滑入，背景有轻微橙色脉冲。

### 7.4 空状态与加载态

- **空状态**：中央显示 LOGO Mark + 标题 + 说明 + CTA。
  - 插图：[design/empty_state_host.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/empty_state_host.svg)
  - 标题：fTitle，600
  - 说明：fBody，`cTextSub`
  - CTA：主按钮
- **加载中**：使用品牌色脉冲动画，而非默认 CircularProgressIndicator。
- **错误态**：
  - 插图：[design/error_state.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/error_state.svg)
  - 标题：fTitle，`cDanger`
  - 说明：fBody，`cTextSub`
  - 操作：重试按钮（secondary）+ 返回按钮（ghost）

---

## 8. 响应式适配

### 桌面端（> 900px）

- 主机列表：左侧边栏 280px + 右侧内容区。
- 终端页：AI 面板默认右侧 420px，可拖拽。
- SFTP 面板：终端右侧，宽度 320px。

### 平板端（600px - 900px）

- 主机列表：隐藏侧边栏，顶部搜索 + 分组筛选。
- 终端页：AI 面板默认底部 45%，横屏时可切右侧。

### 移动端（< 600px）

- 主机列表：单列卡片，分组折叠。
- 终端页：AI 面板默认收起，底部有一个拖拽条，上滑展开/下滑收起。
- 输入框：键盘弹出时工具栏自动隐藏，只保留输入框和发送按钮。
- 顶部栏：品牌区收缩为仅 LOGO，标签页可横向滚动。

---

## 9. 无障碍设计

1. **对比度**：所有文字与背景对比度至少 4.5:1，大号文字至少 3:1。
2. **焦点状态**：所有可交互元素都有可见焦点环（键盘导航）。
3. **颜色不唯一**：安全/警告/危险状态同时用文字标签 + 颜色表达。
4. **语义化**：按钮使用真实 `ElevatedButton`/`TextButton`，不只是 `GestureDetector`。
5. **减少动画**：支持系统 `prefers-reduced-motion` 设置，关闭非必要动效。
6. **最小点击区域**：移动端可点击元素至少 44×44px。

---

## 10. 实现路线图

### Phase 1：设计系统落地（优先）

1. 更新 `lib/core/constants.dart`：
   - 按本文 3.1 节调整背景、表面、边框、文字色值。
   - 确保所有颜色 token 有对应的浅色模式映射。
2. 更新 `lib/core/theme.dart`：
   - 应用新的 `ThemeData`（按钮、输入框、卡片、弹窗）。
   - 确保深色/浅色主题切换正常。
3. 创建 `lib/core/ui_tokens.dart`（可选）：
   - 封装 `AppColors`、`AppTextStyles`、`AppRadii`、`AppSpacing`。

### Phase 2：LOGO 与品牌

1. 将 SVG 导出为各平台图标（可使用 [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)）。
2. 替换启动页、关于页 LOGO。
3. 更新 README、官网品牌展示。

### Phase 3：核心页面重构

1. **主机列表页**：侧边栏 + 新主机卡片 + 品牌化空状态。
2. **终端页**：三段式顶部栏 + 命令块/结果块重设计 + AI 面板优化 + 简化输入区。
3. **聊天页**：新消息气泡 + 统一代码块样式。
4. **设置页**：分组卡片布局。

### Phase 4：动效与打磨

1. 统一按钮/卡片 hover、focus、pressed 状态。
2. 实现 AI 思考、执行、完成的动效。
3. 空状态、错误状态品牌化。
4. 跨平台尺寸与字体适配测试。

---

## 11. 设计资产清单

| 文件 | 说明 |
|------|------|
| [design/logo_mark.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_mark.svg) | 主 LOGO / App Icon 源文件 |
| [design/logo_wordmark.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_wordmark.svg) | 品牌组合标识 |
| [design/logo_mark_light.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/logo_mark_light.svg) | 浅色背景版本 |
| [design/empty_state_host.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/empty_state_host.svg) | 主机列表空状态插图 |
| [design/empty_state_terminal.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/empty_state_terminal.svg) | 终端空状态插图 |
| [design/error_state.svg](file:///Users/cjm/CodeBuddy/ai-terminal/design/error_state.svg) | 错误状态插图 |
| [DESIGN_UI.md](file:///Users/cjm/CodeBuddy/ai-terminal/DESIGN_UI.md) | 本设计文档 |
| [findings.md](file:///Users/cjm/CodeBuddy/ai-terminal/findings.md) | 调研发现与决策记录 |
| [task_plan.md](file:///Users/cjm/CodeBuddy/ai-terminal/task_plan.md) | 任务计划 |
| [progress.md](file:///Users/cjm/CodeBuddy/ai-terminal/progress.md) | 进度记录 |

---

## 12. 关键验收标准

- [ ] 新 LOGO 在 16×16 到 1024×1024 全尺寸下清晰可辨。
- [ ] 深色主题下终端区域与 UI 无割裂感。
- [ ] 命令块/结果块的新样式统一应用，红黄绿按钮已移除。
- [ ] 所有按钮有可感知的 hover/focus/pressed 状态。
- [ ] 主机列表、终端页、聊天页、设置页视觉风格一致。
- [ ] 移动端与桌面端布局均正常，无元素重叠或溢出。
- [ ] 文字对比度满足 WCAG AA 标准。
- [ ] `flutter analyze` 无新增 warning。
