import 'agent_model.dart';
import 'agent_permission_mode.dart';
import 'chat_item.dart';
import 'agent_goal.dart';
import 'ai_model_config.dart';

/// Agent 状态
class AgentState {
  final AgentStatus status;
  final AgentTask? currentTask;
  final String? lastMessage;
  final List<ChatItem> chatItems; // 统一的消息列表，包含用户和AI消息
  final String? error;
  final int maxSteps;

  /// AI 流式响应超时（秒）：连续无数据超过该时长即判定超时
  final int aiTimeoutSeconds;
  final String? pendingConfirmCommand; // 等待用户确认的危险命令
  final List<String> pendingOptions; // 等待用户选择的选项
  /// 当前会话所属 hostId（'local' 或服务器 id），用于持久化隔离
  final String? hostId;

  /// 当前会话 id（Conversation.id）
  final String? conversationId;

  /// 早期对话摘要（压缩后产生，显示在 UI 上让用户感知）
  final String? summary;

  /// 是否正在压缩
  final bool isCompacting;

  /// 是否处于多机编排模式
  final bool isOrchestratorMode;

  /// 执行权限档位（只读 / 询问 / 自动 / 全自动）
  final AgentPermissionMode permissionMode;

  /// 联网搜索会话级开关（与全局开关 OR 合并；运行中切换下次任务生效）
  final bool isWebSearchEnabled;

  /// 跨任务持续的目标（host 级状态，切 tab 不丢；null 表示没有目标）
  final AgentGoal? goal;

  /// 模型原生推理（reasoning_content）的当前步增量。
  /// 只有网关返回该字段时才有内容；任务结束即清空，不落库。
  final String liveReasoning;

  AgentState({
    this.status = AgentStatus.idle,
    this.currentTask,
    this.lastMessage,
    List<ChatItem>? chatItems,
    this.error,
    this.maxSteps = 0,
    this.aiTimeoutSeconds = kDefaultAiResponseTimeoutSeconds,
    this.pendingConfirmCommand,
    List<String>? pendingOptions,
    this.hostId,
    this.conversationId,
    this.summary,
    this.isCompacting = false,
    this.isOrchestratorMode = false,
    this.permissionMode = AgentPermissionMode.ask,
    this.isWebSearchEnabled = false,
    this.goal,
    this.liveReasoning = '',
  })  : chatItems = chatItems ?? [],
        pendingOptions = pendingOptions ?? [];

  bool get isRunning =>
      status == AgentStatus.thinking || status == AgentStatus.executing;
  bool get isWaitingConfirm =>
      status == AgentStatus.waitingConfirm && pendingConfirmCommand != null;
  bool get isWaitingChoice =>
      status == AgentStatus.waitingConfirm && pendingOptions.isNotEmpty;

  AgentState copyWith({
    AgentStatus? status,
    AgentTask? currentTask,
    String? lastMessage,
    List<ChatItem>? chatItems,
    String? error,
    int? maxSteps,
    int? aiTimeoutSeconds,
    String? pendingConfirmCommand,
    List<String>? pendingOptions,
    String? hostId,
    String? conversationId,
    String? summary,
    bool? isCompacting,
    bool clearPendingConfirm = false,
    bool clearPendingOptions = false,
    bool clearHostId = false,
    bool clearConversationId = false,
    bool clearSummary = false,
    bool clearError = false,
    bool? isOrchestratorMode,
    AgentPermissionMode? permissionMode,
    bool? isWebSearchEnabled,
    AgentGoal? goal,
    bool clearGoal = false,
    String? liveReasoning,
    bool clearLiveReasoning = false,
  }) {
    return AgentState(
      status: status ?? this.status,
      currentTask: currentTask ?? this.currentTask,
      lastMessage: lastMessage ?? this.lastMessage,
      chatItems: chatItems ?? this.chatItems,
      error: clearError ? null : (error ?? this.error),
      maxSteps: maxSteps ?? this.maxSteps,
      aiTimeoutSeconds: aiTimeoutSeconds ?? this.aiTimeoutSeconds,
      pendingConfirmCommand: clearPendingConfirm
          ? null
          : (pendingConfirmCommand ?? this.pendingConfirmCommand),
      pendingOptions:
          clearPendingOptions ? [] : (pendingOptions ?? this.pendingOptions),
      hostId: clearHostId ? null : (hostId ?? this.hostId),
      conversationId:
          clearConversationId ? null : (conversationId ?? this.conversationId),
      summary: clearSummary ? null : (summary ?? this.summary),
      isCompacting: isCompacting ?? this.isCompacting,
      isOrchestratorMode: isOrchestratorMode ?? this.isOrchestratorMode,
      permissionMode: permissionMode ?? this.permissionMode,
      isWebSearchEnabled: isWebSearchEnabled ?? this.isWebSearchEnabled,
      goal: clearGoal ? null : (goal ?? this.goal),
      liveReasoning:
          clearLiveReasoning ? '' : (liveReasoning ?? this.liveReasoning),
    );
  }

  String get statusText {
    switch (status) {
      case AgentStatus.idle:
        return '就绪';
      case AgentStatus.thinking:
        if (currentTask?.currentStep != null &&
            currentTask!.currentStep!.isNotEmpty) {
          return '🤔 ${currentTask!.currentStep}';
        }
        return '🤔 思考中...';
      case AgentStatus.executing:
        if (currentTask?.currentStep != null &&
            currentTask!.currentStep!.isNotEmpty) {
          return '⚡ ${currentTask!.currentStep}';
        }
        return '⚡ 执行中...';
      case AgentStatus.waitingConfirm:
        if (pendingOptions.isNotEmpty) return '⏳ 等待选择';
        return '⏳ 等待确认';
      case AgentStatus.completed:
        return '✅ 完成';
      case AgentStatus.failed:
        return '❌ 失败';
      case AgentStatus.cancelled:
        return '🚫 已取消';
      case AgentStatus.paused:
        return '⏸️ 已暂停';
    }
  }
}
