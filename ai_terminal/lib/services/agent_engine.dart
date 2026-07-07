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
import '../core/safety_guard.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart' as prompts;
import '../utils/ansi_stripper.dart';
import '../utils/command_heuristics.dart';
import '../utils/output_processor.dart';
import '../utils/react_stream_parser.dart';
import '../utils/rollback_advisor.dart';
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
  String? _pendingConfirmCommand; // 当前等待确认的命令

  /// 任务代际 token：每次 startTask 递增，循环中检查此 token 是否仍为当前任务
  /// 防止取消+立即发送导致旧循环与新循环并发
  int _currentTaskGeneration = 0;

  /// 等待用户选择选项的 Completer（ReAct ask 动作 / :::choose A|B|C:::）
  Completer<String>? _choiceCompleter;
  List<String> _pendingOptions = []; // 当前等待选择的选项

  /// 命令执行取消令牌：cancelTask 时 complete，_executeCommand 据此提前退出
  Completer<void>? _commandCancelToken;

  /// AI 流式订阅：cancelTask 时取消，立即停止消费旧任务流
  StreamSubscription<String>? _aiStreamSub;

  /// AI 流式超时看门狗（_callAI 内创建，cancelTask 中取消）
  Timer? _aiWatchdog;
  bool _aiStreamTimedOut = false;

  /// AI 流式完成 Completer（cancelTask 可 complete 以解除 _callAI 挂起）
  Completer<void>? _aiDoneCompleter;

  /// 缓存的知识库注入文本（在 startTask 时查询，在 _buildSystemPrompt 时使用）
  String? _cachedKnowledgeInjection;

  /// 对话摘要（由 compact 产生，注入系统提示供 AI 回顾早期对话）
  String? _conversationSummary;

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
  })  : _aiProvider = aiProvider,
        _modelConfig = modelConfig,
        _memory = memory;

  AgentTask? get currentTask => _currentTask;
  bool get isRunning =>
      _currentTask?.status == AgentStatus.thinking ||
      _currentTask?.status == AgentStatus.executing ||
      _currentTask?.status == AgentStatus.waitingConfirm;
  bool get hasPendingConfirm => _confirmCompleter != null && !_confirmCompleter!.isCompleted;
  String? get pendingConfirmCommand => _pendingConfirmCommand;
  bool get hasPendingChoice => _choiceCompleter != null && !_choiceCompleter!.isCompleted;
  List<String> get pendingOptions => List.unmodifiable(_pendingOptions);

  void clearHistory() {
    // 清理瞬态字段，避免旧任务残留污染新会话
    if (isRunning || hasPendingConfirm || hasPendingChoice) {
      cancelTask();
    }
    _accumulatedMessage = '';
    _noCommandRetryCount = 0;
    _lastCommandEventId = '';
    _conversationHistory.clear();
    _conversationSummary = null;
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
    _accumulatedMessage = '';
    _noCommandRetryCount = 0;
    _lastCommandEventId = '';
    _conversationHistory.clear();
    _conversationSummary = summary;
    _conversationHistory.addAll(messages);
    agentLogger.info('RestoreHistory', '恢复引擎历史: ${messages.length} 条消息, summary=${summary != null ? "有" : "无"}');
  }

  /// 设置对话摘要（压缩后 / 恢复会话时调用），下次构建系统提示时会注入
  void setConversationSummary(String? summary) {
    _conversationSummary = summary;
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
    _accumulatedMessage = '';  // 重置累积消息
    _noCommandRetryCount = 0;  // 重置无命令重试计数

    if (isRunning) {
      agentLogger.warn('AgentEngine', 'Agent 正在执行任务，拒绝新任务');
      onError?.call('Agent 正在执行任务，请等待完成');
      return;
    }

    // 新任务代际，使任何残留的旧循环退出
    _currentTaskGeneration++;
    final myGeneration = _currentTaskGeneration;

    _currentTask = AgentTask(
      id: _uuid.v4(),
      goal: goal,
      status: AgentStatus.thinking,
    );
    onTaskUpdated?.call(_currentTask!);

    // 查询知识库，缓存注入文本
    try {
      final knowledge = KnowledgeService();
      // 确保知识库已初始化（懒初始化兜底）
      await knowledge.ensureInitialized();
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
        onError?.call(_friendlyErrorMessage(e));
        onTaskUpdated?.call(_currentTask!);
        // 任务失败通知
        _notifyTaskCompletion(success: false, startTime: startTime, error: e.toString());
      }
    }
  }

  void cancelTask() {
    // 无论当前处于何种状态（thinking/executing/waitingConfirm），都标记为取消
    if (_currentTask != null &&
        _currentTask!.status != AgentStatus.cancelled &&
        _currentTask!.status != AgentStatus.completed &&
        _currentTask!.status != AgentStatus.failed) {
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.cancelled,
        completedAt: DateTime.now(),
      );
      onTaskUpdated?.call(_currentTask!);
    }
    // 递近代际，使任何残留的旧循环立即退出
    _currentTaskGeneration++;
    // 同时取消等待确认
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _pendingConfirmCommand = null;
    // 同时取消等待选择
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    _pendingOptions = [];
    // 取消正在执行的命令
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    // 取消 AI 流式订阅，停止消费旧任务流
    // 注意: cancel() 不触发 onDone，需手动 complete doneCompleter
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
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
      onError?.call('需要连接到终端才能使用自动模式');
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.failed,
        completedAt: DateTime.now(),
      );
      onTaskUpdated?.call(_currentTask!);
      return;
    }

    agentLogger.info('ReAct', '执行器连接状态: ${executor.isConnected}');

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

      // ═══════════════════════════════════════════
      // 阶段1: 思考 (Think) — 调用 AI 获取响应
      // ═══════════════════════════════════════════
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中... (第 $stepCount 步)',
      );
      onTaskUpdated?.call(_currentTask!);
      onThinking?.call('🤔 正在思考下一步...');

      String fullResponse;
      try {
        // 重置提前执行缓存
        _earlyExecutionCompleter = null;
        _earlyExecutionCommand = null;
        fullResponse = await _callAI(
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
        final friendlyMsg = _friendlyErrorMessage(e);
        agentLogger.error('ReAct', 'AI 调用异常: $e\n$stack');
        onError?.call(friendlyMsg);
        // L1 修复：AI 异常应标记 failed 并退出，不应走到循环后的 completed 逻辑
        if (myGeneration == _currentTaskGeneration && _currentTask != null) {
          final startTime = _currentTask!.createdAt;
          _currentTask = _currentTask!.copyWith(
            status: AgentStatus.failed,
            completedAt: DateTime.now(),
          );
          onTaskUpdated?.call(_currentTask!);
          // R5: 失败路径也要 emit finish 事件，避免 UI 卡 running
          onEvent?.call(AgentEvent.finish(summary: '任务失败: $friendlyMsg'));
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
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    onTaskUpdated?.call(_currentTask!);
    agentLogger.info('ReAct', '=== 执行结束 (步数: $stepCount/$maxSteps) ===');

    if (stepCount >= maxSteps) {
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
  }

  /// 调用 AI 模型，流式返回完整响应
  /// [onCommandDetected] 可选回调：流式过程中检测到完整命令时触发，可用于提前执行
  /// 对可重试错误（429/connectionError/timeout）做指数退避重试，最多 3 次
  Future<String> _callAI({
    void Function(String command, String commandId)? onCommandDetected,
  }) async {
    agentLogger.info('ReAct', '调用 AI 模型...');
    agentLogger.debug('ReAct', '消息历史: ${_conversationHistory.length} 条');

    String fullResponse = '';
    // 重试仅对流建立阶段有效，一旦开始接收 chunk 就不再重试
    Stream<String> stream;
    const maxRetries = 3;
    final backoffDelays = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];

    int attempt = 0;
    while (true) {
      attempt++;
      try {
        stream = await _aiProvider.chatStream(
          history: _conversationHistory,
          prompt: '',
          config: _modelConfig,
          systemPrompt: null,
        );
        break; // 成功建立流
      } catch (e) {
        if (attempt > maxRetries || !_isRetryableError(e)) {
          rethrow;
        }
        agentLogger.warn('ReAct', 'AI 流建立失败（第 $attempt 次），${backoffDelays[attempt - 1].inSeconds}s 后重试: $e');
        await Future.delayed(backoffDelays[attempt - 1]);
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

    try {
      await doneCompleter.future;
    } finally {
      _aiWatchdog?.cancel();
      _aiWatchdog = null;
      await _aiStreamSub?.cancel();
      _aiStreamSub = null;
      if (_aiDoneCompleter == doneCompleter) _aiDoneCompleter = null;
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
          // 解析后续的 工具: 和 参数: 行
          for (var j = i + 1; j < lines.length && j < i + 5; j++) {
            final tl = lines[j].trim();
            if (tl.startsWith('工具:') || tl.startsWith('工具：')) {
              final sep = tl.indexOf(tl.contains('：') ? '：' : ':');
              toolName = tl.substring(sep + 1).trim();
            } else if (tl.startsWith('参数:') || tl.startsWith('参数：')) {
              final sep = tl.indexOf(tl.contains('：') ? '：' : ':');
              final argsStr = tl.substring(sep + 1).trim();
              try {
                final parsed = jsonDecode(argsStr);
                if (parsed is Map<String, dynamic>) {
                  toolArgs = parsed;
                }
              } catch (e) {
                agentLogger.warn('ReAct', '工具参数 JSON 解析失败: $e, raw=$argsStr');
              }
            } else if (tl.isEmpty) {
              continue;
            } else {
              // 遇到非工具/参数行，停止
              break;
            }
          }
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

    // 安全检查
    final safetyLevel = SafetyGuard.check(command);
    agentLogger.info('ReAct', '安全检查: $safetyLevel');

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
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    if (safetyLevel == SafetyLevel.blocked) {
      agentLogger.warn('ReAct', '命令被安全系统拦截: $command');
      final reason = SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      onEvent?.call(AgentEvent.info('🚫 命令被安全系统拦截: $command\n原因: $reason'));
      // 审计日志：被拦截的命令也要记录（executed=false）
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
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    // warn 级别命令需要用户确认
    if (safetyLevel == SafetyLevel.warn) {
      agentLogger.warn('ReAct', '高风险命令需要确认: $command');
      _pendingConfirmCommand = command;
      _confirmCompleter = Completer<bool>();

      // 显示具体的风险说明，而非泛泛的"危险操作"
      final reason = SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      onEvent?.call(AgentEvent.info('⚠️ 高风险命令需要确认: `$command`\n风险说明: $reason'));

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.waitingConfirm,
        currentStep: '等待确认: $command',
      );
      onTaskUpdated?.call(_currentTask!);

      final confirmed = await _confirmCompleter!.future;
      _confirmCompleter = null;
      _pendingConfirmCommand = null;

      if (myGeneration != null && myGeneration != _currentTaskGeneration) {
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务在等待确认期间被取消');
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
        return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
      }

      agentLogger.info('ReAct', '用户确认执行危险命令: $command');
      onEvent?.call(AgentEvent.info('✅ 用户已确认，开始执行...'));
    }

    // 执行命令
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      currentStep: command,
    );
    onTaskUpdated?.call(_currentTask!);
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
          final snapshotResult = await _executeCommand(executor, snapshotCmd);
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

    final result = await _executeCommand(executor, command);
    agentLogger.info('ReAct', '命令执行结果: success=${result.success}');

    _memory.rememberCommand(command);
    _memory.rememberResult(
      command,
      result.output ?? result.error ?? '',
      success: result.success,
    );

    // 格式化观测结果
    final isQuery = isQueryCommand(command);
    final outputText = isQuery
        ? (result.output ?? '(无输出)')
        : truncateOutput(result.output, maxLines: 8, maxChars: 600);
    final errorText = isQuery
        ? (result.error ?? '(无错误信息)')
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
      // 审计日志：记录非 safe 级命令的执行情况（含执行结果摘要）
      try {
        await AuditLogger.log(
          hostId: hostId!,
          command: command,
          safetyLevel: safetyLevel.name,
          output: result.success
              ? (result.output?.isNotEmpty == true ? _truncateForAudit(result.output!) : null)
              : (result.error?.isNotEmpty == true ? _truncateForAudit(result.error!) : null),
          executed: true,
        );
      } catch (e) {
        agentLogger.warn('Audit', '审计日志写入失败(忽略): hostId=$hostId, cmd=$command, err=$e');
      }
    }

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

  /// 最近一次 command 事件 id（用于 result 关联）
  /// 由 _callAI 流式解析时更新，_handleExecuteAction 执行命令后用它关联 result
  String _lastCommandEventId = '';

  /// 处理多条命令执行（旧格式 fallback）
  Future<bool> _handleExecuteCommands(List<String> commands, CommandExecutor executor, {required int myGeneration}) async {
    final resultMessages = <String>[];
    for (final command in commands) {
      if (_currentTask?.status == AgentStatus.cancelled) return false;
      if (myGeneration != _currentTaskGeneration) return false;
      final result = await _runCommandWithSafety(command, executor, myGeneration: myGeneration);
      if (result.observation != null) {
        resultMessages.add(result.observation!);
      }
      if (!result.shouldContinue) break;
    }
    if (resultMessages.isNotEmpty) {
      _conversationHistory.add(ChatMessage.create(role: 'user', content: resultMessages.join('\n\n')));
      _trimMessages(_conversationHistory);
    }
    return true;
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
    onTaskUpdated?.call(_currentTask!);

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
    onTaskUpdated?.call(_currentTask!);

    return true; // 继续循环
  }

  /// ═══════════════════════════════════════════════════════
  /// 处理 tool 动作 — 调用非 shell 工具（如 SFTP 上传）
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleToolAction(ReActStep step, CommandExecutor executor, {required int myGeneration}) async {
    final toolName = step.toolName?.trim() ?? '';
    final args = step.toolArgs ?? {};

    if (toolName.isEmpty) {
      agentLogger.warn('ReAct', 'tool 动作但未指定工具名');
      onEvent?.call(AgentEvent.info('⚠️ AI 调用工具但未指定工具名'));
      final observation = '观测: 工具调用失败 — 未指定工具名';
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);
      _noCommandRetryCount++;
      if (_noCommandRetryCount >= _maxNoCommandRetries) {
        agentLogger.warn('ReAct', '工具调用重试次数耗尽');
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
      return true;
    }

    agentLogger.info('ReAct', '调用工具: $toolName, 参数: $args');
    onEvent?.call(AgentEvent.info('🔧 调用工具: $toolName'));

    // 设置执行状态
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      currentStep: '执行工具 $toolName',
    );
    onTaskUpdated?.call(_currentTask!);

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
        command: '$toolName ${jsonEncode(args)}',
      ));

      // 构造观测反馈给 AI
      final observation = ReActObservation(
        command: '$toolName(${jsonEncode(args)})',
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
      onTaskUpdated?.call(_currentTask!);

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
      onTaskUpdated?.call(_currentTask!);
      return true;
    }
  }

  /// 处理无命令情况 — 发送继续提示
  /// 返回 true 表示继续循环，false 表示任务结束
  Future<bool> _handleNoCommand() async {
    _noCommandRetryCount++;
    if (_noCommandRetryCount <= _maxNoCommandRetries) {
      agentLogger.info('ReAct', 'AI 未生成命令，发送继续提示 (重试 $_noCommandRetryCount/$_maxNoCommandRetries)');
      final continuePrompt = '请继续执行任务。如果还有需要执行的步骤，请使用以下格式回复：\n\n思考: [你的推理]\n动作: execute\n命令: [要执行的命令]\n\n如果任务已全部完成，请回复：\n\n思考: [总结]\n动作: finish';
      onEvent?.call(AgentEvent.info('⏳ 继续执行...'));
      _conversationHistory.add(ChatMessage.create(role: 'user', content: continuePrompt));
      _trimMessages(_conversationHistory);
      return true;
    }

    // 重试次数耗尽，视为任务完成
    agentLogger.info('ReAct', 'AI 连续未生成命令，视为任务完成');
    _finishTask();
    return false;
  }

  /// 标记任务为已完成（统一的结束逻辑）
  void _finishTask() {
    _trimMessages(_conversationHistory);
    final startTime = _currentTask?.createdAt;
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    onTaskUpdated?.call(_currentTask!);
    agentLogger.info('AutoExec', '=== 任务完成 ===');
    // L6 修复：补发 finish 事件，让 UI 显示完成卡片并正确结束渲染状态
    onEvent?.call(AgentEvent.finish(summary: _accumulatedMessage));
    if (_accumulatedMessage.isNotEmpty) {
      onCompleted?.call(_accumulatedMessage);
    }
    // 任务完成通知（异步，不阻塞引擎）
    _notifyTaskCompletion(success: true, startTime: startTime);
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
  Future<AgentResult> _executeCommand(CommandExecutor executor, String command) async {
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

    try {
      final result = await executor.executeAndWait(
        command,
        timeout: getCommandTimeout(command),
        cancelToken: _commandCancelToken,
      );

      _commandCancelToken = null;
      stopwatch.stop();

      // 用户取消：返回已取消结果，让上层退出循环
      if (_currentTask?.status == AgentStatus.cancelled) {
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
      return AgentResult(
        success: false,
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  /// 压缩对话：调用 AI 总结一组消息为简短摘要
  ///
  /// 输入是 ConvMessage 列表（来自 persistence 层），但为避免循环依赖，
  /// 这里接收通用的 (role, content) 元组列表，由调用方转换。
  ///
  /// 返回 null 表示压缩失败或无内容。
  Future<String?> summarize(List<({String role, String content})> messages) async {
    if (messages.isEmpty) return null;

    agentLogger.info('Compact', '开始压缩 ${messages.length} 条消息');

    final buffer = StringBuffer();
    buffer.writeln('请将以下对话历史总结为简洁的摘要，保留关键信息：');
    buffer.writeln('- 用户的核心目标和需求');
    buffer.writeln('- 已经执行过的关键命令和结果（成功/失败）');
    buffer.writeln('- 当前系统状态（已安装的软件、版本等）');
    buffer.writeln('- 遗留的问题或下一步计划');
    buffer.writeln('摘要应控制在 500 字以内，用要点形式输出，不要包含客套话。');
    buffer.writeln();
    buffer.writeln('=== 对话历史 ===');
    for (final m in messages) {
      final label = m.role == 'user' ? '用户' : 'AI';
      buffer.writeln('$label: ${m.content}');
      buffer.writeln('---');
    }

    final prompt = buffer.toString();

    try {
      final history = [ChatMessage.create(role: 'system', content: '你是对话压缩助手，只输出摘要内容，不要解释。')];
      final stream = await _aiProvider.chatStream(
        history: history,
        prompt: prompt,
        config: _modelConfig,
        systemPrompt: null,
      );

      final summary = StringBuffer();
      await for (final chunk in stream) {
        summary.write(chunk);
      }
      final result = summary.toString().trim();
      agentLogger.info('Compact', '压缩完成，摘要长度: ${result.length}');
      return result.isEmpty ? null : result;
    } catch (e, stack) {
      agentLogger.error('Compact', '压缩失败: $e\n$stack');
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

  /// 将异常转为用户友好的错误消息
  String _friendlyErrorMessage(dynamic error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          if (statusCode == 401) {
            return 'API Key 无效或已过期，请在设置中更新 API Key';
          } else if (statusCode == 429) {
            return '请求过于频繁，请稍后重试';
          } else if (statusCode == 400) {
            return '请求格式错误，请检查 AI 模型配置（模型名称、API 地址等）';
          } else if (statusCode != null && statusCode >= 500) {
            return 'AI 服务端错误 ($statusCode)，请稍后重试';
          }
          return '请求失败 ($statusCode)';
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '连接 AI 服务超时，请检查网络';
        case DioExceptionType.connectionError:
          return '无法连接到 AI 服务，请检查网络和 API 地址';
        default:
          return '连接失败: ${error.message ?? "未知错误"}';
      }
    }
    return '执行出错: $error';
  }

  String? _extractCommand(String content) {
    agentLogger.debug('ExtractCmd', '开始解析，内容长度: ${content.length}');
    agentLogger.debug('ExtractCmd', '内容前500字符: ${content.length > 500 ? content.substring(0, 500) : content}');

    // ========== 模式 1: markdown 代码块 (```bash ... ``` 或 ``` ... ```) ==========
    // 放宽匹配：允许 ``` 后无换行、允许 bash/sh/shell 标识符后直接跟内容
    final codeBlockPatterns = [
      // ```bash \n content ```
      RegExp(r'```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```', multiLine: true),
      // ``` \n content ``` （无语言标识）
      RegExp(r'```\s*\n([\s\S]*?)```', multiLine: true),
      // ```bash content ``` （单行代码块，无换行）
      RegExp(r'```\s*(?:bash|sh|shell)\s+([^\n]+)```', multiLine: true),
    ];

    for (final pattern in codeBlockPatterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final rawBlock = match.group(1)?.trim();
        if (rawBlock != null && rawBlock.isNotEmpty) {
          // 代码块可能包含多行命令，取第一行有效命令
          final command = _extractFirstCommand(rawBlock);
          if (command != null) {
            agentLogger.info('ExtractCmd', '模式1匹配成功: $command');
            return command;
          }
        }
      }
    }

    // ========== 模式 2: 单个反引号包裹的命令 ==========
    final singleBacktick = RegExp(r'`([^`\n]+)`');
    final backtickMatch = singleBacktick.firstMatch(content);
    if (backtickMatch != null) {
      final cmd = backtickMatch.group(1)?.trim();
      if (cmd != null && looksLikeCommand(cmd)) {
        agentLogger.info('ExtractCmd', '模式2匹配成功(反引号): $cmd');
        return cmd;
      }
    }

    // ========== 模式 3: 独立行的命令（常见命令前缀）==========
    final commandPrefixes = [
      r'^sudo\s+', r'^yum\s+', r'^apt\s+', r'^apt-get\s+', r'^dnf\s+',
      r'^apk\s+', r'^pacman\s+', r'^brew\s+', r'^curl\s+', r'^wget\s+',
      r'^tar\s+', r'^unzip\s+', r'^cat\s+', r'^echo\s+', r'^export\s+',
      r'^source\s+', r'^cd\s+', r'^mkdir\s+', r'^chmod\s+', r'^chown\s+',
      r'^rm\s+', r'^cp\s+', r'^mv\s+', r'^ln\s+', r'^systemctl\s+',
      r'^service\s+', r'^java\s+', r'^javac\s+', r'^python\s+',
      r'^pip\s+', r'^npm\s+', r'^node\s+', r'^git\s+', r'^docker\s+',
      r'^kubectl\s+', r'^ls\s+', r'^grep\s+', r'^find\s+', r'^head\s+',
      r'^tail\s+', r'^which\s+', r'^where\s+', r'^type\s+',
      r'^uname\s+', r'^date\s+', r'^whoami\s+', r'^id\s+',
      r'^pwd\s+', r'^env\s+', r'^printenv\s+', r'^sed\s+',
      r'^awk\s+', r'^sort\s+', r'^uniq\s+', r'^wc\s+',
      r'^chmod\s+', r'^chgrp\s+', r'^touch\s+', r'^dd\s+',
    ];

    final lines = content.split('\n');
    for (final line in lines) {
      var trimmed = line.trim();
      // 跳过说明性文字行
      if (trimmed.startsWith('#') || trimmed.startsWith('//') ||
          trimmed.startsWith('请') || trimmed.startsWith('执行') ||
          trimmed.startsWith('命令') || trimmed.startsWith('说明') ||
          trimmed.startsWith('注意') || trimmed.startsWith('提示') ||
          trimmed.startsWith('警告') || trimmed.startsWith('- ') ||
          trimmed.startsWith('* ')) {
        continue;
      }
      // 清理可能的列表前缀 (1. 2. 3. 或 - *)
      trimmed = trimmed.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
      trimmed = trimmed.replaceFirst(RegExp(r'^[-*]\s*'), '');

      for (final prefix in commandPrefixes) {
        if (RegExp(prefix).hasMatch(trimmed) && looksLikeCommand(trimmed)) {
          agentLogger.info('ExtractCmd', '模式3匹配成功(前缀): $trimmed');
          return trimmed;
        }
      }
    }

    // ========== 模式 4: 宽松提取 — 从内容中找任何像命令的独立行 ==========
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      // 跳过明显非命令的行
      if (isDescriptiveText(trimmed)) continue;
      // 清理列表前缀
      var cleaned = trimmed.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'^[-*]\s*'), '');
      if (looksLikeCommand(cleaned) && cleaned.length >= 3) {
        agentLogger.info('ExtractCmd', '模式4匹配成功(宽松): $cleaned');
        return cleaned;
      }
    }

    agentLogger.warn('ExtractCmd', '所有模式均未匹配到命令');
    return null;
  }

  /// 从 AI 响应中提取所有可执行命令（支持批量）
  /// 优先从代码块中提取所有有效命令行，如果没有代码块则回退到单条提取
  List<String> _extractCommands(String content) {
    agentLogger.debug('ExtractCmd', '开始批量解析，内容长度: ${content.length}');

    final commands = <String>[];

    // ========== 模式 1: markdown 代码块 (```bash ... ``` 或 ``` ... ```) ==========
    final codeBlockPatterns = [
      RegExp(r'```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*(?:bash|sh|shell)\s+([^\n]+)```', multiLine: true),
    ];

    for (final pattern in codeBlockPatterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final rawBlock = match.group(1)?.trim();
        if (rawBlock != null && rawBlock.isNotEmpty) {
          commands.addAll(_parseCodeBlock(rawBlock));
          if (commands.isNotEmpty) {
            agentLogger.info('ExtractCmd', '批量模式1提取 ${commands.length} 条命令');
            return commands;
          }
        }
      }
    }

    // 回退到单条命令提取
    final single = _extractCommand(content);
    if (single != null) {
      commands.add(single);
      agentLogger.info('ExtractCmd', '回退单条提取: $single');
    }
    return commands;
  }

  /// 解析代码块，识别 heredoc 并将其作为整体提取
  List<String> _parseCodeBlock(String rawBlock) {
    final commands = <String>[];
    final lines = rawBlock.split('\n');

    int i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();

      if (line.isEmpty) {
        i++;
        continue;
      }

      // 检测 heredoc 开始：cat > file << 'EOF' 或 cat > file << EOF 等
      final heredocStart = RegExp(r'''<<\s*['"]?(\w+)['"]?''');
      final heredocMatch = heredocStart.firstMatch(line);

      if (heredocMatch != null) {
        final delimiter = heredocMatch.group(1)!;
        final heredocLines = <String>[line];

        // 收集 heredoc 内容直到遇到结束标记
        i++;
        while (i < lines.length) {
          final heredocLine = lines[i];
          heredocLines.add(heredocLine);
          if (heredocLine.trim() == delimiter) {
            i++;
            break;
          }
          i++;
        }

        final heredocCommand = heredocLines.join('\n');
        commands.add(heredocCommand);
        agentLogger.info('ExtractCmd', 'heredoc 命令提取: ${heredocCommand.length} 字符');
        continue;
      }

      // 非注释、非代码块标记的普通命令行
      if (line.startsWith('#') && !line.startsWith('#!')) {
        i++;
        continue;
      }
      if (line.startsWith('```') || line.endsWith('```')) {
        i++;
        continue;
      }
      if (line.length >= 3) {
        commands.add(line);
      }
      i++;
    }

    return commands;
  }

  /// 从多行代码块中提取第一条有效命令
  String? _extractFirstCommand(String block) {
    final lines = block.split('\n');
    for (final line in lines) {
      final cmd = line.trim();
      if (cmd.isEmpty || cmd.startsWith('#')) continue;
      if (cmd.startsWith('```') || cmd.endsWith('```')) continue;
      if (looksLikeCommand(cmd)) return cmd;
    }
    // 如果没有找到"像命令"的行，返回第一个非空非注释行
    for (final line in lines) {
      final cmd = line.trim();
      if (cmd.isEmpty || cmd.startsWith('#') || cmd.startsWith('```')) continue;
      if (cmd.length >= 3) return cmd;
    }
    return null;
  }

  String _buildSystemPrompt(CommandExecutor? executor) {
    final buffer = StringBuffer();

    buffer.writeln('你是 AI 助手，可以执行命令。');

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

    // 早期对话摘要（压缩后产生，帮助 AI 回顾早期对话）
    if (_conversationSummary != null && _conversationSummary!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('【早期对话摘要】');
      buffer.writeln(_conversationSummary);
    }

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
   参数: {"hostId":"web1","command":"systemctl status nginx","timeout":"30"}

2. 批量执行同一命令到多机（如时间同步、日志清理）：
   动作: tool
   工具: exec_batch
   参数: {"hostIds":"web1,web2,db1","command":"ntpdate ntp.aliyun.com","stopOnFailure":"false"}

3. 跨机连通性测试（部署前验证网络依赖）：
   动作: tool
   工具: check_connectivity
   参数: {"fromHostId":"web1","targetHost":"192.168.1.20","port":"3306"}

4. 跨机上传文件/目录到指定主机（部署构建产物等）：
   动作: tool
   工具: upload_to
   参数: {"hostId":"web1","local":"/path/to/dist","remote":"/var/www","recursive":"true"}

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

  /// 使 system prompt 缓存失效（下次 startTask 重建）
  void _invalidateSystemPromptCache() {
    // 清空对话历史中的 system 消息，强制重建
    _conversationHistory.removeWhere((m) => m.role == 'system');
  }

  String? _getCustomPrompt() {
    try {
      final box = HiveInit.settingsBox;
      return box.get('customSystemPrompt') as String?;
    } catch (e) {
      debugPrint('[AgentEngine] 读取自定义提示词失败: $e');
      return null;
    }
  }

  /// 裁剪对话历史，保留最近 _maxConversationRounds 轮，并对长消息截断
  void _trimMessages(List<ChatMessage> messages) {
    // 保留 system 消息
    final systemMsgs = messages.where((m) => m.role == 'system').toList();
    final nonSystemMsgs = messages.where((m) => m.role != 'system').toList();

    // 每轮 = 1 assistant + 1 user，保留最近 _maxConversationRounds 轮
    final maxNonSystem = _maxConversationRounds * 2;
    List<ChatMessage> keptNonSystem;
    if (nonSystemMsgs.length > maxNonSystem) {
      keptNonSystem = nonSystemMsgs.skip(nonSystemMsgs.length - maxNonSystem).toList();
      agentLogger.info('TrimMsgs', '裁剪对话历史: ${nonSystemMsgs.length} → ${keptNonSystem.length} 条非系统消息');
    } else {
      keptNonSystem = nonSystemMsgs;
    }

    // 对每条非系统消息截断过长内容
    for (int i = 0; i < keptNonSystem.length; i++) {
      final msg = keptNonSystem[i];
      if (msg.content.length > _maxMessageChars) {
        var truncated = msg.content.substring(msg.content.length - _maxMessageChars);
        // 确保代码块完整闭合：统计 ``` 数量，奇数则补一个 ```
        final openCount = '```'.allMatches(truncated).length;
        if (openCount % 2 != 0) {
          truncated = '$truncated\n```';
        }
        keptNonSystem[i] = ChatMessage.create(
          role: msg.role,
          content: '...(已截断前 ${msg.content.length - _maxMessageChars} 字符)\n$truncated',
        );
      }
    }

    messages
      ..clear()
      ..addAll(systemMsgs)
      ..addAll(keptNonSystem);
  }

  Future<void> collectSystemInfo(CommandExecutor executor) async {
    try {
      // 平台分支：Unix 用 Unix 命令，Windows 用 wmic/systeminfo
      final isWindowsLocal = executor is! SSHService && Platform.isWindows;
      final commands = isWindowsLocal
          ? [
              // N8: 用 PowerShell + Select-String 兼容中英文系统
              ('powershell -Command "systeminfo | Select-String \"OS Name|OS Version\""', 'os'),
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
