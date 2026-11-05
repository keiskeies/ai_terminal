# 每 Tab 常驻工作区（终端 / Agent / 监控）设计

状态：已实现并完成 Windows 真机验证
关联：`lib/pages/terminal_page.dart`、`lib/providers/agent_provider.dart`、`lib/widgets/server_monitor_panel.dart`、`lib/widgets/terminal_view.dart`

---

## 1. 问题

切换连接 tab 时，三块内容都会“重新加载”：

- **终端**：原实现只有一个 `TerminalView`，切换时换 `_terminal` 并 `setState`，`Terminal` 缓冲虽在，但视图滚动/选区状态被重建。
- **Agent**：状态本身按 scope 隔离，但 UI 只渲染 active scope；`AgentProcessTimeline` / `OperationSheet` 的展开状态是 widget 本地状态，切走后 widget 销毁，回来默认收起。
- **监控**：`ServerMonitorPanel.dispose()` 调用 `service.reset()`，而监控服务按 **host** 缓存；同一个服务器的多个 tab 共享历史，切 tab 即清空，从 0 开始。

用户要求：每个连接 tab 是一个独立区域，即使连接的是同一台服务器也互不影响。

## 2. 架构

### 2.1 顶部 tab 栏 + Offstage 工作区栈

`TerminalPage` 仍然是单个页面，但主体不再是“只渲染 active tab”，而是：

- 每个 tab 一棵常驻 `_buildMainBody` 工作区，外层 `KeyedSubtree(key: tab-workspace-<tabId>)`；
- 所有工作区放在 `Stack(fit: expand)` 中，非活跃工作区用 `Offstage` 隐藏，`ExcludeFocus` 排除焦点，`TickerMode(enabled: false)` 停动画；
- 切 tab 只改变 `Offstage.offstage`，不销毁、不重建子树；终端的滚动、Agent 的展开状态、输入的 TextEditingController 都保留。

### 2.2 每 tab 独立终端

- `Terminal` 实例按 tab 缓存在 `_tabTerminals`；
- 输出订阅 `_tabOutputSubscriptions` 按 tab 常驻，后台 tab 的 PTY 输出继续写自己的缓冲；
- 每个 `TerminalView` 绑定自己的 `Terminal` 和 `onSend`（写回该 tab 的 service）；
- `TerminalView.active` 控制 `autofocus`：只有可见 tab 抢焦点，避免后台 tab 把键盘焦点抢走；
- 重连只替换 tab 上的 service，`onOutput` 闭包读实时 service，不重绑订阅。

### 2.3 每 tab 独立 Agent

- `AgentNotifier.stateForScope(scopeId, hostId)`：活跃 scope 用当前 `state`，非活跃 scope 读 `AgentHostRegistry` 缓存；工作区按 tab 取自己的状态。
- **新 tab 一律开新会话**（`startFresh: true`）：不再加载 host 的 active 会话；同服务器第二个 tab 的 Agent 区域从空白开始，和它自己的终端一致。
- 非活跃 workspace 不随 active 流式更新频繁重建；切回来时 `switchTab` 把最新 registry 状态加载为 active，页面重建一次，已有消息的 widget State 仍在，展开/折叠状态不丢。
- 聊天滚动状态按 tab 拆成 `_chatScrollControllers` / `_tabAutoScroll` / `_tabShowScrollToBottom`，不再共用一个 offset。
- 输入框文字、执行中命令、等待确认命令改用 tab.id 索引，不再读 `_currentTabId` 的全局值。

### 2.4 每 tab 独立监控

- `_monitorServices` 的 key 从 `hostId` 改为 **tab.id**：同服务器多 tab 各自一份 `ServerMonitorService` 和历史；
- `ServerMonitorPanel.dispose()` **不再 reset**，只停自己的定时器；历史归 per-tab service；
- 清空只发生在：关闭 tab（`_removeTab` 显式 reset）或重连导致 executor 更换（`_getOrCreateMonitorService` 检测到实例变化时 reset 旧服务）；
- 面板随工作区常驻，切 tab 不重建，历史曲线连续。

### 2.5 SFTP

沿用原有 per-tab `Offstage` 方案；SFTP 侧面板提到工作区栈外层统一包裹，不在每个 workspace 里重复。

### 2.6 面板开关与布局也按 tab 独立

- `_tabAiPanelVisible` / `_tabAiPanelPosition` / `_tabAiPanelRatio`：AI 面板的展开/收起、在右/在下、宽度比例都按 tab 存；
- `_tabMonitorVisible`：监控栏开关按 tab 存；`monitorVisibleHosts` 只作为新 tab 的 host 默认值，已有 tab 不再跟着变；
- 新 tab 创建时由 `_initTabPanelState` 把当时的默认值**快照**到自己的 map。之后另一个 tab 改布局只更新默认值（供未来新 tab）和自己的 map，不会改动已存在 tab；
- 顶部 AI / 监控按钮、分割条上的 AI 收起/方位按钮、拖拽宽度、移动端上滑/下滑手势，全部作用于当前 tab。

## 3. 代码落点（按符号，不按行号）

- `_buildTabWorkspaces`：构建所有 tab 的常驻工作区（Offstage/ExcludeFocus/TickerMode）。
- `_buildMainBody(..., {required bool isActive})`：按 tab 构建终端/AI 面板；终端传 `active`。
- `_ensureTabTerminal` / `_setupTerminalListener`：per-tab Terminal + 常驻订阅。
- `AgentNotifier.stateForScope` / `switchTab` 的 `startFresh: true`。
- `_chatControllerFor` / `_onChatScroll`：per-tab 滚动控制器与状态。
- `_getOrCreateMonitorService`：per-tab 服务 key；`ServerMonitorPanel.dispose` 去掉 reset。
- `TerminalView.active`：只有可见 tab 自动聚焦。

## 4. 验证

Windows Release 真机（本地 + 同一台 `192.168.1.5` 两个 tab）：

1. 在第一个 `192.168.1.5` tab 发起 `hostname` 任务；切到第二个同服务器 tab，第二个 tab 的 Agent 区域 **空白**、终端独立、监控曲线独立。
2. 任务在后台继续并完成；切回第一个 tab，用户消息、AI 结论、底部指标条都在，任务没有被取消或重置。
3. 展开“过程与证据”后切到另一个 tab 再切回，**仍保持展开**——这是原 bug 最直接的复现路径。
4. 两个同服务器 tab 的监控曲线各自累计；切走再切回历史不清零。
5. 终端输出与提示符各自保留；`TerminalView` 只在 active tab 抢焦点。
6. AI 面板开关独立：tab1 收起后切到 tab2，tab2 仍保持展开；切回 tab1 仍是收起。
7. AI 方位/宽度独立：tab1 切到底部，tab2 仍在右侧；tab2 拖宽后切走再切回，宽度保持，tab1 不受影响。
8. 监控开关独立：tab1 开启、tab2 关闭，来回切换各自保持。

门禁：`flutter analyze` 33 issues / 0 errors（既有基线）；`flutter test` 856 passed / 24 skipped（24 个为原有环境门控 E2E）。

## 5. 已知边界

- 所有打开过的 tab 工作区都常驻内存（懒建：首次切到该 tab 时建立）；关闭 tab 释放终端/控制器/监控服务。
- 监控每个可见 tab 各起一份采样；同服务器多 tab 会增加少量监控命令，换取独立历史。
- 面板开关/方位/宽度按 tab 独立，但设置里保存的是**最后一次选择作为新 tab 默认值**；已有 tab 的快照不随默认值变化。tab 关闭后其独立布局不持久化（tab id 是临时的）。
- Goal（目标模式）仍是 host 级状态，同服务器 tab 共用目标横幅；这是产品上“跨任务持续目标”的设计，不属于本次 tab 内容隔离范围。
- `ChatProvider` 的旧对话状态仍按 host 保存；Agent 面板实际渲染 AgentState（按 tab 隔离），Legacy chat 仅用于错误横幅等。
