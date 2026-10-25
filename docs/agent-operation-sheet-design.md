# Agent 回答结构重构设计：操作单（Operation Sheet）

> 状态：设计稿（待评审）
> 适用范围：Agent 自动执行模式（ReAct）下一轮任务的回答呈现与相关数据契约
> 不改变：ReAct 决策循环、SafetyGuard 规则、终端交互方式
> 现状核对：2026-10-25 当前工作区（含未提交改动）
> 关联：[AGENTS.md](../AGENTS.md) 工程规则、[orchestrator-design.md](./orchestrator-design.md)

---

## 1. 为什么要改

当前 Agent 的一轮回答是"按发生顺序平铺的事件流"：思考、旁白、命令、结果权重相同，全部展开。用户看完一屏后，仍然很难在 5 秒内回答四个问题：

1. 这件事做成了没有？
2. 服务器现在是什么状态？
3. 改了什么东西，出问题能不能退？
4. 还有哪台机器/哪一步没完成？

本软件不是"在本地写代码的 Agent"，而是**用自然语言操作远程服务器的控制台**。它的核心承诺是"安全、可控、可追溯"。回答结构必须体现这个承诺，而不是模仿编程 Agent 的推理直播。

本设计把一轮回答从"聊天记录"改成**一张操作单**：结论先行、变更可查、证据可折叠、主机是第一维度。

---

## 2. 产品定位与远程约束

### 2.1 产品定位

一句话：用户用自然语言描述目标，AI 连接远程主机执行命令，并把结果以**可验证、可审计、可回滚**的方式交付。

用户不是单一群体：

- 小白 / 非技术用户：看不懂命令，只关心"网站好了没、会不会坏"。
- 开发者：关心命令、退出码、日志，需要快速排障。
- 运维：关心影响面、多主机一致性、变更台账与回滚。
- 产品经理 / 独立开发者：关心结果和风险，不关心实现细节。

因此同一轮回答必须支持**两种读法**：默认读结论和变更，需要时展开证据。

### 2.2 远程场景的七个约束

| 约束 | 对回答结构的直接影响 |
|---|---|
| AI 执行走独立 SSH 通道，输出不一定出现在用户眼前的终端 | 回答必须自包含证据：主机、命令、退出码、耗时、输出摘要 |
| 远程变更不可逆，可能影响生产 | 变更与回滚必须是一等公民；危险操作按"影响"确认，不按命令确认 |
| 网络会断、会慢、会超时 | 失败必须分类（断线/超时/权限/语法/命令失败），并给出恢复动作 |
| 一次意图可能打到多台主机 | 主机是第一维度；多机结果用矩阵/分组，不能串成一条流 |
| 输出不可控，可能几 MB | 默认摘要 + 折叠 + 明确标注截断；完整输出另行落盘/查看 |
| 任务可能很长，App 可能切后台或被杀 | 操作单必须持久化，恢复后知道"做到第几步" |
| 用户水平差异大 | 结论层 / 证据层分离，默认简洁视图，可切技术视图 |

### 2.3 与编程 Agent 的关键差异

编程 Agent 的信任来自"代码正确 + 推理透明"；远程运维的信任来自**可验证的服务器状态 + 审计链 + 回滚路径**。

所以：

- 思考过程默认折叠，不占主视觉。
- 结论必须尽量有证据支撑；没有验证证据时，不做绿色"运行正常"断言（P0 用中性"AI 结论"，P1 起显示"已验证/未独立验证"徽标）。
- 任务清单不是"模型的 12 个 todo"，而是"这次操作的步骤清单"，每一项要能对应真实命令/主机/结果。

---

## 3. 现状诊断（代码事实）

| # | 现象 | 代码事实 | 影响 |
|---|---|---|---|
| P1 | 事件平铺，无层级 | `AgentEventContent._buildEventsContent` 把 thought/text/info 合并成一个 Markdown 串；command 后紧跟 result 卡片 | 思考、旁白、执行同权重，长任务滚动成本高 |
| P2 | 每个 step 两张重量级卡片 | `AgentCommandBlock` 顶部有"可执行"栏 + 播放按钮；`_buildResultCard` 又有"执行成功/N 行"标题栏 | 10 步任务 ≈ 20 条标题栏；历史命令仍显示可播放 |
| P3 | 结果"全部展开"名不副实 | 引擎发出 result 事件前已截断：非查询命令 8 行/600 字符，查询命令 20000 字符（`agent_engine.dart` `_handleExecuteAction`） | UI 无法真正展开全部；也没有标注截断 |
| P4 | 完成摘要不能当结论 | `_finishTask` 用 `_accumulatedMessage`（原始 ReAct 文本）作为 finish summary | 把推理过程当结论展示，非技术用户读不懂 |
| P5 | 已有数据完全没露出 | `AgentTask.goal / elapsedSeconds / successCount / failureCount` 从不渲染；`ChangeRecord` 只写不读；`CommandResult.duration / exitCode / failureKind` 在转 `AgentResult` 时丢失 | 回滚、审计、耗时、失败类型这些差异化能力全部浪费 |
| P6 | 历史轮次无法复原为操作单 | `AgentTask` 只在内存；`ConvMessage` 不存 taskId；`ChangeRecord.conversationId` 实际写入的是 task.id | 重开 App 后无法把变更关联回某一轮 |
| P7 | 进度信息混在字符串里 | `currentStep = "第 N 步 | ✅x ❌y | Ns"`，只在工具栏徽标显示 | 无法结构化渲染，也无法在 transcript 里展示 |
| P8 | 多机结果只有格式化文本 | `ExecBatchTool` 返回 `MultiHostExecutor.formatBatchResult` 文本，事件里没有 per-host 结构 | 做不了主机矩阵，只能读一大段文本 |
| P9 | 暂停/恢复破坏连续性 | `resumeTask` 重置 `_currentStepCount=0`，并新建 task id | 恢复后步数归零、变更关联断裂 |
| P10 | 步数上限可能是无限 | `maxSteps=0` 表示不限制 | "步骤 N/M" 在无限模式下不成立 |

---

## 4. 设计原则

1. **结论先行，证据可查**：先给"做成了什么/现在什么状态"，再给命令与输出。
2. **持久态上浮，瞬态下沉**：目标、变更、待决定常驻；思考、原始输出默认折叠。
3. **一次操作一张单**：一轮任务 = 一张操作单，而不是无限追加的卡片流。
4. **主机是第一维度**：任何命令、结果、变更都必须能回答"在哪台机器上"。
5. **危险、失败、截断不隐藏**：宁可显示"未验证/无自动回滚"，也不给虚假安全感。
6. **两种读法**：简洁视图面向所有用户，技术视图面向排障；同一份数据，不同展开深度。
7. **不伪造进度**：没有计划就不显示清单；没有验证就不显示"运行正常"；没有回滚命令就不显示回滚按钮。

---

## 5. 信息架构

### 5.1 三层阅读层级

```
结论层   ← 所有人默认看到：目标、结果、状态、变更、待决定
操作层   ← 需要知道过程时看：步骤清单、命令、主机、耗时、退出码
证据层   ← 排障时看：思考、完整输出、审计记录、原始事件
```

### 5.2 常驻目标条（输入框上方）

任务运行期间常驻，切到其他 tab 再回来也能立刻知道在干什么。

```
目标 · 在 web-01 上部署 Nginx 并开启 HTTPS
web-01 · 正在执行变更 · 第 7 步 · 00:42   [暂停] [停止]
```

- 主机：当前执行目标；多机时显示 `3 台主机`。
- 阶段：见第 6 节。
- 步数：`第 N 步`；有模型计划时才显示 `N/M`。
- 计时：以前端 `createdAt` ticker 秒级刷新；`AgentTask.elapsedSeconds` 每步才更新，只用于校准。
- 操作：暂停（已有 `pauseTask/resumeTask`）、停止（已有 `cancelTask`）。

### 5.3 操作单五段式

一轮完成后，transcript 中保留一张操作单：

```
目标：在 web-01 上部署 Nginx 并开启 HTTPS
web-01 · Ubuntu 22.04 · root · 4m12s · 9 步

结论
Nginx 已安装并运行，HTTPS 已配置，网站现在可以通过 https://example.com 访问。
[服务运行中] [443 已监听] [开机自启] [2 项变更]

执行清单（仅多步骤任务显示）
✓ 检查系统与端口占用
✓ 安装 Nginx
✓ 申请并配置证书
✓ 验证 HTTPS 访问

变更与回滚
apt install nginx          可回滚 → apt remove nginx
systemctl enable nginx     可回滚 → systemctl disable nginx
systemctl restart nginx    无自动回滚 · 重启类变更
[查看审计记录]

需要你决定
[把 80 跳转到 HTTPS] [先这样]

▸ 过程与证据 · 9 条命令 · 思考、输出、退出码
```

> 示例中的状态徽标（服务运行中/端口监听）是 P1 验证器能力；P0 只显示确定性统计（已完成步骤、命令变更数、失败数）。执行清单在 P0 是事件归纳，P2 才接模型计划。

各段规则：

1. **目标头**：目标来自 `AgentTask.goal`；主机、系统、用户、总耗时、步数来自任务元数据。
2. **结论**：1-3 句自然语言，回答"做成了什么/现在什么状态"。必须与证据分离；没有验证证据时不做绿色成功断言（P0 中性"AI 结论"，P1 起显示"未独立验证"徽标）。
3. **执行清单**：只在真实多步骤（有模型计划或 ≥3 个有效动作）时显示；每项状态为 完成/进行中/待处理/失败/跳过。单命令任务不显示，避免装饰。
4. **变更与回滚**：来自 `ChangeRecord`，按 `operationId` 关联（不是 taskId，见 7.4）；只有 `rollbackCommand != null` 才显示回滚按钮；其余明确写"无自动回滚"。
5. **待决定**：来自 `ask` 事件或模型建议的下一步；无则不显示。
6. **证据层**：默认折叠；展开后按时间顺序显示思考摘要、命令、退出码、耗时、输出摘要。原始事件不直接裸奔。

### 5.4 运行态：一条活块，不是满屏卡片

```
正在执行变更 · web-01 · 00:42
  ● systemctl restart nginx
    最后 3 行输出…                [在终端查看] [停止]
  ✓ 已执行 6 条 · 失败 0
```

- 只显示当前步骤与最近一条输出，不把历史所有卡片重新展开。
- 历史步骤在运行中自动折叠为 `✓ 已执行 6 条`。
- 思考流只在阶段行显示计时，不把 token 流当正文。
- 不做独立的实时输出查看器：当前 `executeAndWait` 没有增量回调，但命令输出经 `outputController` 进入可见终端。P0 提供"在终端查看"（切到终端 tab），P2 再评估专用查看器。

### 5.5 多主机

单机任务不显示主机矩阵；多机任务按主机聚合：

```
执行清单 · 3 台主机
               web-01  web-02  web-03
检查磁盘         ✓       ✓       ✓
清理日志         ✓       ✓       ✗ 权限不足
重启服务         ✓       ✓       —
[重试失败项]  [查看 web-03 详情]
```

> 已落地：`ExecBatchTool` 同时返回格式化文本与结构化 per-host 结果，证据层由 `HostResultMatrix` 渲染（见 7.7）。

---

## 6. 状态与阶段模型

### 6.1 保留现有状态机

`AgentStatus`（idle/thinking/executing/waitingConfirm/completed/failed/cancelled/paused）继续作为引擎的唯一状态机，避免触碰 R5。阶段只是**展示层派生字段**，不参与调度。

### 6.2 新增 OperationPhase（仅展示）

| Phase | 文案 | 派生条件（引擎钩子） |
|---|---|---|
| understanding | 理解需求 | 任务开始，首次 AI 调用前 |
| planning | 思考中 | 每步 AI 调用前 |
| inspecting | 检查环境 | 执行只读/查询命令（isQueryCommand） |
| executing | 执行命令 | 非查询且非 warn/blocked 命令 |
| changing | 执行变更 | 执行 warn/blocked 级命令，或用户确认后 |
| tooling | 执行工具 | 调用非 shell 工具 |
| verifying | 验证结果 | 检测器产出确定性徽标后 |
| reporting | 整理结论 | 收到 finish 动作、生成报告前 |
| waitingUser | 等待确认/选择 | waitingConfirm |
| reconnecting | 连接恢复中 | 连续连接失败 > 0 且正在自愈（待实现） |
| paused | 已暂停 | paused |

> 已落地：`AgentTask.phase` 由引擎在这些钩子点写入，UI 只展示；不参与调度。

规则：

- 阶段切换只写视图模型，不改 `AgentStatus`。
- 同一阶段连续超过 5 秒才显示计时，避免闪烁。
- 历史操作单只保留"总耗时"，不保留每阶段耗时（P1 可选做阶段时间线）。

### 6.3 状态覆盖矩阵

| 引擎状态 | 活块 | 操作单结论区 | 证据层默认 |
|---|---|---|---|
| idle | 不显示 | 不显示 | 折叠 |
| thinking | 阶段 + 计时 | 运行中占位 | 折叠 |
| executing | 阶段 + 当前命令 + 计时 | 运行中占位 | 当前步骤输出预览 |
| waitingConfirm | 影响确认卡 | 等待确认 | 显示待执行命令 |
| waitingChoice | 选项卡 | 等待选择 | 折叠 |
| paused | 已暂停 + 恢复按钮 | "已暂停于第 N 步" | 折叠 |
| completed | 不显示 | 结论 + 变更 + 待决定 | 折叠 |
| failed | 不显示 | 失败摘要 + 恢复动作 + 继续任务 | 展开错误行 |
| cancelled | 不显示 | "已取消于第 N 步" + 继续任务 | 折叠 |
| interrupted（maxSteps） | 不显示 | "达到步数上限" + 继续任务 | 折叠 |

---

## 7. 数据契约

### 7.1 已有可复用数据

| 数据 | 来源 | 现状 |
|---|---|---|
| 目标 | `AgentTask.goal` | 有，未渲染 |
| 总耗时 | `AgentTask.elapsedSeconds` | 有，未渲染 |
| 成功/失败数 | `AgentTask.successCount / failureCount` | 有，未渲染 |
| 步数 | `_currentStepCount`（引擎私有） | 有，未暴露 |
| 风险等级 | `SafetyGuard.check` | 有 |
| 退出码/耗时/失败类型 | `CommandResult.exitCode / duration / failureKind` | 有，转 `AgentResult` 时丢失 |
| 变更/回滚 | `ChangeRecord` + `ChangeRecordService` | 有，未在回答中露出；仅覆盖 shell 变更 |
| 审计 | `AuditLogger` | 有，无入口；仅覆盖 shell 命令 |
| 多机结果 | `MultiHostExecutor.executeBatch` 返回 `Map<hostId, CommandResult>` | 有，但工具层只格式化文本 |

### 7.2 扩展 AgentEvent（向后兼容 JSON）

`AgentEvent.result` 增加：

| 字段 | 类型 | 用途 |
|---|---|---|
| `hostId` | String? | 主机标识 |
| `toolName` | String? | 终端命令 / 读取文件 / 搜索等 |
| `durationMs` | int? | 命令耗时 |
| `exitCode` | int? | 退出码 |
| `failureKind` | String? | 断线/超时/权限/语法/交互提示等 |
| `outputTotalChars` | int? | 未截断前的字符数 |
| `outputTruncated` | bool? | 是否被截断 |

`AgentEvent.command` 增加 `hostId`、`toolName`、`riskLevel`（safe/info/warn/blocked）。

工具调用必须有自己的 command 事件：

- 当前 `_handleToolAction` 只发一条 `info` 事件，result 复用 `_lastCommandEventId`，可能把工具输出挂到上一条 shell 命令上（违反 R4）。
- P0 先修：每次工具调用生成唯一 id 的 `command` 事件（`toolName + 参数`），result 使用该 id；shell 命令同样保持一命令一 id。

序列化在 `daos.dart` 的 `_eventToJson/_eventFromJson`，缺字段按 null 处理即可兼容旧数据。

### 7.3 扩展 AgentTask

新增 `stepIndex`（来自 `_currentStepCount`），渲染时不再解析 `currentStep` 字符串。`currentStep` 保留给 AI/日志使用。

注意：`successCount/failureCount` 目前只在 `_handleExecuteAction` 累加，工具调用不计入。操作单必须标明统计口径是"命令"，或新增 `toolSuccessCount/toolFailureCount`；不能把两者混成一个"成功数"。

### 7.4 持久化：新增 report 事件，而不是扩展 ConvMessage

初稿曾计划给 `ConvMessage` 增加 taskId/goal/elapsed/report 等字段。二次验证后否决：`_persistAssistantCompletion` 在每条 command/result 事件都会写一次，只传 content + events；扩字段需要改 `updateLastAssistantContent` 和所有调用点，中间写入容易丢字段，迁移风险高（R8/R9）。

改用事件承载：

```dart
enum AgentEventType { thought, command, result, ask, finish, text, info, report }

class OperationReport {
  final String operationId;         // 稳定操作 id（暂停/恢复不变）
  final String? taskId;             // 引擎内部任务 id（恢复后会变）
  final String goal;
  final int elapsedSeconds;
  final int stepIndex;
  final int commandSuccessCount;
  final int commandFailureCount;
  final String conclusion;          // 1-3 句
  final List<String> stateBadges;   // 确定性检测结果（P1）
  final List<String> changeRecordIds;
  final List<String> nextActions;
  final bool verified;              // P0 恒为 false，P1 由检测器给出
  final bool aiGenerated;
}
```

- `report` 事件随 `ConvMessage.events` JSON 一起持久化，不需要改会话表结构；`OperationReport` 在事件 JSON 内部序列化，不新增 Hive 适配器。
- report 事件只用于 UI 与操作单复原，不进入 AI 对话上下文（`_conversationHistory` 不消费 events），避免模型自我强化。
- 旧会话没有 report 事件 → 自动走遗留紧凑模式。
- 历史操作单读取 `events.lastWhere(type == report)`；实时界面用 `AgentTask` + 事件。
- `finish.summary` 保留作兼容兜底；有 report 时 UI 不再重复展示 finish 摘要。

写入时机必须覆盖**所有终态路径**（R5）：

| 路径 | 是否 emit report |
|---|---|
| AI 主动 finish / `_finishTask(success:true)` | 是 |
| `_finishTask(success:false)`（工具重试耗尽、异常终止） | 是 |
| `cancelTask`（用户取消） | 是 |
| maxSteps 耗尽（`AgentFinishState.interrupted`） | 是 |
| `_handleNoCommand` 熔断（走 `_finishTask`） | 是（由 `_finishTask` 覆盖） |
| AI 调用失败（直接置 failed + finish，不走 `_finishTask`） | 是（必须在 onEvent 路径补） |
| `startTask` executor 为 null / `_executeAutomatic` 未连接 / `resumeTask` catch | 是（这些路径当前连 finish 都没有，需统一终态出口） |
| `pauseTask` | 否（不是终态） |

其他实现约束：

- report 必须在 `finish` 事件**之前** emit，保证"看到 finish 就停止渲染"的消费方也能拿到报告。
- 同一轮同时存在 finish 与 report 时，UI 只渲染 report 的结论区，finish 不再单独成卡（避免两份总结）。
- 新增 `AgentEventType.report` 后必须补齐所有 switch/枚举消费点（`agent_event_cards.dart`、`agent_event.dart` 的 `statusLabel`、`daos.dart` 序列化等），Dart 的穷尽检查会强制。

补充约束：

- 每个 operation 只能有一个 report 事件；引擎加 `_reportEmitted` 幂等标记，避免 finish 后又被循环末尾重复 emit。
- Provider 的 `onEvent` 目前只对 command/result 即时持久化；需把 `report` 加入即时持久化条件。否则"取消且没有任何累积文本"的路径不会触发 `onCompleted`，report 会丢。
- `operationId` 在 `startTask` 生成，`resumeTask` 必须沿用；`ChangeRecord` 记录时写入 `operationId`，不要继续把 taskId 塞进 `conversationId`。

### 7.5 结论的生成与校验

不允许直接把 `_accumulatedMessage` 当结论（它包含完整 ReAct 文本）。采用**混合生成**：

1. **确定性部分**（系统生成，优先）：
   - 执行结果统计、耗时、步数、失败分类。
   - 已知验证命令的检测结果：`systemctl is-active X`、`ss -lntp`、`curl -I`、`nginx -t`、`df` 等（P1 实现 `VerificationDetector`）。
   - 变更记录与回滚可用性。
2. **模型部分**（提示词约束）：
   - 在 `finish` 时输出四段：结论 / 现状 / 变更 / 建议。
   - 只允许引用实际执行过的结果；不得编造未验证的状态。

实现注意：当前 `case ActionType.finish` 调用 `_finishTask()` 不带 summary，`_finishTask` 只能回退到 `_accumulatedMessage`。需要改成 `_finishTask(summary: step.thought)`（或解析专门的 `总结:` 字段），再基于该文本生成 `report.conclusion`；否则四段式不会生效。模型完全不按四段式时，用确定性统计 + 通用结论模板兜底。

P0 的显示策略：

- 没有检测器时，`verified=false`，但**不要**给每一轮都打"未独立验证"的警告；显示中性的"AI 结论"标签即可。
- P1 有检测器后，才显示"已验证 / 未独立验证"徽标。
- 模型结论包含"运行中/已开启/可访问"等状态词但没有对应证据 → 证据层标注"该状态来自 AI 总结"，不做绿色成功徽标。
- 模型结论与确定性检测冲突 → 以确定性结果为准，并在证据层标注冲突。
- 结论为空 → 降级为"任务已结束，详见执行记录"。
- 取消 / 中断 / 失败的 report 使用确定性模板（状态 + 步数 + 原因），**不得**直接使用 `_accumulatedMessage` 作为结论。

### 7.6 计划清单（已落地）

计划只在多步骤任务中出现，且必须绑定真实执行意图：

```dart
enum PlanStepStatus { pending, inProgress, completed, failed, skipped }

class PlanStep {
  final String title;
  final PlanStepStatus status;
  final List<String> hostIds;
  final String? note;
}
```

已选协议：**ReAct 响应内 `计划:` 字段**（不额外增加模型往返）。

```
思考: ...
计划:
- [x] 已完成的步骤
- [>] 当前进行中的步骤
- [ ] 待处理的步骤
- [!] 失败的步骤
- [-] 跳过的步骤
动作: execute
命令: ...
```

- `ReActStreamParser` 解析为 `plan` 事件，随 events JSON 持久化。
- 模型每次状态变化输出**完整计划**，引擎替换 `_currentPlan`，不追加快照；`resumeTask` 保留计划。
- `OperationReport.plan` 携带终态计划；运行中则从最近一个 `plan` 事件读取。
- UI 使用 `PlanPanel`：计数、状态图标、当前步骤高亮、长计划折叠；运行中在第一个进行中步骤下展示尚未产出结果的命令。
- 计划是模型声明，不是验证结果；真实状态仍以命令输出/验证徽标为准。没有计划就不显示，绝不伪造总任务数。

未采用方案：`update_plan` 工具调用（结构化更可靠，但多一次模型往返）。如果后续模型对 `计划:` 格式遵循度差，再切换。

### 7.7 多主机结构化结果（已落地）

- `HostExecutionResult`：hostId、success、output/error、exitCode、durationMs、failureKind。
- `ToolResult.hostResults` + `ExecBatchTool` 同时返回文本与结构化结果。
- `AgentEvent.result.hostResults` 随 events JSON 持久化。
- 证据层用 `HostResultMatrix` 渲染：每台主机状态、耗时、退出码、失败类型、首行摘要；点击展开该主机输出。
- 矩阵只依赖结构化字段，不解析 `formatBatchResult` 文本；单主机仍显示原始输出。
- 有失败主机时提供"重试失败主机"，把失败 hostIds 带回新一轮任务；不自动重跑全部主机。

### 7.8 数据流

```
引擎执行
  ├─ AgentEvent.command (+host/tool/risk)
  ├─ CommandResult (exitCode/duration/failureKind) ──┐
  ├─ AgentEvent.result (+duration/exitCode/failureKind/output meta)
  ├─ ChangeRecord (按 operationId 关联) ─────────────┤
  └─ AgentTask (goal/step/elapsed/counters) ─────────┤
                                                     ▼
                                        OperationSheetBuilder（视图模型）
                                         ├─ 结论/验证状态
                                         ├─ 步骤/证据分组
                                         ├─ 变更+回滚
                                         └─ 待决定
                                                     ▼
                                      OperationSheet 渲染 + 目标条/活块
```

视图模型在 provider 层构建并缓存（按事件数量/最后事件 id 失效），禁止在 build 中查数据库（R1/R2）。

---

## 8. 交互规则

### 8.1 默认展开策略

| 内容 | 运行中 | 完成后 | 失败/中断 |
|---|---|---|---|
| 结论 | 占位 | 展开 | 展开失败摘要 |
| 执行清单 | 展开当前 | 展开（>2 步） | 展开并标红失败项 |
| 变更与回滚 | 首次变更后出现 | 展开 | 展开 |
| 当前步骤输出 | 最近 3 行 | — | 首 5 行错误 |
| 历史步骤 | 折叠 | 折叠 | 折叠 |
| 思考 | 仅阶段计时 | 折叠为"已思考" | 折叠 |
| 完整输出/审计 | 折叠 | 折叠 | 折叠，错误行前置 |

### 8.2 输出与截断

- 事件里的输出已经是引擎截断后的文本（非查询 8 行/600 字符；查询 20000 字符）。审计日志只保留 500 字符。
- 完整输出目前只在可见终端的 scrollback 里（SSH/本地命令都经 `outputController` 写入终端）；没有可查询的完整输出 API。
- UI 必须区分三种状态：
  - **UI 折叠**：输出完整存在于事件中，可展开。
  - **引擎截断**：`outputTruncated=true`，显示"输出已截断（原始 N 字符）"。
  - **无完整输出源**：工具调用（SFTP/文件写入等）不经过终端，事件输出就是全部可见内容。
- "查看完整输出"只在存在完整输出源时提供；命令类统一给"在终端查看"，工具类只展示事件输出。
- 注意：工作区正在引入 `runOnce`（静默通道，不写入交互终端），目前用于监控/系统信息采集。如果后续 AI 命令也切到静默通道，"在终端查看"将失效，必须改为专用输出查看器 + 落盘证据。
- 已落地 `outputTail`：非查询命令保留最多 8KB 原始尾部，随 result 事件持久化，结果卡内可展开；更完整的输出落盘/专用查看器仍未做。

### 8.3 失败分类与恢复动作

复用 `CommandFailureKind`，映射为面向用户的动作：

| failureKind | 用户看到的 | 可用动作 |
|---|---|---|
| disconnected | 服务器连接已断开 | 重连 / 重试本步 |
| timeout | 命令执行超时 | 延长超时重试 / 终止 |
| permissionDenied | 权限不足，需要 sudo 或更高权限 | 使用 sudo 重试 / 更换用户 / 终止 |
| interactivePrompt | 命令在等待输入（密码/确认） | 提供输入 / 终止 |
| syntaxError | 命令语法错误，未执行 | 修正后重试 |
| cancelled | 已取消 | 重新执行 |
| unknown | 执行失败（退出码 N） | 重试 / 查看输出 / 终止 |

所有失败都必须显示退出码（有则显示）和主机。失败结果卡提供"让 AI 重试"：把失败命令与错误首行带回新一轮任务；只有当前主机已连接时才可用。disconnected 失败额外提供"重连"，直接重连当前主机并刷新 Agent executor。

### 8.4 危险操作确认卡

确认卡按"影响"组织，而不是只甩一条命令：

```
需要确认 · web-01
将执行：systemctl restart nginx
影响：重启 Nginx 服务，网站可能中断数秒
风险：高（修改运行中的服务）
可回滚：重启类操作无自动回滚；执行前已生成状态快照
[取消] [确认执行]
```

- 风险等级来自 `SafetyGuard`；变更类型来自 `ChangeRecordService.inferType`。
- 快照能力来自 `RollbackAdvisor`（已存在）。
- "影响"文案没有现成数据：SafetyGuard 只给等级，ChangeRecordService 只给类型。P1 新增 `RiskExplainer`（类型 + 命令 → 通俗影响）；未覆盖时用保守通用文案（"该命令会修改服务器状态"），不编造具体影响。
- 非技术用户可读；技术用户可展开完整命令。

### 8.5 变更与回滚

- 只展示 `ChangeRecord` 中成功的变更；失败命令单独归入"失败记录"。
- 回滚按钮仅在 `rollbackCommand != null` 时出现；点击后必须二次确认并显示回滚命令、主机、审计提示。
- 回滚执行走 `ChangeRecordService.executeRollback`（已含安全检查和审计），成功后 UI 标记"已回滚"。该 API 需要当前主机的已连接 executor：历史操作单里的主机如果未连接，按钮会提示"主机未连接"，不会执行。
- `restart / fileOperation / permission / modifyConfig / other` 当前没有自动回滚（`restartService` 明确返回 null），显示"无自动回滚，建议使用执行前快照"。
- 台账范围：shell 变更在 `_handleExecuteAction` 记录；文件工具（`file_write / file_patch / sftp_upload / upload_to / file_sync`）由引擎在工具成功后补写 ChangeRecord（type=fileOperation）与 AuditLogger，并进入 report.changes。`file_patch` 提供行级 `+N -M` 统计；其他文件工具没有 diff，回滚统一标"无自动回滚"。
- `ChangeRecord.username` 目前未写入，UI 不展示操作者；如需审计展示，需在 record 时补充。
- 引擎当前忽略 `ChangeRecordService.record` 的返回值；需要收集 `record.id` 到 `_operationChangeIds`，report 事件带上。失败记录也收集，但 UI 在"变更"段只显示 `success=true`，失败记录单列。
- 查询方式：`ChangeRecordsDao` 目前只有 `getCachedByHost` / `cachedAll`；需要新增按 `operationId` 过滤的查询（或确保 cache 已加载后内存过滤），不要在 build 中直接遍历数据库。
- 操作单变更区提供"审计记录"入口，跳转 `/audit-log?hostId=...`；回滚执行本身也会写审计。

### 8.6 历史与旧数据

- 新消息：完整操作单。
- 旧消息（无 report 事件）：渲染为"遗留记录"紧凑模式，只显示原有事件摘要，不伪造结论、变更、步数。
- 重启 App：从 `ConvMessage` 恢复操作单；进行中的任务显示"已中断于第 N 步"，不自动续跑。
- 中断判定：新格式回合（带 hostId/toolName/duration/plan 等元数据）若没有 finish/report，则渲染"任务已中断"横幅并允许继续；旧格式回合没有这些元数据，不误标。不要为中断回合伪造 report 或成功结论。

### 8.7 响应式

- 窄屏（手机）：结论与变更优先；目标条压缩为两行；主机矩阵改为按主机分组的纵向列表。
- 宽屏：操作单最大宽度与聊天区一致，不额外加卡片边框；避免三层嵌套容器。
- 本地模式：主机维度退化为"本地"标签；变更台账与审计仍按 hostId='local' 走同一套逻辑，实现时需验证。

---

## 9. 模块映射

| 职责 | 现有模块 | 动作 |
|---|---|---|
| 事件模型 | `models/agent_event.dart` | 扩展 result/command 字段；新增 report 类型 |
| 事件持久化 | `services/daos.dart` | report 事件 JSON；result 元数据字段 |
| 任务元数据 | `models/agent_model.dart` / `agent_state.dart` | 增加 stepIndex、operationId；暴露给视图 |
| 引擎事件 | `services/agent_engine.dart` | 工具调用独立 command id；传递 host/tool/duration/exitCode/failureKind；所有终态 emit report；验证钩子 |
| 变更台账 | `services/change_record_service.dart` | 写入 operationId；增加按 operationId 查询；P1 覆盖文件工具 |
| 审计 | `utils/audit_logger.dart` | 提供"查看审计"入口 |
| 多机 | `services/multi_host_executor.dart` | P2 结构化 hostResults |
| 视图模型 | 新增 `services/operation_sheet_builder.dart` | 由 ChatItem/events/task/changes 构建 |
| 渲染 | 新增 `widgets/operation_sheet.dart`、`live_bar.dart`、`change_ledger.dart` | 新结构 |
| 现有渲染 | `widgets/agent_event_cards.dart` / `agent_command_block.dart` | 降级为证据层组件，移除重复标题栏 |
| 页面 | `pages/terminal_page.dart` | 接入目标条、操作单；工具栏徽标简化 |
| 提示词 | `services/agent_engine.dart` / l10n prompts | finish 四段式、变更后验证、计划协议 |

---

## 10. 落地阶段

### P0：操作单骨架（不改引擎决策逻辑）

1. 扩展 `AgentEvent.result/command` 元数据（host/tool/duration/exitCode/failureKind/output meta）；修复工具 result 复用 `_lastCommandEventId` 的错配。
2. `AgentTask` 暴露 `stepIndex`；`startTask` 生成 `operationId`，`resumeTask` 沿用（建议由引擎持有，Provider 只透传；最终归属见 A.6）。
3. 新增 `report` 事件（operationId/goal/elapsed/step/counters/conclusion/nextActions）并在所有终态路径 emit；Provider 即时持久化 report。
4. 新增 `OperationSheetBuilder` + `OperationSheet` 渲染：目标头、结论、证据折叠。
5. 输入框上方常驻目标条；运行中活块（阶段 + 当前命令 + 计时 + 停止 + "在终端查看"）。
6. finish 报告四段式提示词 + `_finishTask(summary: step.thought)`；结论与证据分离；P0 用中性"AI 结论"标签，不强制"未验证"警告。
7. 旧数据降级为遗留模式；统计口径标注"命令"。

验收：单命令任务、多步任务、失败任务各跑一遍；重开 App 能复原"目标/耗时/步数/结论/证据"；取消/中断也能落 report。

### P1：变更、风险与失败恢复

1. 变更台账接入操作单；回滚按钮 + 二次确认；无回滚能力明确标注；按 operationId 查询。
2. 文件工具（FileWrite/FilePatch/SFTP/FileSync）补 ChangeRecord + AuditLogger，必要时补 diff 统计；在此之前"变更"段只承诺命令变更。
3. 危险确认卡按影响展示（RiskExplainer + 回滚 + 快照）。
4. 失败分类与恢复动作（重连/重试/ sudo/终止）。
5. 输出预算与截断标注；完整输出落盘策略（outputTail + 容量上限）。
6. 验证检测器（systemctl/ss/curl 等常见检查）与 verified 徽标。

验收：权限不足、断线、超时、危险命令取消/确认、回滚成功/失败、文件变更入台账。

### P2：计划、多机与连续性

1. 计划清单协议（工具或 ReAct 字段）与执行清单渲染。
2. 阶段时间线（可选）。
3. 多主机矩阵（ToolResult/AgentEvent 结构化 hostResults）。
4. 暂停/恢复连续性：operationId 不变、步数累计、计划/耗时/报告延续。
5. 断点续跑（需要引擎状态恢复设计，单独立项）。
6. 专用实时输出查看器（当前只有终端 scrollback）。

---

## 11. 验收标准

| 场景 | 期望 |
|---|---|
| 单条只读命令成功 | 结论一句话；1 行命令证据；无变更段 |
| 多步变更成功 | 结论 + 执行清单 + 变更/回滚 + 证据折叠 |
| 权限不足 | 结论说明失败原因；恢复动作"使用 sudo 重试"；主机/退出码可见 |
| 连接断开 | 不显示"命令失败"了事；显示"连接已断开"+ 重连入口 |
| 危险命令等待确认 | 影响卡包含主机、影响、风险、回滚；命令可展开 |
| 多主机部分失败 | 矩阵显示每台状态；失败主机可钻取；不串成一条流 |
| 用户取消 | "已取消于第 N 步"；不显示成功结论；证据保留 |
| 达到步数上限 | "达到步数上限，任务中断"；可继续；不标成功 |
| App 重启 | 操作单恢复；进行中任务标"已中断"；不自动重跑 |
| 旧会话 | 遗留紧凑模式；不伪造结论/变更 |
| 输出超长 | 显示摘要 + "已截断（原始 N 字符）"；完整输出入口明确 |

---

## 12. 风险与开放问题

### 12.1 风险

1. **模型不按四段式输出**：需要 fallback（模板化结论 + 统计），不能让 UI 空白。
2. **虚假结论**：模型声称"运行中"但无验证。P0 用中性标签、弱化成功色；P1 起用确定性检测或"未独立验证"标记兜底。
3. **回滚误导**：只有部分变更可自动回滚，UI 不能暗示全部可退。
4. **输出存储成本**：完整输出落盘需要容量上限与清理策略。
5. **性能**：长任务事件多；必须使用扁平列表/惰性构建，禁止在 build 中查库。
6. **异步安全**：报告生成、变更查询都要遵守 R1/R2/R3（代际检查、回调清理、host 隔离）。
7. **数据迁移**：采用 report 事件而非扩展 ConvMessage，迁移面已缩小；AgentEvent 新字段仍必须向后兼容，旧数据不得因解析失败丢失。
8. **暂停/恢复**：已修复连续性：`resumeTask` 保留 operationId、计划、步数偏移、耗时、成功/失败计数；task id 仍会新建，但操作单按 operationId 聚合。
9. **统计口径**：成功/失败数只覆盖 shell 命令；文件工具、SFTP 操作不在其中（但已进入变更台账），UI 不能笼统写"全部操作成功"。

### 12.2 开放问题（需要产品决策）

1. 默认视图：所有用户默认简洁视图，还是技术用户默认展开证据？
2. 结论生成：模型四段式 + 确定性校验，是否接受"未独立验证"这个中间态？
3. 完整输出保留多久、存在哪里（会话日志/审计/临时文件）？
4. 多主机矩阵是否 P2 必须，还是先用文本摘要 + 主机标签？
5. 计划清单的更新协议：工具调用（可靠、多一次往返）还是 ReAct 内联字段（省往返、解析脆弱）？
6. 回滚按钮是否允许在操作单里直接执行，还是只跳转变更台账？
7. 本地终端模式是否复用同一套操作单（主机维度退化为"本地"）？
8. `operationId` 由引擎还是 Provider 生成？`ChangeRecord` 是新增字段还是把现有 `conversationId` 语义改为 operationId（涉及历史数据）？
9. 文件类工具（写入/补丁/上传）是否必须在 P1 纳入变更台账？这关系到"可追溯"承诺是否完整。

---

## 附录 A：二次逻辑验证

> 本节在文档初稿完成后，逐条对照代码做第二轮验证。判定标准：文档里每个 UI 元素必须有数据源；每个终态必须有报告出口；每个产品承诺必须有代码能力支撑。不满足的标注"需新增/需降级"，并回写正文。

### A.1 验证范围

- 事件模型与序列化：`agent_event.dart`、`daos.dart`、`chat_item.dart`
- 引擎终态与事件发射：`agent_engine.dart`（finish/cancel/maxSteps/异常/未连接）
- Provider 持久化链路：`agent_provider.dart`（`onEvent`、`onCompleted`、`_persistAssistantCompletion`）
- 变更与审计：`change_record_service.dart`、`audit_logger.dart`、`FileWriteTool/FilePatchTool`
- 多机执行：`multi_host_executor.dart`、`ExecBatchTool`
- 输出链路：`executeAndWait`、`outputController`、截断常量
- 暂停/恢复：`pauseTask`、`resumeTask`
- 工程规则：AGENTS.md R1–R9

### A.2 数据可得性核对

| 界面元素 | 规划数据源 | 代码现状 | 结论 |
|---|---|---|---|
| 目标 | `AgentTask.goal`（实时）/ report.goal（历史） | 内存有，不持久化 | report 事件承载历史 |
| 总耗时 | `AgentTask.elapsedSeconds` / `createdAt` | `_notifyTaskUpdate` 每步刷新 | 前端用 `createdAt` 做秒级 ticker |
| 步数 | `_currentStepCount` | 引擎私有，只在 `currentStep` 字符串里 | 新增 `AgentTask.stepIndex` |
| 成功/失败数 | `AgentTask.successCount/failureCount` | 只在 shell 命令执行时累加 | UI 明确标"命令"，工具另计 |
| 当前阶段 | 无 | `AgentStatus` 只有 thinking/executing | 新增展示层 `OperationPhase` |
| 命令/退出码/耗时/失败类型 | `CommandResult` | 有；转 `AgentResult` 时丢 `failureKind` | 扩展 result 事件并透传 |
| 输出 | `AgentEvent.output` | 已被截断（8 行/600 字符；查询 20k） | 标注截断 + 终端链接 |
| 变更记录 | `ChangeRecord` | 有；只覆盖 shell 变更；`conversationId` 实际是 taskId | 引入 operationId；P1 扩工具 |
| 回滚 | `ChangeRecord.rollbackCommand` | 仅 install/start/stop 有值 | 仅在非空时显示 |
| 审计 | `AuditLogger` | 有；只覆盖 shell 命令 | 提供入口，标注范围 |
| 多机结果 | `Map<hostId, CommandResult>` | 有；`ExecBatchTool` 只返回格式化文本 | P2 结构化 hostResults |
| 计划 | 无 | `AgentTask.steps`/`totalStepsEstimate` 从未赋值 | P2 显式计划协议 |
| 验证结论 | 无 | 无 VerificationDetector | P1 实现；P0 用中性标签 |
| 操作者 | `ChangeRecord.username` | record 时未传入 | 不展示 |
| 实时输出 | `outputController` | 命令输出进入终端；`executeAndWait` 无增量回调 | P0 "在终端查看" |

### A.3 终态路径核对

| 终态路径 | 代码事实 | finish 事件 | onCompleted | report 要求 |
|---|---|---|---|---|
| AI 主动 finish | `_finishTask(success:true)` | 有 | 有 | 有 |
| 工具重试耗尽 | `_finishTask(success:false)` | 有 | 有 | 有 |
| `_handleNoCommand` 熔断 | `_finishTask(success:false)` | 有 | 有 | 有 |
| maxSteps 耗尽 | 直接置 failed + finish(interrupted) | 有 | 有条件 | 有 |
| 用户取消 | `cancelTask` + finish(cancelled) | 有 | 有条件（累积文本非空） | 有，需即时持久化 |
| AI 调用失败 | 直接置 failed + finish(failed) | 有 | 无（避免污染知识库） | 有，需即时持久化 |
| startTask executor 为 null | 直接置 failed | **无** | 无 | 有，需补统一出口 |
| `_executeAutomatic` 未连接 | 直接置 failed | **无** | 无 | 有，需补统一出口 |
| resumeTask 异常 | 直接置 failed | **无** | 无 | 有，需补统一出口 |
| pauseTask | 非终态 | 无 | 无 | 无 |

结论：报告生成不能只挂在 `_finishTask`。需要抽一个统一的 `_emitTerminalReport(...)`，在上述所有终态路径调用；顺带补齐三条缺失的 finish 事件（R5）。

### A.4 发现的问题与修订

| ID | 问题 | 严重度 | 处置 | 正文落点 |
|---|---|---|---|---|
| V1 | finish/cancel 把 `_accumulatedMessage` 当结论 | 高 | 新增 report 事件 + 四段式；finish summary 仅兜底 | 7.4 / 7.5 |
| V2 | 报告只挂 `_finishTask`，遗漏 cancel/maxSteps/AI 失败/未连接/resume 异常 | 高 | 统一终态出口，所有路径 emit report | 7.4 / A.3 |
| V3 | 扩 `ConvMessage` 字段需改持久化链路，中间写入可能丢字段 | 中 | 改为 report 事件，复用 events JSON | 7.4 |
| V4 | 工具 result 复用 `_lastCommandEventId`，可能错挂到上一条 shell 命令（R4） | 高 | 每次工具调用生成独立 command 事件与 id | 7.2 / P0 |
| V5 | 成功/失败计数只覆盖 shell 命令 | 中 | 标注"命令成功数"；工具另计 | 7.3 / 8.5 |
| V6 | 文件工具/SFTP 不写 ChangeRecord 与 AuditLogger | 高 | P0 只承诺"命令变更"；P1 补台账与审计 | 8.5 / P1 |
| V7 | 自动回滚只覆盖 install/start/stop | 中 | 仅 `rollbackCommand != null` 显示按钮；其余提示快照/人工 | 8.5 |
| V8 | 输出有三重截断：事件 8 行/600 字符、查询 20k、审计 500 字符 | 高 | 标注截断 + 终端链接；P1 outputTail | 8.2 |
| V9 | 没有实时输出 API；输出只进终端 scrollback | 中 | P0 "在终端查看"；P2 专用查看器 | 5.4 / 8.2 |
| V10 | maxSteps=0 表示无限；resume 重置步数 | 中 | 有上限才显示 N/M；P2 修连续性 | 6.3 / 7.3 / 12 |
| V11 | `ChangeRecord.conversationId` 实际写 taskId，resume 后断链 | 高 | 引入 operationId，report/change 都用它 | 7.4 / 8.5 |
| V12 | `AgentTask.steps`/`totalStepsEstimate` 从未赋值 | 中 | 不能当计划数据源；P2 显式协议 | 7.6 |
| V13 | 多机结果只有格式化文本，`ToolResult` 无 metadata | 中 | P2 结构化 hostResults | 7.7 |
| V14 | P0 没有验证器，强制标"未验证"会造成噪音 | 中 | P0 用中性"AI 结论"；P1 再上 verified 徽标 | 7.5 |
| V15 | 确认卡的"影响"文案没有现成数据 | 低 | P1 `RiskExplainer`；未覆盖用保守文案 | 8.4 |
| V16 | report 若只在 `onCompleted` 持久化，取消且无累积文本时会丢 | 高 | Provider 对 `report` 事件即时持久化 | 7.4 |
| V17 | 旧会话没有 report，直接解析会空白 | 低 | 遗留紧凑模式 | 8.6 |
| V18 | 本地模式 hostId 可能写 'local'，台账/终端行为不同 | 低 | 主机标签显示"本地"；实现时验证 | 8.7 / 12 |
| V19 | 实时计时若只依赖 `elapsedSeconds` 会按步跳变 | 低 | 前端用 `createdAt` ticker，步进只做校准 | 5.2 |
| V20 | report 可能在 finish 后被循环末尾重复 emit | 中 | `_reportEmitted` 幂等标记 | 7.4 |
| V21 | 回滚需要有已连接 executor；历史主机可能不可回滚 | 中 | 仅当前已连接主机直接回滚，否则跳转 | 8.5 |
| V22 | 模型不一定遵守四段式 | 中 | 模板化 fallback（统计 + 通用结论） | 7.5 / 12 |
| V23 | `ActionType.finish` 不把 `step.thought` 传给 `_finishTask`，四段式无法生效 | 高 | `_finishTask(summary: step.thought)` 或新增 `总结:` 字段 | 7.5 |

### A.5 修订后的自洽性检查

- **数据源**：A.2 中每个界面元素都有明确来源；无来源的项已标"需新增"。
- **终态**：A.3 所有终态都有 report 出口；report 只 emit 一次。
- **统计口径**：步数、命令成功/失败、工具调用、文件变更分别标注，不混算。
- **回滚**：只在有 `rollbackCommand` 且主机已连接时提供；否则明确"无自动回滚"。
- **输出**：UI 折叠与引擎截断分开标注；完整输出入口与来源匹配。
- **旧数据**：无 report 走遗留模式，不伪造结论。
- **R1/R2**：report 生成是同步的；若查询变更记录是异步，await 后必须做代际/host 校验；阶段计时器在 dispose 时取消。
- **R3**：report/变更查询使用捕获的 operationId/hostId，不用 `activeHostId`。
- **R4**：一命令一 id；工具调用独立 id；report 每 operation 一个。
- **R5**：failed 不标 completed；所有终态 emit finish/report；知识库记录仍只认 `completed`。
- **R8**：report JSON 有大小上限；输出有 cap；截断必须可见。
- **R9**：事件字段变更需 grep 所有消费者：`agent_event_cards`、`react_stream_parser`、`daos`、`chat_item`、测试用例。

### A.6 仍需产品决策

1. operationId 的归属与生命周期（引擎 / Provider；跨会话是否复用）。
2. `ChangeRecord` 是新增 `operationId` 字段，还是把 `conversationId` 语义正式改为 operationId（需要迁移历史数据）。
3. 文件类工具是否 P1 必须纳入台账（关系到"可追溯"承诺的完整性）。
4. P0 是否接受"AI 结论 + 证据折叠"这个中间态，还是等验证器一起上。
5. report 事件是否只用于 UI（建议不进入 AI 对话上下文，避免自我强化）。
6. 取消/中断时结论的措辞模板（"已取消于第 N 步" vs "部分完成"）。
7. AI 命令是否也改走静默通道（`runOnce`）？如果是，证据层必须有自己的输出落盘，不能再依赖"在终端查看"。

---

## 附录 B：P0 落地记录（2026-10-25）

### B.1 已实现

| 能力 | 实现 |
|---|---|
| `report` 事件 | `models/agent_event.dart`、`models/operation_report.dart`、`services/daos.dart` |
| 结论生成 | `_finishTask(summary: step.thought)` → `OperationReport.extractConclusion`；取消/失败/中断用确定性模板 |
| 终态覆盖 | `_finishTask`、`cancelTask`、maxSteps、AI 调用失败、外层异常、executor 为空、未连接、resume 异常 |
| 工具事件 | `_handleToolAction` 生成独立 command 事件与 id；result 关联自身 id，不再复用 `_lastCommandEventId` |
| 结果元数据 | result 事件带 hostId/toolName/durationMs/exitCode/failureKind/outputTotalChars/outputTruncated |
| 操作单 | `widgets/operation_sheet.dart`：目标头、结论、AI 结论标签、下一步、可折叠证据 |
| 常驻运行条 | `LiveOperationBar`：目标、阶段、步数、计时、暂停/恢复/停止、在终端查看 |
| 运行态折叠 | `CollapsibleEventStream`：运行中只展示最近事件，更早的折叠为一行摘要 |
| 变更与回滚 | report 携带成功变更摘要（命令/类型/回滚命令）；操作单显示"可回滚/需人工" |
| 确定性验证 | `VerificationDetector` 识别 systemctl/ss/curl/nginx -t，生成状态徽标；有成功徽标时 verified=true |
| 变更计数 | 引擎收集成功变更 id，report 显示"N 项变更" |
| 执行清单 | ReAct `计划:` 字段 → `plan` 事件 → `PlanPanel`；report.plan 持久化；resume 保留计划 |
| 计划 UI | 运行中常驻在事件流上方；完成后在操作单内；计数/状态/当前步骤高亮/长计划折叠 |
| 阶段文案 | `AgentTask.phase`：理解需求/思考中/检查环境/执行变更/验证结果/整理结论；运行条展示 |
| 暂停恢复连续性 | operationId、计划、步数偏移、耗时、成功/失败计数、已执行标记全部跨恢复保留 |
| 危险命令影响说明 | `RiskExplainer`：变更类型、通俗影响、SafetyGuard 风险原因、回滚命令；命令块内展示 |
| 变更分类修复 | `ChangeRecordService` 支持 `sudo` 前缀，重启/服务类命令不再误判为 other；回滚保留 sudo |
| 历史命令状态 | 已执行命令显示"已运行"，不再显示播放按钮；证据层不再看起来像可重复执行 |
| 文件工具台账 | 文件写入/补丁/上传/同步成功后补 ChangeRecord + AuditLogger，进入 report.changes |
| 失败恢复提示 | 结果卡按 failureKind 显示 sudo/重连/超时/非交互等下一步建议 |
| 回滚执行 | 操作单"回滚"按钮 → 二次确认（主机/命令/审计提示）→ 已连接 executor → executeRollback；成功后标记"已回滚" |
| 多主机矩阵 | `HostExecutionResult` + `ToolResult.hostResults` + `AgentEvent.result.hostResults`；证据层按主机展示状态/耗时/退出码/失败类型 |
| 审计入口 | 操作单变更区"审计记录" → `/audit-log?hostId=...` |
| 原始输出尾部 | 非查询命令保留最多 8KB 原始输出尾部；结果卡内可展开，弥补 8 行/600 字符截断 |
| 失败重试 | 失败结果卡"让 AI 重试"：携带失败命令与错误摘要启动新一轮任务；要求当前主机已连接 |
| 文件 diff 统计 | `file_patch` 计算 old→new 的行级增删（LCS，≤600 行），随 OperationChange 持久化并在变更行显示 `+N -M` |
| 断线重连 | disconnected 失败卡"重连"；当前主机 tab 必须匹配，重连成功后刷新 Agent executor |
| 多主机重试 | 矩阵失败主机可"重试失败主机"：把失败 hostIds 带回新一轮任务，只重试失败项 |
| 继续任务 | 取消/失败/步数中断的操作单提供"继续任务"：带上次目标和执行清单开启新一轮，要求先核对状态再续做；必须匹配原操作主机 |
| 复制操作单 | 结论区一键复制目标/结论/变更摘要，便于贴到工单或群聊 |
| 中断回合识别 | 历史回合有新格式元数据但没有 finish/report → 显示"任务已中断"横幅 + 继续任务；旧格式不误标 |
| 当前命令映射 | 运行中把"尚未产出结果的命令"显示在第一个进行中计划步骤下；只展示，不自动改步骤状态 |
| 输出查看器 | 原始输出尾部支持底部面板查看：搜索过滤、复制全部、字符数提示 |
| 重连状态 | 重连期间显示"正在重连 X · 连接恢复中"常驻横幅 |
| 提示词 | finish 四段式 + 变更后验证；`_finishTask` 使用 finish 思考作为总结 |
| 旧数据 | 无 report 事件的消息继续走原有事件流渲染 |

### B.2 实现中的决策

1. **report 用事件承载，不扩 ConvMessage**：复用现有 events JSON 持久化，避免改 `_persistAssistantCompletion` 和会话表结构。
2. **P0 不强行标"未验证"**：没有验证检测器时只显示中性"AI 结论"，避免每轮都出现警告；P1 再上 verified 徽标。
3. **工具调用用 command 事件 + `isTool` 标记**：既是证据层的一行记录，又禁止把工具参数当 shell 命令执行。
4. **operationId 由引擎生成**：startTask 生成，resumeTask 沿用；变更台账的 `conversationId` 写入 operationId。
5. **结果卡显示失败分类**：权限不足/断线/超时/语法错误等直接可见，退出码、耗时、截断提示作为元数据 chips。
6. **常驻条固定在输入框上方**：切 tab 回来仍能看到目标与阶段；工具栏徽标简化为"思考中/执行中"。
7. **真实模型校准**：finish 时计划不得留下进行中步骤（提示词 + UI 警告）；四段可能写在同一行，结论解析在下一个段标签前截断；模型不写四段时回退首段，不伪造章节；finish 思考为空时结论使用确定性模板，禁止回退到完整 ReAct 文本。
8. **文件编码修复（真实 E2E 发现）**：PTY 写入前临时关闭 ICRNL/INLCR/IGNCR 并恢复 stty，避免 CRLF 的 `\r` 被吞；`executeAndWait` 的 marker 改为另起一行，避免 heredoc 结束行被 `; echo` 破坏。

### B.3 验证

- `flutter analyze --no-pub`：无新增 error/warning（仅存量 info/warning）。
- `flutter test --no-pub`：358 个测试通过，4 个环境变量启用的 E2E 默认跳过。
- `flutter build windows --debug --no-pub`：构建成功（`build\windows\x64\runner\Debug\ai_terminal.exe`）。
- **真实 SSH E2E（确定性脚本模型）**：CentOS 8 Docker 容器（127.0.0.1:1022）；执行 `cat` / `ss -lntp` / `file_write` / `file_patch` / `cat`；report 计划 3/3 完成、端口 22 验证徽标、file_patch `+2 -1`、操作单渲染通过。命令：`E2E_SSH_HOST=... E2E_SSH_PORT=... E2E_SSH_USER=... E2E_SSH_PASSWORD=... flutter test --no-pub test/docker_e2e_test.dart`。
- **真实 LLM + 真实 SSH E2E**：本地 OpenAI 兼容网关（`agnes`）驱动真实 Agent；模型按 ReAct 执行 `cat` / `ss -lntp` 并 finish；report success、计划全部完成、端口 22 徽标；操作单从真实事件生成。命令：设置 `E2E_LLM_BASE_URL / E2E_LLM_API_KEY / E2E_LLM_MODEL` 和 `E2E_SSH_*` 后运行 `flutter test --no-pub test/local_llm_e2e_test.dart`。
- **文件编码 E2E（真实 SSH）**：逐字节校验 `file_write` / `file_patch` / `append` / CRLF / 无尾换行 / 7.5KB+1.5KB 分块 / PTY stdin / 引号 heredoc。中文、emoji、`$`、反引号、引号、反斜杠、制表符、尾部空格全部按 UTF-8 原样落盘。
- **真实 LLM 写中文文件 E2E**：本地 `agnes` 模型按 ReAct 调用工具写入中文/emoji 文件；严格 UTF-8 解码成功、35 字节、无 BOM、内容包含中文与 emoji。模型可能省略“第 N 行：”前缀，这是提示词遵循问题，不是编码问题。
- 真实模型校准发现：finish 时计划可能留下进行中步骤；四段可能写在同一行；模型有时不按四段输出。已分别用提示词约束 + UI 警告、结论段截断、首段回退处理。
- 新增测试：
  - `test/operation_report_test.dart`：JSON 往返、结论/建议/详情解析、finish 四段式端到端、AgentTask/AgentResult 元数据。
  - `test/operation_sheet_widget_test.dart`：操作单渲染、证据展开、失败态、运行条交互、360px 窄屏无溢出。
  - `test/agent_engine_resilience_test.dart`：finish 发射 success report 且先于 finish；取消发射 cancelled report；校验命令生成状态徽标并标记 verified。
  - `test/verification_detector_test.dart`：systemctl/ss/curl/nginx -t 的确定性检测。
  - `test/plan_parser_test.dart`：计划标记解析、中文状态、散文过滤、空计划。
  - `test/operation_sheet_widget_test.dart`：PlanPanel 计数/折叠/展开全部；操作单内计划渲染。
  - 引擎测试：模型计划写入 report，且每个步骤发出 plan 事件；暂停恢复保留 operationId/步数/命令计数；截断结果保留原始输出尾部。
  - `test/risk_explainer_test.dart`：重启/安装/权限变更的影响与回滚说明。
  - `test/change_record_service_test.dart`：sudo 前缀下的变更分类、回滚命令、文件工具台账描述、executeRollback 实际执行。
  - 操作单 widget 测试：回滚按钮回调、已回滚状态、回滚中禁用；失败卡"让 AI 重试"/"重连"回调；`+N -M` 展示；中断/失败"继续任务"回调；复制操作单入口。
  - `test/interrupted_turn_detector_test.dart` / `test/interrupted_turn_banner_test.dart`：新格式未完成回合识别、旧格式不误标、中断横幅与继续回调。
  - PlanPanel 测试：进行中步骤下展示当前命令。
  - `test/output_viewer_sheet_test.dart`：输出查看器搜索过滤与空匹配提示。
  - `test/reconnecting_banner_test.dart`：重连主机与"连接恢复中"文案。
  - `test/file_encoding_e2e_test.dart`（环境变量启用）：SFTP/PTY/heredoc 的 UTF-8、CRLF、特殊字符、分块写入逐字节校验。
  - `test/local_llm_e2e_test.dart`（环境变量启用）：真实模型读检查 + 写中文/emoji 文件。
  - `test/line_diff_test.dart`：行级 diff 的增删、CRLF、超限返回 null。
  - `test/host_result_matrix_test.dart`：per-host JSON、矩阵状态/展开、360px 无溢出、result 卡片多主机矩阵、"重试失败主机"回调。
- 真机视觉验收：E2E 已用真实 SSH 与真实 LLM 验证数据/渲染管线，但尚未做人工截图核对最终视觉；UI 结构、交互和窄屏溢出由 widget test 覆盖。

### B.4 后续可选（非本轮目标）

以下三项是刻意保留的边界，不是遗漏：

- **更完整的输出落盘**：当前保留 8KB 原始尾部并提供可搜索/复制的查看器，足够排障；无限日志需要独立的容量与清理策略。
- **状态机级精确断点续跑**：当前对中断/失败回合提供基于对话上下文和上次执行清单的"继续任务"；精确恢复需要改引擎代际/任务壳，单独立项。
- **计划步骤状态自动映射**：当前只把"运行中的命令"展示在进行中步骤下，不自动改状态；计划状态由模型声明，避免用命令成功伪造步骤完成。

## 附录 C：文件传输与本地/远程编辑深测（2026-10-26）

### C.1 新能力

1. **`sftp_download` 工具**：此前 Agent 只能上传（`sftp_upload`）不能下载，单机会话拿到日志/配置只能靠手动 SFTP 面板。新增默认注册的 `sftp_download`，支持单文件与目录递归下载；单文件本地目标是已存在目录或以分隔符结尾时，自动拼接远程文件名。目录语义与上传对称：远端目录放到本地父目录下并自动创建 `basename(remote)`，若本地末段同名则不重复追加。下载与上传一样写入变更台账（`sftp_download remote -> local`）。
2. **传输原子化**：`SftpService.uploadFile` 改为同目录临时文件完整写入后再 rename 覆盖；`downloadFile` 改为本地 `.part` 临时文件完整落盘后 rename。中途失败只删临时文件，不会把服务器原文件或本地目标截断成半成品。OpenSSH 走 `posix-rename`；不支持覆盖 rename 的服务端先移走旧文件、失败自动恢复。
3. **空目录保留**：目录上传/下载不再只处理文件，空目录结构也会在目标端创建。
4. **本地文件编辑**：`file_write` 的本地分支不再依赖 `cat > file` PTY（Windows 直接失败、append 被忽略），改为 Dart 直接文件 I/O：支持 Windows/macOS/Linux、write/append、自动建父目录、覆盖前备份、失败自动恢复。Unix 上若 Dart 进程因权限写不了（例如当前 shell 已 `sudo -i` 进 root），仍回退到 PTY stdin / `sudo tee`，保留旧能力。`file_patch` 新增本地分支，支持本地文件替换。
5. **`file_patch` 字节级替换**：远端与本地都改为按原始字节查找/替换，BOM、CRLF、非 UTF-8 字节原样保留；旧实现的 `utf8.decode(allowMalformed: true)` + 重新编码会损坏非 UTF-8 文件。
6. **降低对模型 base64 的依赖**：真实 E2E 发现本地模型为中文计算 base64 会算错，导致写入乱码或 patch 找不到 old。新增 `file_write.content`（单行写法，`\n/\r/\t/\\` 转义）和 `file_patch.old/new` 纯文本参数；普通中文/配置/单行替换不再需要模型手算 base64。`content_b64/old_b64/new_b64` 保留给二进制、多行、需要保留首尾空白或逐字节精确的场景。`content` 为空会明确拒绝，避免多行内容被单行参数截断后静默写入空文件。
7. **SFTP 文本编辑器防截断**：读取前检查大小，超过 100KB/500KB 上限直接报错，不再“只读前半段再整文件覆盖”；严格 UTF-8 解码，非文本文件拒绝打开；保留 UTF-8 BOM；保存失败时用旧内容恢复，避免网络中断截断原文件。

### C.2 真实 E2E 发现的缺陷

1. **Windows 目录上传把嵌套文件平铺成带反斜杠的文件名**：`uploadDirectory` 用 `p.relative` 得到本机相对路径（Windows 为 `sub\a.txt`），却又用 `p.posix.split` 拆分，POSIX 不认反斜杠，结果远端出现单个文件名 `sub\a.txt`，`sub` 目录下的文件全部落在根目录。修复：本机相对路径先 `p.split`，再用 `'/'` 拼成远程路径。该缺陷只在 Windows 客户端 + 目录上传时出现，之前的单文件/手测未覆盖。
2. **本地模型中文 base64 错误**：同一提示词下模型可能把 `name = 旧值` 编成错误 UTF-8 字节（解码为 `name = 旛��`），`file_patch` 因 old 未找到失败；`file_write` 则可能把中文写成另一种乱码。根因是模型生成 base64 的可靠性，不是传输链路。对策见 C.1.6。
3. **下载失败时本地父路径被当成文件**：本地目标父路径是文件时，Dart `Directory.create` 抛 `PathExistsException`；现在工具返回失败并保留原文件内容，不产生半成品。
4. **SFTP 编辑器保存会截断大文件**：`readFileContent` 只读前 500KB，编辑器保存却整文件 truncate 写入，打开大文件后保存会丢掉剩余内容；同时 BOM 会被 Dart `utf8.decode` 去掉、非 UTF-8 文件会被替换字符损坏。已改为超限/非文本拒绝打开、BOM 原样带回、保存失败恢复旧内容。
5. **`broadcast_upload` 单文件把目录名当文件名**：该工具的 `remote` 语义是“目标目录”，但单文件分支直接把 remote 传给 `UploadToTool`（后者把 remote 当完整文件路径），结果文件被写成名为目录的文件，而不是落在目录内。修复：广播时单文件自动拼接 `basename(local)`；目录仍由 `UploadToTool` 追加目录名。

### C.3 验证

- `test/transfer_e2e_test.dart`（真实 SSH，环境变量启用）9 个场景：
  - 单文件上传/下载：中文/emoji/空格/引号/`$`/反引号/`&`/`;` 文件名与内容、CRLF、BOM、无尾换行；远程与本地覆盖后内容正确且无 `.part/.ai-*` 残留。
  - 2MB 随机二进制（含 0x00/0xFF）：远端 `sha256sum` 与本地 SHA-256 一致，下载后逐字节一致。
  - 目录递归上传/下载：嵌套中文/emoji 文件、`node_modules/.git` 排除、空目录保留、恢复后的相对路径集合与内容逐字节一致。
  - 失败路径：本地源不存在、远程目标不存在、目录未 recursive、上传目标本身是目录、本地父路径是文件、`/proc` 不可写路径；失败后已有文件不变、无临时残留、目标不被误创建。
  - 单文件显式本地路径与结尾分隔符两种下载语义。
  - SFTP 文本编辑器：中文/emoji/CRLF 往返、BOM 逐字节保留、0600 权限位保存后不变、非 UTF-8 文件拒绝打开、超过读取上限拒绝打开且文件不变。
  - 编排传输：`upload_to` 单机上传、`broadcast_upload` 广播到两台主机、`collect_file` 从两台主机采集并加 hostId 前缀；真实内容逐字节一致、无 `.part` 残留。
  - 远程 `file_patch` 纯文本 old/new：BOM/CRLF/中文/emoji 与非 UTF-8 尾部字节全部保留，diff 统计正确。
- `test/local_file_edit_test.dart`（默认运行）17 个场景：本地 `file_write` 中文/emoji/CRLF、append、备份、自动建目录、`content` 转义、空 content 拒绝；本地 `file_patch` 的 BOM/CRLF/非 UTF-8 字节保留、删除、唯一性拒绝、缺失文件、备份、多行中文、纯文本 old/new。
- `test/local_llm_transfer_e2e_test.dart`（真实 LLM + 真实 SSH，环境变量启用）3 个场景：
  - 模型主动调用 `sftp_upload` + `sftp_download`，远端与本地逐字节一致；
  - 模型用 `file_patch`（base64）修改服务器文件，其他中文行保留；
  - 模型用 `file_patch`（纯文本 old/new）修改 Windows 本地文件，其他内容保留。
- 既有 `test/docker_e2e_test.dart`、`test/file_encoding_e2e_test.dart`、`test/local_llm_e2e_test.dart` 与新增套件一起运行：16 个 E2E 全部通过；`flutter test --no-pub` 375 个测试通过、环境变量 E2E 默认跳过；`flutter analyze --no-pub` 无新增 error/warning。

### C.4 刻意边界

- 目录下载跳过符号链接并计入 `skippedLinks`，避免循环与越界；需要跟随链接时应显式处理。
- 目录上传/下载是逐文件串行，暂不做并发与断点续传；大目录失败会保留已完成文件并在结果里列出失败项。
- `file_patch` 的“读取后 stat 再校验”仍有微小 TOCTOU 窗口（与远端实现一致）；真正的事务级原子替换需要服务端锁或版本号。
- 纯文本 `content`/`old`/`new` 会被参数解析器去掉首尾空白；需要保留首尾空白时使用 base64。内容中的字面反斜杠必须写成 `\\`，否则 `\n` 会被当成换行。

## 附录 D：石墨青视觉 Token（2026-10-26）

### D.1 设计判断

“中性石墨 + 青/金”的方向成立：它解决的是旧配色“整块蓝、层级靠蓝色填充、正文与辅助文字混在一起”的问题。落地时做了三点修正：

1. **7%/14% 发丝线太弱**：石墨底上 7% 白仅约 1.19:1、14% 约 1.39:1，仍会出现“分界不明显”。最终使用 12% 默认边框、22% 交互/焦点边框、7% 仅用于内部分隔。
2. **金色与警告色太近**：金色 #E0AF63 与警告 #E8B75C 色相几乎重合。警告改为偏橙 #F09A5C，金色只用于耗时、变更类型、结果时长等“第二数据色”。
3. **青色不做大面积填充**：青色只用于进行中、焦点、链接、可交互控件；卡片靠石墨 surface 阶梯 + 发丝线分层。

### D.2 Token

| 用途 | 深色值 | 说明 |
|---|---|---|
| bg | `#0B0D0D` | 页面底 |
| panel | `#111414` | 操作单/结论/执行清单面板 |
| raised | `#171B1B` | 下一步 chips、变更行、弹窗 |
| active | `#1E2323` | 当前计划步骤、输入填充 |
| hairline | white 7% | 内部分隔 |
| border | white 12% | 卡片默认轮廓 |
| borderHover | white 22% | hover/焦点/当前步骤 |
| textPrimary | `#F1F3F1` | 目标、结论、正文重点 |
| textSecondary | `#B8BEBA` | 正文、章节标签 |
| textTertiary | `#858D88` | 元信息、说明 |
| textMuted | `#6F7671` | 仅禁用/占位/装饰 |
| brand | `#45C8C3` | 当前步骤、链接、AI 标识、发送 |
| gold | `#E0AF63` | 耗时、变更类型、时长等数据 |
| ok | `#6FD39A` | 完成、验证通过 |
| warn | `#F09A5C` | 未收尾计划、危险命令、连接异常 |
| error | `#F07C86` | 失败、删除、阻断 |

浅色主题不直接使用亮青，而是用深青保证白底可读性；`ThemeColors.brand/gold/ok/warn/error` 按 light/dark 分别映射。

| 用途 | 浅色值 | 对比度（对 panel） |
|---|---|---|
| bg / panel / raised / active | `#F3F5F3` / `#FBFCFB` / `#FFFFFF` / `#E7ECE8` | — |
| hairline / border / borderHover | black 7% / 14% / 23% | 1.2 / 1.4 / 1.7 |
| textPrimary / Secondary / Tertiary / Muted | `#171B19` / `#4B534E` / `#68716B` / `#8A938D` | 16.9 / 7.7 / 4.9 / 3.1 |
| brand | `#0B7A75` | 5.0（白字按钮 5.2） |
| gold | `#8A5D0A` | 5.6 |
| ok / warn / error | `#1B7F4B` / `#A65B00` / `#B42318` | 4.9 / 5.0 / 6.4 |

浅色主题的 Material 组件（主按钮、输入焦点、Tab 指示器、Chip 选中态、FAB、分隔线）和 Agent 操作区都使用这套 light token。

### D.3 落地范围

- 全局深色底、卡片、输入、弹窗、文字与边框：`constants.dart` / `theme.dart` / `theme_colors.dart`
- 操作单：结论卡、元信息（耗时金色、失败玫红）、状态徽标、下一步 chips、变更/回滚、证据层、运行条
- 执行清单：石墨面板、当前步骤石墨激活面 + 青色描边、完成/待处理文字层级
- Agent 卡片：命令块、结果卡、询问卡、终态卡、多主机矩阵、断线/中断横幅
- 对话气泡：用户气泡改为中性石墨；AI 角色标签与发送按钮使用品牌青

### D.4 验证

- 对比度：主文字 17.5:1、次文字 9.8:1、三级文字 5.4:1、brand 9.1:1、gold 9.2:1（相对 panel `#111414`）。
- 377 个单元/Widget 测试通过（含浅色主题与英文 Agent 文案渲染测试）；`flutter analyze --no-pub` 无新增 error/warning；Windows debug 构建通过。
- 深色与浅色主题的主按钮、输入焦点、Tab 指示器、Chip 选中态均切换为对应品牌青；Agent 操作单在两种亮度下都通过 360px 窄屏测试。

### D.5 实机启动校验（2026-10-26）

启动 Windows Debug 构建后做了真实窗口截图核对，额外修复：

- **Next actions chip 溢出**：长建议文案把 chip 撑破，出现 Flutter 黄黑溢出条；改为 `Flexible + maxLines: 2`，文本可换行。
- **元信息中文被拆行**：窄侧栏下“4 失败”被拆成两行；元信息由单段 RichText 改为 `Wrap` 按项换行，host 限制 200px 并省略。
- **Material 默认紫色残留**：单选/滑杆仍使用默认 `ColorScheme`；为深/浅主题分别设置品牌青 ColorScheme。
- **终端未跟随主题**：xterm 原为固定纯黑主题；新增深/浅两套 ANSI 调色板，浅色终端背景 `#FBFCFB`、深色 `#080A0A`。
- 浅色主题下操作单、执行清单、结论卡、下一步 chips、终端和输入区均已实机截图确认；当前运行实例停留在浅色模式，可在“设置 → 外观设置 → 跟随系统”切回。

### D.6 对话气泡与字重校正（2026-10-26）

实机查看浅色界面后继续调整：

- **用户气泡与 AI 气泡区分**：用户消息改为品牌青淡染（深色 `#12302E`、浅色 `#E1F2F0`）+ 青色描边；AI 气泡保持中性石墨/近白。角色标签“你/AI 助手”统一使用品牌青。
- **浅色字重提升**：Agent 正文 Markdown、计划步骤、元信息、命令文本、结果输出、输入框及全局 `bodyMedium/bodySmall` 提升到 `w500`；当前步骤/标题保持 `w600+`，避免浅色底上笔画过细。
- 实机确认：用户气泡、结论卡、计划、下一步 chips、终端浅色主题均清晰可读。
