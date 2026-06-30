import 'dart:async';
import 'dart:collection';
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
import '../core/safety_guard.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart' as prompts;
import '../utils/ansi_stripper.dart';
import '../utils/react_stream_parser.dart';

/// Agent 日志记录器
///
/// 性能优化要点：
/// 1. 使用循环缓冲区（Queue）替代 List + removeAt(0)，避免 O(n) 移动
/// 2. 文件写入改为异步 + 批量缓冲（500ms 聚合一次），避免每条日志都同步 IO
/// 3. 控制台输出改用 debugPrint（release 模式自动禁用），并按级别过滤
/// 4. 提供同步 getLogs() 用于 UI 读取，避免 UI 卡顿
class AgentLogger {
  static final AgentLogger _instance = AgentLogger._internal();
  factory AgentLogger() => _instance;
  AgentLogger._internal() : _logFile = _initLogFile();

  /// 循环缓冲区：入队 O(1)，超出容量时 removeFirst O(1)
  final Queue<String> _logs = Queue();
  static const int _maxLogs = 1000;

  final File? _logFile;

  /// 文件写入缓冲区：聚合多条件日志一次性异步写入
  final StringBuffer _fileBuffer = StringBuffer();
  Timer? _flushTimer;
  bool _fileWriting = false;

  /// 控制台输出级别控制（避免 release 模式下大量 print 阻塞）
  /// 仅在 debug 模式输出 INFO/DEBUG，WARN/ERROR 始终输出
  static bool get _isDebugMode {
    bool inDebugMode = false;
    assert(() { inDebugMode = true; return true; }());
    return inDebugMode;
  }

  static File? _initLogFile() {
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/ai_terminal_agent.log');
      // 异步写入头部，避免阻塞启动
      file.writeAsString('=== Agent Log Started ${DateTime.now()} ===\n');
      return file;
    } catch (e) {
      return null;
    }
  }

  void log(String level, String tag, String message) {
    final timestamp = DateTime.now();
    final logEntry = '[$timestamp] [$level] [$tag] $message';

    // 入队循环缓冲区
    _logs.addLast(logEntry);
    if (_logs.length > _maxLogs) _logs.removeFirst();

    // 控制台输出：release 模式只输出 WARN/ERROR，debug 模式全量
    if (level == 'WARN' || level == 'ERROR' || _isDebugMode) {
      debugPrint(logEntry);
    }

    // 文件写入：缓冲聚合，500ms 刷一次
    _fileBuffer.writeln(logEntry);
    _scheduleFlush();

    // 通知订阅者（会话持久化层订阅，将日志写入对应 Conversation）
    // 复制监听器列表避免回调中修改列表导致并发问题
    if (_listeners.isNotEmpty) {
      final listeners = List<void Function(String, String, String, DateTime)>.from(_listeners);
      for (final l in listeners) {
        try {
          l(level, tag, message, timestamp);
        } catch (e) { debugPrint('[AgentLogger] 日志监听器异常: $e'); }
      }
    }
  }

  /// 调度异步刷盘（500ms 内的多条日志合并为一次 IO）
  void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(milliseconds: 500), _flushToFile);
  }

  Future<void> _flushToFile() async {
    _flushTimer = null;
    if (_fileWriting) {
      // 上一次还没写完，重新调度
      _scheduleFlush();
      return;
    }
    final file = _logFile;
    if (file == null || _fileBuffer.isEmpty) return;

    final pending = _fileBuffer.toString();
    _fileBuffer.clear();
    _fileWriting = true;
    try {
      await file.writeAsString(pending, mode: FileMode.append, flush: false);
    } catch (e) {
      debugPrint('[AgentLogger] 日志文件写入失败: $e');
      // 写入失败时把内容放回缓冲区，下次再试
      _fileBuffer.write(pending);
    } finally {
      _fileWriting = false;
    }
  }

  void debug(String tag, String message) => log('DEBUG', tag, message);
  void info(String tag, String message) => log('INFO', tag, message);
  void warn(String tag, String message) => log('WARN', tag, message);
  void error(String tag, String message) => log('ERROR', tag, message);

  /// 返回日志副本（正序：最早在前，最新在后，UI 滚动到底部看最新）
  List<String> getLogs() => _logs.toList(growable: false);

  String getLogsAsString() => _logs.join('\n');

  // ═══════════════════════════════════════════
  // 日志订阅：供会话持久化层订阅，将日志写入对应 Conversation
  // ═══════════════════════════════════════════
  final List<void Function(String level, String tag, String message, DateTime timestamp)> _listeners = [];

  /// 订阅日志写入事件（返回取消订阅的函数）
  void Function() subscribe(void Function(String level, String tag, String message, DateTime timestamp) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// 确保所有缓冲日志刷盘（应用退出时调用）
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flushToFile();
  }
}

final agentLogger = AgentLogger();

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

  /// 等待用户选择选项的 Completer（ReAct ask 动作 / :::choose A|B|C:::）
  Completer<String>? _choiceCompleter;
  List<String> _pendingOptions = []; // 当前等待选择的选项

  /// 命令执行取消令牌：cancelTask 时 complete，_executeCommand 据此提前退出
  Completer<void>? _commandCancelToken;

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

  /// 对话历史最大轮数（每轮 = assistant + user），超出时裁剪最早的轮次
  static const int _maxConversationRounds = 40;

  /// 单条消息最大字符数，超出截断
  static const int _maxMessageChars = 4000;

  AgentEngine({
    required AIProvider aiProvider,
    required AIModelConfig modelConfig,
    required AgentMemory memory,
    this.maxSteps = 0,
  })  : _aiProvider = aiProvider,
        _modelConfig = modelConfig,
        _memory = memory;

  AgentTask? get currentTask => _currentTask;
  bool get isRunning =>
      _currentTask?.status == AgentStatus.thinking ||
      _currentTask?.status == AgentStatus.executing;
  bool get hasPendingConfirm => _confirmCompleter != null && !_confirmCompleter!.isCompleted;
  String? get pendingConfirmCommand => _pendingConfirmCommand;
  bool get hasPendingChoice => _choiceCompleter != null && !_choiceCompleter!.isCompleted;
  List<String> get pendingOptions => List.unmodifiable(_pendingOptions);

  void clearHistory() {
    _conversationHistory.clear();
    _conversationSummary = null;
  }

  /// 从持久化消息恢复引擎对话历史（切换会话时调用）
  /// [messages] 已摘要索引之后的消息（含 user/assistant，不含 system）
  /// [summary] 对话摘要（如有）
  /// system 消息会在下次 startTask 时由 _buildSystemPrompt 重建
  void restoreHistory(List<ChatMessage> messages, {String? summary}) {
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
        osInfo: executor is SSHService ? (executor as SSHService).osInfo : null,
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
      await _executeAutomatic(goal, executor);
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '执行异常: $e\n$stack');
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.failed,
        completedAt: DateTime.now(),
      );
      onError?.call(_friendlyErrorMessage(e));
      onTaskUpdated?.call(_currentTask!);
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

  Future<void> _executeAutomatic(String goal, CommandExecutor? executor) async {
    agentLogger.info('ReAct', '=== 开始 ReAct 自动执行 ===');

    if (executor == null || !executor.isConnected) {
      final type = executor == null ? '无执行器' : '未连接';
      agentLogger.error('ReAct', '$type!');
      onError?.call('需要连接到终端才能使用自动模式');
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
              _runCommandWithSafety(command, executor, commandId: commandId).then((result) {
                if (_earlyExecutionCompleter?.isCompleted == false) {
                  _earlyExecutionCompleter?.complete(result);
                }
              });
            }
          },
        );
      } catch (e, stack) {
        final friendlyMsg = _friendlyErrorMessage(e);
        agentLogger.error('ReAct', 'AI 调用异常: $e\n$stack');
        onError?.call(friendlyMsg);
        break;
      }

      // 将 AI 响应加入对话历史
      _conversationHistory.add(ChatMessage.create(role: 'assistant', content: fullResponse));

      // 用户在 AI 流式输出期间点了取消
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', 'AI 响应期间任务被取消');
        return;
      }

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
          final shouldContinue = await _handleAskAction(step);
          if (!shouldContinue) return;
          continue;

        case ActionType.execute:
          if (step.command == null || step.command!.trim().isEmpty) {
            // ReAct 解析出了 execute 但无命令 → fallback 到旧方式提取
            final fallbackCommands = _extractCommands(fullResponse);
            if (fallbackCommands.isNotEmpty) {
              agentLogger.info('ReAct', 'ReAct 格式无命令，旧方式提取 ${fallbackCommands.length} 条');
              final shouldContinue = await _handleExecuteCommands(fallbackCommands, executor);
              if (!shouldContinue) return;
              break;
            }
            // 两种方式都未提取到命令，发送继续提示
            final shouldContinue = await _handleNoCommand();
            if (!shouldContinue) return;
            continue;
          }
          final shouldContinue = await _handleExecuteAction(step, executor);
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
    } else {
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
    }
  }

  /// 调用 AI 模型，流式返回完整响应
  /// [onCommandDetected] 可选回调：流式过程中检测到完整命令时触发，可用于提前执行
  Future<String> _callAI({
    void Function(String command, String commandId)? onCommandDetected,
  }) async {
    agentLogger.info('ReAct', '调用 AI 模型...');
    agentLogger.debug('ReAct', '消息历史: ${_conversationHistory.length} 条');

    String fullResponse = '';
    final stream = await _aiProvider.chatStream(
      history: _conversationHistory,
      prompt: '',
      config: _modelConfig,
      systemPrompt: null,
    );

    int chunkCount = 0;
    final emittedStableIds = <String>{}; // 已发出事件的稳定 ID（内容哈希），用于流式去重
    final stableIdToFinalId = <String, String>{}; // 稳定 ID → 最终全局唯一 ID 的映射
    int globalEventSeq = 0; // 全局事件序号
    bool commandDetectedNotified = false; // 是否已通知过命令检测（一轮只通知一次）
    Timer? watchdog; // AI 流式超时看门狗

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

    // 超时看门狗：如果 120 秒内没有新 chunk 到达，强制结束流
    bool streamTimedOut = false;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(const Duration(seconds: 120), () {
        streamTimedOut = true;
        agentLogger.error('ReAct', 'AI 流式输出超时（120s 无数据），强制中断');
      });
    }
    resetWatchdog();

    try {
      await for (final chunk in stream) {
        if (streamTimedOut) break;
        resetWatchdog();
        chunkCount++;
        fullResponse += chunk;
        _accumulatedMessage += chunk;
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
                  final finalId = assignFinalId(e);
                  _lastCommandEventId = finalId;
                  // 立即发出 command 事件，让 UI 先显示命令块
                  if (!emittedStableIds.contains(e.id)) {
                    emittedStableIds.add(e.id);
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
      }
    } finally {
      watchdog?.cancel();
    }

    if (streamTimedOut && fullResponse.isEmpty) {
      throw TimeoutException('AI 响应超时（120s 无数据）');
    }

    // 流式结束：一次性发出所有事件
    final events = ReActStreamParser.parse(fullResponse);
    for (final e in events) {
      if (!emittedStableIds.contains(e.id)) {
        emittedStableIds.add(e.id);
        final finalId = assignFinalId(e);
        e.isStreaming = false;
        onEvent?.call(e);
      }
      if (e.isCommand) {
        _lastCommandEventId = stableIdToFinalId[e.id] ?? e.id;
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
    final lines = content.split('\n');
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.startsWith('动作:') || trimmedLine.startsWith('动作：')) {
        final sepIdx = trimmedLine.indexOf(trimmedLine.contains('：') ? '：' : ':');
        final actionStr = trimmedLine.substring(sepIdx + 1).trim().toLowerCase();
        if (actionStr == 'execute') {
          action = ActionType.execute;
        } else if (actionStr == 'finish') {
          action = ActionType.finish;
        } else if (actionStr == 'ask') {
          action = ActionType.ask;
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
      if (_isTaskComplete(content)) {
        return ReActStep(thought: thought ?? content, action: ActionType.finish, rawResponse: content);
      }
      if (command != null) {
        return ReActStep(thought: thought ?? '', action: ActionType.execute, command: command, rawResponse: content);
      }
      // 有思考内容但没有命令 → 继续执行，不要结束
      if (thought != null && thought!.isNotEmpty) {
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
      rawResponse: content,
    );
  }

  /// ═══════════════════════════════════════════════════════
  /// 处理 execute 动作 — 执行单条命令并返回观测
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleExecuteAction(ReActStep step, CommandExecutor executor) async {
    final command = step.command!.trim();

    // 如果有提前执行的结果（或正在执行中），直接用
    if (_earlyExecutionCommand == command && _earlyExecutionCompleter != null) {
      final result = await _earlyExecutionCompleter!.future;
      _earlyExecutionCompleter = null;
      _earlyExecutionCommand = null;

      if (!result.shouldContinue) {
        return false;
      }
      // 把观测加入对话历史
      if (result.observation != null) {
        _conversationHistory.add(ChatMessage.create(role: 'user', content: result.observation!));
        _trimMessages(_conversationHistory);
      }
      return true;
    }

    final result = await _runCommandWithSafety(command, executor);
    if (!result.shouldContinue) {
      return false;
    }
    if (result.observation != null) {
      _conversationHistory.add(ChatMessage.create(role: 'user', content: result.observation!));
      _trimMessages(_conversationHistory);
    }
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
  }) async {
    agentLogger.info('ReAct', '执行命令: $command (commandId=$commandId)');

    // 安全检查
    final safetyLevel = SafetyGuard.check(command);
    agentLogger.info('ReAct', '安全检查: $safetyLevel');

    if (safetyLevel == SafetyLevel.blocked) {
      agentLogger.warn('ReAct', '命令被安全系统拦截: $command');
      onEvent?.call(AgentEvent.info('🚫 命令被安全系统拦截: $command'));
      final observation = ReActObservation(
        command: command,
        output: '命令被安全系统拦截，禁止执行',
        success: false,
        error: SafetyGuard.getTip(safetyLevel),
      ).format();
      return _EarlyExecutionResult(shouldContinue: true, observation: observation, command: command);
    }

    // warn 级别命令需要用户确认
    if (safetyLevel == SafetyLevel.warn) {
      agentLogger.warn('ReAct', '高风险命令需要确认: $command');
      _pendingConfirmCommand = command;
      _confirmCompleter = Completer<bool>();

      onEvent?.call(AgentEvent.info('⚠️ 高风险命令需要确认: `$command`\n${SafetyGuard.getTip(safetyLevel)}'));

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.waitingConfirm,
        currentStep: '等待确认: $command',
      );
      onTaskUpdated?.call(_currentTask!);

      final confirmed = await _confirmCompleter!.future;
      _confirmCompleter = null;
      _pendingConfirmCommand = null;

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

    final result = await _executeCommand(executor, command);
    agentLogger.info('ReAct', '命令执行结果: success=${result.success}');

    _memory.rememberCommand(command);
    _memory.rememberResult(
      command,
      result.output ?? result.error ?? '',
      success: result.success,
    );

    // 格式化观测结果
    final isQuery = _isQueryCommand(command);
    final outputText = isQuery
        ? (result.output ?? '(无输出)')
        : _truncateOutput(result.output, maxLines: 8, maxChars: 600);
    final errorText = isQuery
        ? (result.error ?? '(无错误信息)')
        : _truncateOutput(result.error, maxLines: 8, maxChars: 600);

    final observation = ReActObservation(
      command: command,
      output: result.success ? outputText : errorText,
      success: result.success,
      error: result.success ? null : errorText,
    );

    // 先发出结构化结果事件，再通知执行完成
    onEvent?.call(AgentEvent.result(
      commandId: commandId ?? _lastCommandEventId,
      command: command,
      success: result.success,
      output: outputText,
      error: result.success ? null : errorText,
    ));

    onCommandExecuted?.call(result);

    return _EarlyExecutionResult(
      shouldContinue: true,
      observation: observation.format(),
      command: command,
      success: result.success,
    );
  }

  /// 最近一次 command 事件 id（用于 result 关联）
  /// 由 _callAI 流式解析时更新，_handleExecuteAction 执行命令后用它关联 result
  String _lastCommandEventId = '';

  /// 处理多条命令执行（旧格式 fallback）
  Future<bool> _handleExecuteCommands(List<String> commands, CommandExecutor executor) async {
    final resultMessages = <String>[];

    for (final command in commands) {
      if (_currentTask?.status == AgentStatus.cancelled) return false;

      final safetyLevel = SafetyGuard.check(command);

      if (safetyLevel == SafetyLevel.blocked) {
        onEvent?.call(AgentEvent.info('🚫 命令被安全系统拦截: $command'));
        resultMessages.add('🚫 命令被安全系统拦截: $command');
        continue;
      }

      if (safetyLevel == SafetyLevel.warn) {
        _pendingConfirmCommand = command;
        _confirmCompleter = Completer<bool>();
        onEvent?.call(AgentEvent.info('⚠️ 高风险命令需要确认: `$command`\n${SafetyGuard.getTip(safetyLevel)}'));

        _currentTask = _currentTask!.copyWith(
          status: AgentStatus.waitingConfirm,
          currentStep: '等待确认: $command',
        );
        onTaskUpdated?.call(_currentTask!);

        final confirmed = await _confirmCompleter!.future;
        _confirmCompleter = null;
        _pendingConfirmCommand = null;

        if (_currentTask?.status == AgentStatus.cancelled) return false;

        if (!confirmed) {
          onEvent?.call(AgentEvent.info('❌ 用户拒绝执行此命令'));
          resultMessages.add('❌ 用户拒绝执行: $command');
          continue;
        }

        onEvent?.call(AgentEvent.info('✅ 用户已确认，开始执行...'));
      }

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.executing,
        currentStep: command,
      );
      onTaskUpdated?.call(_currentTask!);
      onCommandGenerated?.call(command);

      final result = await _executeCommand(executor, command);
      onCommandExecuted?.call(result);

      _memory.rememberCommand(command);
      _memory.rememberResult(command, result.output ?? result.error ?? '', success: result.success);

      final isQuery = _isQueryCommand(command);
      final outputText = isQuery ? (result.output ?? '(无输出)') : _truncateOutput(result.output, maxLines: 8, maxChars: 600);
      final errorText = isQuery ? (result.error ?? '(无错误信息)') : _truncateOutput(result.error, maxLines: 8, maxChars: 600);

      // 使用 ReAct 观测格式反馈
      final observation = ReActObservation(
        command: command,
        output: result.success ? outputText : errorText,
        success: result.success,
        error: result.success ? null : errorText,
      );
      resultMessages.add(observation.format());

      // 发出结构化结果事件（与 _runCommandWithSafety 保持一致）
      onEvent?.call(AgentEvent.result(
        commandId: '',
        command: command,
        success: result.success,
        output: outputText,
        error: result.success ? null : errorText,
      ));
    }

    // 汇总观测作为 user 消息
    if (resultMessages.isNotEmpty) {
      _conversationHistory.add(ChatMessage.create(role: 'user', content: resultMessages.join('\n\n')));
      _trimMessages(_conversationHistory);
    }

    return true;
  }

  /// 处理 ask 动作 — 暂停等待用户选择
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleAskAction(ReActStep step) async {
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
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    onTaskUpdated?.call(_currentTask!);
    agentLogger.info('AutoExec', '=== 任务完成 ===');
    if (_accumulatedMessage.isNotEmpty) {
      onCompleted?.call(_accumulatedMessage);
    }
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
        timeout: const Duration(seconds: 60),
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
      cleanOutput = _stripCommandEcho(cleanOutput, command);

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
      if (cmd != null && _looksLikeCommand(cmd)) {
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
        if (RegExp(prefix).hasMatch(trimmed) && _looksLikeCommand(trimmed)) {
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
      if (_isDescriptiveText(trimmed)) continue;
      // 清理列表前缀
      var cleaned = trimmed.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'^[-*]\s*'), '');
      if (_looksLikeCommand(cleaned) && cleaned.length >= 3) {
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
      if (_looksLikeCommand(cmd)) return cmd;
    }
    // 如果没有找到"像命令"的行，返回第一个非空非注释行
    for (final line in lines) {
      final cmd = line.trim();
      if (cmd.isEmpty || cmd.startsWith('#') || cmd.startsWith('```')) continue;
      if (cmd.length >= 3) return cmd;
    }
    return null;
  }

  /// 判断文本是否是描述性文字（而非命令）
  bool _isDescriptiveText(String text) {
    // 中文字符占比过高
    final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
    if (text.length > 0 && chineseCount / text.length > 0.5) return true;
    // 常见的说明性开头
    final descriptiveStarts = ['请', '可以', '需要', '应该', '将', '这个', '该',
      '命令', '说明', '例如', '如下', '包括', '用于', '表示', '输出', '结果',
      '检查', '查看', '确认', '注意', '提示', '警告', '步骤'];
    for (final s in descriptiveStarts) {
      if (text.startsWith(s)) return true;
    }
    return false;
  }

  bool _looksLikeCommand(String text) {
    // 检查文本是否看起来像命令
    if (text.length < 3 || text.length > 500) return false;
    // 不应该包含太多中文
    final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
    if (chineseCount > text.length * 0.3) return false;
    // 应该包含至少一个常见命令关键词
    final cmdKeywords = [
      'sudo', 'yum', 'apt', 'dnf', 'apk', 'curl', 'wget', 'tar',
      'cat', 'echo', 'export', 'cd', 'mkdir', 'chmod', 'java',
      'rm', 'cp', 'mv', 'ln', 'systemctl', 'service', 'install',
      'download', 'extract', 'set', 'export', 'source', 'update'
    ];
    return cmdKeywords.any((k) => text.toLowerCase().contains(k));
  }

  /// 判断命令是否是查询/只读类命令（输出不应截断，agent 需要完整结果定位问题）
  bool _isQueryCommand(String command) {
    final queryPrefixes = [
      // 文件搜索与内容查找
      'grep', 'egrep', 'fgrep', 'find', 'locate', 'which', 'where', 'type',
      // 文件查看
      'cat', 'head', 'tail', 'less', 'more', 'file', 'stat', 'diff',
      // 目录列表
      'ls', 'tree', 'du', 'df',
      // 系统信息
      'uname', 'hostname', 'uptime', 'free', 'env', 'printenv', 'pwd',
      'whoami', 'id', 'date', 'cal',
      // 进程与服务
      'ps', 'top', 'htop', 'lsof', 'ss', 'netstat', 'vmstat', 'iostat',
      // 系统管理（只读子命令）
      'systemctl status', 'systemctl list', 'systemctl is-',
      'service status',
      // 日志查看
      'journalctl', 'dmesg', 'last', 'lastb', 'w', 'who',
      // 容器/编排（只读子命令）
      'docker ps', 'docker images', 'docker logs', 'docker inspect', 'docker search',
      'kubectl get', 'kubectl describe', 'kubectl logs', 'kubectl top',
      // 包管理（只读子命令）
      'apt list', 'apt show', 'apt-cache', 'yum list', 'yum info',
      'dnf list', 'dnf info', 'rpm -q', 'dpkg -l', 'dpkg -s',
      // 网络（只读）
      'ping', 'traceroute', 'dig', 'nslookup', 'host', 'curl', 'wget',
      'ip addr', 'ip route', 'ip link', 'ifconfig',
      // 文本统计
      'wc', 'sort', 'uniq', 'awk', 'sed -n',
    ];

    final cmdLower = command.trim().toLowerCase();
    return queryPrefixes.any((prefix) => cmdLower.startsWith(prefix));
  }

  bool _isTaskComplete(String response) {
    final keywords = [
      '任务完成', '任务已完成', '✅ 任务完成', '✅任务完成',
      '已完成', '已全部完成', '全部完成', '所有步骤已完成',
      '操作完成', '安装完成', '配置完成', '部署完成',
    ];
    for (final k in keywords) {
      if (response.contains(k)) return true;
    }
    return false;
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

  /// 截断命令输出，保留尾部（长输出有价值的信息通常在末尾，如 "Complete!"）
  /// 最多保留 [maxLines] 行，或 [maxChars] 字符
  String _truncateOutput(String? output, {int maxLines = 8, int maxChars = 600}) {
    if (output == null || output.isEmpty) return '(无输出)';
    if (output.length <= maxChars) return output;

    // 按行分割，取尾部行
    final lines = output.split('\n');
    if (lines.length <= maxLines) {
      // 行数不多但字符超限，取尾部字符
      return '...(输出过长，已截断前 ${output.length - maxChars} 字符)\n${output.substring(output.length - maxChars)}';
    }

    // 取尾部行
    final tailLines = lines.skip(lines.length - maxLines).toList();
    final tailText = tailLines.join('\n');
    if (tailText.length > maxChars) {
      return '...(输出过长，已截断)\n${tailText.substring(tailText.length - maxChars)}';
    }
    return '...(输出过长，已截断前 ${lines.length - maxLines} 行)\n$tailText';
  }

  /// 清理 PTY 输出中的命令回显
  /// 终端在执行命令时会先把输入的命令回显到 stdout，导致结果里包含命令本身
  String _stripCommandEcho(String output, String command) {
    if (output.isEmpty || command.isEmpty) return output;

    final trimmedOutput = output.trimLeft();
    final trimmedCommand = command.trim();

    // 情况 1：输出第一行就是命令本身（最常见）
    final firstNewline = trimmedOutput.indexOf('\n');
    final firstLine = firstNewline == -1 ? trimmedOutput : trimmedOutput.substring(0, firstNewline);
    if (firstLine.trim() == trimmedCommand || firstLine.trim().endsWith(trimmedCommand)) {
      return firstNewline == -1 ? '' : trimmedOutput.substring(firstNewline + 1).trimLeft();
    }

    // 情况 2：命令出现在开头，但前面可能有 prompt 残留字符
    final commandIndex = trimmedOutput.indexOf(trimmedCommand);
    if (commandIndex >= 0 && commandIndex < 20) {
      final afterCommand = trimmedOutput.substring(commandIndex + trimmedCommand.length);
      // 如果命令后紧跟换行，则把这整段视为回显
      if (afterCommand.startsWith('\n') || afterCommand.startsWith('\r')) {
        return afterCommand.replaceFirst(RegExp(r'^[\r\n]+'), '').trimLeft();
      }
    }

    return output;
  }

  Future<void> collectSystemInfo(CommandExecutor executor) async {
    try {
      final commands = [
        ('cat /etc/os-release 2>/dev/null || uname -a', 'os'),
        ('cat /proc/cpuinfo | grep "model name" | head -1', 'cpu'),
        ('free -h', 'memory'),
        ('df -h | head -5', 'disk'),
      ];

      for (final (cmd, cat) in commands) {
        final completer = Completer<String>();
        String output = '';
        StreamSubscription<String>? sub;

        sub = executor.output.listen(
          (data) => output += data,
          onDone: () {
            if (!completer.isCompleted) completer.complete(output);
          },
        );

        executor.execute(cmd);

        // 2 秒超时收集系统信息
        output = await completer.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            return output;
          },
        );

        // 始终取消订阅，防止泄漏
        await sub.cancel();

        final clean = AnsiStripper.strip(output);
        _memory.rememberSystemInfo('$cat: ${clean.trim()}', category: cat);
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
