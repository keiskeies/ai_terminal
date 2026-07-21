# Agent 与多机编排功能流程分析发现

## 关键发现汇总（按严重程度）

### 高风险问题

#### H1. `_runCommandWithSafety` / `_executeCommand` 缺 generation 检查
- 位置：`agent_engine.dart:1130, 1145-1152, 1572-1583`
- 问题：`await _executeCommand` 后只检查 `status == cancelled`，不检查 generation
- 影响：取消+立即新任务时，旧命令成功/失败会计入新任务 `_currentTask` 统计，旧命令 result 事件注入新任务事件流
- 违反规则：R1（await 后必须 generation 检查）、R5（状态机一致性）

#### H2. `cancelTask` 路径不 emit finish 事件
- 位置：`agent_engine.dart:325-375`
- 问题：cancelTask 只设 cancelled 状态 + `_notifyTaskUpdate`，没有 emit `AgentEvent.finish`
- 影响：UI 若依赖 finish 事件停止流式渲染状态，cancel 后可能卡 running
- 违反规则：R5（所有终态路径必须 emit finish）

### 中风险问题

#### M1. `switchTab` 调用 cancelTask 前不清空回调
- 位置：`agent_provider.dart:106-108`
- 问题：与 `removeTab`/`init`/`dispose` 三个路径不一致（它们都先清空回调 → cancelTask）
- 影响：依赖 `_updateHostState` hostId 路由兜底；cancelTask 后延迟触发的 onMessage 会向旧 host registry 写入脏数据
- 违反规则：R2（清空回调 BEFORE cancel）

#### M2. `_confirmCompleter` 无超时机制
- 位置：`agent_engine.dart:1082`
- 问题：`await _confirmCompleter!.future` 无超时
- 影响：用户不点击确认/取消/停止时，任务无限阻塞 waitingConfirm，无法启动新任务

#### M3. `startTask` 知识库查询 await 后无 generation 检查
- 位置：`agent_engine.dart:267, 273`
- 影响：`_cachedKnowledgeInjection` 实例字段可能被旧任务覆盖

#### M4. `_callAI` 退避延迟后无 generation 检查
- 位置：`agent_engine.dart:686`
- 影响：取消后仍会重试一次 chatStream，浪费 API 调用

#### M5. `AgentNotifier._persistAssistantCompletion` 静默吞错
- 位置：`agent_provider.dart:546-562`
- 问题：catch 块仅 `debugPrint`，无 UI 错误提示
- 影响：assistant 内容持久化失败用户无感知，重启后消息可能缺失
- 违反规则：R8（持久化失败必须暴露）

#### M6. maxSteps 耗尽标记为 completed 而非 failed
- 位置：`agent_engine.dart:626-629`
- 影响：任务被步数上限中断，但 UI 显示"✅ 完成"，语义误导

### 低风险问题

#### L1. fallback 多命令路径 result 关联错误
- 位置：`agent_engine.dart:1265-1281`
- 问题：所有 result 关联到同一个 `_lastCommandEventId`
- 影响：主流程已规避，仅 fallback 路径受影响
- 违反规则：R4

#### L2. 旧版 `ChatNotifier` 完全静默吞错
- 位置：`chat_provider.dart:176, 248, 284`
- 问题：`try { ... } catch (_) {}` / `.catchError((_) {})`
- 影响：仅 `chat_page.dart` 用户受影响（非 Agent 主流程）
- 违反规则：R8

#### L3. `ConversationService.flushAll / _scheduleFlush` 静默
- 位置：`conversation_service.dart:197-199, 217-223`
- 影响：app 退出/日志刷盘失败无提示

#### L4. `SSHConnectionPool.release` 未 await disconnect
- 位置：`ssh_connection_pool.dart:110`
- 影响：清理不够严谨，但实际风险低

#### L5. `_orchestratorCancelToken` 在 cancelTask 中只 complete 不置 null
- 位置：`agent_engine.dart:354-356`
- 影响：状态留置不干净，但下次启动会重新赋值

#### L6. ErnieProvider 错误未映射为友好消息
- 位置：`ai_service.dart:291-294`
- 影响：使用文心模型时看到原始错误

#### L7. `OrchestratorState` 模型未接入执行流程
- 位置：`models/orchestrator_state.dart`
- 影响：当前编排本质是工具级编排，非状态机驱动；状态机模型是"哑模型"

#### L8. 结果卡片全量展开 2 万字符
- 位置：`agent_event_cards.dart:230-242`
- 影响：低端设备可能卡顿（引擎层已截断缓解）

## 规则合规性总览

| 规则 | 合规状态 | 主要问题 |
|---|---|---|
| R1 async cancellation | ⚠ 14处合规，5处缺失 | H1（命令执行路径） |
| R2 resource lifecycle | ⚠ 大部分合规 | M1（switchTab 不清回调） |
| R3 multi-host isolation | ✓ 严格合规 | 无违规 |
| R4 event dedup | ⚠ 主流程合规 | L1（fallback 路径） |
| R5 state machine | ⚠ 大部分合规 | H2（cancel 不 emit finish）、M6（maxSteps 语义） |
| R6 cross-platform | ✓ | - |
| R7 security | ✓ | - |
| R8 defensive | ⚠ 部分违规 | M5、L2、L3（静默吞错） |
