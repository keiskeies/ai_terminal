import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_model.dart';
import '../models/agent_event.dart';
import '../models/agent_memory.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../services/ai_service.dart';
import '../services/ssh_service.dart';
import '../services/command_executor.dart';
import '../services/knowledge_service.dart';
import 'agent_tool.dart';
import 'agent_host_registry.dart' as agent_host_registry;
import 'agent_logger.dart';
export 'agent_logger.dart';
import 'agent_tracer.dart';
import '../core/safety_guard.dart';
import '../core/l10n_holder.dart';
import 'daos.dart';
import '../core/prompts.dart' as prompts;
import '../utils/ansi_stripper.dart';
import '../utils/command_heuristics.dart';
import '../utils/output_processor.dart';
import '../utils/tool_args_parser.dart';
import '../utils/react_stream_parser.dart';
import '../utils/rollback_advisor.dart';
import '../utils/command_extractor.dart';
import '../utils/token_estimator.dart';
import '../utils/audit_logger.dart';
import 'change_record_service.dart';
import 'change_window_service.dart';
import 'notification_service.dart';

/// Agent 执行引擎 - 核心自动执行系统
class AgentEngine {
  final AIProvider _aiProvider;
  final AIModelConfig _modelConfig;
  final AgentMemory _memory;
  final Uuid _uuid = const Uuid();

  AgentTask? _currentTask;
  String _accumulatedMessage = '';  // 跟踪累积的消息
  Completer<bool>? _confirmCompleter; // 等待用户确认危险命令的 Completer
  Timer? _confirmTimeoutTimer; // 确认超时定时器，cancelTask 时需 cancel
  String? _pendingConfirmCommand; // 当前等待确认的命令

  /// 任务开始时间（用于计算 elapsedSeconds 进度）
  DateTime? _taskStartTime;

  /// 当前执行步数（_executeAutomatic 循环计数，供进度文本使用）
  int _currentStepCount = 0;

  /// 任务代际 token：每次 startTask 递增，循环中检查此 token 是否仍为当前任务
  /// 防止取消+立即发送导致旧循环与新循环并发
  int _currentTaskGeneration = 0;

  /// 等待用户选择选项的 Completer（ReAct ask 动作 / :::choose A|B|C:::）
  Completer<String>? _choiceCompleter;
  List<String> _pendingOptions = []; // 当前等待选择的选项

  /// 命令执行取消令牌：cancelTask 时 complete，_executeCommand 据此提前退出
  Completer<void>? _commandCancelToken;

  /// 编排任务的取消令牌：覆盖整个 ReAct 循环周期（比 _commandCancelToken 生命周期长）。
  /// 在 _executeAutomatic 开始时创建并注入到 MultiHostExecutor，cancelTask 时 complete。
  /// 编排工具的 executeAndWait 通过它响应取消，否则点停止后批量命令会跑到 timeout 才停。
  Completer<void>? _orchestratorCancelToken;

  /// 暴露当前编排取消令牌给调试/监控用。
  Completer<void>? get currentCancelToken => _orchestratorCancelToken ?? _commandCancelToken;

  /// AI 流式订阅：cancelTask 时取消，立即停止消费旧任务流
  StreamSubscription<String>? _aiStreamSub;

  /// AI 流式超时看门狗（_callAI 内创建，cancelTask 中取消）
  Timer? _aiWatchdog;
  bool _aiStreamTimedOut = false;

  /// AI 流式完成 Completer（cancelTask 可 complete 以解除 _callAI 挂起）
  Completer<void>? _aiDoneCompleter;

  /// AI HTTP 请求取消令牌（_callAI 内创建，cancelTask 中触发）
  /// 比 _aiStreamSub.cancel() 更彻底：直接关闭底层 Dio HTTP 连接
  /// 避免取消任务后 API 仍在流式输出消耗配额
  CancelToken? _aiCancelToken;

  /// 备用 AI Provider（主模型重试 maxRetries 次仍失败时切换）
  AIProvider? _fallbackProvider;
  AIModelConfig? _fallbackConfig;

  /// 缓存的知识库注入文本（在 startTask 时查询，在 _buildSystemPrompt 时使用）
  String? _cachedKnowledgeInjection;

  /// 持久化对话历史，跨 startTask() 调用保留上下文
  final List<ChatMessage> _conversationHistory = [];

  /// 连续无命令重试计数（防止 AI 只给解释不给命令时过早结束任务）
  int _noCommandRetryCount = 0;
  static const int _maxNoCommandRetries = 2;

  /// 默认最大执行步数（maxSteps=0 时的兜底上限，防止无限循环）
  static const int _defaultMaxSteps = 20;

  /// _accumulatedMessage 最大字符数（防止长任务内存无界增长）
  static const int _maxAccumulatedChars = 20000;

  void Function(String)? onThinking;
  void Function(String)? onCommandGenerated;
  void Function(AgentResult)? onCommandExecuted;
  void Function(String)? onError;
  void Function(AgentTask)? onTaskUpdated;
  void Function(String)? onMessage;
  void Function(String)? onCompleted;

  /// 结构化事件回调（新增）：每个 ReAct 步骤的思考/命令/结果/询问/完成
  /// 通过此回调发出结构化事件，UI 可按事件类型分别渲染卡片。
  /// 保留 onMessage 用于兼容旧 UI 的纯文本流。
  void Function(AgentEvent)? onEvent;

  int maxSteps = 0; // 0 = 无限制（运行时兜底为 _defaultMaxSteps）

  /// 当前引擎所属的 hostId（用于知识库经验匹配和多 host 隔离）
  String? hostId;

  /// 工具注册表 — 管理 AI 可调用的非 shell 工具（如 SFTP 上传）
  final AgentToolRegistry _tools = AgentToolRegistry();

  /// 多机编排模式开关
  bool _orchestratorMode = false;

  bool get isOrchestratorMode => _orchestratorMode;

  /// 只读模式（Dry-run）开关：开启后只允许 safe 级命令执行，info/warn/blocked 全部拒绝
  bool _readOnlyMode = false;

  bool get isReadOnlyMode => _readOnlyMode;

  /// sudo 密码：执行 sudo 命令时检测到密码提示后自动注入（不写入命令本身/审计日志）
  /// 由 AgentNotifier 从 CredentialsStore 加载并设置
  String? _sudoPassword;

  /// R2: 清理工具持有的资源（文件同步的 watcher/timer 等）
  /// 在 agent_provider dispose 时调用
  void disposeTools() {
    _tools.fileSyncService.dispose();
    // 同步重置编排标志，避免 _orchestratorMode 与 _tools.multiHostExecutor 不一致
    _orchestratorMode = false;
    _tools.disableOrchestrator();
  }

  /// 对话历史最大轮数（每轮 = assistant + user），超出时裁剪最早的轮次
  static const int _maxConversationRounds = 40;

  /// 单条消息最大字符数，超出截断
  static const int _maxMessageChars = 4000;

  AgentEngine({
    required AIProvider aiProvider,
    required AIModelConfig modelConfig,
    required AgentMemory memory,
    this.maxSteps = 0,
    this.hostId,
    AIProvider? fallbackProvider,
    AIModelConfig? fallbackConfig,
  })  : _aiProvider = aiProvider,
        _modelConfig = modelConfig,
        _memory = memory,
        _fallbackProvider = fallbackProvider,
        _fallbackConfig = fallbackConfig;

  /// 设置/更新 fallback 模型（运行时切换备用模型用）
  void setFallbackModel(AIProvider? provider, AIModelConfig? config) {
    _fallbackProvider = provider;
    _fallbackConfig = config;
  }

  AgentTask? get currentTask => _currentTask;
  bool get isRunning =>
      _currentTask?.status == AgentStatus.thinking ||
      _currentTask?.status == AgentStatus.executing ||
      _currentTask?.status == AgentStatus.waitingConfirm;
  /// P2-7: 任务是否已暂停（可恢复）
  bool get isPaused => _currentTask?.status == AgentStatus.paused;
  bool get hasPendingConfirm => _confirmCompleter != null && !_confirmCompleter!.isCompleted;
  String? get pendingConfirmCommand => _pendingConfirmCommand;
  bool get hasPendingChoice => _choiceCompleter != null && !_choiceCompleter!.isCompleted;
  List<String> get pendingOptions => List.unmodifiable(_pendingOptions);

  /// 构建进度步骤文本：第 N 步 | ✅成功数 ❌失败数 | 已用秒数
  String _progressStepText() {
    final elapsed = _taskStartTime != null
        ? DateTime.now().difference(_taskStartTime!).inSeconds
        : 0;
    final s = _currentTask?.successCount ?? 0;
    final f = _currentTask?.failureCount ?? 0;
    return '第 $_currentStepCount 步 | ✅$s ❌$f | ${elapsed}s';
  }

  /// 刷新 elapsedSeconds 并通知任务更新（在每次 onTaskUpdated 前调用）
  void _notifyTaskUpdate() {
    if (_currentTask == null) return;
    if (_taskStartTime != null) {
      final elapsed = DateTime.now().difference(_taskStartTime!).inSeconds;
      _currentTask = _currentTask!.copyWith(elapsedSeconds: elapsed);
    }
    final updateCb = onTaskUpdated;
    if (updateCb != null) updateCb(_currentTask!);
  }

  void clearHistory() {
    // 清理瞬态字段，避免旧任务残留污染新会话
    if (isRunning || hasPendingConfirm || hasPendingChoice) {
      cancelTask();
    }
    _resetTransientState();
    _conversationHistory.clear();
  }

  /// 从持久化消息恢复引擎对话历史（切换会话时调用）
  /// [messages] 已摘要索引之后的消息（含 user/assistant，不含 system）
  /// [summary] 对话摘要（如有）
  /// system 消息会在下次 startTask 时由 _buildSystemPrompt 重建
  void restoreHistory(List<ChatMessage> messages, {String? summary}) {
    // 清理瞬态字段，避免旧任务残留污染切换后的会话
    if (isRunning || hasPendingConfirm || hasPendingChoice) {
      cancelTask();
    }
    _resetTransientState();
    _conversationHistory.clear();
    _conversationHistory.addAll(messages);
    agentLogger.info('RestoreHistory', '恢复引擎历史: ${messages.length} 条消息, summary=${summary != null ? "有" : "无"}');
  }

  /// 重置所有任务相关瞬态字段（不清理 _conversationHistory）
  /// 用于 clearHistory / restoreHistory / startTask 开头
  /// R2: 确保旧任务残留的 Completer/Subscription/Timer/CancelToken 不污染新任务
  void _resetTransientState() {
    _accumulatedMessage = '';
    _noCommandRetryCount = 0;
    _lastCommandEventId = '';
    _currentTask = null;
    _taskStartTime = null;
    _currentStepCount = 0;
    // 清理取消令牌（防御性，cancelTask 应该已处理过）
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiStreamTimedOut = false;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiDoneCompleter = null;
    _aiCancelToken = null;
    _commandCancelToken = null;
    _orchestratorCancelToken = null;
    _earlyExecutionCompleter = null;
    _earlyExecutionCommand = null;
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    _confirmCompleter = null;
    _pendingConfirmCommand = null;
    _choiceCompleter = null;
    _pendingOptions = [];
    // 注意：不递增 _currentTaskGeneration — 那是 startTask 的职责
    // 这里只清状态，不失效代际（cancelTask 已失效过的话不需要再失效）
  }

  /// 压缩后同步内存历史：移除已摘要的旧消息，保留最近 N 轮
  /// 使内存中的 _conversationHistory 与持久化层（Conversation.messages）保持一致
  void syncAfterCompact(int keepRecentRounds) {
    final systemMsgs = _conversationHistory.where((m) => m.role == 'system').toList();
    final nonSystemMsgs = _conversationHistory.where((m) => m.role != 'system').toList();
    final keepCount = keepRecentRounds * 2;
    if (nonSystemMsgs.length > keepCount) {
      final kept = nonSystemMsgs.skip(nonSystemMsgs.length - keepCount).toList();
      _conversationHistory
        ..clear()
        ..addAll(systemMsgs)
        ..addAll(kept);
      agentLogger.info('SyncCompact', '同步内存历史: ${nonSystemMsgs.length} → ${kept.length} 条非系统消息');
    }
  }

  /// 启动 Agent 任务
  /// [goal] 用户目标
  /// [executor] 命令执行器，支持 SSHService（远程）或 LocalTerminalService（本地）
  Future<void> startTask(String goal, CommandExecutor? executor) async {
    agentLogger.info('AgentEngine', '=== 开始任务 ===');
    agentLogger.info('AgentEngine', '目标: $goal');
    agentLogger.info('AgentEngine', '模式: Agent (ReAct)');
    agentLogger.info('AgentEngine', '执行器: ${executor != null ? (executor.isConnected ? "已连接" : "未连接") : "无"}');

    if (isRunning) {
      agentLogger.warn('AgentEngine', 'Agent 正在执行任务，拒绝新任务');
      onError?.call(L10n.str.agentRunning);
      return;
    }

    // R2: startTask 开头彻底重置瞬态字段
    // 不依赖 cancelTask 清理（旧任务可能正常 completed 后未清理）
    // 保证新任务起点干净：无残留 Completer/Subscription/Timer/CancelToken
    _resetTransientState();

    // 新任务代际，使任何残留的旧循环退出
    _currentTaskGeneration++;
    final myGeneration = _currentTaskGeneration;
    _taskStartTime = DateTime.now();  // 记录任务开始时间，用于进度计算
    _currentStepCount = 0;

    _currentTask = AgentTask(
      id: _uuid.v4(),
      goal: goal,
      status: AgentStatus.thinking,
    );
    _notifyTaskUpdate();

    // P0-2: trace 任务开始
    AgentTracer.instance.startTask(_currentTask!.id, goal, hostId: hostId);

    // 查询知识库，缓存注入文本
    try {
      final knowledge = KnowledgeService();
      // 确保知识库已初始化（懒初始化兜底）
      await knowledge.ensureInitialized();
      // R1: await 后检查代际，避免旧任务的知识库结果覆盖新任务的 _cachedKnowledgeInjection
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('AgentEngine', '知识库初始化期间代际失效，放弃任务');
        return;
      }
      // 检测远程平台：SSH 连接时从 osInfo 推断，否则用本地平台
      String? knowledgePlatform;
      if (executor is SSHService) {
        knowledgePlatform = KnowledgeService.detectPlatformFromOsInfo(executor.osInfo);
      }
      _cachedKnowledgeInjection = await knowledge.buildKnowledgeInjection(
        goal,
        platform: knowledgePlatform,
        osInfo: executor is SSHService ? executor.osInfo : null,
        hostId: hostId,
      );
      // R1: 第二次 await 后再次检查代际
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('AgentEngine', '知识库查询期间代际失效，放弃任务');
        return;
      }
      if (_cachedKnowledgeInjection != null) {
        agentLogger.info('AgentEngine', '知识库命中 ✓ (platform=${knowledgePlatform ?? "local"})');
      } else {
        agentLogger.info('AgentEngine', '知识库未命中 (platform=${knowledgePlatform ?? "local"})');
      }
    } catch (e) {
      agentLogger.warn('AgentEngine', '知识库查询失败: $e');
      _cachedKnowledgeInjection = null;
    }

    try {
      agentLogger.info('AgentEngine', '执行 Agent 模式');
      await _executeAutomatic(goal, executor, myGeneration);
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '执行异常: $e\n$stack');
      // R1: 代际检查 — 旧任务抛异常时不能覆盖新任务状态
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('AgentEngine', '代际已变更，跳过失败状态写入');
        return;
      }
      final startTime = _currentTask?.createdAt;
      _currentTask = _currentTask?.copyWith(
        status: AgentStatus.failed,
        completedAt: DateTime.now(),
      );
      if (_currentTask != null) {
        // 如果最后一条是 user 消息（无 assistant 响应），添加错误消息保持历史完整
        if (_conversationHistory.isNotEmpty &&
            _conversationHistory.last.role == 'user') {
          _conversationHistory.add(ChatMessage.create(
            role: 'assistant',
            content: '${L10n.str.taskExecutionError}: ${_friendlyErrorMessage(e)}',
          ));
        }
        // R5: 所有终态路径必须 emit finish 事件 + flush 流式内容到持久化
        // 但失败路径不调用 onCompleted（它会触发 _recordLearningFromTask 污染知识库）
        // 只 emit finish 事件让 UI 停止流式状态，流式内容由 onError 回调中的 error 状态替代
        onEvent?.call(AgentEvent.finish(summary: '⚠️ 任务异常终止: ${_friendlyErrorMessage(e)}'));
        onError?.call(_friendlyErrorMessage(e));
        _notifyTaskUpdate();
        // 任务失败通知
        _notifyTaskCompletion(success: false, startTime: startTime, error: e.toString());
      }
    }
  }

  void cancelTask() {
    // 无论当前处于何种状态（thinking/executing/waitingConfirm），都标记为取消
    final wasActive = _currentTask != null &&
        _currentTask!.status != AgentStatus.cancelled &&
        _currentTask!.status != AgentStatus.completed &&
        _currentTask!.status != AgentStatus.failed;
    if (wasActive) {
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.cancelled,
        completedAt: DateTime.now(),
      );
      _notifyTaskUpdate();
      // P0-2: trace 任务取消
      AgentTracer.instance.endTask(
        _currentTask!.id,
        status: 'cancelled',
        summary: '用户取消任务',
        hostId: hostId,
      );
    }
    // 递近代际，使任何残留的旧循环立即退出
    _currentTaskGeneration++;
    // 同时取消等待确认
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _pendingConfirmCommand = null;
    // R2: cancel 确认超时定时器，避免 Timer 泄漏
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    // 同时取消等待选择
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    _pendingOptions = [];
    // 取消正在执行的命令
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    _commandCancelToken = null;
    // 取消编排任务（覆盖整个 ReAct 循环周期，批量命令通过它立即中断）
    if (_orchestratorCancelToken != null && !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    _orchestratorCancelToken = null;
    // 取消 AI 流式订阅，停止消费旧任务流
    // 注意: cancel() 不触发 onDone，需手动 complete doneCompleter
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    // 取消底层 Dio HTTP 请求：比 _aiStreamSub.cancel() 更彻底
    // 直接关闭 TCP 连接，避免取消任务后 API 仍在流式输出消耗配额
    // 防御性 if 包裹：cancelToken 可能已 completed（Dio 二次 cancel 会触发 warning）
    if (_aiCancelToken != null && !_aiCancelToken!.isCancelled) {
      _aiCancelToken!.cancel('用户取消任务');
    }
    _aiCancelToken = null;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiDoneCompleter = null;
    // 清理提前执行残留，避免下一轮误用
    if (_earlyExecutionCompleter != null && !_earlyExecutionCompleter!.isCompleted) {
      _earlyExecutionCompleter!.complete(_EarlyExecutionResult(
        shouldContinue: false,
        command: _earlyExecutionCommand ?? '',
      ));
    }
    _earlyExecutionCompleter = null;
    _earlyExecutionCommand = null;

    // R5: cancel 是终态路径，必须 emit finish 事件，让 UI 停止流式渲染状态
    // 否则依赖 finish 事件关闭"运行中"动画的 UI 会卡住
    if (wasActive) {
      final finishSummary = _accumulatedMessage.isNotEmpty
          ? _accumulatedMessage
          : '任务已取消';
      onEvent?.call(AgentEvent.finish(summary: finishSummary));
      // flush 流式内容到持久化（与 _finishTask 的 onCompleted 路径对齐）
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
    }
  }

  /// P2-7: 暂停当前任务
  /// 行为：标记 status=paused，让 ReAct 循环在下一轮检查时退出。
  /// 与 cancelTask 的关键区别：
  ///   - 不递近代际（保留 myGeneration，resumeTask 时可继续）
  ///   - 不 emit finish 事件（任务未结束，UI 保持"已暂停"状态）
  ///   - 不清理 _conversationHistory（恢复后继续对话）
  ///   - 不调用 onCompleted（不 flush 流式内容到持久化）
  ///   - 但会取消正在执行的命令和 AI 流（让阻塞的 await 立即返回）
  void pauseTask() {
    if (_currentTask == null) return;
    final s = _currentTask!.status;
    // 只在 thinking/executing/waitingConfirm 时允许暂停
    if (s != AgentStatus.thinking &&
        s != AgentStatus.executing &&
        s != AgentStatus.waitingConfirm) {
      return;
    }
    _currentTask = _currentTask!.copyWith(status: AgentStatus.paused);
    _notifyTaskUpdate();
    agentLogger.info('AgentEngine', '任务已暂停 (暂停前状态: $s)');

    // 取消正在执行的命令（不递近代际，恢复时由用户重新发起 startTask 或继续）
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    if (_orchestratorCancelToken != null && !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    // 取消 AI 流式订阅
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    if (_aiCancelToken != null && !_aiCancelToken!.isCancelled) {
      _aiCancelToken!.cancel('用户暂停任务');
    }
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiDoneCompleter = null;
    _aiCancelToken = null;
    // 取消等待确认 / 选择（让 await 立即返回）
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    // R2: 取消确认超时定时器，避免暂停后定时器仍占用资源
    // （恢复时 _resetTransientState 会再次清理，但暂停期间不该让定时器空转）
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    // 通知 UI 暂停（info 事件，不是 finish）
    onEvent?.call(AgentEvent.info('⏸️ 任务已暂停，可点击恢复继续'));
  }

  /// P2-7: 恢复已暂停的任务
  /// 实现：清除 paused 状态，重新调用 _executeAutomatic 触发 ReAct 循环
  /// （会复用 _conversationHistory 中已累积的上下文）
  /// [executor] 当前命令执行器；若为 null 则无法恢复
  Future<void> resumeTask(CommandExecutor? executor) async {
    if (_currentTask == null || _currentTask!.status != AgentStatus.paused) {
      return;
    }
    if (executor == null || !executor.isConnected) {
      onError?.call(L10n.str.terminalNotConnected);
      return;
    }
    // 在 _resetTransientState 之前捕获 goal（reset 会清空 _currentTask）
    final goal = _currentTask!.goal;
    agentLogger.info('AgentEngine', '恢复已暂停的任务: $goal');
    // 清理瞬态字段但保留 _conversationHistory（恢复上下文）
    _resetTransientState();
    _currentTaskGeneration++;
    final myGeneration = _currentTaskGeneration;
    _taskStartTime = DateTime.now();
    _currentStepCount = 0;
    _currentTask = AgentTask(
      id: _uuid.v4(),
      goal: goal,
      status: AgentStatus.thinking,
    );
    _notifyTaskUpdate();
    AgentTracer.instance.startTask(_currentTask!.id, '恢复: $goal', hostId: hostId);
    onEvent?.call(AgentEvent.info('▶️ 任务已恢复，继续执行...'));
    try {
      await _executeAutomatic(goal, executor, myGeneration);
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '恢复执行异常: $e\n$stack');
      if (myGeneration == _currentTaskGeneration && _currentTask != null) {
        _currentTask = _currentTask!.copyWith(
          status: AgentStatus.failed,
          completedAt: DateTime.now(),
        );
        _notifyTaskUpdate();
      }
    }
  }

  /// 确认执行危险命令（由用户点击确认按钮触发）
  void confirmDangerousCommand() {
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(true);
    }
    _pendingConfirmCommand = null;
  }

  /// 拒绝执行危险命令（由用户点击拒绝按钮触发）
  void rejectDangerousCommand() {
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _pendingConfirmCommand = null;
  }

  /// 用户选择了一个选项（:::choose 格式）
  void selectChoice(String choice) {
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete(choice);
    }
    _pendingOptions = [];
  }

  Future<void> _executeAutomatic(String goal, CommandExecutor? executor, int myGeneration) async {
    agentLogger.info('ReAct', '=== 开始 ReAct 自动执行 ===');

    // 代际失效：说明在 startTask 等待期间被新任务覆盖或取消了
    if (myGeneration != _currentTaskGeneration) {
      agentLogger.info('ReAct', '代际失效，放弃执行');
      return;
    }

    if (executor == null || !executor.isConnected) {
      final type = executor == null ? '无执行器' : '未连接';
      agentLogger.error('ReAct', '$type!');
      onError?.call(L10n.str.terminalNotConnected);
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.failed,
        completedAt: DateTime.now(),
      );
      _notifyTaskUpdate();
      return;
    }

    agentLogger.info('ReAct', '执行器连接状态: ${executor.isConnected}');

    // 创建编排取消令牌：覆盖整个 ReAct 循环周期，注入到 MultiHostExecutor。
    // cancelTask 会 complete 它，编排里的批量 executeAndWait 据此立即中断。
    // 旧任务残留的 token 先丢弃（理论上 cancelTask 已 complete 过）。
    _orchestratorCancelToken = Completer<void>();
    final mhe = _tools.multiHostExecutor;
    if (mhe != null) {
      mhe.cancelToken = _orchestratorCancelToken;
    }

    // maxSteps=0 时使用兜底上限，防止无限循环
    final maxSteps = this.maxSteps > 0 ? this.maxSteps : _defaultMaxSteps;
    var stepCount = 0;

    // 判断是否为新对话
    final isNewConversation = _conversationHistory.isEmpty;

    // 更新或创建系统提示（ReAct 模式专用）
    final systemPrompt = _buildSystemPrompt(executor);
    if (isNewConversation) {
      _conversationHistory.add(ChatMessage.create(role: 'system', content: systemPrompt));
    } else if (_conversationHistory.isNotEmpty && _conversationHistory[0].role == 'system') {
      _conversationHistory[0] = ChatMessage.create(role: 'system', content: systemPrompt);
    } else {
      // 恢复历史后索引 0 不是 system 消息，需在开头插入
      _conversationHistory.insert(0, ChatMessage.create(role: 'system', content: systemPrompt));
    }

    // 添加用户消息
    _conversationHistory.add(ChatMessage.create(
      role: 'user',
      content: isNewConversation ? '任务: $goal\n\n请分析任务并开始执行。' : goal,
    ));

    agentLogger.info('ReAct', '对话历史: ${_conversationHistory.length} 条消息 (新对话: $isNewConversation)');

    // 仅新对话显示启动提示（只走事件通道，不混入文本流）
    if (isNewConversation) {
      _accumulatedMessage = '';
      onEvent?.call(AgentEvent.info('🚀 开始自动执行任务...'));
    } else {
      _accumulatedMessage = '';
    }

    agentLogger.info('ReAct', '开始 ReAct 循环 (最多 $maxSteps 步)');

    while (stepCount < maxSteps) {
      stepCount++;
      agentLogger.info('ReAct', '--- 步骤 $stepCount ---');

      // 代际失效：新任务已启动或已取消，旧循环立即退出
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('ReAct', '代际失效，旧循环退出');
        return;
      }

      // P2-7: 暂停检查 — pauseTask 设置 status=paused 后旧循环退出
      // resumeTask 会创建新代际+新任务壳，由新循环接管
      if (_currentTask?.status == AgentStatus.paused) {
        agentLogger.info('ReAct', '任务已暂停，循环退出');
        return;
      }

      // ═══════════════════════════════════════════
      // 阶段1: 思考 (Think) — 调用 AI 获取响应
      // ═══════════════════════════════════════════
      _currentStepCount = stepCount;
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: _progressStepText(),
      );
      _notifyTaskUpdate();
      onThinking?.call(L10n.str.thinkingNextStep);

      String fullResponse;
      try {
        // 重置提前执行缓存
        _earlyExecutionCompleter = null;
        _earlyExecutionCommand = null;
        fullResponse = await _callAI(
          myGeneration: myGeneration,
          onCommandDetected: (command, commandId) {
            // 检测到完整命令，启动提前执行（异步，不阻塞AI流式输出）
            if (_earlyExecutionCompleter == null &&
                _currentTask?.status != AgentStatus.cancelled) {
              _earlyExecutionCommand = command;
              _earlyExecutionCompleter = Completer<_EarlyExecutionResult>();
              _runCommandWithSafety(command, executor, commandId: commandId, myGeneration: myGeneration).then(
                (result) {
                  if (_earlyExecutionCompleter?.isCompleted == false) {
                    _earlyExecutionCompleter?.complete(result);
                  }
                },
                onError: (Object e) {
                  agentLogger.error('ReAct', '提前执行异常: $e');
                  if (_earlyExecutionCompleter?.isCompleted == false) {
                    _earlyExecutionCompleter?.complete(_EarlyExecutionResult(
                      shouldContinue: false,
                      command: command,
                    ));
                  }
                },
              );
            }
          },
        );
      } catch (e, stack) {
        // R1: 区分"取消/代际变更"和真正的 AI 调用异常
        // 前者是正常流程的一部分（用户点了取消或新任务覆盖），不应记 error 日志
        final isCancellation = e is StateError &&
            (e.message == '任务已取消' || e.message == '任务已被新任务覆盖');
        if (isCancellation) {
          agentLogger.info('ReAct', 'AI 调用因取消/代际变更终止: ${e.message}');
        } else {
          agentLogger.error('ReAct', 'AI 调用异常: $e\n$stack');
        }
        // L1 修复：AI 异常应标记 failed 并退出，不应走到循环后的 completed 逻辑
        if (myGeneration == _currentTaskGeneration && _currentTask != null) {
          if (isCancellation) {
            // 取消场景：cancelTask 已设置 status=cancelled 并 emit finish，不重复处理
            return;
          }
          final friendlyMsg = _friendlyErrorMessage(e);
          // 将错误信息作为 assistant 消息加入历史，保持 user/assistant 交替完整性
          // 这样下次任务（如用户发"继续"）时 AI 能看到之前的上下文
          final errorMsg = '⚠️ AI 调用失败: $friendlyMsg';
          _accumulatedMessage = errorMsg;
          onMessage?.call(errorMsg);
          _conversationHistory.add(ChatMessage.create(
            role: 'assistant',
            content: errorMsg,
          ));
          onError?.call(friendlyMsg);
          final startTime = _currentTask!.createdAt;
          _currentTask = _currentTask!.copyWith(
            status: AgentStatus.failed,
            completedAt: DateTime.now(),
          );
          _notifyTaskUpdate();
          // R5: 失败路径也要 emit finish 事件，避免 UI 卡 running
          onEvent?.call(AgentEvent.finish(summary: '${L10n.str.taskFailed}: $friendlyMsg'));
          // 任务失败通知（与外层 catch 保持一致）
          _notifyTaskCompletion(success: false, startTime: startTime, error: e.toString());
        }
        return;
      }

      // 代际失效：AI 流式期间被新任务覆盖，旧循环退出
      // L5 修复：先检查代际，再加入历史，避免旧响应污染新会话
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('ReAct', 'AI 响应期间代际失效，旧循环退出');
        return;
      }

      // 用户在 AI 流式输出期间点了取消
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', 'AI 响应期间任务被取消');
        return;
      }

      // 将 AI 响应加入对话历史（代际和取消检查通过后）
      _conversationHistory.add(ChatMessage.create(role: 'assistant', content: fullResponse));

      // ═══════════════════════════════════════════
      // 阶段2: 解析 (Parse) — 从 AI 响应中提取结构化动作
      // ═══════════════════════════════════════════
      final step = _parseReActResponse(fullResponse);
      agentLogger.info('ReAct', '解析结果: thought="${step.thought}", action=${step.action}, command=${step.command}, options=${step.options}');

      // ═══════════════════════════════════════════
      // 阶段3: 行动 (Act) — 根据动作类型执行
      // ═══════════════════════════════════════════
      switch (step.action) {
        case ActionType.finish:
          agentLogger.info('ReAct', '任务完成 (AI 返回 finish 动作)');
          _finishTask();
          return;

        case ActionType.ask:
          final shouldContinue = await _handleAskAction(step, myGeneration: myGeneration);
          if (!shouldContinue) return;
          continue;

        case ActionType.execute:
          if (step.command == null || step.command!.trim().isEmpty) {
            // ReAct 解析出了 execute 但无命令 → fallback 到旧方式提取
            final fallbackCommands = _extractCommands(fullResponse);
            if (fallbackCommands.isNotEmpty) {
              agentLogger.info('ReAct', 'ReAct 格式无命令，旧方式提取 ${fallbackCommands.length} 条');
              final shouldContinue = await _handleExecuteCommands(fallbackCommands, executor, myGeneration: myGeneration);
              if (!shouldContinue) return;
              break;
            }
            // 两种方式都未提取到命令，发送继续提示
            final shouldContinue = await _handleNoCommand();
            if (!shouldContinue) return;
            continue;
          }
          final shouldContinue = await _handleExecuteAction(step, executor, myGeneration: myGeneration);
          if (!shouldContinue) return;

        case ActionType.tool:
          final shouldContinue = await _handleToolAction(step, executor, myGeneration: myGeneration);
          if (!shouldContinue) return;

        case null:
          // 空响应或只有思考内容 → 发送继续提示
          agentLogger.info('ReAct', 'AI 未返回有效动作，发送继续提示');
          final shouldContinue = await _handleNoCommand();
          if (!shouldContinue) return;
          continue;
      }

      // 检查任务是否被取消
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务被取消');
        return;
      }
    }

    // 达到最大步数
    // L1 修复：代际失效时不覆盖新任务状态
    if (myGeneration != _currentTaskGeneration) return;
    // R5: 步数耗尽是异常终止，应标记 failed 而非 completed
    // 标 completed 会误导用户以为任务成功完成
    final hitMaxSteps = stepCount >= maxSteps;
    _currentTask = _currentTask!.copyWith(
      status: hitMaxSteps ? AgentStatus.failed : AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    _notifyTaskUpdate();
    agentLogger.info('ReAct', '=== 执行结束 (步数: $stepCount/$maxSteps) ===');

    if (hitMaxSteps) {
      agentLogger.warn('ReAct', '达到最大执行步数 $maxSteps');
      onEvent?.call(AgentEvent.info('⚠️ 达到最大执行步数 ($maxSteps)，任务被中断'));
      onEvent?.call(AgentEvent.finish(summary: '达到最大执行步数，任务被中断'));
      // L15 修复：maxSteps 路径也调 onCompleted，确保流式内容 flush 到 content
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
    } else {
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
    }

    // 清理编排取消令牌（ReAct 循环结束）
    _orchestratorCancelToken = null;
    final mhe2 = _tools.multiHostExecutor;
    if (mhe2 != null) {
      mhe2.cancelToken = null;
    }
  }

  /// 调用 AI 模型，流式返回完整响应
  /// [onCommandDetected] 可选回调：流式过程中检测到完整命令时触发，可用于提前执行
  /// [myGeneration] 任务代际，用于退避期间识别"取消 + 立即新任务"竞态
  /// 对可重试错误（429/connectionError/timeout）做指数退避重试，最多 3 次
  Future<String> _callAI({
    void Function(String command, String commandId)? onCommandDetected,
    int? myGeneration,
  }) async {
    agentLogger.info('ReAct', '调用 AI 模型...');
    agentLogger.debug('ReAct', '消息历史: ${_conversationHistory.length} 条');

    String fullResponse = '';
    // 重试仅对流建立阶段有效，一旦开始接收 chunk 就不再重试
    Stream<String> stream;
    const maxRetries = 3;
    final backoffDelays = [const Duration(seconds: 1), const Duration(seconds: 2), const Duration(seconds: 4)];

    // P1-4: Fallback 模型 — 主模型 maxRetries 次重试仍失败时切换备用模型重试一次
    var activeProvider = _aiProvider;
    var activeConfig = _modelConfig;
    var fallbackAttempted = false;
    int attempt = 0;
    while (true) {
      // R1: 循环顶部先检查代际/取消，避免 cancelTask 后又立刻进入新一轮 chatStream 调用
      // 之前只在退避后检查，但首轮重试前没有检查，导致取消的任务仍会发起新请求
      if (myGeneration != null && myGeneration != _currentTaskGeneration) {
        throw StateError('任务已被新任务覆盖');
      }
      if (_currentTask?.status == AgentStatus.cancelled) {
        throw StateError('任务已取消');
      }
      attempt++;
      // P0-2: trace AI 调用开始
      final taskId = _currentTask?.id;
      if (taskId != null) {
        AgentTracer.instance.emitSync(TraceEvent(
          taskId: taskId,
          hostId: hostId,
          type: TraceEventType.aiCallStart,
          generation: myGeneration,
          step: _currentStepCount,
          payload: {
            'attempt': attempt,
            'retry': attempt > 1,
            'fallback': fallbackAttempted,
            'model': activeConfig.modelName,
            'history_len': _conversationHistory.length,
          },
        ));
      }
      try {
        // 不在此处加 .timeout()：底层 Dio 已配置 connectTimeout=30s / receiveTimeout=120s，
        // 用 .timeout() 抛 TimeoutException 时不会取消 Dio 请求，会导致连接泄漏。
        // 改用 CancelToken 机制：cancelTask 触发后立即关闭底层 HTTP 连接，毫秒级响应。
        // 每轮重试都创建新 token（旧 token 可能已被 cancel）。
        final token = CancelToken();
        _aiCancelToken = token;
        // P2-6: 模型支持 FC 时，构建 tools schema 传入
        List<Map<String, dynamic>>? toolsSchema;
        if (activeConfig.supportsFunctionCalling) {
          toolsSchema = _tools.buildOpenAIToolsSchema();
          if (toolsSchema.isEmpty) toolsSchema = null;
        }
        stream = await activeProvider.chatStream(
          history: _conversationHistory,
          prompt: '',
          config: activeConfig,
          systemPrompt: null,
          cancelToken: token,
          tools: toolsSchema,
        );
        break; // 成功建立流
      } catch (e) {
        // 取消导致的异常不重试（重试会消耗新 API 配额且违背用户意图）
        if (_isCancellationError(e) ||
            (myGeneration != null && myGeneration != _currentTaskGeneration) ||
            _currentTask?.status == AgentStatus.cancelled) {
          rethrow;
        }
        if (attempt > maxRetries || !_isRetryableError(e)) {
          // P1-4: 主模型重试耗尽，切换到 fallback 模型重试一次
          if (!fallbackAttempted &&
              _fallbackProvider != null &&
              _fallbackConfig != null) {
            agentLogger.warn('ReAct',
                '主模型 ${activeConfig.modelName} 重试 $attempt 次仍失败，切换 fallback 模型 ${_fallbackConfig!.modelName}: $e');
            fallbackAttempted = true;
            attempt = 0;
            activeProvider = _fallbackProvider!;
            activeConfig = _fallbackConfig!;
            // 通知 UI：模型已切换
            onEvent?.call(AgentEvent.info('⚠️ 主模型 ${_modelConfig.modelName} 不可用，已切换到备用模型 ${activeConfig.modelName}'));
            continue;
          }
          rethrow;
        }
        agentLogger.warn('ReAct', 'AI 流建立失败（第 $attempt 次），${backoffDelays[attempt - 1].inSeconds}s 后重试: $e');
        await Future.delayed(backoffDelays[attempt - 1]);
        // R1: 退避期间任务可能被取消或被新任务覆盖
        // 旧实现只检查 status==cancelled，无法识别"cancel + 立即 startTask"场景
        // （新任务把 status 重置为 thinking，旧检查会通过，导致旧任务继续发起新 chatStream
        // 调用、消耗 API 配额、并把旧响应通过 onMessage 写到新任务的 UI 流）
        // 修复：同时检查代际和取消状态，任一失效都放弃重试
        if (myGeneration != null && myGeneration != _currentTaskGeneration) {
          agentLogger.info('ReAct', '退避期间代际已变更（新任务已启动），放弃重试');
          throw StateError('任务已被新任务覆盖');
        }
        if (_currentTask?.status == AgentStatus.cancelled) {
          agentLogger.info('ReAct', '退避期间任务被取消，放弃重试');
          throw StateError('任务已取消');
        }
      }
    }

    int chunkCount = 0;
    final emittedStableIds = <String>{}; // 已发出事件的稳定 ID（内容哈希），用于流式去重
    final stableIdToFinalId = <String, String>{}; // 稳定 ID → 最终全局唯一 ID 的映射
    int globalEventSeq = 0; // 全局事件序号
    bool commandDetectedNotified = false; // 是否已通知过命令检测（一轮只通知一次）
    // watchdog 已改为实例字段 _aiWatchdog

    String assignFinalId(AgentEvent e) {
      final stableId = e.id; // 解析器生成的稳定 ID（内容哈希）
      if (stableIdToFinalId.containsKey(stableId)) {
        return stableIdToFinalId[stableId]!;
      }
      globalEventSeq++;
      final finalId = 'evt_${globalEventSeq}_${stableId.substring(0, stableId.length > 8 ? 8 : stableId.length)}';
      stableIdToFinalId[stableId] = finalId;
      e.id = finalId;
      return finalId;
    }

    // 超时看门狗：用实例字段以便 cancelTask 取消
    _aiStreamTimedOut = false;
    final doneCompleter = Completer<void>();
    _aiDoneCompleter = doneCompleter;
    void resetWatchdog() {
      _aiWatchdog?.cancel();
      _aiWatchdog = Timer(const Duration(seconds: 120), () {
        _aiStreamTimedOut = true;
        agentLogger.error('ReAct', 'AI 流式输出超时（120s 无数据），强制中断');
        _aiStreamSub?.cancel();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      });
    }
    resetWatchdog();

    _aiStreamSub = stream.listen(
      (chunk) {
        if (_aiStreamTimedOut) return;
        resetWatchdog();
        chunkCount++;
        fullResponse += chunk;
        // B5: 限制 _accumulatedMessage 增长，超出上限只保留尾部
        _accumulatedMessage += chunk;
        if (_accumulatedMessage.length > _maxAccumulatedChars) {
          _accumulatedMessage = _accumulatedMessage.substring(
            _accumulatedMessage.length - _maxAccumulatedChars);
        }
        onMessage?.call(chunk);

        // 流式过程中检测完整命令：立即发出 command 事件 + 触发提前执行
        if (onCommandDetected != null && !commandDetectedNotified) {
          final currentEvents = ReActStreamParser.parse(fullResponse);
          // 找第一个已确定完成的 command 事件（不是最后一个）
          if (currentEvents.length > 1) {
            for (int i = 0; i < currentEvents.length - 1; i++) {
              final e = currentEvents[i];
              if (e.isCommand) {
                final cmd = e.command ?? '';
                if (cmd.isNotEmpty) {
                  commandDetectedNotified = true;
                  // A5 修复：先记录 stableId，再改写为 finalId
                  final stableId = e.id;
                  final finalId = assignFinalId(e);
                  _lastCommandEventId = finalId;
                  // 立即发出 command 事件，让 UI 先显示命令块
                  if (!emittedStableIds.contains(stableId)) {
                    emittedStableIds.add(stableId);
                    e.id = finalId;
                    e.isStreaming = false;
                    onEvent?.call(e);
                  }
                  onCommandDetected(cmd, finalId);
                  break;
                }
              }
            }
          }
        }
      },
      onError: (e) {
        if (!doneCompleter.isCompleted) doneCompleter.completeError(e);
      },
      onDone: () {
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
      cancelOnError: true,
    );

    // 在 finally 前记录 cancel 状态（finally 会清理 _aiCancelToken 引用）
    final wasCancelled = _aiCancelToken?.isCancelled ?? false;
    try {
      await doneCompleter.future;
    } catch (e) {
      // R1: 如果 cancel 触发了 DioException(cancel) 错误路径，统一转换为 StateError
      // 让外层 catch 用 _isCancellationError 识别走取消路径（不重试、不记 error 日志）
      if (wasCancelled || _isCancellationError(e)) {
        throw StateError('任务已取消');
      }
      rethrow;
    } finally {
      _aiWatchdog?.cancel();
      _aiWatchdog = null;
      await _aiStreamSub?.cancel();
      _aiStreamSub = null;
      if (_aiDoneCompleter == doneCompleter) _aiDoneCompleter = null;
      // R2: 清理 CancelToken 引用（已完成的请求 token 无需保留）
      _aiCancelToken = null;
    }

    // 取消导致的提前结束：抛 StateError 让外层 catch 走取消路径
    // 不抛 TimeoutException（那是超时场景）— 区分路径避免误报
    if (wasCancelled) {
      throw StateError('任务已取消');
    }

    if (_aiStreamTimedOut && fullResponse.isEmpty) {
      throw TimeoutException('AI 响应超时（120s 无数据）');
    }

    // 流式结束：一次性发出所有事件（e.id 此时是 stableId）
    final events = ReActStreamParser.parse(fullResponse);
    // L10 修复：只记录第一个 command 事件的 id（主流程只执行第一个命令）
    bool firstCommandIdSet = false;
    for (final e in events) {
      final stableId = e.id;
      if (!emittedStableIds.contains(stableId)) {
        emittedStableIds.add(stableId);
        assignFinalId(e); // 此处会改写 e.id 为 finalId
        e.isStreaming = false;
        onEvent?.call(e);
      } else {
        // 已发过，确保 _lastCommandEventId 用 finalId
        e.id = stableIdToFinalId[stableId] ?? e.id;
      }
      if (e.isCommand && !firstCommandIdSet) {
        _lastCommandEventId = stableIdToFinalId[stableId] ?? e.id;
        firstCommandIdSet = true;
      }
    }

    // 如果流式过程中没检测到命令（命令在最后），现在也通知一下
    if (!commandDetectedNotified && onCommandDetected != null) {
      for (final e in events) {
        if (e.isCommand) {
          final cmd = e.command ?? '';
          if (cmd.isNotEmpty) {
            commandDetectedNotified = true;
            final finalId = stableIdToFinalId[e.id] ?? e.id;
            _lastCommandEventId = finalId;
            onCommandDetected(cmd, finalId);
            break;
          }
        }
      }
    }

    agentLogger.info('ReAct', 'AI 响应完成，共 $chunkCount 个数据块，${fullResponse.length} 字符');
    // P0-2 + P1-3: trace AI 调用结束，附 token 估算
    final endTaskId = _currentTask?.id;
    if (endTaskId != null) {
      // 估算 prompt tokens：system 消息 + 对话历史 + 当前 prompt
      // 注意：这里只能粗估，因为 system prompt 在 provider 层构建
      final promptTokens = TokenEstimator.estimateHistory(_conversationHistory);
      final completionTokens = TokenEstimator.estimateText(fullResponse);
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: endTaskId,
        hostId: hostId,
        type: TraceEventType.aiCallEnd,
        generation: myGeneration,
        step: _currentStepCount,
        payload: {
          'chunks': chunkCount,
          'chars': fullResponse.length,
          'attempt': attempt,
          'retry': attempt > 1,
          'fallback': fallbackAttempted,
          'model': activeConfig.modelName,
          'prompt_tokens': promptTokens,
          'completion_tokens': completionTokens,
        },
      ));
    }
    return fullResponse;
  }

  /// ═══════════════════════════════════════════════════════
  /// ReAct 解析器 — 从 AI 响应中提取结构化动作
  /// 命令提取复用 ReActStreamParser，正确处理多行 heredoc
  /// ═══════════════════════════════════════════════════════
  ReActStep _parseReActResponse(String content) {
    String? thought;
    ActionType? action;
    String? command;
    List<String>? options;

    // 使用 ReActStreamParser 统一提取命令（正确处理多行 heredoc 和代码块）
    final events = ReActStreamParser.parse(content);
    for (final e in events) {
      if (e.isCommand && command == null) {
        command = e.command;
      } else if (e.type == AgentEventType.thought && thought == null) {
        thought = e.text;
      } else if (e.type == AgentEventType.ask && options == null) {
        options = e.options;
      }
    }

    // 解析动作行（ReActStreamParser 不提取动作类型，需单独解析）
    String? toolName;
    Map<String, dynamic>? toolArgs;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmedLine = lines[i].trim();
      if (trimmedLine.startsWith('动作:') || trimmedLine.startsWith('动作：')) {
        final sepIdx = trimmedLine.indexOf(trimmedLine.contains('：') ? '：' : ':');
        final actionStr = trimmedLine.substring(sepIdx + 1).trim().toLowerCase();
        if (actionStr == 'execute') {
          action = ActionType.execute;
        } else if (actionStr == 'finish') {
          action = ActionType.finish;
        } else if (actionStr == 'ask') {
          action = ActionType.ask;
        } else if (actionStr == 'tool') {
          action = ActionType.tool;
          // 解析后续的 工具: 和 参数: 行（多行 key:value 格式）
          // 抽成静态方法以便单元测试覆盖端到端解析链路
          final toolResult = parseToolAction(lines, i + 1);
          toolName = toolResult.$1;
          toolArgs = toolResult.$2;
        }
        break;
      }
    }

    // 如果有命令但没有指定动作，默认为 execute
    if (command != null && action == null) {
      action = ActionType.execute;
    }

    // Fallback：AI 未遵循格式
    if (action == null) {
      // 空响应 → 视为 AI 还在思考，不结束任务
      if (content.trim().isEmpty) {
        return ReActStep(thought: '', action: null, rawResponse: content);
      }
      if (isTaskComplete(content)) {
        return ReActStep(thought: thought ?? content, action: ActionType.finish, rawResponse: content);
      }
      if (command != null) {
        return ReActStep(thought: thought ?? '', action: ActionType.execute, command: command, rawResponse: content);
      }
      // 有思考内容但没有命令 → 继续执行，不要结束
      if (thought != null && thought.isNotEmpty) {
        return ReActStep(thought: thought, action: null, rawResponse: content);
      }
      // 无法识别格式 → 不结束任务，交给 _handleNoCommand 重试
      return ReActStep(thought: thought ?? content, action: null, rawResponse: content);
    }

    return ReActStep(
      thought: thought ?? '',
      action: action,
      command: command,
      options: options,
      toolName: toolName,
      toolArgs: toolArgs,
      rawResponse: content,
    );
  }

  /// 解析 "动作: tool" 行之后的 工具: 和 参数: 行。
  /// 返回 (toolName, toolArgs)，未找到时对应字段为 null。
  ///
  /// 抽成静态方法以便单元测试覆盖端到端解析链路：
  /// FC tool_calls → ToolCallAccumulator.toReActText → (拼接 thought)
  /// → _parseReActResponse → parseToolAction → toolName/toolArgs
  static (String?, Map<String, dynamic>?) parseToolAction(
      List<String> lines, int startIndex) {
    String? toolName;
    Map<String, dynamic>? toolArgs;

    for (var j = startIndex; j < lines.length; j++) {
      final tl = lines[j];
      final tlTrim = tl.trim();
      // 遇到新的 ReAct 关键词行 → 停止收集
      // （'工具:' 不在此列，因为它是 tool 动作的必填字段）
      if (tlTrim.startsWith('思考:') || tlTrim.startsWith('思考：') ||
          tlTrim.startsWith('动作:') || tlTrim.startsWith('动作：') ||
          tlTrim.startsWith('命令:') || tlTrim.startsWith('命令：') ||
          tlTrim.startsWith('选项:') || tlTrim.startsWith('选项：') ||
          tlTrim.startsWith('观测:') || tlTrim.startsWith('观测：')) {
        break;
      }
      if (tlTrim.startsWith('工具:') || tlTrim.startsWith('工具：')) {
        final sep = tlTrim.indexOf(tlTrim.contains('：') ? '：' : ':');
        toolName = tlTrim.substring(sep + 1).trim();
      } else if (tlTrim.startsWith('参数:') || tlTrim.startsWith('参数：')) {
        // 收集参数：参数: 行本身 + 后续所有缩进行（多行 key:value 格式）
        final sep = tlTrim.indexOf(tlTrim.contains('：') ? '：' : ':');
        final argsBuffer = StringBuffer()
          ..writeln(tlTrim.substring(sep + 1));
        // 收集后续缩进行（2 空格或 Tab 开头）
        for (var k = j + 1; k < lines.length; k++) {
          final pl = lines[k];
          if (pl.isEmpty) continue;
          // 缩进行：以空格或 Tab 开头且非空
          if (pl.startsWith(' ') || pl.startsWith('\t')) {
            argsBuffer.writeln(pl);
          } else {
            break;
          }
        }
        final parsed = ToolArgsParser.parse(argsBuffer.toString());
        if (parsed != null) {
          toolArgs = parsed;
        } else {
          agentLogger.warn('ReAct', '工具参数解析失败, raw=$argsBuffer');
        }
        break; // 参数解析完成后停止扫描后续行
      } else if (tlTrim.isEmpty) {
        continue;
      } else {
        // 遇到非工具/参数行，停止
        break;
      }
    }
    return (toolName, toolArgs);
  }

  /// ═══════════════════════════════════════════════════════
  /// 处理 execute 动作 — 执行单条命令并返回观测
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleExecuteAction(ReActStep step, CommandExecutor executor, {required int myGeneration}) async {
    final command = step.command!.trim();

    // 如果有提前执行的结果（或正在执行中），直接用
    if (_earlyExecutionCommand == command && _earlyExecutionCompleter != null) {
      final result = await _earlyExecutionCompleter!.future;
      _earlyExecutionCompleter = null;
      _earlyExecutionCommand = null;

      if (myGeneration != _currentTaskGeneration) return false;
      if (!result.shouldContinue) {
        return false;
      }
      // 把观测加入对话历史
      if (result.observation != null) {
        _conversationHistory.add(ChatMessage.create(role: 'user', content: result.observation!));
        _trimMessages(_conversationHistory);
      }
      // L2 修复：成功执行命令后重置无命令重试计数
      _noCommandRetryCount = 0;
      return true;
    }

    final result = await _runCommandWithSafety(command, executor, myGeneration: myGeneration);
    if (myGeneration != _currentTaskGeneration) return false;
    if (!result.shouldContinue) {
      return false;
    }
    if (result.observation != null) {
      _conversationHistory.add(ChatMessage.create(role: 'user', content: result.observation!));
      _trimMessages(_conversationHistory);
    }
    // L2 修复：成功执行命令后重置无命令重试计数
    _noCommandRetryCount = 0;
    return true;
  }

  /// 提前执行的结果缓存（用 Completer 处理执行中状态）
  Completer<_EarlyExecutionResult>? _earlyExecutionCompleter;
  String? _earlyExecutionCommand;

  /// 执行命令（含安全检查、用户确认、执行、发 result 事件），返回执行结果和观测
  /// [commandId] 用于关联 result 事件与 command 事件（流式提前执行时由 _callAI 传入）
  Future<_EarlyExecutionResult> _runCommandWithSafety(
    String command,
    CommandExecutor executor, {
    String? commandId,
    int? myGeneration,
  }) async {
    agentLogger.info('ReAct', '执行命令: $command (commandId=$commandId)');

    // P0-2: trace 命令执行开始
    final traceTaskId = _currentTask?.id;
    if (traceTaskId != null) {
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: traceTaskId,
        hostId: hostId,
        type: TraceEventType.commandStart,
        generation: myGeneration,
        step: _currentStepCount,
        payload: {
          if (commandId != null) 'command_id': commandId,
          'command': command,
        },
      ));
    }
    // 局部状态追踪：finally 中统一 emit commandEnd
    var cmdSuccess = false;
    var cmdReason = 'unknown';
    var outputChars = 0;

    try {
      return await _runCommandWithSafetyInner(
        command, executor,
        commandId: commandId,
        myGeneration: myGeneration,
        traceTaskId: traceTaskId,
        onSuccess: (s, reason, chars) {
          cmdSuccess = s;
          cmdReason = reason;
          outputChars = chars;
        },
      );
    } catch (e) {
      cmdReason = 'exception';
      rethrow;
    } finally {
      if (traceTaskId != null) {
        AgentTracer.instance.emitSync(TraceEvent(
          taskId: traceTaskId,
          hostId: hostId,
          type: TraceEventType.commandEnd,
          generation: myGeneration,
          step: _currentStepCount,
          payload: {
            if (commandId != null) 'command_id': commandId,
            'success': cmdSuccess,
            'reason': cmdReason,
            if (outputChars > 0) 'output_chars': outputChars,
          },
        ));
      }
    }
  }

  /// _runCommandWithSafety 的内部实现（不含 trace，由外层 wrapper 统一记录）
  Future<_EarlyExecutionResult> _runCommandWithSafetyInner(
    String command,
    CommandExecutor executor, {
    String? commandId,
    int? myGeneration,
    String? traceTaskId,
    required void Function(bool success, String reason, int outputChars) onSuccess,
  }) async {
    // 安全检查
    final safetyLevel = SafetyGuard.check(command);
    agentLogger.info('ReAct', '安全检查: $safetyLevel');

    // 审计日志（执行前写入）：即使执行中崩溃，也能追溯"曾发起过这条命令"
    // 所有命令都记录（含 safe 级），因为 cat /etc/shadow 等只读命令也可能泄露敏感信息
    if (hostId != null) {
      try {
        await AuditLogger.log(
          hostId: hostId!,
          command: command,
          safetyLevel: safetyLevel.name,
          output: null, // 执行前无输出，执行后会追加一条带结果的记录
          executed: false,
        );
      } catch (e) {
        agentLogger.warn('Audit', '审计日志写入失败(执行前): $e');
      }
    }

    // 变更窗口/封网期检查：非 safe 级命令在封网期被拒绝
    final (windowAllowed, windowReason) = ChangeWindowService.checkCommand(command);
    if (!windowAllowed) {
      agentLogger.warn('ReAct', '封网期拦截修改性命令: $command');
      onEvent?.call(AgentEvent.info('🚫 封网期拦截\n命令: `$command`\n$windowReason'));
      final observation = ReActObservation(
        command: command,
        output: '封网期内禁止执行修改性命令（仅允许只读命令）',
        success: false,
        error: windowReason ?? '封网期拦截',
      ).format();
      onSuccess(false, 'window_blocked', 0);
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    // 只读模式（Dry-run）：非 safe 级命令直接拒绝，不执行
    if (_readOnlyMode && safetyLevel != SafetyLevel.safe) {
      agentLogger.warn('ReAct', '只读模式拦截非只读命令: $command');
      final reason = SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      onEvent?.call(AgentEvent.info('🔒 只读模式已开启，此命令被拒绝执行: `$command`\n等级: $safetyLevel\n说明: $reason'));
      final observation = ReActObservation(
        command: command,
        output: '只读模式下禁止执行非只读命令（当前等级: $safetyLevel）',
        success: false,
        error: '只读模式拦截',
      ).format();
      onSuccess(false, 'read_only_blocked', 0);
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    if (safetyLevel == SafetyLevel.blocked) {
      agentLogger.warn('ReAct', '命令被安全系统拦截: $command');
      final reason = SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      onEvent?.call(AgentEvent.info('🚫 命令被安全系统拦截: $command\n原因: $reason'));
      // 审计日志：被拦截的命令追加记录（执行前已写一条 executed=false）
      if (hostId != null) {
        try {
          await AuditLogger.log(
            hostId: hostId!,
            command: command,
            safetyLevel: safetyLevel.name,
            output: reason,
            executed: false,
          );
        } catch (e) {
          agentLogger.warn('Audit', '审计日志写入失败(拦截分支): $e');
        }
      }
      final observation = ReActObservation(
        command: command,
        output: '命令被安全系统拦截，禁止执行',
        success: false,
        error: reason,
      ).format();
      onSuccess(false, 'safety_blocked', 0);
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    // warn 级别命令需要用户确认
    if (safetyLevel == SafetyLevel.warn) {
      agentLogger.warn('ReAct', '高风险命令需要确认: $command');
      _pendingConfirmCommand = command;
      _confirmCompleter = Completer<bool>();
      // 超时定时器：10 分钟无响应自动拒绝，避免任务永久卡在 waitingConfirm
      // 用实例字段以便 cancelTask 能 cancel 它
      _confirmTimeoutTimer = Timer(const Duration(minutes: 10), () {
        if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
          agentLogger.warn('ReAct', '确认超时(10min)，自动拒绝: $command');
          _confirmCompleter!.complete(false);
        }
      });

      // 显示具体的风险说明，而非泛泛的"危险操作"
      final reason = SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      onEvent?.call(AgentEvent.info('⚠️ 高风险命令需要确认: `$command`\n风险说明: $reason'));

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.waitingConfirm,
        currentStep: '等待确认: $command',
      );
      _notifyTaskUpdate();

      final confirmed = await _confirmCompleter!.future;
      _confirmTimeoutTimer?.cancel();
      _confirmTimeoutTimer = null;
      _confirmCompleter = null;
      _pendingConfirmCommand = null;

      if (myGeneration != null && myGeneration != _currentTaskGeneration) {
        onSuccess(false, 'generation_invalid_during_confirm', 0);
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务在等待确认期间被取消');
        onSuccess(false, 'cancelled_during_confirm', 0);
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }

      if (!confirmed) {
        agentLogger.info('ReAct', '用户拒绝执行危险命令: $command');
        onEvent?.call(AgentEvent.info('❌ 用户拒绝执行此命令'));
        final observation = ReActObservation(
          command: command,
          output: '用户拒绝执行此命令',
          success: false,
          error: '用户拒绝',
        ).format();
        onSuccess(false, 'user_rejected', 0);
        return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
      }

      agentLogger.info('ReAct', '用户确认执行危险命令: $command');
      onEvent?.call(AgentEvent.info('✅ 用户已确认，开始执行...'));
    }

    // 执行命令
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      currentStep: _progressStepText(),
    );
    _notifyTaskUpdate();
    onCommandGenerated?.call(command);

    if (safetyLevel == SafetyLevel.info) {
      agentLogger.info('ReAct', '低风险操作提示: $command');
    }

    // 失败回滚：修改类命令执行前做快照（只读，不影响原命令）
    PreSnapshot? snapshot;
    final modifyTarget = RollbackAdvisor.analyze(command);
    if (modifyTarget != null) {
      final snapshotCmd = RollbackAdvisor.buildSnapshotCommand(modifyTarget);
      if (snapshotCmd != null) {
        agentLogger.info('Rollback', '检测到修改类命令，执行预快照: ${modifyTarget.type}');
        try {
          final snapshotResult = await _executeCommand(executor, snapshotCmd, myGeneration: myGeneration);
          // R1: 快照执行后检查代际，避免旧任务快照污染新任务
          if (myGeneration != null && myGeneration != _currentTaskGeneration) {
            onSuccess(false, 'generation_invalid_after_snapshot', 0);
            return _EarlyExecutionResult(shouldContinue: false, command: command);
          }
          snapshot = PreSnapshot(
            target: modifyTarget,
            snapshotCommand: snapshotCmd,
            snapshotOutput: snapshotResult.success ? snapshotResult.output : null,
          );
          if (snapshotResult.success && (snapshotResult.output?.isNotEmpty ?? false)) {
            agentLogger.info('Rollback', '快照已记录: ${snapshotResult.output?.length ?? 0} 字符');
          }
        } catch (e) {
          agentLogger.warn('Rollback', '快照执行失败(忽略): $e');
        }
      }
    }

    final result = await _executeCommand(executor, command, myGeneration: myGeneration);
    agentLogger.info('ReAct', '命令执行结果: success=${result.success}');

    // R1: 主命令执行后检查代际，避免旧任务结果污染新任务的统计/事件流
    // 若代际已变更（cancel + 立即新任务），不再更新 _currentTask 统计、不再 emit result 事件
    if (myGeneration != null && myGeneration != _currentTaskGeneration) {
      agentLogger.info('ReAct', '命令执行后代际失效，丢弃结果不污染新任务');
      onSuccess(result.success, 'generation_invalid_after_exec', 0);
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }

    // 更新命令成功/失败计数
    _currentTask = _currentTask!.copyWith(
      successCount: _currentTask!.successCount + (result.success ? 1 : 0),
      failureCount: _currentTask!.failureCount + (result.success ? 0 : 1),
    );

    _memory.rememberCommand(command);
    _memory.rememberResult(
      command,
      result.output ?? result.error ?? '',
      success: result.success,
    );

    // 格式化观测结果
    // R8: 即使是查询命令也强制上限（20000 字符），防止 cat huge_file / journalctl 等输出撑爆 AI 上下文
    final isQuery = isQueryCommand(command);
    final outputText = isQuery
        ? _truncateQueryOutput(result.output)
        : truncateOutput(result.output, maxLines: 8, maxChars: 600);
    final errorText = isQuery
        ? _truncateQueryOutput(result.error)
        : truncateOutput(result.error, maxLines: 8, maxChars: 600);

    // 失败回滚：命令失败时，把快照+回滚建议注入观测，AI 会看到并建议回滚
    String? rollbackHint;
    if (!result.success && snapshot != null) {
      rollbackHint = RollbackAdvisor.buildRollbackSuggestion(snapshot.target, snapshot.snapshotOutput);
      if (rollbackHint != null) {
        agentLogger.info('Rollback', '命令失败，已生成回滚建议: $rollbackHint');
      }
    }

    final observation = ReActObservation(
      command: command,
      output: result.success
          ? outputText
          : (rollbackHint != null
              ? '$errorText\n\n【失败回滚提示】修改前已快照:\n${snapshot?.snapshotOutput ?? "(无快照)"}\n$rollbackHint'
              : errorText),
      success: result.success,
      error: result.success ? null : errorText,
    );

    // 先发出结构化结果事件，再通知执行完成
    onEvent?.call(AgentEvent.result(
      commandId: commandId ?? _lastCommandEventId,
      command: command,
      success: result.success,
      output: outputText,
      error: result.success ? null : (rollbackHint != null ? '$errorText\n\n$rollbackHint' : errorText),
    ));

    onCommandExecuted?.call(result);

    // 变更台账：非 safe 级命令（即修改性命令）记录到台账，便于事后追溯和回滚
    // safe 级命令（ls/cat/grep 等只读命令）不记录，避免台账膨胀
    if (safetyLevel != SafetyLevel.safe && hostId != null) {
      try {
        await ChangeRecordService.record(
          hostId: hostId!,
          command: command,
          success: result.success,
          conversationId: _currentTask?.id,
        );
      } catch (e) {
        // R8: 持久化失败不可静默吞掉，需记录日志带上下文
        agentLogger.warn('ChangeRecord', '记录变更台账失败(忽略): hostId=$hostId, cmd=$command, err=$e');
      }
    }

    // 审计日志（执行后）：记录执行结果，与执行前的 executed=false 形成完整审计链
    // 所有命令都记录（含 safe 级），执行前已写 executed=false，这里写 executed=true + 结果
    if (hostId != null) {
      try {
        await AuditLogger.log(
          hostId: hostId!,
          command: command,
          safetyLevel: safetyLevel.name,
          output: result.success
              ? (result.output?.isNotEmpty == true ? _truncateForAudit(result.output!) : '(无输出)')
              : (result.error?.isNotEmpty == true ? _truncateForAudit(result.error!) : '(无错误信息)'),
          executed: true,
        );
      } catch (e) {
        agentLogger.warn('Audit', '审计日志写入失败(执行后): hostId=$hostId, cmd=$command, err=$e');
      }
    }

    onSuccess(result.success, 'completed', outputText.length);
    return _EarlyExecutionResult(
      shouldContinue: true,
      observation: observation.format(),
      command: command,
      success: result.success,
    );
  }

  /// 审计日志输出截断（避免 MB 级日志膨胀审计 box）
  static String _truncateForAudit(String s) {
    if (s.length <= 500) return s;
    return '${s.substring(0, 500)}...(${s.length} chars)';
  }

  /// 查询命令输出截断：保留尾部 20000 字符（错误信息通常在末尾）
  /// R8: 查询命令不截断会导致 cat/journalctl/find 等输出撑爆 AI 上下文
  static const int _maxQueryOutputChars = 20000;
  static String _truncateQueryOutput(String? output) {
    if (output == null || output.isEmpty) return '(无输出)';
    if (output.length <= _maxQueryOutputChars) return output;
    return '...(输出过长，已截断前 ${output.length - _maxQueryOutputChars} 字符)\n'
        '${output.substring(output.length - _maxQueryOutputChars)}';
  }

  /// 最近一次 command 事件 id（用于 result 关联）
  /// 由 _callAI 流式解析时更新，_handleExecuteAction 执行命令后用它关联 result
  String _lastCommandEventId = '';

  /// 处理多条命令执行（旧格式 fallback）
  Future<bool> _handleExecuteCommands(List<String> commands, CommandExecutor executor, {required int myGeneration}) async {
    final resultMessages = <String>[];
    var aborted = false;
    for (final command in commands) {
      if (_currentTask?.status == AgentStatus.cancelled) {
        aborted = true;
        break;
      }
      if (myGeneration != _currentTaskGeneration) {
        aborted = true;
        break;
      }
      // R4: 为每条 fallback 命令生成独立的 commandId，并先发 command 事件
      // 否则所有 result 会关联到同一个 _lastCommandEventId，导致 UI 错误地把每个结果卡片链接到最后一条命令
      final cmdId = 'evt_fallback_${_uuid.v4().substring(0, 8)}';
      onEvent?.call(AgentEvent.command(command, id: cmdId));
      final result = await _runCommandWithSafety(command, executor, commandId: cmdId, myGeneration: myGeneration);
      // R1: 命令执行后再次检查代际（执行期间可能被取消/新任务覆盖）
      if (myGeneration != _currentTaskGeneration) {
        aborted = true;
        break;
      }
      if (result.observation != null) {
        resultMessages.add(result.observation!);
      }
      if (!result.shouldContinue) {
        aborted = true;
        break;
      }
    }
    // 即使中断也保留已收集的观测（用户能看到部分命令的执行结果）
    if (resultMessages.isNotEmpty) {
      _conversationHistory.add(ChatMessage.create(role: 'user', content: resultMessages.join('\n\n')));
      _trimMessages(_conversationHistory);
    }
    // 中断时返回 false 让上层退出循环；正常完成返回 true
    return !aborted;
  }

  /// 处理 ask 动作 — 暂停等待用户选择
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleAskAction(ReActStep step, {required int myGeneration}) async {
    final options = step.options ?? [];
    if (options.isEmpty) {
      agentLogger.warn('ReAct', 'ask 动作但无选项，视为 finish');
      _finishTask();
      return false;
    }

    agentLogger.info('ReAct', '检测到选项，暂停等待用户选择: $options');

    _pendingOptions = options;
    _choiceCompleter = Completer<String>();

    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.waitingConfirm,
      currentStep: '等待选择',
    );
    _notifyTaskUpdate();

    // 暂停循环，等待用户选择
    final choice = await _choiceCompleter!.future;
    _choiceCompleter = null;
    _pendingOptions = [];

    if (myGeneration != _currentTaskGeneration) return false;
    if (_currentTask?.status == AgentStatus.cancelled) {
      agentLogger.info('ReAct', '任务在等待选择期间被取消');
      return false;
    }

    if (choice.isEmpty) {
      agentLogger.info('ReAct', '用户取消选择');
      return false;
    }

    // 将用户选择反馈给 AI
    agentLogger.info('ReAct', '用户选择了: $choice');
    onEvent?.call(AgentEvent.info('👉 你选择了: $choice'));

    // 以 ReAct 观测格式反馈
    final observation = '观测: 用户选择了 "$choice"';
    _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
    _trimMessages(_conversationHistory);

    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.thinking,
      currentStep: '继续处理...',
    );
    _notifyTaskUpdate();

    return true; // 继续循环
  }

  /// ═══════════════════════════════════════════════════════
  /// 把工具参数格式化为展示用文本（多行 key:value 格式，与 ReAct 调用格式一致）
  /// 用于 AgentEvent.result.command 和 ReActObservation.command
  /// 避免 AI 从观测/事件里看到 JSON 格式而被"带偏"
  static String _formatToolCommandForDisplay(String toolName, Map<String, dynamic> args) {
    if (args.isEmpty) return toolName;
    final buffer = StringBuffer()
      ..writeln(toolName);
    for (final entry in args.entries) {
      final v = entry.value;
      if (v is List) {
        buffer.writeln('  ${entry.key}: ${v.join(',')}');
      } else {
        buffer.writeln('  ${entry.key}: $v');
      }
    }
    return buffer.toString().trimRight();
  }

  /// 处理 tool 动作 — 调用非 shell 工具（如 SFTP 上传）
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleToolAction(ReActStep step, CommandExecutor executor, {required int myGeneration}) async {
    final toolName = step.toolName?.trim() ?? '';
    final args = step.toolArgs ?? {};

    if (toolName.isEmpty) {
      agentLogger.warn('ReAct', 'tool 动作但未指定工具名');
      onEvent?.call(AgentEvent.info('⚠️ AI 调用工具但未指定工具名'));
      const observation = '观测: 工具调用失败 — 未指定工具名';
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);
      _noCommandRetryCount++;
      if (_noCommandRetryCount >= _maxNoCommandRetries) {
        agentLogger.warn('ReAct', '工具调用重试次数耗尽');
        // R5: 所有终态路径必须设终态 + emit finish + flush 流式内容
        _finishTask(success: false, summary: L10n.str.toolRetryExhausted);
        return false;
      }
      return true;
    }

    final tool = _tools.get(toolName);
    if (tool == null) {
      agentLogger.warn('ReAct', '未知工具: $toolName');
      onEvent?.call(AgentEvent.info('⚠️ 未知工具: $toolName'));
      final available = _tools.all.map((t) => t.name).join(', ');
      final observation = '观测: 工具 $toolName 不存在。可用工具: $available';
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);
      // 与 toolName.isEmpty 路径一致：累计重试次数，防止 AI 反复调用不存在的工具造成死循环
      _noCommandRetryCount++;
      if (_noCommandRetryCount >= _maxNoCommandRetries) {
        agentLogger.warn('ReAct', '未知工具调用重试次数耗尽');
        _finishTask(success: false, summary: L10n.str.toolRetryExhausted);
        return false;
      }
      return true;
    }

    agentLogger.info('ReAct', '调用工具: $toolName, 参数: $args');
    onEvent?.call(AgentEvent.info('🔧 调用工具: $toolName'));

    // 设置执行状态
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      currentStep: '执行工具 $toolName',
    );
    _notifyTaskUpdate();

    try {
      final result = await tool.execute(
        executor: executor,
        args: args,
        onProgress: (msg) {
          agentLogger.info('Tool', '[$toolName] $msg');
          onEvent?.call(AgentEvent.info('  $msg'));
        },
      );

      // R1: await 后做代际检查
      if (myGeneration != _currentTaskGeneration) return false;
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '工具执行期间任务被取消');
        return false;
      }

      agentLogger.info('ReAct', '工具 $toolName 执行结果: success=${result.success}');

      // 发 result 事件
      onEvent?.call(AgentEvent.result(
        commandId: _lastCommandEventId.isNotEmpty ? _lastCommandEventId : 'tool_${DateTime.now().millisecondsSinceEpoch}',
        success: result.success,
        output: result.success ? result.output : null,
        error: result.success ? null : (result.error ?? result.output),
        // UI 展示用：工具名 + 多行参数（与 ReAct 文本格式一致）
        command: _formatToolCommandForDisplay(toolName, args),
      ));

      // 构造观测反馈给 AI
      // 注意：观测里的 command 用多行格式展示参数，避免 AI 从观测里学到 JSON 格式
      final observation = ReActObservation(
        command: _formatToolCommandForDisplay(toolName, args),
        output: result.success ? result.output : (result.output.isNotEmpty ? result.output : '(无输出)'),
        success: result.success,
        error: result.success ? null : result.error,
      ).format();
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);

      // 工具执行成功视为有效进展，重置无命令重试计数
      if (result.success) {
        _noCommandRetryCount = 0;
      }

      // 恢复 thinking 状态
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中...',
      );
      _notifyTaskUpdate();

      return true;
    } catch (e) {
      agentLogger.error('ReAct', '工具 $toolName 执行异常: $e');
      onEvent?.call(AgentEvent.info('❌ 工具 $toolName 执行异常: $e'));

      if (myGeneration != _currentTaskGeneration) return false;

      final observation = '观测: 工具 $toolName 执行异常 — $e';
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中...',
      );
      _notifyTaskUpdate();
      return true;
    }
  }

  /// 处理无命令情况 — 发送继续提示
  /// 返回 true 表示继续循环，false 表示任务结束
  Future<bool> _handleNoCommand() async {
    _noCommandRetryCount++;
    if (_noCommandRetryCount <= _maxNoCommandRetries) {
      agentLogger.info('ReAct', 'AI 未生成命令，发送继续提示 (重试 $_noCommandRetryCount/$_maxNoCommandRetries)');
      const continuePrompt = '请继续执行任务。如果还有需要执行的步骤，请使用以下格式回复：\n\n思考: [你的推理]\n动作: execute\n命令: [要执行的命令]\n\n如果任务已全部完成，请回复：\n\n思考: [总结]\n动作: finish';
      onEvent?.call(AgentEvent.info('⏳ 继续执行...'));
      _conversationHistory.add(ChatMessage.create(role: 'user', content: continuePrompt));
      _trimMessages(_conversationHistory);
      return true;
    }

    // 重试次数耗尽 — AI 连续多次未生成有效命令，说明它已经陷入解释循环或无能力继续
    // R5: 此为异常终止，必须标记 failed，不能默认 completed 误导用户以为任务成功
    agentLogger.warn('ReAct', 'AI 连续 $_noCommandRetryCount 次未生成命令，任务终止 (failed)');
    _finishTask(success: false, summary: 'AI 连续未生成有效命令，任务终止');
    return false;
  }

  /// 标记任务为已完成（统一的结束逻辑）
  void _finishTask({bool success = true, String? summary}) {
    _trimMessages(_conversationHistory);
    final startTime = _currentTask?.createdAt;
    _currentTask = _currentTask!.copyWith(
      status: success ? AgentStatus.completed : AgentStatus.failed,
      completedAt: DateTime.now(),
    );
    _notifyTaskUpdate();
    agentLogger.info('AutoExec', '=== 任务${success ? "完成" : "终止"} ===');
    // L6 修复：补发 finish 事件，让 UI 显示完成卡片并正确结束渲染状态
    final finishSummary = summary ?? _accumulatedMessage;
    onEvent?.call(AgentEvent.finish(summary: finishSummary));
    if (finishSummary.isNotEmpty) {
      onCompleted?.call(finishSummary);
    }
    // P0-2: trace 任务结束
    final taskId = _currentTask?.id;
    if (taskId != null) {
      AgentTracer.instance.endTask(
        taskId,
        status: success ? 'completed' : 'failed',
        summary: finishSummary,
        hostId: hostId,
      );
    }
    // R2: 任务终态后清理瞬态资源（不依赖下次 startTask 才清理）
    // 避免正常 completed 后 _orchestratorCancelToken/_earlyExecutionCompleter 等仍指向旧资源
    // 注意：不清理 _currentTask / _accumulatedMessage / _conversationHistory —
    //   这些是任务结果数据，需要保留供 UI 显示和下次"继续"对话
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiStreamTimedOut = false;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiDoneCompleter = null;
    _aiCancelToken = null;
    _commandCancelToken = null;
    _orchestratorCancelToken = null;
    final mhe = _tools.multiHostExecutor;
    if (mhe != null) {
      mhe.cancelToken = null;
    }
    if (_earlyExecutionCompleter != null && !_earlyExecutionCompleter!.isCompleted) {
      _earlyExecutionCompleter!.complete(_EarlyExecutionResult(
        shouldContinue: false,
        command: _earlyExecutionCommand ?? '',
      ));
    }
    _earlyExecutionCompleter = null;
    _earlyExecutionCommand = null;
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    // 不清 _confirmCompleter / _choiceCompleter — _finishTask 调用前已退出等待状态

    // 任务完成通知（异步，不阻塞引擎）
    _notifyTaskCompletion(success: success, startTime: startTime);
  }

  /// 推送任务完成通知（异步触发，不阻塞引擎主流程）
  void _notifyTaskCompletion({required bool success, DateTime? startTime, String? error}) {
    final task = _currentTask;
    if (task == null) return;
    final duration = startTime != null ? DateTime.now().difference(startTime) : null;
    // 异步推送，不 await，避免阻塞 UI；用独立 async 块 + try/catch 避免 catchError 类型问题
    () async {
      try {
        await NotificationService.notifyTaskCompletion(
          goal: task.goal,
          success: success,
          duration: duration,
          error: error,
        );
      } catch (e) {
        agentLogger.warn('Notification', '推送通知失败: $e');
      }
    }();
  }

  /// 执行单条命令（支持 SSH 和本地 PTY）
  /// [myGeneration] 任务代际，用于 await 后识别"取消 + 立即新任务"竞态
  Future<AgentResult> _executeCommand(CommandExecutor executor, String command, {int? myGeneration}) async {
    final stopwatch = Stopwatch()..start();

    // 执行前检查连接状态
    if (!executor.isConnected) {
      agentLogger.warn('AgentEngine', '连接已断开');
      return AgentResult(
        success: false,
        error: executor is SSHService
            ? 'SSH 连接已断开，请重连后重试'
            : '本地终端已退出，请重新打开终端',
        duration: stopwatch.elapsed,
      );
    }

    // 创建取消令牌，cancelTask 时 complete 触发提前退出
    _commandCancelToken = Completer<void>();

    // sudo 密码自动注入：当命令包含 sudo 且已配置密码时，监控输出流检测密码提示
    // 检测到 "[sudo] password" 或行尾 "Password:" 后通过 writeToTerminal 写入密码
    // 密码不会出现在命令本身或审计日志中（仅写入终端 stdin）
    // 支持多次注入：命令链中可能有多条 sudo（如 sudo cmd1 && sudo cmd2）
    StreamSubscription<String>? sudoSub;
    int sudoInjectCount = 0;
    if (_sudoPassword != null && _sudoPassword!.isNotEmpty && _isSudoCommand(command)) {
      final tailBuffer = StringBuffer();
      // 只匹配 [sudo] 前缀的密码提示，不匹配泛化的 "Password:"
      // 避免 mysql/ssh/su 等其他程序的密码提示触发误注入，导致密码泄露到终端
      final sudoPromptPattern = RegExp(
        r'\[sudo\] password for',
        caseSensitive: false,
      );
      sudoSub = executor.output.listen(
        (data) {
          tailBuffer.write(data);
          // 仅保留尾部 300 字符，避免长输出导致缓冲区无界增长
          if (tailBuffer.length > 300) {
            final s = tailBuffer.toString();
            tailBuffer.clear();
            tailBuffer.write(s.substring(s.length - 300));
          }
          // 清理 ANSI 后匹配，避免转义序列干扰提示检测
          final cleaned = AnsiStripper.strip(tailBuffer.toString());
          if (sudoPromptPattern.hasMatch(cleaned)) {
            executor.writeToTerminal('$_sudoPassword\n');
            sudoInjectCount++;
            // 注入后清空缓冲区，防止同一段提示重复匹配，同时允许下次 sudo 提示再次注入
            tailBuffer.clear();
            agentLogger.info('Sudo', '检测到 sudo 密码提示，已自动注入密码 (第 $sudoInjectCount 次)');
          }
        },
        onError: (e) {
          agentLogger.warn('Sudo', 'sudo 监控订阅错误: $e');
        },
        onDone: () {},
      );
    }

    try {
      final result = await executor.executeAndWait(
        command,
        timeout: getCommandTimeout(command),
        cancelToken: _commandCancelToken,
      );

      _commandCancelToken = null;
      stopwatch.stop();
      await sudoSub?.cancel();

      // R1: 用户取消或代际失效（cancelTask + 立即新任务）→ 返回已取消结果
      // 仅检查 status==cancelled 无法识别"cancel + 立即新任务"场景（新任务会把 status 重置为 thinking）
      if (_currentTask?.status == AgentStatus.cancelled ||
          (myGeneration != null && myGeneration != _currentTaskGeneration)) {
        return AgentResult(
          success: false,
          error: '用户取消了任务',
          duration: stopwatch.elapsed,
        );
      }

      // 清理 ANSI 转义序列
      var cleanOutput = AnsiStripper.strip(result.stdout);
      // 清理 PTY 回显的命令本身
      cleanOutput = stripCommandEcho(cleanOutput, command);

      return AgentResult.fromCommand(
        command: command,
        stdout: cleanOutput,
        stderr: result.stderr,
        exitCode: result.exitCode,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      _commandCancelToken = null;
      await sudoSub?.cancel();
      return AgentResult(
        success: false,
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  /// 一次性压缩对话：调用 AI 将一组消息逐条压缩，返回每条消息对应的压缩摘要
  ///
  /// 输入是 (index, role, content, command, commandSuccess) 元组列表。
  /// 返回 List<(int index, String summary)>，长度 <= 输入（AI 可能合并部分消息）。
  /// 返回 null 表示压缩失败。
  Future<List<(int index, String summary)>?> summarizeMessages(
    List<({int index, String role, String content, String? command, bool? commandSuccess})> messages,
  ) async {
    if (messages.isEmpty) return null;

    agentLogger.info('Compact', '开始一次性压缩 ${messages.length} 条消息');

    // 构造压缩 prompt：要求 AI 输出 JSON 数组，每个元素 {index, summary}
    final buffer = StringBuffer();
    buffer.writeln('你是对话压缩助手。请将以下对话历史逐条压缩为简洁摘要。');
    buffer.writeln();
    buffer.writeln('压缩规则：');
    buffer.writeln('- 用户的废话/寒暄/重复表述压缩为一句话意图');
    buffer.writeln('- 查询类命令（ls/cat/ps/grep/find/df 等）的输出结果：只保留关键结论，冗长输出直接丢弃');
    buffer.writeln('- 修改类命令（install/restart/stop/rm/config 等）：只保留"执行成功"或"失败原因"');
    buffer.writeln('- AI 的思考和推理：压缩为关键决策和结论，去掉推理过程');
    buffer.writeln('- 保留所有关键信息：用户目标、已执行命令、系统状态、遗留问题、下一步计划');
    buffer.writeln('- 每条摘要控制在 200 字以内');
    buffer.writeln('- 不要编造未出现的信息');
    buffer.writeln();
    buffer.writeln('输出格式：JSON 数组，每个元素 {"index": 消息序号, "summary": "压缩摘要"}');
    buffer.writeln('只输出 JSON，不要解释，不要 markdown 代码块标记。');
    buffer.writeln();
    buffer.writeln('=== 对话历史 ===');
    for (final m in messages) {
      final label = m.role == 'user' ? '用户' : 'AI';
      buffer.writeln('[$m.index] $label: ${m.content}');
      if (m.command != null) {
        buffer.writeln('  [命令] ${m.command} → ${m.commandSuccess == true ? "成功" : m.commandSuccess == false ? "失败" : "未知"}');
      }
      buffer.writeln('---');
    }

    final prompt = buffer.toString();

    try {
      final history = [ChatMessage.create(role: 'system', content: '你是对话压缩助手，只输出 JSON 数组，不要解释。')];
      final stream = await _aiProvider.chatStream(
        history: history,
        prompt: prompt,
        config: _modelConfig,
        systemPrompt: null,
      );

      final raw = StringBuffer();
      // 压缩看门狗：防止 AI 流式卡住导致 compact 永久挂起
      await for (final chunk in stream.timeout(
        const Duration(seconds: 120),
        onTimeout: (sink) {
          agentLogger.warn('Compact', '压缩流超时(120s)，终止并使用已收集内容');
          sink.close();
        },
      )) {
        raw.write(chunk);
      }

      final result = _parseCompactJson(raw.toString().trim(), messages);
      if (result == null || result.isEmpty) {
        agentLogger.warn('Compact', '压缩结果解析失败或为空');
        return null;
      }
      agentLogger.info('Compact', '压缩完成: ${result.length} 条摘要');
      return result;
    } catch (e, stack) {
      agentLogger.error('Compact', '压缩失败: $e\n$stack');
      return null;
    }
  }

  /// 解析 AI 返回的 JSON 数组为 (index, summary) 列表
  /// 容错处理：去掉 markdown 代码块标记、提取 JSON 数组片段
  List<(int index, String summary)>? _parseCompactJson(
    String raw,
    List<({int index, String role, String content, String? command, bool? commandSuccess})> messages,
  ) {
    try {
      // 去掉可能的 markdown 代码块标记
      var jsonStr = raw;
      if (jsonStr.startsWith('```')) {
        // 去掉首行 ```json 或 ```
        final firstNewline = jsonStr.indexOf('\n');
        if (firstNewline > 0) jsonStr = jsonStr.substring(firstNewline + 1);
        // 去掉末尾 ```
        if (jsonStr.endsWith('```')) {
          jsonStr = jsonStr.substring(0, jsonStr.length - 3);
        }
      }
      jsonStr = jsonStr.trim();

      // 找到第一个 [ 和最后一个 ]，提取 JSON 数组
      final start = jsonStr.indexOf('[');
      final end = jsonStr.lastIndexOf(']');
      if (start < 0 || end < 0 || end <= start) return null;
      jsonStr = jsonStr.substring(start, end + 1);

      final list = jsonDecode(jsonStr) as List;
      final result = <(int, String)>[];
      for (final item in list) {
        if (item is! Map) continue;
        final idx = item['index'];
        final summary = item['summary'];
        if (idx is int && summary is String && summary.trim().isNotEmpty) {
          result.add((idx, summary.trim()));
        }
      }
      return result;
    } catch (e) {
      agentLogger.warn('Compact', 'JSON 解析失败: $e, raw: ${raw.substring(0, raw.length > 200 ? 200 : raw.length)}');
      return null;
    }
  }

  /// 判断 AI 调用错误是否值得重试（429限流 / 连接错误 / 超时）
  /// 401/400/403 等不可重试
  bool _isRetryableError(dynamic error) {
    if (error is TimeoutException) return true;
    if (error is DioException) {
      return error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          (error.response?.statusCode == 429) ||
          (error.response != null && error.response!.statusCode! >= 500);
    }
    // 网络相关异常字符串兜底
    final msg = error.toString().toLowerCase();
    return msg.contains('connection') || msg.contains('timeout') || msg.contains('reset by peer');
  }

  /// 判断 AI 调用错误是否因取消（取消不可重试，重试违背用户意图）
  /// - DioExceptionType.cancel：Dio CancelToken.cancel() 触发的异常
  /// - StateError('任务已取消'/'任务已被新任务覆盖')：上层代际检查抛出
  bool _isCancellationError(dynamic error) {
    if (error is DioException && error.type == DioExceptionType.cancel) return true;
    if (error is StateError &&
        (error.message == '任务已取消' || error.message == '任务已被新任务覆盖')) {
      return true;
    }
    return false;
  }

  /// 将异常转为用户友好的错误消息
  String _friendlyErrorMessage(dynamic error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          if (statusCode == 401) {
            return L10n.str.errApiKeyInvalid;
          } else if (statusCode == 429) {
            return L10n.str.errRateLimit;
          } else if (statusCode == 400) {
            return L10n.str.errBadRequest;
          } else if (statusCode != null && statusCode >= 500) {
            return L10n.str.errServerError(statusCode);
          }
          return L10n.str.errRequestFailed(statusCode ?? 0);
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return L10n.str.errConnectionTimeout;
        case DioExceptionType.connectionError:
          return L10n.str.errConnectionError;
        default:
          return L10n.str.errConnectionFailed(error.message ?? 'Unknown');
      }
    }
    return L10n.str.errExecutionError(error.toString());
  }

  /// 从 AI 响应中提取所有可执行命令（委托给 CommandExtractor）
  List<String> _extractCommands(String content) => CommandExtractor.extractCommands(content);

  String _buildSystemPrompt(CommandExecutor? executor) {
    final buffer = StringBuffer();

    buffer.writeln('你是 AI 助手，可以执行命令。');

    // 语言自适应：让 AI 根据用户使用的语言回复
    buffer.writeln('【语言要求】');
    buffer.writeln("Always respond in the same language the user uses. If the user speaks Japanese, reply in Japanese; if French, reply in French; if Chinese, reply in Chinese; and so on. Your thinking, explanations, and summaries must all follow the user's language. Commands and technical terms remain as-is.");
    buffer.writeln();

    buffer.writeln('【ReAct 自动执行模式】');
    buffer.writeln('你正在使用 ReAct（推理-行动-观测）框架。');
    buffer.writeln();
    buffer.writeln(prompts.agentAutoRule);

    buffer.writeln();
    buffer.writeln(prompts.behaviorBoundaryRule);
    buffer.writeln();
    buffer.writeln(prompts.knowledgeSafetyRule);
    buffer.writeln();
    buffer.writeln(prompts.dangerousCommandExplainRule);

    // 用户自定义提示词
    String? customPrompt;
    try {
      customPrompt = _getCustomPrompt();
    } catch (e) { debugPrint('[AgentEngine] 读取自定义提示词失败: $e'); }
    if (customPrompt != null && customPrompt.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('【用户自定义指令】');
      buffer.writeln(customPrompt);
    }

    // 知识库注入（异步获取，使用缓存结果）
    if (_cachedKnowledgeInjection != null) {
      buffer.writeln();
      buffer.writeln(_cachedKnowledgeInjection);
    }

    // 工具能力注入（告诉 AI 有哪些非 shell 工具可用）
    final toolsPrompt = _tools.buildToolsPrompt();
    if (toolsPrompt.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(toolsPrompt);
    }

    // 多机编排模式注入
    if (_orchestratorMode && _tools.multiHostExecutor != null) {
      buffer.writeln();
      buffer.writeln(_buildOrchestratorPrompt());
    }

    // 只读模式（Dry-run）注入
    if (_readOnlyMode) {
      buffer.writeln();
      buffer.writeln('【只读模式 / Dry-run】');
      buffer.writeln('当前已开启只读模式，你只能执行只读命令（如 ls/cat/ps/grep/systemctl status 等）。');
      buffer.writeln('任何可能产生副作用的命令（安装/修改/重启/删除等）都会被系统直接拒绝，不需要询问用户确认。');
      buffer.writeln('若任务必须修改系统才能完成，请用 finish 动作告知用户"当前为只读模式，请关闭后重试"。');
    }

    // 注：早期对话摘要已改为逐条写入 ConvMessage.summary，不再在 system prompt 中注入

    if (executor != null) {
      buffer.writeln('\n【系统环境】');
      if (executor is SSHService && executor.osInfo.isNotEmpty) {
        buffer.writeln(executor.osInfo);
      } else {
        buffer.writeln('平台: ${Platform.operatingSystem}');
        buffer.writeln('主机: 本地 (${Platform.localHostname})');
        buffer.writeln('用户: ${Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'unknown'}');
      }
    }

    final memory = _memory.buildContext();
    if (memory.isNotEmpty) buffer.writeln('\n$memory');

    return buffer.toString();
  }

  /// 构建多机编排模式 system prompt 段落
  String _buildOrchestratorPrompt() {
    final executor = _tools.multiHostExecutor!;
    final hostList = executor.buildHostListText();
    return '''【多机编排模式】
你正在多机编排模式下工作，需要跨多台主机调度操作。

【可用主机清单】
$hostList

【编排规则】
1. 跨主机执行命令必须用工具调用，不要用普通 execute：
   动作: tool
   工具: exec_on
   参数:
     hostId: web1
     command: systemctl status nginx
     timeout: 30

2. 批量执行同一命令到多机（如时间同步、日志清理）：
   动作: tool
   工具: exec_batch
   参数:
     hostIds: web1,web2,db1
     command: ntpdate ntp.aliyun.com
     stopOnFailure: false

3. 跨机连通性测试（部署前验证网络依赖）：
   动作: tool
   工具: check_connectivity
   参数:
     fromHostId: web1
     targetHost: 192.168.1.20
     port: 3306

4. 跨机上传文件/目录到指定主机（部署构建产物等）：
   动作: tool
   工具: upload_to
   参数:
     hostId: web1
     local: /path/to/dist
     remote: /var/www
     recursive: true

5. 高风险操作（restart/stop/修改配置/删除）必须先用 ask 询问用户确认
6. 一台主机失败时，用 ask 询问用户选择：中止/跳过该台继续/重试
7. 不要假设主机间网络互通，关键依赖（如 web→db）必须用 check_connectivity 验证
8. 普通 execute 命令仍可用，但只在当前活跃主机执行，不跨主机
9. 部署类任务建议分阶段：规划 → 用 ask 确认矩阵 → 执行 → 验证连通性''';
  }

  /// 启用多机编排模式
  /// [registry] 来自 AgentNotifier，提供对所有 host executor 的访问
  void enableOrchestrator(agent_host_registry.AgentHostRegistry registry) {
    if (_orchestratorMode) return;
    _orchestratorMode = true;
    _tools.enableOrchestrator(registry);
    // 强制下次 startTask 重建 system prompt
    _invalidateSystemPromptCache();
  }

  /// 禁用多机编排模式
  void disableOrchestrator() {
    if (!_orchestratorMode) return;
    _orchestratorMode = false;
    _tools.disableOrchestrator();
    _invalidateSystemPromptCache();
  }

  /// 开启/关闭只读模式（Dry-run）
  /// 开启后 AI 只能执行只读命令（SafetyLevel.safe），任何修改性命令直接拒绝
  void setReadOnlyMode(bool enabled) {
    if (_readOnlyMode == enabled) return;
    _readOnlyMode = enabled;
    _invalidateSystemPromptCache();
  }

  /// 设置 sudo 密码（由 AgentNotifier 从安全存储加载后调用）
  /// 传 null/空字符串则关闭 sudo 自动注入
  void setSudoPassword(String? password) {
    _sudoPassword = (password != null && password.isNotEmpty) ? password : null;
  }

  /// 判断命令是否调用了 sudo（作为命令词，避免匹配 sudoers 等单词）
  bool _isSudoCommand(String command) {
    return RegExp(r'(^|[\s;&|`(])sudo([\s]|$)').hasMatch(command);
  }

  /// 使 system prompt 缓存失效（下次 startTask 重建）
  void _invalidateSystemPromptCache() {
    // 清空对话历史中的 system 消息，强制重建
    _conversationHistory.removeWhere((m) => m.role == 'system');
  }

  String? _getCustomPrompt() {
    try {
      return SettingsDao.getCached('customSystemPrompt') as String?;
    } catch (e) {
      debugPrint('[AgentEngine] 读取自定义提示词失败: $e');
      return null;
    }
  }

  /// 裁剪对话历史：token-aware 裁剪 + 轮数兜底 + 长消息截断
  ///
  /// 三层策略：
  /// 1. 单条消息截断：超过 _maxMessageChars 的内容保留尾部
  /// 2. 轮数兜底：保留最近 _maxConversationRounds 轮（防止极端情况 token 估算偏低）
  /// 3. token-aware 裁剪：估算非系统消息总 token 数，超出 contextWindow * 0.7 时
  ///    丢弃最早的非系统消息，直到总 token 数降至阈值以下
  ///
  /// 阈值 0.7 留出 30% 给 system prompt + 当前 user prompt + completion
  @visibleForTesting
  void trimMessagesForTesting(List<ChatMessage> messages) => _trimMessages(messages);

  void _trimMessages(List<ChatMessage> messages) {
    // 保留 system 消息
    final systemMsgs = messages.where((m) => m.role == 'system').toList();
    final nonSystemMsgs = messages.where((m) => m.role != 'system').toList();

    // 第 1 层：单条消息截断（先截断再做 token 估算，避免单条消息撑爆预算）
    final truncated = <ChatMessage>[];
    for (final msg in nonSystemMsgs) {
      if (msg.content.length > _maxMessageChars) {
        var t = msg.content.substring(msg.content.length - _maxMessageChars);
        // 确保代码块完整闭合：统计 ``` 数量，奇数则补一个 ```
        final openCount = '```'.allMatches(t).length;
        if (openCount % 2 != 0) {
          t = '$t\n```';
        }
        truncated.add(ChatMessage.create(
          role: msg.role,
          content: '...(已截断前 ${msg.content.length - _maxMessageChars} 字符)\n$t',
        ));
      } else {
        truncated.add(msg);
      }
    }

    // 第 2 层：轮数兜底裁剪
    const maxNonSystem = _maxConversationRounds * 2;
    var kept = truncated.length > maxNonSystem
        ? truncated.skip(truncated.length - maxNonSystem).toList()
        : truncated;
    if (kept.length != truncated.length) {
      agentLogger.info('TrimMsgs', '轮数裁剪: ${truncated.length} → ${kept.length} 条');
    }

    // 第 3 层：token-aware 裁剪（保留最近消息，丢弃最早的）
    final contextWindow = _modelConfig.effectiveContextWindow;
    final tokenBudget = (contextWindow * 0.7).round();
    var totalTokens = TokenEstimator.estimateHistory(kept);
    if (totalTokens > tokenBudget) {
      final originalCount = kept.length;
      // 从最早开始丢弃，直到总 token 数降至预算以下或仅剩 2 条
      while (kept.length > 2 && totalTokens > tokenBudget) {
        final removed = kept.removeAt(0);
        totalTokens -= TokenEstimator.estimateMessage(removed);
      }
      agentLogger.info(
        'TrimMsgs',
        'token-aware 裁剪: $originalCount → ${kept.length} 条, '
        'tokens=$totalTokens/$tokenBudget (ctx=$contextWindow)',
      );
    }

    messages
      ..clear()
      ..addAll(systemMsgs)
      ..addAll(kept);
  }

  Future<void> collectSystemInfo(CommandExecutor executor) async {
    try {
      // 平台分支：Unix 用 Unix 命令，Windows 用 wmic/systeminfo
      final isWindowsLocal = executor is! SSHService && Platform.isWindows;
      final commands = isWindowsLocal
          ? [
              // N8: 用 PowerShell + Select-String 兼容中英文系统
              ('powershell -Command "systeminfo | Select-String "OS Name|OS Version""', 'os'),
              ('powershell -Command "Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name"', 'cpu'),
              ('powershell -Command "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory"', 'memory'),
              ('powershell -Command "Get-CimInstance Win32_LogicalDisk | Select-Object Size,FreeSpace,Caption"', 'disk'),
            ]
          : [
              ('cat /etc/os-release 2>/dev/null || uname -a', 'os'),
              ('cat /proc/cpuinfo | grep "model name" | head -1', 'cpu'),
              ('free -h', 'memory'),
              ('df -h | head -5', 'disk'),
            ];

      for (final (cmd, cat) in commands) {
        try {
          // N8: systeminfo 等命令较慢，给 15s 超时
          final result = await executor.executeAndWait(
            cmd,
            timeout: const Duration(seconds: 15),
          );
          final clean = AnsiStripper.strip(result.stdout);
          _memory.rememberSystemInfo('$cat: ${clean.trim()}', category: cat);
        } catch (e) {
          agentLogger.warn('AgentEngine', '收集 $cat 失败: $e');
        }
      }
    } catch (e) { debugPrint('[AgentEngine] 收集系统信息失败: $e'); }
  }
}

/// 提前执行结果
class _EarlyExecutionResult {
  final bool shouldContinue;
  final String? observation;
  final String command;
  final bool success;

  _EarlyExecutionResult({
    required this.shouldContinue,
    required this.command,
    this.observation,
    this.success = false,
  });
}
