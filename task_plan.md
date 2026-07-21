# 任务计划：Agent 与多机编排功能流程分析

## 目标
系统分析 ai_terminal 项目中 Agent 与多机编排的完整功能流程，重点包括：
- 用户确认 / 终止 / 切换终端 等操作后的流程与数据展示问题
- 识别潜在的 bug 与状态一致性问题（参照 AGENTS.md 中的工程规则 R1-R8）

## 阶段

### Phase 1: 项目结构探索 [completed]
- 梳理 lib/ 目录结构
- 识别核心文件：agent_engine.dart, agent_provider.dart, multi_host_executor.dart 等

### Phase 2: Agent 核心流程分析 [in_progress]
- ReAct 循环（_callAI / _executeCommand / 流式处理）
- 任务状态机（AgentTaskStatus）
- generation 检查机制
- 事件流（AgentEvent / AgentStreamReducer）

### Phase 3: 多机编排流程分析 [pending]
- AgentHostRegistry / 多主机注册
- MultiHostExecutor 广播执行
- 会话隔离（hostId 绑定）
- OrchestratorState

### Phase 4: 用户确认流程分析 [pending]
- SafetyGuard 危险命令检测
- inline 确认按钮 UI 流程
- AgentCommandBlock 状态流转
- 确认/取消后的事件链路

### Phase 5: 终止流程分析 [pending]
- cancelTask 实现
- StreamSubscription.cancel 与 Completer
- 资源清理（SSH/Subscription/Timer）
- 回调清空顺序

### Phase 6: 终端切换流程分析 [pending]
- tab 切换时的状态重置
- cancelTask + reducer.reset
- 非活动主机状态更新（_updateHostState）

### Phase 7: 数据展示流程分析 [pending]
- AgentEvent → UI 渲染链路
- 流式文本更新
- 命令块/结果块显示
- 会话历史持久化

### Phase 8: 汇总报告 [pending]
- 输出最终分析报告
- 标注潜在问题与改进建议

## 关键文件清单
- services/agent_engine.dart - 核心引擎
- providers/agent_provider.dart - 状态管理
- services/multi_host_executor.dart - 多机执行
- services/agent_host_registry.dart - 主机注册
- services/agent_stream_reducer.dart - 事件归约
- core/safety_guard.dart - 安全守卫
- widgets/agent_command_block.dart - 命令块 UI
- widgets/agent_event_cards.dart - 事件卡片 UI
- models/agent_event.dart - 事件模型
- models/agent_state.dart - 状态模型
