# Agent 底部指标栏 / 目标模式 / 命令栏 / 右侧面板 设计

> 状态：**P0–P7 已全部实施并真机复拍**（§6 是交付记录，§6.1–§6.13 是实施期发现与自纠）。本文最初是方案 + 数据可得性核查。
> 参照物：Qoder Desktop 自身 UI（用户提供的两张截图）与 Claude Code 的命令体系。
> 前置阅读：[agent-builtin-tools-timeline-design.md](./agent-builtin-tools-timeline-design.md)（内置工具与过程时间线，已交付）。
> §5 的 8 条发现推翻或改写本节初稿，**以 §5 修订后的 §3 为准**。

**⚠️ 文中 `文件名#L行号` 链接已过期，以符号名为准。** §1 的行号是实施前抓的快照；实施把 `terminal_page.dart` 撑大了 ~350 行，越往后偏得越多。实测漂移（2026-11-01，实施后）：

| 符号 | 文中链接 | 实际行 |
|---|---|---|
| `enum _AiPanelPosition` | L50 | **57** |
| `_aiPanelPosition` 默认值 | L81 | **130** |
| `_updateMobilePosition` | L153-169 | **202** |
| `_loadSettings` | L171-190 | **230** |
| 面板 `LayoutBuilder` 分支 | L709-803 | **784** |
| `_buildAreaDivider` | L1424 | **1501** |
| `_buildAIPanel` / 压缩横幅 | L1585 / L1598 | **1665 / 1678** |
| `_handleSlashCommand` | L2670 | **2994** |
| `_buildBottomBar` / `LiveOperationBar` 调用点 | L2721 / L2747 | **3090 / 3120** |
| `AgentTask` / `stepIndex` | L175 / L197 | 175 / 197（未漂移） |
| `_trimMessages` 的 ctx 预算 | L3524-3539 | **3639 / 3673** |
| `_maybeAutoCompact` / `compact()` | L1001 / L1023 | **1244 / 1266** |
| `LiveOperationBar` / `_buildLiveMeta` | L848 / L988 | **1043 / 1188** |

不逐个回改的原因：下一次编辑又会把它们吹掉，而"改错的链接"比"标了过期的链接"更坏。要定位就用符号名 grep。

---

## 0. 需求与结论

用户诉求拆成 4 件事：

| # | 诉求 | 结论 |
|---|---|---|
| 1 | 底部模块显示 token/步骤使用情况（截图：`16 轮 563 步 · 217 tok/s`、`165M tok · 缓存命中 99.5%`、`44%` 环形） | **步骤可立刻做；token 必须先补数据链路**：现在 token 只落在 trace 文件，进不了 UI。**缓存命中全库无数据来源**，没有就整项不渲染，不显示 0% |
| 2 | `/goal xxx` 目标模式（截图横幅：Status/Objective/Rounds/Activation + pause/edit/delete） | 新状态机 + 跨任务自动续跑。**主要风险是失控自驱**，靠预算 + 无进展检测 + 确认门不被绕过兜住。续跑钩子**不能挂 `onCompleted`**（§5-V1） |
| 3 | 计划/压缩等各种可参考的命令 | `/compact` **已存在**；`/model`、只读、日志导出**已有按钮入口**，做成命令别名即可，不重建 UI。带参数的命令**当前解析不了**（F2），得先修解析 |
| 4 | agent 面板默认从右边展开 | 最便宜：`_AiPanelPosition.right` 已完整实现，只改默认值 + 补持久化（方向与比例现在都不存盘） |

---

## 1. 代码核查事实（F1–F14）

全部实读确认，不是推测。

**面板布局**

- **F1** `_AiPanelPosition {bottom, right}` 已存在（[terminal_page.dart:50](../ai_terminal/lib/pages/terminal_page.dart#L50)），默认值 `bottom`（[:81](../ai_terminal/lib/pages/terminal_page.dart#L81)）。右侧布局 `Row + SizedBox(width: totalW*ratio)` 与底部 `Column + SizedBox(height: totalH*ratio)` 都已实现（[:709-803](../ai_terminal/lib/pages/terminal_page.dart#L709-L803)），分界线上有布局切换按钮（[:1520-1522](../ai_terminal/lib/pages/terminal_page.dart#L1520-L1522)、[:1573-1575](../ai_terminal/lib/pages/terminal_page.dart#L1573-L1575)）。
- **F1b** 持久化只有可见性：`SettingsDao.getCached('aiPanelVisible')`（[:186-188](../ai_terminal/lib/pages/terminal_page.dart#L186-L188)）。**方向与比例 `_aiPanelRatio` 都不落盘**，每次启动回到 `bottom / 0.4`。`_aiPanelPosition` 一共只有 3 个写入点：初值 :81、移动端方向自动选 :164、用户点按钮 :1439。`_updateMobilePosition` 在 `build` 里每帧调用，但开头 `if (!_isMobile) return;`（[:154](../ai_terminal/lib/pages/terminal_page.dart#L154)）→ **桌面端不会被运行中重置**。
- **F1c** `getCached(key)` 缺失返回 `null`（[daos.dart:769-771](../ai_terminal/lib/services/daos.dart#L769-L771)），现有 `terminalFontSize` 已有「null 才用新默认」的写法可照抄（[terminal_page.dart:173-180](../ai_terminal/lib/pages/terminal_page.dart#L173-L180)）。

**命令体系**

- **F2** 斜杠命令基础设施已在，但两处都不支持带参数：
  - 建议浮层要求 `text.startsWith('/') && !text.contains(' ')`（[ai_prompt_input.dart:102](../ai_terminal/lib/widgets/ai_prompt_input.dart#L102)）→ 敲空格浮层消失（可接受）；
  - 处理函数 `final cmd = command.trim().toLowerCase(); switch (cmd)`（[terminal_page.dart:2670](../ai_terminal/lib/pages/terminal_page.dart#L2670)）→ `'/goal 修复nginx'` 匹配不到 case，`default: return false` → **被当普通文本发给 AI 起任务**。必须修：命令名按第一个空格切分，参数保留原样且**不能被 `toLowerCase()` 毁掉**（objective 是用户文本）。
  - 现有命令只有 `/new`、`/compact`（[ai_prompt_input.dart:57-60](../ai_terminal/lib/widgets/ai_prompt_input.dart#L57-L60)）。
- **F2b** 带参数场景的新陷阱：浮层打开时 Enter 走「选中高亮命令」并 `_controller.clear()`（[:204-211](../ai_terminal/lib/widgets/ai_prompt_input.dart#L204-L211)）→ 用户输入 `/go` 后按 Enter 会**清掉草稿去执行高亮项**。已实测推演：`/goal ` 带空格时浮层已隐藏，Enter 正常落到 `_send()`（[:215-221](../ai_terminal/lib/widgets/ai_prompt_input.dart#L215-L221) → [:260-265](../ai_terminal/lib/widgets/ai_prompt_input.dart#L260-L265)）→ **不挡发送**。但加入 `/goal` 候选后必须补规则：**输入含空格（已在写参数）时 Enter 一律发送，不选中候选**。
- **F10** `AIPromptInput._send()` 有 `if (widget.isRunning) return;`（[:256](../ai_terminal/lib/widgets/ai_prompt_input.dart#L256)）→ **任务运行中输入框整个不可用**。所以「暂停目标 / 结束目标」绝不能只做进斜杠命令，必须在横幅上给可点按钮。

**指标数据链路**

- **F3** SSE 解析只看 `choices[0].delta`（[ai_service.dart:173-193](../ai_terminal/lib/services/ai_service.dart#L173-L193) 与 [:389-395](../ai_terminal/lib/services/ai_service.dart#L389-L395)），**顶层 `usage` 从未读取**；请求体也没有 `stream_options.include_usage`（[:109-115](../ai_terminal/lib/services/ai_service.dart#L109-L115)）。好消息：OpenAI 规范里 usage-only 的最后一个 chunk 形如 `choices: []`，现有判断 `choices != null && choices.isNotEmpty` 会**安全跳过**，加 usage 捕获不打断既有流式路径。
- **F4** 现在 token 是**启发式估算**：`TokenEstimator`（[token_estimator.dart:13-66](../ai_terminal/lib/utils/token_estimator.dart#L13-L66)，ASCII 4 字符≈1 token、CJK 1 字符≈1 token）→ 写进 trace 事件（[agent_engine.dart:1489-1513](../ai_terminal/lib/services/agent_engine.dart#L1489-L1513)）→ 只在 `AgentTracer.TaskMetrics` 累加（[agent_tracer.dart:76-77](../ai_terminal/lib/services/agent_tracer.dart#L76-L77)、[:202-204](../ai_terminal/lib/services/agent_tracer.dart#L202-L204)）→ **只落 NDJSON 文件**。**不进 `AgentState`、不进 UI、不入库**。
- **F4b** `TaskMetrics._activeMetrics` 私有，但**已有公开 `AgentTracer.getMetrics(taskId)`**（[:264](../ai_terminal/lib/services/agent_tracer.dart#L264)）可直接读 `aiCallCount`/token 累计；**注意 `endTask` 后 30 秒从表里移除**（[:258-260](../ai_terminal/lib/services/agent_tracer.dart#L258-L260)）→ 只适合读「正在跑的任务」，不能当跨任务累计源。
- **F5** 「步」有现成字段：`AgentTask.stepIndex`（[agent_model.dart:197](../ai_terminal/lib/models/agent_model.dart#L197)），引擎每轮更新（[agent_engine.dart:379](../ai_terminal/lib/services/agent_engine.dart#L379)）。「轮」= AI 调用次数，只在 tracer 的 `TaskMetrics.aiCallCount`（[:71](../ai_terminal/lib/services/agent_tracer.dart#L71)）。
- **F6** 上下文预算已算但**不外露**：`effectiveContextWindow` 兜底 32768（[ai_model_config.dart:55-58](../ai_terminal/lib/models/ai_model_config.dart#L55-L58)）；`_trimMessages` 里 `tokenBudget = contextWindow * 0.7`、`totalTokens = estimateHistory(kept)`，**结果只写日志**（[agent_engine.dart:3524-3539](../ai_terminal/lib/services/agent_engine.dart#L3524-L3539)）。→ 环形百分比的分子分母已在同一处存在，缺的是带出来。
- **F7** 压缩链路完整：阈值 20 轮 / 30000 字符 / 保留 6 轮（[agent_provider.dart:29-32](../ai_terminal/lib/providers/agent_provider.dart#L29-L32)）；`_maybeAutoCompact` 用「未压缩消息对数」当 rounds（[:1001-1018](../ai_terminal/lib/providers/agent_provider.dart#L1001-L1018)）；`compact(hostId)` 公开可调（[:1023](../ai_terminal/lib/providers/agent_provider.dart#L1023)）；`isCompacting` 已有横幅（[agent_state.dart:21](../ai_terminal/lib/models/agent_state.dart#L21) → [terminal_page.dart:1598](../ai_terminal/lib/pages/terminal_page.dart#L1598)）。
- **F8** 缓存命中**全库零来源**：grep `cached_tokens|cache_read|cacheHit` 无任何命中。要显示必须从 `usage.prompt_tokens_details.cached_tokens` 解析，而自定义/本地模型（本项目主要场景）多半不提供。

**已有入口，避免重复造**

- **F9** 底部栏 `LiveOperationBar` 已显示目标/阶段/步数/计时/暂停/停止（[terminal_page.dart:2747-2765](../ai_terminal/lib/pages/terminal_page.dart#L2747-L2765)），其 meta 行已用 `Wrap` 承载 phase/step/elapsed/success/failure/planProgress（[operation_sheet.dart:988-1028](../ai_terminal/lib/widgets/operation_sheet.dart#L988-L1028)）；工具栏已有**模型选择器**、**只读模式**、联网搜索、Runbook、日志对话框、历史（[:2768-2854](../ai_terminal/lib/pages/terminal_page.dart#L2768-L2854)）；只读态由 `toggleReadOnlyMode()` 提供（[agent_provider.dart:916-918](../ai_terminal/lib/providers/agent_provider.dart#L916-L918)）。审计页已有 `_exportLogs()`（[audit_log_page.dart:68](../ai_terminal/lib/pages/audit_log_page.dart#L68)）。
- **F9b** 计划链路已闭环：`ReActStreamParser` 解析 `计划:` 生成 `AgentEvent.plan`（[react_stream_parser.dart:96-103](../ai_terminal/lib/utils/react_stream_parser.dart#L96-L103)、[:292-320](../ai_terminal/lib/utils/react_stream_parser.dart#L292-L320)），引擎维护 `_currentPlan`（[agent_engine.dart:1096-1097](../ai_terminal/lib/services/agent_engine.dart#L1096-L1097)），`PlanPanel` 已在两处渲染（[terminal_page.dart:2474](../ai_terminal/lib/pages/terminal_page.dart#L2474)、[operation_sheet.dart:130](../ai_terminal/lib/widgets/operation_sheet.dart#L130)）。→ **`/plan` 不需要新 UI**。

**工程约束**

- **F11** 状态按 hostId 隔离。`_updateHostState(hostId, updater)`（[agent_provider.dart:305-311](../ai_terminal/lib/providers/agent_provider.dart#L305-L311)）才是正确写法：活跃 host 才 `state =`，否则 `registry.updateState`。`isCompacting` 全程用它（[:1053](../ai_terminal/lib/providers/agent_provider.dart#L1053)、[:1072](../ai_terminal/lib/providers/agent_provider.dart#L1072)、[:1095-1101](../ai_terminal/lib/providers/agent_provider.dart#L1095-L1101)）——**goal 字段照此**。
- **F11b** ⚠️ `AgentNotifier.startTask`（[:692](../ai_terminal/lib/providers/agent_provider.dart#L692)）内部取 `_registry.activeHostId ?? 'local'`（[:721](../ai_terminal/lib/providers/agent_provider.dart#L721)）并裸 `state =`（[:754](../ai_terminal/lib/providers/agent_provider.dart#L754)）→ **跨 tab 自动续跑不能直接复用它**，否则违反 R3 写错 host。
- **F12** 持久化走 `SettingsDao` 的 `settings` KV 表（JSON，[:793-809](../ai_terminal/lib/services/daos.dart#L793-L809)），`aiPanelVisible` 就是这个模式。
- **F13** ⚠️ 修正后：**`onCompleted` 不是终态收敛点**。它有 4 个调用点（[agent_engine.dart:711](../ai_terminal/lib/services/agent_engine.dart#L711) cancel、[:1202](../ai_terminal/lib/services/agent_engine.dart#L1202) maxSteps、[:1206](../ai_terminal/lib/services/agent_engine.dart#L1206) 正常、[:2784](../ai_terminal/lib/services/agent_engine.dart#L2784) `_finishTask`），**且 4 处全部包在「累积文本非空」判断里**；异常失败路径**显式不调**（[:607-608](../ai_terminal/lib/services/agent_engine.dart#L607-L608) 注释说明是为了不污染知识库）。真正的收敛点是 **`AgentEvent.finish` 事件**：8 个发射点覆盖 断连(578/899)、异常(613/845/1064)、取消(705)、maxSteps(1196)、正常完成(2773)，且自带 `finishState`（success/failed/cancelled/interrupted）分类。`pauseTask` 刻意不发 finish（[:720-722](../ai_terminal/lib/services/agent_engine.dart#L720-L722)）——暂停不是终态，正确。
- **F14** `AgentStatus.paused` 存在且 pause/resume 已接线（[terminal_page.dart:2759-2760](../ai_terminal/lib/pages/terminal_page.dart#L2759-L2760)）。

---

## 2. 会引入的缺陷（必须在本次处理）

- **D1｜估算冒充真实值**。把启发式 token 显示成 `165M tok` 就是把估算说成账单，违反本项目「用户可见文案不得夸大/失准」的既定要求。→ 估算值必须带 `≈`，真实值不带；两者不混在同一个数字里。
- **D2｜缓存命中显示 0%**。无数据时显示 `0%` 会被读成「模型没有提示缓存，效果差」。→ **无数据整项不渲染**。
- **D3｜带参数命令被当任务发出去**（F2 现状）。→ 解析层先修，未知命令明确报错而非静默发送。
- **D4｜目标模式绕过安全门**。自动续跑最容易滑向「AI 自己批准自己」。→ 确认门（`waitingConfirm`）在目标模式下**照常阻塞**，超时按已实现的 `confirm_timeout` 归因（不记成用户拒绝），目标进入 paused 而不是继续。
- **D5｜续跑重入清理**（§5-V2）。`_finishTask` 在回调**之后**才做资源清理（[:2786-2822](../ai_terminal/lib/services/agent_engine.dart#L2786-L2822)：读 `_currentTask?.id` 结束 trace、cancel watchdog/streamSub/timer）。若在回调里同步起新任务，这段清理会**作用在新任务上**——新任务刚建就被人拔了线。→ 续跑必须延后到当前同步块结束。

---

## 3. 方案

### 3.1 底部指标栏（Phase M）

**3.1.1 数据来源：先接真 usage，再接 UI**

真实契约是 `abstract AIProvider.chatStream`（[ai_service.dart:24-31](../ai_terminal/lib/services/ai_service.dart#L24-L31)），实现体 OpenAI/Qwen/Ernie（[:93](../ai_terminal/lib/services/ai_service.dart#L93)、[:262](../ai_terminal/lib/services/ai_service.dart#L262)、[:291](../ai_terminal/lib/services/ai_service.dart#L291)），返回 `Future<Stream<String>>`，**没有任何 usage/副作用回调**。

1. 请求体加 `stream_options: {'include_usage': true}`——两处（[:109-115](../ai_terminal/lib/services/ai_service.dart#L109-L115) 与 [:335-339](../ai_terminal/lib/services/ai_service.dart#L335-L339)）。**provider 不支持该字段会 400**，所以按 `AIModelConfig` 开关（默认开、可在模型设置关），失败降级为「不带该字段重试一次」，不能因为统计功能把用户任务打死。
2. 两处 SSE 循环各加 `json['usage']` 分支：`prompt_tokens` / `completion_tokens` / `total_tokens` / `prompt_tokens_details.cached_tokens`。第二处属于 `ErnieProvider.chatStream` 内联循环（[:376-401](../ai_terminal/lib/services/ai_service.dart#L376-L401)），**不是重试代码，两处都得改**。
3. usage 带出的方式：**加可选具名参数，不改返回类型**（改返回类型会牵动每个 await 点）。实施时调用点共 3 处，别漏：`_callAI`（[agent_engine.dart:1281](../ai_terminal/lib/services/agent_engine.dart#L1281)）、**`summarizeMessages` 的第二条独立流**（[:3025](../ai_terminal/lib/services/agent_engine.dart#L3025)）、[chat_provider.dart:192](../ai_terminal/lib/providers/chat_provider.dart#L192)。

**3.1.2 字段矩阵（每个数字必须有出处）**

| 显示项 | 来源 | 无数据时 |
|---|---|---|
| `N 轮` | 运行中：`AgentTracer.getMetrics(taskId).aiCallCount`（F4b）；跨任务累计另存 | 显示 `0 轮`（真值，不是缺数据） |
| `N 步` | `AgentTask.stepIndex`（F5，已有） | `0 步` |
| `N tok/s` | `tokenTotal / elapsedSeconds`，**elapsed 为 0 时不显示**（防除零） | 整项不渲染 |
| `≈N tok` / `N tok` | 有 usage 用真值（不带 `≈`）；无 usage 用 `TokenEstimator` 累计（带 `≈`）——D1 | 不会缺，估算永远可得 |
| `缓存命中 x%` | **仅当** `cached_tokens` 存在时渲染（F8、D2） | 整项不渲染 |
| 环形 `x%` | `min(1, outgoingPromptTokens / effectiveContextWindow)`，即 F6 同一处的两个数 | 未起任务显示 0%（这是真的空上下文） |

分母用 `effectiveContextWindow`，**不用** `_trimMessages` 的 `0.7` 预算——预算是裁剪策略不是窗口。但必须让用户知道：接近满格时引擎已在悄悄丢早期消息，所以 **≥70% 就转警示色**，并在 tooltip 写明「超过 70% 引擎开始丢弃最早的消息」。

**3.1.3 位置与窄面板适配**

**不新开一条带**：直接扩进 `LiveOperationBar._buildLiveMeta` 的现有 `Wrap`（F9b/F9），同一行同类信息，避免两层 Wrap 打架。原稿的「单行不换行」作废（§5-V6）——现有实现本来就会折行，加新约束只会出现两套折行规则互相干扰。
已知的既有溢出点一并修：`LiveOperationBar` 右侧图标按钮组不在 `Flexible` 内（[operation_sheet.dart:957-982](../ai_terminal/lib/widgets/operation_sheet.dart#L957-L982)），窄面板（right 布局 0.4 ≈ 550px）下 Row 自身会溢出。→ 按钮组包 `Flexible`，指标项按优先级 `轮/步 → tok → 环形`，`缓存命中` 与 `tok/s` 在 < 480px 时不构建（`LayoutBuilder` 判定，不是靠 ellipsis 截断）。

### 3.2 目标模式（Phase G）

**3.2.1 状态模型**

```dart
class AgentGoal {
  final String id;
  final String hostId;          // F11：归属 host，不用 activeHostId 代替
  final String objective;       // 用户原文，不做 lowercase
  final AgentGoalStatus status; // active | paused | finished
  final int roundsUsed;
  final int maxRounds;          // 默认 24，上限 256
  final int tokenUsed;          // 跨任务累计（tracer 会 30s 淘汰，F4b）
  final DateTime createdAt;
  final String? note;           // 结束时写原因
}
```
存盘走 `SettingsDao.set('agentGoal:<hostId>', json)`（F12）。`AgentState` 加 `goal` 字段 + `copyWith` 需要 `clearGoal` 哨兵（照现有 `clearSummary` 写法，[agent_state.dart:66-87](../ai_terminal/lib/models/agent_state.dart#L66-L87)），否则无法置 null。

**3.2.2 命令语法**

| 命令 | 行为 |
|---|---|
| `/goal <objective>` | 创建并激活。已有目标时**拒绝并提示**，不静默覆盖 |
| `/goal` | 播报当前目标（Status / Rounds / 剩余），无目标时提示用法 |
| `/goal pause` / `/goal resume` | 暂停 / 恢复。resume 前检查预算，耗尽则拒绝并提示 `/goal edit` 提高上限 |
| `/goal edit <text>` | 改 objective（**保留 roundsUsed**，不重置预算——防止用编辑刷预算） |
| `/goal done` | 手动收尾，status=finished |

子命令词表与 objective 冲突消歧（**实施后修订版**，理由见 §6.1-2）：`edit` 是唯一带参数的子命令，后面整句是新目标；`pause` / `resume` / `done` / `clear` 必须**独占整句**才算指令，后面还有正文就退回成目标。所以 `/goal pause` 是指令，`/goal pause the server` 是目标。宁可多建一个可见的目标（横幅看得见、`/goal clear` 能撤销），也不把用户输入静默吞成指令。

**3.2.3 UI**

面板顶部（压缩横幅同层，[terminal_page.dart:1598](../ai_terminal/lib/pages/terminal_page.dart#L1598) 下方）一条目标横幅，对齐截图字段：

```
● 进行中的目标   <objective 单行省略>
状态 active ｜ 轮次 3/24 ｜ ≈12k tok        [暂停] [编辑] [结束]
```

三个按钮**必须有**（F10：运行中输入框不可用，斜杠命令点不到）。`编辑` 弹对话框改 objective；`结束` 需二次确认（避免误点丢掉长期目标）。

**3.2.4 自动续跑（本节是实现核心）**

**钩子 = provider 的 `onEvent` 收到 `AgentEvent.finish`**（F13 修正后），不是 `onCompleted`。理由：finish 事件覆盖全部 8 条终态路径并自带 `finishState` 分类，而 `onCompleted` 漏掉所有异常路径和空输出路径——用它做续跑会出现「失败了却再也不动」。

判定顺序（每步都必须可测）：
`finishState` 已知 → generation/任务归属检查 → 目标存在且 `status == active` → 预算未耗尽 → 上一轮有进展 → 连接仍在 → 才排续跑。

**延后执行**（D5）：续跑不得在 finish 事件的同步回调里发起。用 `scheduleMicrotask`（或零延迟 Timer，须在 dispose 时取消）把发起推到当前同步块之后，绕开 `_finishTask` 尾部的资源清理。

| finishState / 情形 | 目标动作 | 理由 |
|---|---|---|
| `success`（AI 说 finish）且目标未宣告达成 | 续跑，`roundsUsed + 1` | 模型只是本轮收尾，不等于目标达成 |
| 目标语义完成（横幅「标记完成」或模型输出完成标记） | finished | 达成 |
| `failed`（异常/网络） | **paused** + note | 连续失败还硬续跑就是烧 token；用户可 resume |
| `cancelled`（用户点停止） | **paused** | 用户意图优先，绝不自动复活 |
| `interrupted`（maxSteps） | 续跑，计一轮 | 属于「有进展未做完」 |
| `confirm_timeout`（§P2-14 已实现的归因） | **paused** | 超时说明没人看管，自动续跑会反复超时空转 |
| 预算耗尽 `roundsUsed == maxRounds` | finished + note「轮次预算耗尽」 | 硬止损（R2 的无界问题在此表现为无界续跑） |
| 连续 2 轮 `stepIndex` 无增量 | **paused** + note「无进展」 | 防原地打转 |
| 该 host 已断连 | **paused** + note | 不给引擎发注定失败的任务 |

**不变量**：
- 续跑 prompt = objective + 最近结论 + 剩余预算，**不拼历史全文**（避免撑爆上下文）。
- 目标不改变确认门语义（D4），只读模式照常生效。
- 手动发消息时目标不暂停、照常计数，但**手动任务不计入 `roundsUsed`**（只有目标驱动的任务计数），否则用户追问会把预算吃掉。
- 续跑发起走**显式带 hostId 的内部路径**，不用 `AgentNotifier.startTask`（F11b）。
- 切 tab / 换 host 先 flush 流式 → 清回调 → cancel（R2/R3）；**清的是回调不是目标**，目标是 host 级持久状态，跨 tab 存在。

### 3.3 命令补齐（Phase C）

| 命令 | 与现状关系 | 做什么 |
|---|---|---|
| `/compact` | **已存在** | 加运行中守卫（§5-V8） |
| `/new` | **已存在** | 不动 |
| `/plan <objective>` | 新 | 起任务前临时置只读（F9 已有 `toggleReadOnlyMode`），要求只输出 `计划:` 块；**结束后恢复原值而不是恢复 false**（原来就是只读的用户不能被解锁）。复用 `PlanStep`/`PlanPanel`（F9b），不新做 UI |
| `/model <名称>` | 已有下拉（F9） | 纯别名；参数缺失/歧义就列候选，不猜 |
| `/permission` | 已有锁按钮（F9） | 纯别名 `toggleReadOnlyMode` + 播报当前态 |
| `/export` | 日志对话框已有（F9） | 导出当前会话 + 给出 trace NDJSON 路径（[agent_tracer.dart:138-146](../ai_terminal/lib/services/agent_tracer.dart#L138-L146)）；不新造格式 |
| `/help` | 新 | 文本播报命令表（浮层列 8 条会挤） |

不做（明确排除）：截图里的「添加 文件/反馈」（附件引用体系，需要新输入子系统）、自定义命令目录、`/resume` 会话恢复。

### 3.4 面板默认右侧（Phase P）

1. 默认值 `bottom` → `right`，**仅桌面端**（F1b：`_updateMobilePosition` 有 `!_isMobile` 早退，桌面不会被重置）。
2. 补持久化：`aiPanelPosition`、`aiPanelRatio` 落 `SettingsDao`，在 `_loadSettings`（[:171-190](../ai_terminal/lib/pages/terminal_page.dart#L171-L190)）读取，照 `terminalFontSize` 的 null 分支（F1c）——**没存过才用新默认 `right`**，显式存过 `bottom` 的用户保持 bottom。
3. **移动端不写方向 key**（§5-V7）：`_updateMobilePosition` 每帧覆盖，存了竖屏也会被改回 bottom。持久化只在桌面用户显式点按钮时发生（:1439）。
4. `_aiPanelRatio` 沿用 0.15–0.7 夹取（[:83-84](../ai_terminal/lib/pages/terminal_page.dart#L83-L84)）；窄面板对指标带的压力见 §3.1.3。

---

## 4. 实施顺序与验收

| Phase | 内容 | 完成判据（必须「改坏就变红」） |
|---|---|---|
| P0 | 面板默认 right + 方向/比例持久化（含移动端不写） | widget 测试：首次启动=right；预置 `bottom` 后保持 bottom；预置 ratio 被夹取到 0.15–0.7 |
| P1 | 斜杠命令解析（名/参分离 + 子命令消歧） | 测试：`/goal 清理日志` 不被当任务发送、参数大小写不被毁、`/etc/nginx 目录权限` 仍按文本发给模型。**两条验收原文在实施中撤销**：①"未知命令报错"会让绝对路径没法提交（改成"只认注册过的命令名"）；②"含空格时 Enter 一律发送"经核实原本就成立，未加分支 |
| P2 | usage 真实解析 + `stream_options` 降级重试（3 个调用点全覆盖） | 逐项对账见 §6.11：`usage` 字段值 8 例单测 ✓；400 降级**只测了判定规则**（3 例，破坏性验证过）；"`choices: []` 尾 chunk 不影响文本投递"**无单测**，改以真机 6 轮续跑为证据 |
| P3 | 指标带 UI（扩进 LiveOperationBar）+ `Flexible` 溢出修复 | widget 测试：无 usage 显示 `≈`、有 usage 不显示；`cached_tokens` 缺失时该项不渲染；elapsed=0 无 tok/s；窄宽度无 overflow 异常 |
| P4 | `AgentGoal` 模型 + 存盘 + 横幅 + 三按钮 | 测试：预算耗尽→finished+note；cancel→paused 不复活；resume 超预算被拒；子命令/objective 消歧；跨 tab 目标仍在 |
| P5 | 自动续跑（finish 事件钩子 + microtask 延后）+ 终态矩阵 9 行 | 每行一个测试 ✓（goal_continuation_test 24 例）；"断言确认门仍阻塞"落在 `hadConfirmTimeout → pause` 这一行 + 既有 tool_contract_test 的确认门用例，**未新写"目标模式不绕过确认门"的独立测试**；~~必须先有一条能复现 D5 重入的测试~~ **这条没兑现，原因与处置见 §6.10** |
| P6 | `/plan` `/model` `/permission` `/export` `/help` + `/compact` 运行中守卫 | 每命令一条路由测试；`/plan` 断言结束后只读态**恢复原值**；`/compact` 在 isRunning 时被拒 |
| P7 | 真机复拍（Windows） | 截图确认横幅三行同屏、指标带在 right 布局下不溢出、目标暂停后确实不再起新任务 |

每 phase 收尾跑 `flutter analyze` / `flutter test`（基线：31 issues / 0 error，500 passed / 16 skipped）。

---

## 5. 二次逻辑验证（实施前，逐条对代码反查）

| # | 初稿的假设 | 反查结果 | 处置 |
|---|---|---|---|
| **V1** | 「所有终止路径都汇到 `onCompleted`」（§1 F13 初稿） | **错**。4 个调用点全部包在「累积文本非空」里（:711/:1202/:1206/:2784），异常失败路径**显式不调**（:607-608 注释：怕污染知识库） | 续跑钩子改为 `AgentEvent.finish`（8 发射点，自带 finishState）→ §3.2.4 |
| **V2** | 在 `onCompleted` 里直接 `startTask` 续跑 | **错，且是硬 bug**。`_finishTask` 在回调之后才读 `_currentTask?.id` 收尾 trace 并 cancel watchdog/streamSub/completer/timer（:2786-2822）；同步重入会让这段清理作用在**新任务**上 | 新增 D5；续跑用 microtask 延后 → §3.2.4 |
| **V3** | 「grep `callStream(` 的每个调用点」 | **该方法名不存在**，真实是 `AIProvider.chatStream`（:24-31）；调用点 3 处含易漏的 `summarizeMessages`（engine:3025） | §3.1.1 改写，显式列 3 个调用点 |
| **V4** | 第二处 SSE 循环是「非流式/重试」 | **错**，那是 `ErnieProvider.chatStream` 的实现（:376-401），请求体也有两处 | 两处都要改 → §3.1.1 |
| **V5** | 「避开新建 Hive 类以免踩 R8 adapter」 | **前提过期**：项目已迁 SQLite，全库 `Hive.registerAdapter`/`HiveField` 零命中，仅 [db_init.dart:11](../ai_terminal/lib/core/db_init.dart#L11) 注释写「替代 HiveInit」。→ **AGENTS.md 的「Local storage: Hive (generated adapters) + build_runner」已与代码不符** | 结论（用 SettingsDao KV）不变，理由换成「已有 KV 模式」。AGENTS.md 失真单独报告用户 |
| **V6** | 指标带「单行不换行」 | **与现有实现冲突**：`_buildLiveMeta` 返回 `Wrap`（:1022），同层再设一套不换行规则会出现两套折行逻辑打架；且图标按钮组不在 Flexible 内是既有溢出点 | 改为「扩进现有 Wrap + 修 Flexible」→ §3.1.3 |
| **V7** | 移动端「保留按方向自动选」并同时持久化 | **冲突**：`_updateMobilePosition` 每帧执行并覆盖（build:606 → :153-169），竖屏会把存进去的 right 改回 bottom | 移动端不写方向 key → §3.4 第 3 条 |
| **V8** | `/plan`、`/compact` 可随时触发 | **有洞**：`compact()` 无 `isRunning` 守卫（:1023-1032 只有 convId/engine/isCompacting/条数），运行中调用会起**第二条无 cancelToken 的流**（engine:3025）并 `engine.restoreHistory()`（:1120）——在 ReAct 循环存活时重写 `_conversationHistory`。现网难触发只因输入框运行中禁用（F10）；目标模式自动续跑会把这个窗口打开 | `/compact` 加运行中守卫（P6）；目标续跑期间禁止手动 compact 并发 → §3.3 |

**核对为真、无需改动的假设**：F1/F1b/F1c（面板只有 3 个写入点、桌面不被重置、`getCached` 缺失返回 null）、F2（lowercase 整串导致带参命令落到 default）、F3（空 `choices` 会被安全跳过）、F4/F4b/F5/F6/F7/F8（token 只在 trace、`getMetrics` 公开但 30s 淘汰、stepIndex 现成、ctx 比例只在日志、缓存命中零来源）、F9/F9b（模型/只读/日志入口已有，plan 链路已闭环，`/plan` 不需新 UI）、F10、F11（`_updateHostState` 是正解）、`AgentNotifier.startTask` 用 activeHostId + 裸 `state =`。

**方法记录**：本轮 8 条发现里 5 条推翻初稿（V1/V2/V3/V6/V7），其中 V1+V2 若不查就直接实现，会做出「失败后目标静默停摆」和「新任务刚建就被上一个任务的清理拔线」两个真 bug；V5 顺带查出 AGENTS.md 与代码不符（Hive 已不存在）。

---

## 6. 交付记录

> **阅读顺序提示**：§6.2–§6.13 是分批插入的，落点不在文件末尾，**本节小节的物理顺序与编号不一致**（内容不缺，只是顺序乱）。按编号读应为：
> 6 表头(P0/P1) → 6.1 实施期发现 → 6 表头(P2/P3) → 6.2–6.5 → 6.4 补齐 → 6.6 常驻条 → 6.7 新缺陷 → 6.8 无进展根因 → 6.9 验收回查 → 6.10 D5 → 6.11 P2 对账 → 6.12 README → 6.13 恢复目标。
> 之所以不重排：整节重排要重写 400 行，而这次会话里我已经有两次"编辑吃掉了不该动的内容"的记录（§6.9 的测试断言、§6 的锚点标题）。留一条顺序说明比冒丢内容的风险更划算。

| Phase | 状态 | 实现位置 | 验证 |
|---|---|---|---|
| **P0** 面板默认右侧 + 方向/比例持久化 | 已完成 | `saveAiPanelLayout()`（[terminal_page.dart:52](../ai_terminal/lib/pages/terminal_page.dart#L52)）；默认值改 right（:96）；`_loadSettings` 读两键（:200-215）；分界线按钮 onTap 存方向、拖拽 `onPanEnd` 存比例 | [test/ai_panel_layout_persistence_test.dart](../ai_terminal/test/ai_panel_layout_persistence_test.dart) 3 例。**守卫非空转已实测**：把 `if (savePosition && !isMobile)` 临时改成 `if (true)` → 2 例转红（`Expected: bottom / Actual: right`），随后还原 |
| **P1** 斜杠命令名/参数分离 | 已完成 | 新增 [lib/utils/slash_command.dart](../ai_terminal/lib/utils/slash_command.dart)；`_handleSlashCommand` 改用 `parseSlashCommand`，不再整串 lowercase | [test/slash_command_test.dart](../ai_terminal/test/slash_command_test.dart) 9 例：参数大小写保留、`/etc/nginx 目录权限` 不误判为命令、`/goalx` 前缀不误判、裸命令与尾随空格、`/new` `/compact` 未回退 |

全量门槛：`flutter analyze` 31 issues / 0 error（= 基线）；`flutter test` **512 passed / 16 skipped**（基线 500，新增 12 例）。

| **P2** 真实 usage 解析 | 已完成 | [lib/models/token_usage.dart](../ai_terminal/lib/models/token_usage.dart)（`TokenUsage.tryParse` + `formatTokenCount`）；`AIProvider.chatStream` 新增可选 `onUsage`（4 处签名：抽象 + OpenAI/Qwen/Ernie，Qwen 转发）；OpenAI 与 Ernie 两处 SSE 循环各加 usage 分支；`stream_options.include_usage` 经 `_postChatCompletions` 附加，**400 时去掉该字段自动重试一次** | [test/token_usage_test.dart](../ai_terminal/test/token_usage_test.dart) 8 例（含「给了 0 ≠ 没给」`hasAny`、非数字值不认、`prompt_tokens_details` 类型错误仍解析其余） |
| **P3** 引擎计量 + 指标带 UI | 已完成 | 引擎按轮记 `_tokReal`/`_tokEstimated` 两本账 + `_recordUsage` 覆盖回退；新增 5 个 `@visibleForTesting` 入口；`AgentTask` 加 `rounds`/`tokenTotal`/`hasEstimatedTokens`/`cacheHitPercent`/`contextTokens`（该类无 toJson，纯内存，无需迁移）；`LiveOperationBar._buildLiveMeta` 现有 `Wrap` 内加 轮/tok/速率/缓存/占用环，分母由 terminal_page 传 `contextWindow` | [test/agent_metrics_test.dart](../ai_terminal/test/agent_metrics_test.dart) 10 例 + [operation_sheet_widget_test.dart](../ai_terminal/test/operation_sheet_widget_test.dart) 「LiveOperationBar 指标带」8 例 |

**实施中对 §3.1.2 的两处收紧**（都是测试逼出来的，不是原设计想清楚的）：

1. **缓存命中率的分母必须是「报告过 cached_tokens 的那些轮」**。原设计写 `cached / prompt`，实现时第一版把「部分已知」除以「全部」，长任务里会显示一个系统性偏低的命中率——比说未知更糟。改成 `_promptRealWithCached` 单独做分母，一条测试（第 1 轮不给 cached、第 2 轮给）直接把这个错误钉住：期望 50%，错误实现给 25%。
2. **`tok/s` 只在纯实测时显示**。估算 token 除以真实秒数会得到一个「看着像实测」的速率，而速率本身没法带 `≈`；宁可少给一项，不给假数。

另外两处小偏差：占用环用 `round()` 而非整除（14000/32000 → 44%，整除会给 43%）；`stream_options` 的开关没做成 `AIModelConfig` 字段（那要加列 + 迁移 + 设置页），改为「自动附上、400 自动降级」，用户不需要知道这个开关存在。

**R9 现场验证**：给 `chatStream` 加一个可选命名参数后，`flutter analyze` 立刻报出 4 处 `invalid_override`——`tool_contract_test`、`docker_e2e_test`、`file_encoding_e2e_test`、`agent_engine_resilience_test` 里各有一个 `implements AIProvider` 的测试替身。这正是 AGENTS.md「改契约必须 grep 全部实现方」的由来；只 grep 调用点会漏掉实现方。

全量门槛（P0–P3 收口）：`flutter analyze` **31 issues / 0 error**（= 基线）；`flutter test` **538 passed / 16 skipped**（基线 500，新增 38 例）。P4–P7 未开始。

| **P4** 目标模型/存盘/横幅 | 已完成 | [lib/models/agent_goal.dart](../ai_terminal/lib/models/agent_goal.dart)；`AgentState.goal` + `clearGoal` 哨兵；provider 侧 `_goals` + `SettingsDao` 键 `agentGoal:<hostId>` + `_mirrorGoal` 挂在 `_setupEngineCallbacks`；[lib/widgets/agent_goal_banner.dart](../ai_terminal/lib/widgets/agent_goal_banner.dart)（进行中/已暂停/已结束三态，暂停·编辑·结束都在横幅上） | [test/agent_goal_banner_test.dart](../ai_terminal/test/agent_goal_banner_test.dart) 6 例（含「未确认前不结束」与「已结束显示清除而非剩几轮」）；`AgentGoal` 读盘约束 4 例在 goal_continuation_test |
| **P5** 自动续跑与终态矩阵 | 已完成（未真机验证） | [lib/utils/goal_continuation.dart](../ai_terminal/lib/utils/goal_continuation.dart) 纯函数承载 9 行矩阵 + `shouldScheduleGoalRound` 三条排队守卫；provider 在 `onEvent` 收到 finish 时决策，`scheduleMicrotask` 延后发起（D5）；引擎新增 `hadConfirmTimeout` latch（3 个超时点都置位） | [test/goal_continuation_test.dart](../ai_terminal/test/goal_continuation_test.dart) 24 例：取消优先于预算、达成声明优先于取消、超时/断连/切走/失败一律 paused、预算耗尽 finished、无进展两轮才停、去重与引擎忙 |
| **P6** 命令补齐与 compact 守卫 | 已完成 | `/plan`（临时只读、还原**原值**）、`/model`（`matchModelNames` 精确优先，歧义列候选不猜）、`/permission`、`/help`；`/compact` 加运行中守卫（§5-V8）；`_sendToAgent` 抽出，onSend 与 /goal 首轮共用同一执行器绑定 | 路由测试落在纯函数层：slash_command_test 新增 12 例（子命令消歧 6 + matchModelNames 6）。`_handleSlashCommand` 本身在页面私有方法里，未做 widget 级路由测试 |

全量门槛（P0–P6 收口）：`flutter analyze` **31 issues / 0 error**（= 基线）；`flutter test` **580 passed / 16 skipped**（基线 500，新增 80 例）。

### 6.1 实施期发现（写码后才暴露的，§3/§5 都没预见）

1. **`Flexible` 不能放进 `Wrap`**。横幅第一次跑测就炸了两条——都带 note，正好是唯一走 `Flexible` 分支的形态。改成 `ConstrainedBox(maxWidth: 260)` + ellipsis。失败分布本身是证据：不带 note 的用例全绿。
2. **`/goal pause the server` 的消歧规则 §3.2.2 自相矛盾**：文档前半句说它是目标，后半句的规则（"第一个 token 恰好等于子命令词"）会把它判成指令。实现取更安全的一侧：**无参子命令必须独占整句**，否则退回目标文本。宁可多建一个可见的目标（横幅能看见、`/goal clear` 能撤销），也不把用户输入静默吞成指令。
3. **`onCompleted` 的替代钩子比预想的更省事**：provider 的 `onEvent` 本来就在跑状态更新，finish 分支加在其后，`hostState.currentTask` 正是刚结束的那个任务，直接拿来当去重键。
4. **续跑去重与"引擎忙"两条守卫最初写在 provider 里无法测**，抽成 `shouldScheduleGoalRound` 后才有 4 条测试——这正是 §5-V1 那类"钩子选错就静默停摆"的余波：钩子对了，守卫也得可测才算闭环。
5. **`finally { if (!mounted) return; }` 触发 `control_flow_in_finally`**：finally 里 return 会吞掉正常返回路径，`/plan` 的只读还原可能不做。改成 `if (mounted) {...}`，并在注释里说明"页面已销毁时不还原——留在只读是安全方向"。

### 6.2 P7 真机复拍（Windows，2026-11-01）

跑的是 `flutter build windows` 的 Release 产物，本地终端 + 已配置的 Local Agnes 模型，目标用 `/goal 查看当前目录文件数量`（只读型目标）。

**已证实可用**：

- 面板默认**右侧**展开 ✓（§3.4）
- `/goal xxx` 立刻建目标并**自动起第一轮**：横幅「● 进行中的目标 查看当前目录文件数量 / 轮次 0/24 剩 24 轮」+ 编辑·暂停·结束三个按钮同屏 ✓
- 指标带真实渲染：`检查环境 第 1 步 32s 1轮 11.6k tok ↗360 tok/s ⬇上下文 35%` ✓。**`11.6k tok` 没带 `≈`**——说明本地 provider 确实回了 `usage`，`stream_options.include_usage` 生效，真实值路径在真机上通了
- 取消即暂停、不复活：点停止后横幅转「已暂停的目标 … 你停止了任务，目标已暂停」，按钮换成 编辑/恢复/结束 ✓（§3.2.4 的 `user_cancelled` 行）
- 结束目标有二次确认，文案准确不夸大（"目标会被标记为结束，正在运行的任务不受影响"）✓；确认后横幅消失，记录清除 ✓

**拍到但初稿没想到的缺陷**：模型把「目标已达成」写进了 `命令:` 块，于是被丢进 PowerShell，终端里留下 `CommandNotFoundException`。提示词要求"单独一行输出"，模型照做了——但做成了命令。

修复两处：① 提示词改成"只在「回答:」正文里写，这一行**不是命令**，绝不能放进 命令: 块或工具参数里"；② 执行侧加硬守卫 `isGoalMarkerOnlyCommand`（整条命令剥掉引号/括号/标点后恰好等于标记才拦），在 `_executeCommand` 入口返回一条解释性 observation 而不是真去跑。守卫是纯函数，3 条测试覆盖（含 `echo 目标已达成` 这类正常命令**不该**被误杀）。

**未复拍**：上述修复是在这次跑完之后才提交的，**修好的包没有再上真机**。重跑一次 `/goal` 只能确认不崩，标记是否还会被写成命令取决于模型当轮输出，不可稳定复现。

### 6.3 修复后重打包的复拍（同一台机器，Release）

- 重启后**目标横幅不再出现**：`clearGoal` 真的落盘了。应用库是 SQLCipher 加密的，读不到文件，所以"重启后看不看得到"是唯一可靠的存盘往返证据。
- `/help` 在真机上渲染出完整命令表（`/new /compact /goal /plan /model /permission /help`），且**没有被当成任务发出去**——输入框为空、会话里没有新的用户气泡。这条同时验证了 §1 F2 的解析改造在 UI 层生效。
- 面板仍是右侧默认 ✓。
- **仍未复拍**：达成标记守卫的实际拦截效果。它只有当模型再次把标记写成命令时才会触发，而那是模型行为、不可稳定复现；守卫本身有 3 条纯函数测试托底。

### 6.4 补齐与两处"设计写了但决定不做"

**补齐**：`/export`（§3.3 列了、P6 首轮漏了）→ [conversation_export.dart](../ai_terminal/lib/utils/conversation_export.dart) 把会话拼成纯文本复制进剪贴板，并给出 tracer 的 NDJSON 路径（新增 `AgentTracer.tracePath()`）。不弹保存框、不新造格式。4 条测试（含"仍在流式时 content 为空，得用 streamingContent 兜底"）。

**决定不做，并说明理由**：

1. **§3.1.3 的「图标按钮组不在 Flexible 内是既有溢出点，一并修」——我第一轮判成"不成立"，那个判断是错的**。补 §4-P3 的窄宽度验收测试时，220px 下确实炸出 `A RenderFlex overflowed by 32 pixels on the right`。只是**溢出点不在按钮组**：按钮是固定尺寸且与 `Expanded` 同排，不会顶出去；真正的元凶是我自己加的**上下文占用环**——`mainAxisSize.min` 的 Row 里那个不可缩的 `Text('上下文 100%')` 放进 `Wrap` 后，超过行宽就整行顶出。修法是把环的标签包进 `Flexible` + ellipsis。测试从红到绿，非空转已验证。（按钮部分的原判断仍然成立，未改。）
2. **§3.1.3 的「<480px 主动隐藏 缓存命中/tok·s」——没必要**。`Wrap` 本来就会折行，隐藏逻辑要再引入 `LayoutBuilder` 与一套第二优先级规则，收益只是"少一行"。留作后续：若真出现两行难看，再按宽度裁剪。

**P3 已知边界仍然成立**（§6 末尾）：指标带随任务结束消失，因为 `LiveOperationBar` 只在 running/paused/waitingConfirm 时渲染。要常驻需把计量降到会话级，属独立决策。

全量门槛（P0–P7 + 补齐收口）：`flutter analyze` **31 issues / 0 error**（= 基线）；`flutter test` **587 passed / 16 skipped**（基线 500，新增 87 例）。

### 6.5 自动续跑的真机验证（第三轮复拍）与它抓出的缺陷

前两轮都没能验到"finish → 续跑"这条链（第一轮是 `/goal` 命令直接起的任务，第二轮在任务结束前就被我停了）。第三轮换成开放式目标 `/goal 持续观察本地TCP端口占用变化`，跑满两轮：

- **续跑真的发生了**：会话里出现第二条「【目标模式 · 自动续跑】第 2/24 轮」的用户消息，横幅轮次从 0/24 变 1/24 → `finish` 事件钩子 + `scheduleMicrotask` + 带 hostId 的发起路径整条打通，且没有踩 §5-V2 的重入清理（第二轮正常跑完并出了结论卡片）。
- **但目标两轮就把自己暂停了**：横幅显示「轮次 1/24 剩 23 轮 · 连续 2 轮没有新进展，目标已暂停」，而两轮各执行了 4 条命令。

**根因**：无进展检测比的是 `AgentTask.stepIndex`，而它是**每个任务各自从 1 计**的，跨轮比较没有意义——两轮步数相同就判成"无进展"。设计 §3.2.4 那行"连续 2 轮 stepIndex 无增量"从写下起就是错的，单测也照着错的语义写（`5 → 5` 判无进展），所以 24 例全绿却挡不住真机上的误判。

**修正**：判据改成"本轮有没有真的动手"——`commandsRun = successCount + failureCount`，为 0 才算无进展。`AgentGoal.lastStepIndex` 随之改名 `lastRoundCommands`（存的就是这个数），provider 传命令数而非步数。新增一条回归测试专门钉住"两轮各跑 4 条命令不算无进展"，并把"一条命令都没跑"的两轮停止路径保留。

门槛复测：`flutter analyze` 31 issues / 0 error；`flutter test` **588 passed / 16 skipped**。

**验证后遗留**：这台机器的应用库里留着那个已暂停的目标（`agentGoal:local`），下次启动横幅会出现，按横幅上的 结束 → 清除记录 即可移除；它是 paused，不会自动跑。

### 6.6 常驻指标条（补 §6 的那条边界）

参照 UI 的底部模块是常驻的，而指标原先只在任务运行/暂停/待确认时随 `LiveOperationBar` 出现。补齐做法：

- 把指标项抽成共享的 `buildMetricItems(...)`，`LiveOperationBar` 与新的 `AgentMetricsBar` 同用一套规则。**不抽就会漂**：`≈`、"缺数据整项不渲染"、"速率只在全实测时给"这三条判断各写两遍，两个界面迟早互相矛盾。
- `AgentMetricsBar` 只在终态接管同一个位置（`!isRunning && status != paused && != waitingConfirm`），与运行条互斥，不会同时显示两遍数字。
- 门槛：`flutter analyze` 31 issues / 0 error；`flutter test` **592 passed / 16 skipped**（新增 4 例覆盖常驻条：完成态保留轮/token/环、取消态文案、无计量时不硬凑、含估算仍带 ≈）。
- **终态接管这一帧没拍到**：真机上任务一直停在"等待选择"（属于 waitingConfirm，按规则仍由运行条显示），所以"运行条→常驻条"的切换只在测试里成立，界面切换瞬间未留证。

### 6.7 这轮真机跑出来的两个新问题（**两者已于 §6.17 修复**；原文保留当时的判断，含两处后来被实测否证的猜测）

1. **PowerShell 包装器的退出码标记失效，每条 cmdlet 命令白等 60 秒并被记成失败**。包装器发的是 `… ; echo "EXITCODE_n:$LASTEXITCODE"`，而 `$LASTEXITCODE` 只对**原生命令**生效，`Measure-Object` / `Select-Object` 这类 cmdlet 不设置它 → 终端里回显的是 `EXITCODE_4:`（冒号后为空）。按 AGENTS.md R8 的正确写法（必须匹配 `EXITCODE_n:\d+`）检测器拒绝空值是对的，于是等满 60s 超时。证据：面板显示"0 成功 4 失败"，而终端里 13、目录清单、True 全都正确打出来了。这不是计量或目标模式的问题，是本地 PTY 执行链的问题，要单独修（换不依赖 `$LASTEXITCODE` 的哨兵，或 cmdlet 后强制跑一次原生命令取码）。
2. **`tok/s` 会把"等人"的时间算进去**。任务停在"等待选择"期间耗时继续累加，速率从 215 tok/s 掉到 174 tok/s——数字没算错，但会把"用户在思考"显示成"模型变慢"。要修就得把等待用户确认/选择的时段从分母里剔掉。

### 6.8 无进展误判的**真**根因（第三轮复拍才挖到，前两轮的"修复"都没打中）

第四轮复拍：常驻指标条如期出现（`完成 2m30s 10轮 592.5k tok 3950 tok/s 上下文 100%`），但目标**仍然**在轮次 1/24 就报「连续 2 轮没有新进展，目标已暂停」——而同一屏的运行条明明显示 `6 成功`。

改判定量（stepIndex → commandsRun）没解决问题，说明**取数的那只手就是错的**。查 `_updateHostState` 得到确证：

```
if (_registry.isActive(hostId)) { state = updater(state); }   // 活跃 host 只写 state
else { _registry.updateState(hostId, updater); }              // 非活跃才写注册表
```

而 `getState(hostId) => _states[hostId]` 读的是注册表那份。`startTask` 与 `onTaskUpdated` 对活跃 host 全是直接 `state =`，**注册表里那份从来不被更新**（可能压根没有该 key）。所以 `_registry.getState(activeHost)?.currentTask` 恒为 null：

- 第一版误判（比 stepIndex）：两侧都是 null → 0 > 0 永假 → 判无进展；
- 第二版误判（比 commandsRun）：`null?.successCount ?? 0` + `null?.failureCount ?? 0` = 0 → 还是判无进展。

**同一个根因造出两次"已修复"的假象**，而 24 例纯函数测试两次都全绿——因为决策函数本身没错，错的是喂给它的参数。修复：按 host 取对来源（活跃 host 读 `state.currentTask`，非活跃读注册表），去重用的 `taskId` 同样改过来（它此前也恒为 null，等于**续跑去重一直没生效**，只是被"取消+异常只发一个 finish"掩盖住了）。

**取证方式说明**：这一条不是猜的。`_updateHostState` 的分支与 `getState` 的读源都是实读代码所得（[agent_provider.dart:308-314](../ai_terminal/lib/providers/agent_provider.dart#L308-L314)、[agent_host_registry.dart:19](../ai_terminal/lib/services/agent_host_registry.dart#L19)），且能同时解释两轮复拍的全部现象。

**修复后已复验（第五轮复拍，同一 Release 包）**：同一个开放式目标连跑 **6 轮**，横幅一路走到 `轮次 4/24 剩 20 轮` 仍在「进行中的目标」，**再没出现"连续 2 轮没有新进展"**——修复前它停在 1/24。顺带把 §6.6 欠的那一帧也拍到了：停止任务后运行条消失、**常驻指标条接管同一位置**显示 `已取消 22s 2轮 60.2k tok 2734 tok/s 上下文 100%`；`/goal clear` 在停止后提交成功（"目标记录已清除"，横幅消失）。

一个复拍中反复用到的操作事实：**任务运行中输入框是禁用的**（F10），所以 `/goal clear` 这类命令必须先停止任务才能提交；这也是横幅必须自带 暂停/结束 按钮的原因。

门槛复测：`flutter analyze` 31 issues / 0 error；`flutter test` 592 passed / 16 skipped。

### 6.9 逐条回查 §4 验收表后补的三行（都发现"写了实现但没兑现验收"）

| 验收行 | 原状态 | 补后 |
|---|---|---|
| **P0** "首次启动=right；预置 bottom 后保持 bottom；预置 ratio 被夹取到 0.15–0.7" | 只测了**写入**契约，读盘那条路径完全没测——而"老用户不被翻转"和"脏数据不撑爆面板"恰恰都在读盘侧 | 抽出 `resolveAiPanelLayout(...)` 纯函数（与 `saveAiPanelLayout` 成对），5 例：没存过用新默认、存过 bottom 保持 bottom、脏方向值（`'left'`/`42`/null）回落默认、比例夹到 0.15/0.7、非数字比例用默认 |
| **P3** "窄宽度无 overflow 异常" | 没测，且我一度判定该风险"不成立" | 220px 下 pump `LiveOperationBar` 并断言 `takeException() == null`；**第一次跑就是红的**（`RenderFlex overflowed by 32 pixels`），修掉占用环标签后可见地变绿 |
| **P6** "`/plan` 断言结束后只读态**恢复原值**（不是恢复 false）" | 实现写在页面私有方法里，没有任何测试钉住这条不变量 | 抽出 `shouldRestoreReadOnly({wasReadOnly, nowReadOnly})`，3 例：进入前非只读→结束仍只读要还原；**进入前就是只读→必须保持只读**（写成 false 就漏了这条）；用户在任务期间自己动过开关→不覆盖他的选择 |

**过程中的自伤**：给测试文件追加 group 的那次 Edit，`old_string` 覆盖到了前一个用例的结尾，`new_string` 没把断言和闭合括号原样归还——第三个用例的两条 `expect` 被静默吃掉。是编译错误（`Expected to find ';'`）暴露的，不是测试变红。往文件尾部插代码时，凡是 `old_string` 触到闭合括号，就必须逐字归还。

最终门槛：`flutter analyze` **31 issues / 0 error**（= 基线）；`flutter test` **601 passed / 16 skipped**（基线 500，累计新增 101 例）。

### 6.10 §4-P5 那条"必须先有 D5 复现测试"没兑现，以及为什么不补

写之前先试了能不能复现。结论：**在可控 mock 时序下复现不出来**，所以不写这条测试。

推演（`_finishTask` 的实际顺序，[agent_engine.dart:2773-2822](../ai_terminal/lib/services/agent_engine.dart#L2773-L2822)）：finish 事件在 2773 发出 → 回调里同步 `startTask` 只会跑到它自己的第一个 `await`（`await provider.chatStream(...)`）就交还控制权 → 回到 `_finishTask` 做清理（cancel watchdog / `_aiStreamSub` / 置空 `_aiCancelToken`）→ **此时新任务的 streamSub 还没被赋值**，清理扫到的是旧资源或 null；等新任务的流真的建起来，已经在清理之后了。也就是说：清理确实会碰新任务的 `_aiCancelToken`（这是真实风险，超时保护与取消令牌可能失效），但"新任务刚建就被 cancel 掉 stream"这个我原先设想的必死现象，在同步 mock 下不成立，也就写不出一条会红的断言。

处置：
- **保留延后发起**（`scheduleMicrotask`）。理由不是"有测试证明同步会坏"，而是它让续跑确定地排在整个收尾块之后，避开 `_aiCancelToken`/watchdog 被扫这一段不确定窗口——这是设计判断，不是测试结论。
- **延后路径本身有真机证据**：§6.8 那次连跑 6 轮、每轮都正常起来并出结论卡，说明延后发起在新任务上没有被上一轮清理打掉。这比一条人为构造的引擎级红/绿测试更有说服力。
- 想真正确认清理窗口的影响，需要的是"新任务已建流、旧清理尚未跑完"的交错时序——只有在真实网络下才自然出现，不适合做单测。留作已知不确定项，不假装已验。

### 6.11 §4-P2 三条验收的逐项对账

| 验收原文 | 实际覆盖 | 差在哪、为什么不补 |
|---|---|---|
| "含 usage 的 SSE 样本 → 断字段" | `TokenUsage.tryParse` 8 例（末包完整、缺 details、**给了 0 不算缺失**、浮点取整、非 Map、字符串数字不认、details 类型错仍解析其余） | 断的是 `usage` 对象而非整行 SSE。要断整行得把 `jsonDecode` 从循环里搬出来，两处 provider 的热路径不值得为测试重排 |
| "`choices: []` 尾 chunk 不影响文本投递" | **没有单测**。结构上 usage 分支在 choices 分支之前且不 return；真机 6 轮里 provider 确实回了 usage，文本、命令、结论全部正常投递 | 单测要把 SSE 循环抽成纯函数，动的是最核心的流式路径；真机证据更强，就用真机证据 |
| "400 时降级重试成功" | 抽出 `shouldRetryWithoutStreamOptions` 并接进 catch，3 例：带字段+400 才重试、401/403/429/500/503/无状态码一律上抛、降级那次不再降。**破坏性验证**：把 `sentStreamOptions &&` 摘掉 → "防死循环"那条转红（`Expected: false / Actual: true`），已还原 | 重试的**执行**（真的再发一次请求）没测——那需要给 provider 注入可替换的 Dio。测的是判定，判定正是唯一的新逻辑 |

本轮门槛：`flutter analyze` 31 issues / 0 error；`flutter test` **604 passed / 16 skipped**；Release 包已重建。

### 6.12 README 同步（补 doc A 的 P2-6 交付物）

doc A 的「README 与实现同步（zh/en）」这一交付物，在本文档 P0–P7 落地后**已经过期**：README 完全没提目标模式、运行计量、8 个斜杠命令、面板默认右侧。本轮补齐 `README.md` / `README_EN.md`：新增「目标模式与运行计量 / Goal Mode & Run Metrics」小节（7 条）、统计条加 `8 个斜杠命令`、测试覆盖加 5 条、已知边界加 2 条（估算 token 的 `≈` 规则、续跑只在前台会话）。

写之前逐条核过源码，不写没实现的话：命令数取自 `kSlashCommands` 实数 8 条、默认方向取自 `_aiPanelPosition = _AiPanelPosition.right`、预算 24/256 取自 `AgentGoal.defaultMaxRounds/maxAllowedRounds`。措辞上刻意保留两处"不夸大"：`≈` 与"缓存命中率缺数据就整项不显示"，以及"切走会话时目标暂停而不是后台继续动手"。

**P3 已知边界（未解决，留给 P7 真机复拍时一并定）**：指标带挂在 `LiveOperationBar` 内，而该条只在 `currentTask != null && (isRunning || paused || waitingConfirm)` 时渲染（[terminal_page.dart:2747-2751](../ai_terminal/lib/pages/terminal_page.dart#L2747-L2751)）→ **任务结束后指标随之消失**，不像参照 UI 那样常驻底部。常驻需要把计量落到会话级（而非任务级）并新开一个渲染位置，属于独立决策，未在本次悄悄改动。

**实施中对设计的一处收紧**：§1 F2b 原写「输入含空格时 Enter 一律发送」需新增分支——实读确认**现有实现已满足**（含空格 → 浮层隐藏 → Enter 落到 `_send()` → 整串交 `onSlashCommand`），故未加分支；保留 `/go` + Enter 补全并执行裸命令这一既有交互（与主流 CLI 一致，且此时不可能已输入参数）。

### 6.13 恢复目标原先是个假动作（自己复核实现时发现的死路）

`resumeGoal` 原先只做一件事：把状态翻成 active。但续跑的**唯一触发点是任务终局的 finish 事件**——而目标多半正是在任务被取消/失败后暂停的，此刻已经没有任务在跑。结果：用户点「恢复」，横幅从"已暂停"变回"进行中"，然后什么都不发生。这是个假恢复，也是横幅三个按钮里唯一一个从没在真机上按过的。

修法：恢复时若前台、已连接、且没有任务在跑，就补起一轮（沿用续跑的延后发起与二次校验）；条件不满足时**当场拒绝并写明原因**（未连接 / 不在本会话），而不是翻成 active 再沉默。判定抽成 `shouldKickGoalRound`，4 例单测。门槛：`flutter analyze` 31 issues / 0 error；`flutter test` **608 passed / 16 skipped**；Release 包已重建。

**真机已验到（补拍）**：构造出前置——起目标 → 点停止 → 横幅转「已暂停的目标 · 你停止了任务，目标已暂停」且任务确实不在跑（输入框重新可用）。此时点横幅的 ▶恢复：横幅回到「进行中的目标」，**并且真的起了一轮新任务**（终端里跑出 `Get-ChildItem … | Measure-Object` 得 146，面板出现新的「【目标模式 · 自动续跑】第 1/24 轮」与运行条）。修复前这一按只会翻标签。

顺带拍到两处值得记的：① 停止后常驻指标条再次接管（`已取消 42s 1轮 21k tok 499 tok/s 上下文 64%`），§6.6 那条界面证据补齐；② 被取消的那轮不计入 `roundsUsed`（恢复后仍是 `0/24`，新一轮标"第 1/24 轮"），模型自己注意到了这点并说"系统再次要求推进第 1/24 轮"。**这是有意的**：取消的一轮没有产出，算它等于让中止白捡预算；代价是轮次编号可能重复出现，用户看到的是"第 N 轮"而非严格递增。

**文档自身的两条待办**：① 本节之前的 §6.2–§6.12 是分批插入的，落点不在文件末尾，**§6 的分节顺序已乱**（内容不缺，只是顺序）；已在 §6 开头放了阅读顺序映射，不做整节重写——那需要动 400 行，而本次会话已有两次"编辑吃掉不该动的内容"的记录。② 复拍留下的 paused 目标已用 `/goal clear` 清除，机器上无残留。

### 6.14 `/plan` 的只读还原会改到别的机器（自审代码时发现的 R3 串台）

`_runPlanOnly` 原先进出都用 `notifier.toggleReadOnlyMode()`。看它的实现：

```
final newValue = !state.isReadOnlyMode;
_engine?.setReadOnlyMode(newValue);
state = state.copyWith(isReadOnlyMode: newValue);
```

三行全部作用于**当前活跃 host**。而 `/plan` 的还原发生在 `await _sendToAgent(...)` 之后——一个计划任务跑几十到几百秒，期间用户切 tab 是常规操作。结果：进入时把 A 机置只读，结束时把**当时活跃的 B 机**的只读模式翻了个面。这正是 AGENTS.md R3 明令的那类跨 host 污染，而且是我自己这一轮写的代码。

修法：新增按 host 读写的 `setReadOnlyForHost(hostId, enabled)`（走 `_registry.getEngine(hostId)` + `_updateHostState(hostId, …)`）与 `isReadOnlyFor(hostId)`，`/plan` 的进入与还原都改成它们，hostId 在任务开始前捕获。`/permission` 和工具栏锁按钮仍用 `toggleReadOnlyMode()`——它们是即时操作，不跨 await，没有这个问题。

**补测与一处自我修正**：原先写"这条没有测试"。试着写之后发现**能测，而且测出了我把话说大了**。`AgentNotifier()` 的构造只读 `SettingsDao` 缓存 + 订阅日志，不需要 DB，所以可以裸构造（[agent_notifier_readonly_scope_test.dart](../ai_terminal/test/agent_notifier_readonly_scope_test.dart)）。测出来的事实是：`setReadOnlyForHost` 对**未注册的后台 host 是静默 no-op**——`_updateHostState` 在非活跃分支走 `registry.updateState`，而它对不存在的 key 直接跳过，不凭空建状态。也就是说 §6.14 的"按 host 路由"只对**活跃 host 或已注册 host** 生效。对 `/plan` 无影响（调用时该 host 必然活跃），但"按 host 读写"这个说法比我写的时候窄，测试把边界钉住了：改到后台 host 会什么都没发生，而不是改错机器。

（附带一条噪音：裸构造会在输出里打一行 `[AgentLogger] 日志文件初始化失败: Binding has not yet been initialized`。它被 catch 住、不落盘，故不为此加 `TestWidgetsFlutterBinding`——那会让测试去初始化真实的支持目录。）

仍未验证的部分只剩"跨 await 时 hostId 捕获确实避免了串台"这一条端到端行为，它需要两个真实 host 的引擎与执行器，本仓库没有这层脚手架。

---

## 7. 交接状态（2026-11-01，下次接手先读这里）

**结论**：本文 P0–P7 全部实现并真机复拍过。面板默认右侧、底部运行计量（实测 token 已通）、目标模式（横幅 + 自动续跑 + 终态矩阵）、斜杠命令（8 条）、README 同步，均已落地。

**门槛证据**：`flutter analyze` 31 issues / 0 error（= 基线，未新增）；`flutter test` 610 passed / 16 skipped（基线 500，本功能累计 +110 例）；`flutter build windows` 通过。16 个 skip 全部是环境变量门控的 E2E（5 个 group，1+1+2+3+9），无人为藏起的坏测试。
> 上面这行是 P7 收口时的快照。**当前数以 §6.17 为准**（623 passed / 16 skipped，analyze 仍是 31 issues 基线）。

**真机已拍到界面的**：右侧默认布局；指标带 `1轮 11.6k tok 360 tok/s 上下文 35%`（无 `≈` = provider 真回了 usage）；目标横幅三态与三按钮；自动续跑连跑 6 轮；停止→目标 paused 不复活；恢复→真的补起一轮；常驻指标条在终态接管同一位置（`已取消 42s 1轮 21k tok`）；建目标→杀进程→重启→横幅原样回来；`/goal clear` 后重启不再出现；`/help` 弹命令表且没被当任务发出去。

**剩余四类，逐条给了入口**：

1. ~~**需要凭据**：P1 真机 E2E~~ **已完成**（2026-11-01）：SFTP 9 例 + 真模型 2 例全在真机跑通，后者还抓出一个静默截断缺陷 —— 见 [另一份文档](./agent-builtin-tools-timeline-design.md) §5.8/§5.9。凭据只经环境变量传入，未进仓库。
2. ~~**需要授权**：§6.7 两个既有缺陷~~ **已修**（2026-11-01，见 §6.17）：① PowerShell cmdlet 的空标记改为 `$?` 推导数字，7 例里 4 例真起 powershell.exe 执行生成串；② `tok/s` 分母剔除等确认秒数。**未做的是 app 内复拍**，证据止在 powershell.exe 层。
3. **本环境做不到**：§6.10 的 D5 清理窗口（需真实网络交错）、§6.14 的跨 await host 捕获端到端（需双 host 引擎脚手架）。都已标"未验证"，没有用假测试冒充。
4. **文档自身**：§6 的分节物理顺序仍是乱的（阅读映射在 §6 开头）；文中 `文件名#L行号` 一律过期，实测漂移表在文档顶部，**定位请用符号名 grep**。

**提交注意**：工作树里混有**不属于本次工作**的外来改动，提交前必须排除——`.serena/`、`ai_terminal/.serena/`、`lib/pages/settings_page.dart`、`lib/pages/web_search_settings_page.dart`、`lib/services/web_search_service.dart`。以 `git status` 现场为准逐个核对，不要用 `git add -A`。本次未提交任何东西。

**本轮方法教训（写给下一个做类似事的人）**：① 验收表里的每一行都是主张，"实现做了"不等于"验收兑现"，逐行回查抓出三条空验收；② 想写"这条没有测试"之前先试着写一次——§6.14 就是试写时暴露出我把"按 host 路由"说大了；③ 判定逻辑抽成纯函数才能测，但**热路径（SSE 循环）不值得为测试重排**，那种情况改用真机证据并写明。

### 6.15 目标存盘的"正向"路径复核（此前只验过反向）

真机复拍验的是"清除后重启不再出现"，**没验过"存着的目标重启后会出现"**——而后者才是存盘的意义。这次按代码路径查通了：

- `AgentNotifier` 构造时 `_loadStoredGoals()` 读 `SettingsDao.cachedMap`；缓存是否在跑之前就绪决定成败，实测 `main.dart` 的顺序是 `DbInit.reloadCaches()`（:57）在 `runApp`（:82）**之前**，所以 provider 首次被读时缓存已就位。
- 镜像进 state 靠 `_mirrorGoal`，它挂在 `_setupEngineCallbacks` 上；该函数有 3 个调用点（`switchTab` :148、:276、:355），覆盖"初始化"与"切 tab"两条入口。
- 结论：**已在真机验通**。建目标「存盘验证：重启后这条应该还在」→ `taskkill` 杀进程 → 重启 → 横幅原样回来（「进行中的目标 · 轮次 0/24 剩 24 轮」+ 三个按钮），随后 `/goal clear` 清除、横幅消失。

**顺带拍到一条设计事实**：重启后目标是 `active`，但**没有任何任务在跑**（上一轮是被杀掉的），所以它不会自己续跑——要等用户下一次发消息或点「继续任务」。这与 §6.14 修的"假恢复"形状相同、结论相反：那里是用户显式按恢复却不动，这里是崩溃恢复后**故意不自动动手**。留在此处，免得下一个人把它当同一个 bug 改掉。

**同时修正 §3.1.2 的一格**：表中"环形 x%｜未起任务显示 0%"与实现不符。实现是 `contextTokens > 0` 才渲染环——第一轮 AI 调用之前没有任何上下文测量值，此时显示 `0%` 是"我还没测"而不是"上下文是空的"，与 D2 的取舍相悖。**以实现为准**：未测量前不渲染。

### 6.16 §6.7 缺陷②（tok/s 把等用户的时间算进分母）的落地入口

本轮把改法定位到具体锚点，下次接手可直接照做，不必重新摸排。定位一律用符号名 grep，行号仅作参照。

- **两处确认等待**：`agent_engine.dart` 中 `await _confirmCompleter!.future` 只有 2 个出现点——`_confirmToolExecution`（工具确认）与危险命令确认分支。两处各自用 `DateTime.now()` 前后夹住，累加进新字段 `_confirmWaitSeconds`。
- **清零点**：与 `_aiRounds = 0; _contextTokens = 0;` 同一处（任务启动复位），漏掉会让上一条任务的等待时间污染下一条的速率。
- **口径**：`elapsedSeconds` 保持墙钟不动——"耗时 42s" 对用户是事实，不该偷偷扣；只在 `operation_sheet.dart` 的 `buildMetricItems` 里把速率分母换成 `elapsed - confirmWait`，分母 ≤0 时不渲染 tok/s（沿用 D2「缺数据就不显示，不显示假数」）。因此 `AgentTask` 需多带一个 `confirmWaitSeconds`，`copyWith` 同步；加字段前先确认任务是否被持久化，若走列存表则按 R8 一并核对读写两侧。
- **验收**：纯函数不必要，直接测 `buildMetricItems`——喂 elapsed=60 / confirmWait=45 / tokenTotal=3000，断言速率取 15 秒分母而不是 60；再补一条 elapsed 全花在确认上时**不出现** tok/s 的断言。

本轮未实施的原因：只剩 1 个回合，改 `AgentTask` + 两处 await + 指标带属于跨文件改动，来不及跑 analyze/test 就中断会把工作树留在半完成状态。缺陷①（PowerShell cmdlet 的 `$LASTEXITCODE` 标记为空）同理需要执行链改动与真机验证，两者都仍在"待授权"。

### 6.17 两个缺陷的交付记录（2026-11-01，用户授权"开始做"后）

#### ① PowerShell 退出码标记（§6.7 缺陷①）

改法没有采用 §6.7 当时写的两种猜测（"换不依赖 `$LASTEXITCODE` 的哨兵"或"cmdlet 后强制跑一次原生命令取码"），而是先在真 PowerShell 里把候选形状跑了一遍再定：**用 `$?` 推导数字，`$LASTEXITCODE` 只在确实被设置且非零时采信**。

```powershell
$LASTEXITCODE=$null; <cmd>; $__ec=if($?){0}elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}else{1}; echo "EXITCODE_1:$__ec"
```

对照实测（同一台机器、同一个 powershell.exe）：

| 命令 | 旧包装产出 | 新包装产出 |
|---|---|---|
| `Get-Date`（cmdlet 成功） | `EXITCODE_1:` ← **空标记，60s 挂死的成因** | `EXITCODE_1:0` |
| `cmd /c exit 7`（原生命令） | `EXITCODE_1:7` | `EXITCODE_1:7` |
| `Get-ChildItem 不存在`（cmdlet 失败） | `EXITCODE_1:` | `EXITCODE_1:1` |

置空前缀 `$LASTEXITCODE=$null;` 是必需的而不是顺手写的：它是**会话级**变量，上一条命令留下的非零值会串到下一条（上一条 `cmd /c exit 7`、这一条 cmdlet 失败会报 7 而不是 1）。

落点抽成了纯函数 [LocalTerminalService.wrapCommandWithExitMarker](../ai_terminal/lib/services/local_terminal_service.dart)，三个 shell 分支各一条断言，另有 4 例**真的启动 powershell.exe 执行 Dart 生成的那串字符**并断言 R8 的 `EXITCODE_n:\d+` 能吃下——被测的是产出的字符串本身，不是我对它的描述。含 `cmd /c exit 0; Get-ChildItem 不存在` 这条陈旧值组合，断言得 1。

**同机制的其他路径按 R9 逐个查过**：本文件另一处 marker 在 `writeFileViaPty`，而它开头就有 `if (Platform.isWindows) return …不支持 PTY stdin 写文件` 的早退，所以那里的 `$?` 只会走 POSIX，**不需要改**（查证过，不是假设）；`ssh_service.dart` 两处 marker 无条件用 `$?`，隐含"远端是 POSIX shell"，SSH 到 Windows 主机会同样失效——那是**另一个未修的既有范围外问题**，本轮没动。

#### ② tok/s 分母（§6.16 的计划照做，两处偏差）

- `_confirmWaitSeconds` 在**恰好两处** await 上累计（破坏性工具 `_confirmToolExecution` / 危险命令分支），与 §6.16 数出来的一致；每处都用"进入 await 前的代际 == 当前代际"守卫，切会话时 `cancelTask` 补完成 future 带来的旧任务等待时间不会挂到新任务计量上。复位与 `_aiRounds = 0` 同处。
- §6.16 留的疑问"AgentTask 是否被持久化"查清了：**没有**（全库无 `AgentTask` 的 toJson/列存写入），所以不涉及迁移；`copyWith` 加透传即可。
- 口径按计划执行：`elapsedSeconds` 仍是墙钟，只有速率分母改成 `wall - confirmWaitSeconds`，`active <= 0` 时整项不渲染（不显示 `0 tok/s`）。

**测试**：`tool_contract_test.dart` 里那条"用户确认后工具才真正执行"改为**真的多等 1.1 秒**再放行，断言引擎计数器 `>=1` 且写进了 `task.confirmWaitSeconds`；`operation_sheet_widget_test.dart` 新增两例（elapsed=60/等待=45 → `86 tok/s` 且**不是** `21 tok/s`；等待占满 30/30 → 无 tok/s）。非空转没有靠临时改码验证——改 `_confirmWaitSeconds += 0` 的那次试验把代码块尾巴吃掉了（`grep -n "_confirmWaitSeconds"` 显示写入点只有初始值、两处 `+=`、一处复位，所以 `>=1` 只可能由累计产生），据此判定断言必然依赖该累计。

**门槛**：`flutter test` **623 通过 / 16 跳过**（本轮 +9：shell 包装 7 例新文件 + 速率分母 2 例新断言；`tool_contract_test.dart` 那条是改造已有用例，不新增计数。上一轮的解析契约 4 例已计入改前的 614），`flutter analyze` 31 issues / 0 error 基线未变。**未做**：运行 app 复拍那条"0 成功 4 失败"变绿——本轮证据止于真实 powershell.exe 层的 7 例，引擎→PTY→面板整条链的界面表现还没在 app 里重跑过。
