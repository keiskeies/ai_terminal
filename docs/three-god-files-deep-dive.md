# 三个上帝文件深度拆解分析

- 日期：2026-11-20
- 基线：`7694ae3`（架构治理 Phase A 已合入）
- 对象：`terminal_page.dart` / `agent_engine.dart` / `agent_provider.dart`
- 性质：**只读分析 + 可落地的迁移方案**，本轮不改代码
- 关联：`docs/terminal-architecture-refactor-design.md`（Phase A 设计与实施记录）

---

## 0. 摘要

| 文件 | 实测规模 | 核心病症 | 关键结论 |
|---|---|---|---|
| `pages/terminal_page.dart` | ~7750 行 / 87 import / 单个 State 占 178–7128 | 35 个 per-tab 平行 Map + `_currentTabId` 隐式寻址 | **所有 R1/R3 问题的共同根因是隐式寻址**。先建 `SessionState` 把 tabId 显式化，再拆 Pane/Output/Lifecycle/UI |
| `services/agent_engine.dart` | 5706 行 / 55 import / 2 类 / **7 个 Completer** | 状态机、prompt、解析、执行、工具、compact 全压一类；终态路径分叉 | R1 主体质量高，但 **5 条失败终态缺 flush**、**2 组 await 后无代际检查写共享 list**。状态机收口必须最后做，但要先建 `TerminationGuard` |
| `providers/agent_provider.dart` | 2225 行 / 实际 **7 处状态持有者** | 不是三重而是七重；registry 活跃快照陈旧、不可订阅 | registry 容器够格但**数据新鲜度与可订阅性不够格**。chatItems/events 留在 Riverpod，registry 升级为权威容器 + 派生投影；先做 5 个低风险修补 |

**跨文件共同根因**：隐含的"当前是谁"——`_currentTabId`（页面）、`_registry.activeScopeId`（provider）、`_engine`（缓存）。三处都用了"活跃对象"顶替"任务归属对象"。

**本轮最值得先修的不是拆分，而是 8 个已验证的真实 bug**（见 §5）：它们改动局部、风险低、且是拆分的前置条件。

---

## 1. 三者关系与依赖方向

```
terminal_page.dart ──(ref.read/watch, 40+ 处)──▶ agent_provider.dart
                                                    │
                                    ┌───────────────┴────────────────┐
                                    ▼                                ▼
                          agent_host_registry.dart          agent_engine.dart
                          (per-scope 容器)                   (每 scope 一个实例)
                                    ▲                                │
                                    └────── engine/executor/state ─────┘
```

- `agent_engine.dart` 不反向依赖 provider（只依赖 registry），方向是干净的。
- `terminal_page.dart` 直接读写 40+ 处 provider、10+ 个 service/DAO —— 拆分的最大障碍是 **UI 层承担了太多业务编排**。
- 三者必须按 `provider 状态源统一 → engine 终态收口 → page SessionState 显式化` 的顺序治理；page 拆得再漂亮，底层状态漂移仍会串台。

---

## 2. `terminal_page.dart`（7750 行）

### 2.1 职责地图（行号为 Phase A 后）

| 区段 | 行号 | 职责 |
|---|---|---|
| 纯函数 / Widget 壳 | 89–176 | 面板布局算法、`TerminalPage` |
| State 字段区 | 178–445 | 全部 per-tab Map、资源、UI 态 |
| 初始化 / 设置 | 446–568 | init、Agent 初始化、设置读写 |
| 输出与滚动 | 570–600、808–919、1371–1434 | 帧级缓冲、xterm 写入、chat 合并 |
| 模型与连接 | 602–806、1476–1632 | 端点/模型同步、连接/重连、加主机 |
| 分屏 pane | 921–1370 | 额外 pane 会话全生命周期 + 渲染 |
| tab 生命周期 | 1435–1474、2668–2830 | 切 tab、尺寸同步、关 tab 22 项清理 |
| dispose / build | 1668–1884 | 15 类资源回收；4 个 `ref.listen` + 页面骨架 |
| 主布局 / 顶栏 | 1886–3258 | 主布局、SFTP、顶栏、监控、连接占位 |
| AI 面板与消息 | 3259–4931 | 面板壳、消息气泡、Markdown/流式渲染 |
| 危险操作 | 3972–4381 | 回滚、跨主机重连、续接/重试 |
| 交互桥 / 斜杠命令 | 4932–5743 | secret/输入/目录授权、/plan /model /export /goal /compact |
| 底部栏 / 快捷键 / Runbook | 5745–6819 | 输入、快捷序列、命令面板、Runbook 执行 |
| 辅助 widget | 7131–7750 | 7 个已独立的小类 |

### 2.2 per-tab Map 分类

- **key 必须是 tabId**：`_tabExecutingCommand`、`_tabExecutedCommands`、`_tabPendingConfirm`、`_tabTerminals`、`_tabAiInputText`、`_sessionRecorders`、`_portForwardServices`、`_tabAiPanel*`、`_tabFocusMode`、`_tabMonitorVisible`、`_monitorServices`、`_tabSftpVisible/InitialPath`、`_chatScrollControllers`、`_tabOutputSubscriptions`、`_tabChatOutput*`、`_tabTermWrite*`、`_tabCommandTrackers`、`_tabBlockTrackers`、`_lastTabStatus`。
- **key 是 paneId**：`_paneTerminals`、`_paneOutputSubscriptions`、`_paneTermWrite*`、`_paneSessions`、`_paneOpening`；`_tabPaneLayout` 名字带 tab 但存的是 tab→布局。
- **增删不对称**：`_ensureTabTerminal`（1371–1402）一次写 9 处；`_removeTab`（2760–2795）删 22 处但漏 `_tabFocusMode`、`_tabSftpInitialPath`；`dispose`（1668–1741）又漏 `_tabBlockTrackers`/`_tabCommandTrackers`/`_monitorServices`/两个 MenuController（当前不致命，拆分后立刻变泄漏）。

### 2.3 真实问题（按危险度）

| # | 位置 | 问题 | 规则 |
|---|---|---|---|
| 1 | `_executeLineDirectly` 5135–5162 | `await 800ms` 后 `_executedCommands`/`_executingCommand` 经 getter 按 `_currentTabId` 寻址（354–363）。800ms 内切 tab → 命令发到 A、状态记到 B | R1+R3 |
| 2 | `_setAiPanelVisible/Position` 253–263 + 5418–5423 | 右键任意 tab 时把该 tab 的面板态写成**全局默认并落盘**，后台 tab 渗透全局 | R3 |
| 3 | `_retryFailedHosts` 4293–4332 / `_startContinuation` 4226–4275 / `_retryFailedCommand` 4335–4380 | executor 永远取 activeTab；门禁用全局 `isRunning` 而非 `isRunningFor(tab.id)` | R3 |
| 4 | `_sendRunbookPrompt/Command` 6738–6809 | `void async`，弹窗期间 tab 可能已关闭仍写其 executor | R1+R5 |
| 5 | `_executeRollback` 3989–4107 | 按 hostId 扫 tab 取**第一个**匹配；确认弹窗期间 tab 可能被关 | R3 |
| 6 | build 内 `ref.listen` 1815–1847 | 在 build 阶段写 State + 间接触发 setState（与 provider 原地复用强绑定） | 可接受但拆分需整体迁移 |

### 2.4 拆分方案与顺序

依赖方向：`TerminalPage(壳)` → `SessionState` / `PaneHost` / `OutputRouter` / `TabLifecycleCoordinator` / `ConnectionActions` / `AgentActions` / `AiPanel` / `TerminalChrome`。

| 步 | 内容 | 验证 | 理由 |
|---|---|---|---|
| 0 | **建 `SessionState`**：字段 192–445 归位，`forTab(tabId)` 显式访问器替代 354–380 隐式 getter；修 §2.3 #1/#2 | 开/关/切 3 tab 后所有 Map key 集合一致；多 host 回归 | 所有 R1/R3 的共同根因，必须先做 |
| 1 | 纯函数 91–167 + 辅助类 7131–7750 独立成文件 | 布局 golden 不变 | 零风险 |
| 2 | `PaneHost`：401–412 + 921–1370 + dispose pane 段 | 分屏/关屏/掉线补开/退出无孤儿 PTY | 边界清晰、R2 验证点明确 |
| 3 | `OutputRouter`：570–600 + 808–919 + 1371–1434 + 3465–3507 | 高频 tail 不卡、切 tab 不串台 | 高频路径，早拆早受益 |
| 4 | `TabLifecycleCoordinator`：统一 `_removeTab`/dispose 清理契约 | 资源 assert 测试 | 修增删不对称 |
| 5 | `ConnectionActions` + `AgentActions`（业务下沉 service） | R5 四终态一致、跨 tab 续接正确 | 业务最不该留在 Widget |
| 6 | 最后拆 UI（AI 面板 + Chrome） | golden 对比 | build 读 30+ 字段，必须等 SessionState |

**暂时别动**：build 内 4 个 `ref.listen`、Agent handler 注册/清理（468–471/1727–1739）、`_reconnectSub`、面板位置存盘 —— Phase A 刚治理，单独迁出易造成 listener 重复注册或 handler 提前释放。

---

## 3. `agent_engine.dart`（5706 行）

### 3.1 职责地图

| 区段 | 行号 | 职责 |
|---|---|---|
| 字段/构造/工具注册 | 57–494 | 50+ 字段、7 Completer |
| 用户等待通道 | 496–679 | 危险命令确认、交互输入桥 |
| 历史/瞬态/compact 同步 | 681–961 | clear/restore/reset/sync |
| 任务启动与外层 catch | 963–1099 | `startTask`/`_startTask`、代际 token |
| 取消/暂停/恢复 | 1101–1364 | 全部 Completer 收口点 |
| ReAct 主循环 | 1412–1943 | 状态机核心（代际门/暂停门/Think/Parse/Act） |
| AI 流式 | 1945–2507 | 重试/fallback/watchdog/提前执行/去重 |
| FC-first 转换 | 2509–2636 | 结构化动作 |
| ReAct 文本协议解析 | 2638–3010 | 几乎全 static |
| 命令执行 | 3012–3110、3274–3806、4711–4855 | 多命令展开、安全/权限/审计、单命令执行 |
| 工具编排 | 3963–4476 | 文件变更、权限、确认、执行 |
| finish 收口 | 4508–4709 | 操作单报告 + `_finishTask` + 通知 |
| compact / prompt / 裁剪 | 4857–5690 | 摘要、错误分类、prompt 构建、模式开关 |

### 3.2 7 个 Completer（不是 6 个）

| 字段 | 行 | 等待对象 | 缺口 |
|---|---|---|---|
| `_confirmCompleter` | 91 | 危险命令确认 | 有 10min 超时 ✅ |
| `_choiceCompleter` | 215 | 用户 A/B/C 选择 | 无超时（可接受） |
| `_interactiveInputCompleter` | 222 | 终端交互提示 | `.then` 有 `catchError` ✅ |
| `_commandCancelToken` | 232 | 单命令中断 | `_resetTransientState:904` 只置 null 未 complete ⚠ |
| `_orchestratorCancelToken` | 250 | 整个循环 | `_resetTransientState:905` 只置 null 未 complete ⚠ |
| `_aiDoneCompleter` | 272 | AI 流 onDone | **902 / 4658 直接置 null 不 complete** ❌ R1 |
| `_earlyExecutionCompleter` | **3113** | 提前执行命令结果 | 字段声明离用途 2600 行，拆分易漏迁 |

### 3.3 R5 终态审计（关键）

> **复核修正（见 §5.2）**：初版把失败路径的 flush 全标 ❌，是基于"flush 只走 onCompleted"的误判。
> 实际 provider 的 `onError`（`:735`）同样会调 `_flushStreamingToContent`。下表已按复核结果修正：
> 只有 `_resumeTask` catch 与 ask 异常取消两条真缺 flush，均已修。

| 路径 | status | finish | flush | 说明 |
|---|---|---|---|---|
| AI finish / no-command 耗尽 / 工具重试耗尽 / maxSteps / cancel | ✅ | ✅ | ✅ | cancel 走 onCompleted（:1197） |
| executor 为 null（1040–1056） | ✅ | ✅ | ✅ | onError :1041 触发 flush |
| `_startTask` 外层 catch（1059–1098） | ✅ | ✅ | ✅ | onError :1092 触发；:1082 注释措辞有误但不影响行为 |
| `_resumeTask` catch（1345–1362） | ✅ | ✅ | ❌→✅ | **真缺**，原两回调都不调，已补 onError |
| 未连接（1422–1439） | ✅ | ✅ | ✅ | onError :1424 触发 |
| `_callAI` 异常（1618–1665） | ✅ | ✅ | ✅ | onError :1644 触发（:1638 覆盖 engine 侧正文，但 provider reducer 独立，不影响 flush 内容） |
| ask 正常取消/pause（3934–3937） | ✅(cancelled/paused) | ✅ | ✅ | cancel/pause 先设状态再 complete('')，前面分支已 return |
| ask 异常取消（外部 selectChoice('')） | ❌ | ❌ | ❌→✅ | 悬在 waitingConfirm，已补防御性收口 |

### 3.4 R1 竞态缺口

> **2026-11-20 复核（当前磁盘，agent_engine.dart 共 5314 行）**：本节行号为旧基线，**R1 缺口已全部修完**，不再是待办。
>
> - 真正会污染新 operation 的两处台账写入已加代际比对：shell 路径 3407 捕获 `genAtRecord` → `await ChangeRecordService.record`(3409) → 3415–3417 比对 → 才写 `_operationChangeIds`(3418)/`_operationChanges`(3419)；文件工具路径同构（3670 / 3672 await / 3681–3683 比对 / 3684–3685 写）。这是 P0-5 的落地。
> - 5 处 `await AuditLogger.log`（当前 2954/2982/3093/3438/3702）无代际检查是**有意为之**：append-only 落盘、不写引擎共享 list，加检查反而丢历史审计。
> - shell 主结果路径 3282 还有总代际门；`_executeCommand` 自身 4397/4489 各有检查。整条命令链代际检查 18+ 处。
> - `requestSudoPassword` 的 await 后写 `_sudoPassword` 问题：已在 P0/P1 收口阶段处理（见 §5 实施记录）。
> - `.then()` 仅 2 处且都有 `onError`/`catchError` ✅；其余 `sub.cancel()` 配对 complete ✅（除 §3.2 的 902/4658）。

### 3.5 拆分方案

依赖方向（从叶子到根）：

```
ReActParser / PromptBuilder / HistoryPolicy      (纯函数，无引擎依赖)
        ↓
EventStore (R4: stableId→finalId, 去重)          (每引擎独立)
        ↓
CommandRunner (R1: generation 显式传参)
        ↓
ToolOrchestrator
        ↓
TerminationGuard (R5: 唯一终态收口)
        ↓
AgentEngine facade (循环 + 生命周期 + 7 Completer)
```

- **Step 0 特征化测试**：✅ 已补（提交 `40853c8`）——`test/react_parser_test.dart` 15 例 + CI quality 门禁 + 终态写入棘轮脚本 `tools/check_terminal_writes.py`（基线 10，待 TerminationGuard 落地后降为 0）。终态断言经复核修正：5 条失败终态缺 flush 实为 1 条（`_resumeTask` catch），已在 P1 修复。
- **Step 1–4 叶子拆分**：✅ 已落地 3/4（保留 `*ForTesting` 转发，145 个 agent 测试零改动）：
  - Step 1 `ReActParser`（`287ffb4`）：358 行纯静态解析 → `lib/services/react_parser.dart`，engine 留薄转发壳。
  - Step 2 `PromptBuilder`：**部分落地**（`3d701f1`）—— 复核发现 `_buildSystemPrompt` 并非报告原判的「纯函数无引擎依赖」，而是直接/间接依赖 7 个实例字段（`_modelConfig`/`hostId`/`_tools`/`_orchestratorMode`/`_memory`/`_webSearchEnabled`/`_permissionMode`），且 `_syncWebToolsRegistration` 带副作用改写 `_tools`。主体整体提取等于重构语义，风险中-高，**暂缓**；留待 `ToolOrchestrator`（`_tools` 所有权迁移）之后一并处理。本轮先抽出 4 个可显式传参的纯文本叶子到 `lib/services/prompt_builder.dart`：`isSudoCommand`、`planStatusGlyph`、`buildPlanProgressBlock(plan)`、`executionLocationPrompt(executor)`、`permissionModePrompt(mode)`；计划进度标记常量也收敛为单一来源。engine 留薄转发壳，调用点零改动；新增 `test/prompt_builder_test.dart` 6 例。至此 Step 1–4 叶子拆分 **4/4 均已有产出**（PromptBuilder 主体除外）。
  - Step 3 `EventStore`（`88cd6fb`）：`_eventSeq` + 轮内两个集合 → `lib/services/event_store.dart`（`EventStore` 跨轮序号 + `EventScope` 轮内去重）。保留「序号跨轮递增、去重集合轮内隔离」的原始语义；新增 7 例特征化测试，含「两轮相同 ask 不撞 id」回归。
  - Step 4 `HistoryPolicy`（`720d6fd`）：三层裁剪 + 3 个上限常量 → `lib/services/history_policy.dart`，唯一实例依赖 `effectiveContextWindow` 改显式入参；22 处调用点经 `_trimMessages` 转发零改动。新增 8 例特征化测试。
  - 每次拆分均通过 `flutter analyze`（81 issues / 0 error 基线）与全量测试（现 1725 passed / 25 skipped）。
- **Step 5–6（判定：推迟）**：`CommandRunner`（旧 3016–3110/3275–3806/4713–4855 → 当前 2668–2851/2927–3535/4389–4531）**不在本阶段提取**。复核结论：①「顺手修 §3.4」前提已不成立（R1 缺口修完，见 §3.4）；② `_runCommandWithSafetyInner`(2927–3464，538 行) 不是可提取的执行器，而是引擎状态机本身——5 次 `_currentTask.copyWith`、6/7 个 Completer、终态门、台账/badges/memory、3 回调、10+ `onEvent` 全部交织；③ 代际检查 18+ 处与 cancel/pause/resume 的 Completer 顺序强耦合。推迟到 **Step 7 TerminationGuard 之后**：Guard 落地后可在入口统一收口 generation，`_executeCommand`(4389–4531) 才能真正变成接收显式 generation/executor 的纯执行器。`ToolOrchestrator` 同理待 Guard 后再评估。
- **Step 7 最后做**：引入 `TerminationGuard.terminate({status, finishState, flush})`，固定顺序执行 status→report→finish→flush→tracer→清理，包 try/finally；替换全部 11 条终态路径。**必须每引擎一个实例，严禁 static**；guard 接收 `generation/hostId/operationId`，进入时统一代际检查。
- **暂时别动**：`_callAI`（stream + watchdog + doneCompleter 六件事咬合）、`cancelTask/pauseTask/resumeTask`（与 7 Completer 和回调清空顺序强耦合）。

---

## 4. `agent_provider.dart`（2225 行）

### 4.1 实际是 7 处状态持有者（不止三重）

1. Riverpod `AgentState`
2. `AgentHostRegistry`（per-scope 容器）
3. `AgentEngine` 内部字段
4. `AgentStreamReducer`（StringBuffer 流式增量）
5. `_pendingPersist` / `_persistDrainFutures` 等持久化节流映射
6. `_goals` + `SettingsDao` KV
7. `ConversationsDao` / 磁盘

### 4.2 关键不一致

| # | 位置 | 现象 |
|---|---|---|
| U1 | 761 vs 2001–2008 | 活跃 scope 的 `currentTask` 只写 state，registry 快照滞后（有注释承认） |
| U2 | 673/1202/1572 | `lastMessage` 高频写但**全 lib 无读取点**（死写，触发 rebuild） |
| U3 | 1524/1537/1550 | `confirmCommand/rejectCommand/selectChoice` 仍直读 `_engine` + `_engineScopeId ?? ''`，**Phase A 漏改**；removeTab 后 scopeId 为 `''` |
| U4 | 1055 | `startTask` 用 `_executor` 活跃缓存，对比 `resume:1515` 的 `getScopeExecutor ?? _executor` |
| U5 | 949/976–1000 | `setMaxSteps`/`loadSettings` 不向 registry 各 scope 广播（timeout 有，maxSteps 没有） |
| U6 | 275–284 | `_clearEngineCallbacks` 漏清 `onStreamDiscarded`/`onReasoning`/3 个透传回调 |

### 4.3 registry 能否当唯一真相源

- **够格**：per-scope 隔离键完整（state/engine/executor/config/memory/sysInfo）、`getScopeExecutor` 有自愈、`removeScope` 级联完整。
- **不够格**：① 活跃 scope 的 state 只在 `switchTab:213` 写回，平时是**陈旧快照**；② 不含 reducer 增量、持久化节流、启动窗口、goals；③ **不是 Listenable**，Riverpod 无法订阅。
- **结论**：容器结构够格，数据新鲜度与可订阅性不够格。补齐这两点前不能直接当真相源。

### 4.4 R2 违反（已验证）

`removeTab`（405–420）与 `dispose`（2205–2220）都是 `clear 回调 → cancelTask → disposeTools`，**没有 `_flushStreamingToContent`**。而 `switchTab`（199–202）和 `init`（543–545）都遵守了 flush→clear→cancel。AGENTS.md R2 明确点名 `removeTab` 也必须 flush —— 结果是关 tab 时最后一段 assistant 流式内容未固化到 `content` 就被 `removeScope` 丢弃。

### 4.5 三个候选方案

| | A 最小修补 | **B registry 权威 + 派生投影（推荐）** | C 全量搬入 registry |
|---|---|---|---|
| 思路 | 修 U1–U6，明确主次 | `AgentScope` 聚合对象存 registry；Riverpod 只持活跃投影 | chatItems/events 全移入 |
| 改动 | ~10 处 | 中（新类 + 改写入路径） | 大（UI 全量重写） |
| 根治漂移 | ✗ | ✓ | ✓ |
| 全量复制 | 不解决 | **解决**（scope 内可变累积 + 节流投影） | 更差 |
| 推荐 | **立即做** | **最终目标** | 否 |

**核心判断**：chatItems/events **留在 Riverpod**（流式高频 120ms tick，搬进 registry 零收益还要多一层通知），但 registry 升级为权威容器，Riverpod state 降级为它的投影。`onEvent`（690–691）每次事件双 O(n) 复制可改为 scope 内 `eventsBuffer` 可变累积 + 节流时一次性投影。

**迁移步骤**：
- 第 0 步（低风险快赢）：U2 删 lastMessage；U3 confirm/reject/select 走 `_activeEngine()`；U4 startTask 用 `getScopeExecutor`；U5 maxSteps 广播。
- 第 1 步：removeTab/dispose 补 flush；补齐 `_clearEngineCallbacks`。
- 第 2 步：新增 `AgentScope` + registry `update/notifyListeners`，吸收 reducer 与 persist 元数据，旧 API 保持 delegating。
- 第 3 步：`_updateScopeState` 改走 `registry.update`，Riverpod state 由 watcher 派生；逐回调切换，每切一个跑全量 agent 测试。
- 最后：删 `_engine/_executor/_modelConfig/_engineScopeId`；UI 订阅改为 `agentScopeProvider(scopeId)`。
- **别动**：engine 的 `_conversationHistory`/代际检查、`cancel/pause/resume` 内部、`_goals` + SettingsDao 层、`_hostExecutors` 回退通道。

### 4.6 测试影响

`agent_tab_scope_test.dart:104–140`（switchTab 往返状态保留）、`:187–200`（cancel 立即写 state）、`agent_steering_provider_test.dart:24–28`（`_TestNotifier.setStateForTest` 直写 state）在方案 B 下会失效/变异步，需改为断言 `registry.stateOf(scopeId)` 与 `registryForTesting.setState()`。

---

## 5. 可立即修复的 8 个高危点（不动架构）

| 优先级 | 位置 | 修复 | 风险 |
|---|---|---|---|
| P0 | `terminal_page.dart:5135–5162` | 用捕获的 `tab.id` 显式寻址 `_tabExecutedCommands/_tabExecutingCommand` | 低 |
| P0 | `terminal_page.dart:253–263 + 5418` | 拆分 `setTabOnly` / `setGlobalDefault` | 低 |
| P0 | `agent_provider.dart:1524/1537/1550` | 走 `_activeEngine()`，去掉 `_engineScopeId ?? ''` | 低 |
| P0 | `agent_provider.dart:405–420 / 2205–2220` | clear 前补 `_flushStreamingToContent(scopeId)` | 低 |
| P0 | `agent_engine.dart:3753/4003/3302/3330/3441/3780/4031` | await 后加 `generation != _currentTaskGeneration` 检查 | 低 |
| P1 | `agent_engine.dart` 失败终态 | 复核后仅 `_resumeTask` catch 真缺 flush（详见 §5.2），已补 onError | 低 |
| P1 | `agent_engine.dart:902 / 4679`（原记 4658，为改前行号） | `_aiDoneCompleter = null` 前先 `complete()` | 低 |
| P1 | `agent_engine.dart:3949–3960` | ask 异常取消补防御性终态（正常 cancel/pause 已正确） | 低 |

建议单独一个 commit 修前 5 项（P0），第 6 项单独评估后再做。

### 5.1 实施记录（2026-11-20）

前 5 项 P0 已全部落地，改动 3 个代码文件（+83/−45）：

| 项 | 落地方式 | 文件 |
|---|---|---|
| P0-1 | `_executeLineDirectly` 全程用捕获的 `tab.id` 显式寻址 `_tabPendingConfirm`/`_tabExecutingCommand`/`_tabExecutedCommands`；删除随之孤立的 `_executingCommand` setter 与 `_executedCommands` getter（getter 读路径仍被 4499/4691 使用，保留） | `terminal_page.dart` |
| P0-2 | `_setAiPanelVisible/_setAiPanelPosition` 增 `updateDefault` 开关；`_putIntoAgentInput`（右键后台 tab）传 false，只改该 tab 自身态，不写全局默认、不落盘 | `terminal_page.dart` |
| P0-3 | `confirmCommand/rejectCommand/selectChoice` 改用 `_activeEngine()` 取引擎与归属 scopeId，去掉滞后的 `_engine` + `_engineScopeId ?? ''` | `agent_provider.dart` |
| P0-4 | `removeTab` 在 `removeScope`/`_reducer.reset` 前、`dispose` 在清回调前，遍历 scope 补 `_flushStreamingToContent`；落盘 `_drainPendingPersist` 不依赖 reducer，顺序安全 | `agent_provider.dart` |
| P0-5 | 两处 `ChangeRecordService.record` await 前捕获 `genAtRecord`，写共享 list 前比对 `_currentTaskGeneration`，旧任务记录不再污染新 operation | `agent_engine.dart` |

**关于 P0-5 未覆盖的行**：§5 表中 3302/3330/3441/3780/4031 是 `AuditLogger.log` 的 await——它是 append-only 审计落盘，不写引擎共享 list；加代际检查反而会丢弃历史审计记录，故不改。真正会污染新 operation 的只有 3753/4003 两处台账写入，已覆盖。

**未补特征化测试的理由**：这 5 处均为深度耦合内部状态的私有方法（Widget State 私有方法、engine 私有流程 + 静态 DB 服务），补单测需新增大量 `ForTesting` 后门与 mock 基础设施，改动面和风险超过修复本身，与"低风险局部修复"初衷相悖。§7 的测试安全网是面向后续大重构（尤其 P1 终态项）的，非这 5 项机械修复的前提。验证以全量回归 + 静态分析 + diff 复查为准。

**验证**：`flutter analyze` 81 issues / 0 error（与基线持平，无新增告警）；`flutter test` 1689 passed / 25 skipped（与基线一致）。

### 5.2 P1 实施记录（2026-11-20）

第 6–8 项 P1 也已落地，改动 1 个文件（`agent_engine.dart`，+25/−0）。

**关键复核修正**：§3.3/§5 曾声称"5 条失败终态缺 flush"，逐条核查后**证实只有 1 条真缺**。判断依据是 flush 的实际触发点——provider 的 `onError` 回调（`:735`）和 `onCompleted`（`:777`）都会调 `_flushStreamingToContent`，并非只有 `onCompleted`：

| 失败终态 | 是否调 onError/onCompleted | 是否真缺 flush |
|---|---|---|
| executor null（:1043） | onError :1041 | ✗ 不缺 |
| `_startTask` catch（:1068） | onError :1092 | ✗ 不缺 |
| 未连接（:1426） | onError :1424 | ✗ 不缺 |
| `_callAI` 异常（:1647） | onError :1644 | ✗ 不缺 |
| cancel（:1109） | onCompleted :1197 | ✗ 不缺 |
| **`_resumeTask` catch（:1349）** | **两者都不调** | **✓ 真缺，已修** |

| 项 | 落地方式 |
|---|---|
| P1-1（修正后） | 仅 `_resumeTask` catch 补 `onError?.call(_friendlyErrorMessage(e))`，触发 flush + 错误状态，与其余失败终态一致 |
| P1-2 | `_resetTransientState`（:902）与 `_finishTask`（:4679）的 `_aiDoneCompleter = null` 前均补 `if (!dc.isCompleted) dc.complete()`，与 cancelTask/pauseTask 一致，消除 awaiter 永久挂起 |
| P1-3 | `_handleAskAction` 的 `choice.isEmpty` 分支加防御：若状态仍为 `waitingConfirm`（非 cancel 的 cancelled / pause 的 paused，正常来源已在前面 return），用 `_finishTask(success:false)` 主动收口，避免异常路径下任务永久悬在等待选择态 |

**未改的点（附理由）**：
- `_callAI` 异常 :1638 的 `_accumulatedMessage = errorMsg`：provider reducer 通过 `onMessage` 独立累积流式正文，engine 侧这个覆盖不影响 flush 内容；改动反而影响"继续对话"的历史，风险超收益。
- §3.2 表中 902/4658 之外，`cancelTask`(:1160)、`pauseTask`(:1236)、流 onDone(:2257) 三处 complete 本就正确，无需动。

**验证**：`flutter analyze` 81 issues / 0 error；`flutter test` 1689 passed / 25 skipped（与基线一致）。

---

## 6. 跨三个文件的统一治理顺序

```
阶段 0（现在）: §5 的 8 个 bug 修复 + 特征化测试安全网
        ↓
阶段 1: provider U1–U6 修补 + removeTab/dispose flush（不改结构）
        ↓
阶段 2: engine 抽叶子模块（Parser → Prompt → EventStore → History），
        同时 provider 引入 AgentScope（两者互不依赖，可并行）
        ↓
阶段 3: engine TerminationGuard 收口 + provider 切换写入路径
        ↓
阶段 4: page SessionState + 分模块拆分（依赖阶段 3 的状态稳定性）
        ↓
阶段 5: page 业务下沉 service + UI 拆分（最后）
```

**不可颠倒的约束**：page 拆分必须等 provider 状态稳定；engine 状态机收口必须等 EventStore 就位；TerminationGuard 必须每引擎独立实例。

---

## 7. 测试安全网

- 现有全量基线：`flutter test` = **1704 passed / 25 skipped**，`flutter analyze` = 81 issues / 0 error。
- `test/agent_*` 约 145 例，其中 `agent_engine_resilience_test.dart` 25 例、`agent_tab_scope_test.dart` 9 例是直接安全网。
- **已补（2026-11-20）**：`test/react_parser_test.dart` 新增 15 例，直接覆盖刚抽出的 `ReActParser.parseReActResponse` 动作分流（execute/finish/ask/tool/空响应/无动作回退/isTaskComplete/复用 parsedEvents）与 `parseAnswerBlock`（围栏防误切、有界截断、无回答返回 null）、`parseReportSections`。这是 ReActParser 拆分的行为锁定安全网。
- **仍存缺口（待 TerminationGuard 落地后补）**：失败终态 finish+flush 的独立断言；"旧命令 record 在 cancel+新任务后返回"回归；"两 scope 同时终态 guard 不串台"用例；`_aiDoneCompleter` 置 null 断言；ask 取消选择终态断言。这些路径深度耦合引擎私有状态，补单测需大量 `ForTesting` 后门，风险超收益，留到 TerminationGuard 收口时一并补。
- **CI 静态检查（已落地）**：`.github/workflows/quality.yml` 在 push/PR main 时跑 analyze + 全量 test；`tools/check_terminal_writes.py` 对终态写入点做**棘轮式**检查（当前基线 10 处合法写入，只增不减）。最终目标「除 TerminationGuard 外禁止直接赋终态」待 TerminationGuard 实现后把基线降到 0 切换为硬禁令——现在直接上硬禁令会误伤 10 处合法路径。

---

## 8. 验证方式与证据

- 三份独立深挖均基于全文 Read + `wc -l`/`grep -n` + 反向调用点搜索；本报告对 4 个最高危结论做了逐行复核：`terminal_page.dart:354–363 + 5135–5162`、`agent_engine.dart:1040–1098`、`agent_provider.dart:405–420 + 2205–2220 + 1524–1558`，全部属实。
- 行号以基线 `7694ae3` 为准；Phase A 已删除页面内重连定时器，故与旧评审报告的 7780 行/旧行号有偏移。
- 前一版文档提到的"855 项测试"是历史快照，当前实测 1689 项。
