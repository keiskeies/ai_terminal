import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_model.dart';
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

/// Agent 日志记录器
class AgentLogger {
  static final AgentLogger _instance = AgentLogger._internal();
  factory AgentLogger() => _instance;
  AgentLogger._internal() : _logFile = _initLogFile();

  final List<String> _logs = [];
  final File? _logFile;

  static File? _initLogFile() {
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/ai_terminal_agent.log');
      file.writeAsStringSync('=== Agent Log Started ${DateTime.now()} ===\n');
      return file;
    } catch (e) {
      return null;
    }
  }

  void log(String level, String tag, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logEntry = '[$timestamp] [$level] [$tag] $message';
    _logs.add(logEntry);
    if (_logs.length > 1000) _logs.removeAt(0);

    // 打印到控制台
    print(logEntry);

    // 写入文件
    try {
      _logFile?.writeAsStringSync('$logEntry\n', mode: FileMode.append);
    } catch (_) {}
  }

  void debug(String tag, String message) => log('DEBUG', tag, message);
  void info(String tag, String message) => log('INFO', tag, message);
  void warn(String tag, String message) => log('WARN', tag, message);
  void error(String tag, String message) => log('ERROR', tag, message);

  List<String> getLogs() => List.unmodifiable(_logs);
  String getLogsAsString() => _logs.join('\n');
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

  /// ReAct 格式重试计数（AI 未遵循格式时递增）
  int _reactFormatRetryCount = 0;
  static const int _maxReactFormatRetries = 2;

  /// 缓存的知识库注入文本（在 startTask 时查询，在 _buildSystemPrompt 时使用）
  String? _cachedKnowledgeInjection;

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

  int maxSteps = 0; // 0 = 无限制（运行时兜底为 _defaultMaxSteps）

  /// 对话历史最大轮数（每轮 = assistant + user），超出时裁剪最早的轮次
  static const int _maxConversationRounds = 10;

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
    _reactFormatRetryCount = 0;  // 重置 ReAct 格式重试计数

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
    if (_currentTask != null && isRunning) {
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
    } else {
      _conversationHistory[0] = ChatMessage.create(role: 'system', content: systemPrompt);
    }

    // 添加用户消息
    _conversationHistory.add(ChatMessage.create(
      role: 'user',
      content: isNewConversation ? '任务: $goal\n\n请分析任务并开始执行。' : goal,
    ));

    agentLogger.info('ReAct', '对话历史: ${_conversationHistory.length} 条消息 (新对话: $isNewConversation)');

    // 仅新对话显示启动提示
    if (isNewConversation) {
      _accumulatedMessage = '🚀 开始自动执行任务...\n\n';
      onMessage?.call('🚀 开始自动执行任务...\n\n');
    } else {
      _accumulatedMessage = '';
    }

    agentLogger.info('ReAct', '开始 ReAct 循环 (最多 $maxSteps 步)');

    while (stepCount < maxSteps) {
      stepCount++;
      _reactFormatRetryCount = 0; // 重置格式重试计数
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
        fullResponse = await _callAI();
      } catch (e, stack) {
        final friendlyMsg = _friendlyErrorMessage(e);
        agentLogger.error('ReAct', 'AI 调用异常: $e\n$stack');
        onError?.call(friendlyMsg);
        break;
      }

      // 将 AI 响应加入对话历史
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
      }

      // 检查任务是否被取消
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务被取消');
        return;
      }
    }

    // 达到最大步数
    _currentTask = _currentTask!.copyWith(
      status: (stepCount >= maxSteps) ? AgentStatus.failed : AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    onTaskUpdated?.call(_currentTask!);
    agentLogger.info('ReAct', '=== 执行结束 (步数: $stepCount/$maxSteps) ===');

    if (stepCount >= maxSteps) {
      agentLogger.warn('ReAct', '达到最大执行步数 $maxSteps');
      final msg = '\n\n⚠️ 达到最大执行步数 ($maxSteps)，任务被中断';
      _accumulatedMessage += msg;
      onMessage?.call(msg);
    } else {
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
    }
  }

  /// 调用 AI 模型，流式返回完整响应
  Future<String> _callAI() async {
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
    await for (final chunk in stream) {
      chunkCount++;
      fullResponse += chunk;
      _accumulatedMessage += chunk;
      onMessage?.call(chunk);
    }
    agentLogger.info('ReAct', 'AI 响应完成，共 $chunkCount 个数据块，${fullResponse.length} 字符');
    return fullResponse;
  }

  /// ═══════════════════════════════════════════════════════
  /// ReAct 解析器 — 从 AI 响应中提取结构化动作
  /// ═══════════════════════════════════════════════════════
  ReActStep _parseReActResponse(String content) {
    String? thought;
    ActionType? action;
    String? command;
    List<String>? options;

    final lines = content.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmedLine = line.trim();

      // 解析 "思考:" 行（支持中英文冒号）
      if (trimmedLine.startsWith('思考:') || trimmedLine.startsWith('思考：')) {
        final sepIdx = trimmedLine.indexOf(trimmedLine.contains('：') ? '：' : ':');
        thought = trimmedLine.substring(sepIdx + 1).trim();
        continue;
      }

      // 解析 "动作:" 行
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
        continue;
      }

      // 解析 "选项:" 行（ask 动作的参数）
      if (trimmedLine.startsWith('选项:') || trimmedLine.startsWith('选项：')) {
        final sepIdx = trimmedLine.indexOf(trimmedLine.contains('：') ? '：' : ':');
        final optionsStr = trimmedLine.substring(sepIdx + 1).trim();
        options = optionsStr
            .split('|')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        continue;
      }

      // 解析 "命令:" 行（execute 动作的参数）
      // 命令可能跨多行（如 heredoc），取 "命令:" 后到响应末尾的所有内容
      if (trimmedLine.startsWith('命令:') || trimmedLine.startsWith('命令：')) {
        final sepIdx = line.indexOf(line.contains('：') ? '：' : ':');
        final cmdFirstLine = line.substring(sepIdx + 1).trim();
        // 收集后续行直到遇到另一个字段标记或响应结束
        final cmdLines = <String>[cmdFirstLine];
        for (int j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          // 遇到字段标记则停止
          if (nextLine.startsWith('思考:') || nextLine.startsWith('思考：') ||
              nextLine.startsWith('动作:') || nextLine.startsWith('动作：') ||
              nextLine.startsWith('选项:') || nextLine.startsWith('选项：') ||
              nextLine.startsWith('命令:') || nextLine.startsWith('命令：')) {
            break;
          }
          cmdLines.add(lines[j]);
        }
        command = cmdLines.join('\n').trim();
        continue;
      }
    }

    // ═══ Fallback：AI 未遵循 ReAct 格式 ═══
    if (action == null) {
      // 检查旧格式完成标记
      if (_isTaskComplete(content)) {
        agentLogger.info('ReAct', 'Fallback: 检测到旧格式完成标记');
        return ReActStep(
          thought: thought ?? content,
          action: ActionType.finish,
          rawResponse: content,
        );
      }

      // 检查旧格式 :::choose 选项
      final legacyOptions = _extractOptions(content);
      if (legacyOptions.isNotEmpty) {
        agentLogger.info('ReAct', 'Fallback: 检测到 :::choose 选项');
        return ReActStep(
          thought: thought ?? '',
          action: ActionType.ask,
          options: legacyOptions,
          rawResponse: content,
        );
      }

      // 尝试旧格式提取命令
      final legacyCommands = _extractCommands(content);
      if (legacyCommands.isNotEmpty) {
        agentLogger.info('ReAct', 'Fallback: 旧格式提取 ${legacyCommands.length} 条命令');
        return ReActStep(
          thought: thought ?? '',
          action: ActionType.execute,
          command: legacyCommands.first,
          options: legacyCommands.length > 1
              ? legacyCommands.skip(1).toList()
              : null,
          rawResponse: content,
        );
      }

      // 完全无法解析，视为仅思考
      agentLogger.info('ReAct', '无法解析 AI 响应为任何已知格式');
      return ReActStep(
        thought: thought ?? content,
        action: ActionType.finish, // 无有效动作，将由 _handleNoCommand 处理
        rawResponse: content,
      );
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
    agentLogger.info('ReAct', '执行命令: $command');

    // 安全检查
    final safetyLevel = SafetyGuard.check(command);
    agentLogger.info('ReAct', '安全检查: $safetyLevel');

    if (safetyLevel == SafetyLevel.blocked) {
      agentLogger.warn('ReAct', '命令被安全系统拦截: $command');
      final msg = '\n\n🚫 命令被安全系统拦截: $command\n';
      _accumulatedMessage += msg;
      onMessage?.call(msg);
      // 将拦截信息作为观测反馈给 AI
      final observation = ReActObservation(
        command: command,
        output: '命令被安全系统拦截，禁止执行',
        success: false,
        error: SafetyGuard.getTip(safetyLevel),
      );
      _conversationHistory.add(ChatMessage.create(role: 'user', content: observation.format()));
      _trimMessages(_conversationHistory);
      return true; // 继续循环，让 AI 基于观测调整
    }

    // warn 级别命令需要用户确认
    if (safetyLevel == SafetyLevel.warn) {
      agentLogger.warn('ReAct', '高风险命令需要确认: $command');
      _pendingConfirmCommand = command;
      _confirmCompleter = Completer<bool>();

      final msg = '\n\n⚠️ 高风险命令需要确认: `$command`\n${SafetyGuard.getTip(safetyLevel)}\n请点击下方按钮确认或拒绝。\n';
      _accumulatedMessage += msg;
      onMessage?.call(msg);

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.waitingConfirm,
        currentStep: '等待确认: $command',
      );
      onTaskUpdated?.call(_currentTask!);

      // 暂停循环，等待用户确认或拒绝
      final confirmed = await _confirmCompleter!.future;
      _confirmCompleter = null;
      _pendingConfirmCommand = null;

      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务在等待确认期间被取消');
        return false;
      }

      if (!confirmed) {
        agentLogger.info('ReAct', '用户拒绝执行危险命令: $command');
        final rejectMsg = '\n❌ 用户拒绝执行此命令。\n';
        _accumulatedMessage += rejectMsg;
        onMessage?.call(rejectMsg);
        // 将拒绝信息作为观测反馈给 AI
        final observation = ReActObservation(
          command: command,
          output: '用户拒绝执行此命令',
          success: false,
          error: '用户拒绝',
        );
        _conversationHistory.add(ChatMessage.create(role: 'user', content: observation.format()));
        _trimMessages(_conversationHistory);
        return true; // 继续循环，让 AI 尝试其他方案
      }

      agentLogger.info('ReAct', '用户确认执行危险命令: $command');
      final confirmMsg = '\n✅ 用户已确认，开始执行...\n';
      _accumulatedMessage += confirmMsg;
      onMessage?.call(confirmMsg);
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

    onCommandExecuted?.call(result);

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

    // 向 UI 显示执行结果
    final resultMsg = result.success
        ? '📋 观测: 命令 `$command` 执行成功\n输出:\n$outputText'
        : '📋 观测: 命令 `$command` 执行失败\n错误:\n$errorText';
    _accumulatedMessage += '\n$resultMsg';
    onMessage?.call('\n$resultMsg');

    // 将观测作为 user 消息反馈给 AI（ReAct 核心环节）
    _conversationHistory.add(ChatMessage.create(role: 'user', content: observation.format()));
    _trimMessages(_conversationHistory);

    return true; // 继续循环
  }

  /// 处理多条命令执行（旧格式 fallback）
  Future<bool> _handleExecuteCommands(List<String> commands, CommandExecutor executor) async {
    final resultMessages = <String>[];

    for (final command in commands) {
      if (_currentTask?.status == AgentStatus.cancelled) return false;

      final safetyLevel = SafetyGuard.check(command);

      if (safetyLevel == SafetyLevel.blocked) {
        final msg = '\n\n🚫 命令被安全系统拦截: $command\n';
        _accumulatedMessage += msg;
        onMessage?.call(msg);
        resultMessages.add('🚫 命令被安全系统拦截: $command');
        continue;
      }

      if (safetyLevel == SafetyLevel.warn) {
        _pendingConfirmCommand = command;
        _confirmCompleter = Completer<bool>();
        final msg = '\n\n⚠️ 高风险命令需要确认: `$command`\n${SafetyGuard.getTip(safetyLevel)}\n请点击下方按钮确认或拒绝。\n';
        _accumulatedMessage += msg;
        onMessage?.call(msg);

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
          final rejectMsg = '\n❌ 用户拒绝执行此命令。\n';
          _accumulatedMessage += rejectMsg;
          onMessage?.call(rejectMsg);
          resultMessages.add('❌ 用户拒绝执行: $command');
          continue;
        }

        final confirmMsg = '\n✅ 用户已确认，开始执行...\n';
        _accumulatedMessage += confirmMsg;
        onMessage?.call(confirmMsg);
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

      final resultMsg = result.success
          ? '📋 观测: 命令 `$command` 执行成功\n输出:\n$outputText'
          : '📋 观测: 命令 `$command` 执行失败\n错误:\n$errorText';
      _accumulatedMessage += '\n$resultMsg';
      onMessage?.call('\n$resultMsg');
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
    final choiceMsg = '\n\n👉 你选择了: $choice\n';
    _accumulatedMessage += choiceMsg;
    onMessage?.call(choiceMsg);

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
      _accumulatedMessage += '\n\n⏳ 继续执行...\n';
      onMessage?.call('\n\n⏳ 继续执行...\n');
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

    try {
      final completer = Completer<String>();
      String stdoutData = '';
      StreamSubscription<String>? sub;

      // 监听输出流（PTY 流永不关闭，依赖超时）
      sub = executor.output.listen(
        (data) => stdoutData += data,
        onDone: () {
          if (!completer.isCompleted) completer.complete(stdoutData);
        },
      );

      // 写入命令 + 回车
      executor.execute(command);

      // 等待输出或超时（PTY 命令默认 30 秒超时）
      stdoutData = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          return stdoutData;
        },
      );

      // 始终取消订阅，防止泄漏
      await sub.cancel();

      stopwatch.stop();

      // 清理 ANSI 转义序列，避免在消息气泡中显示乱码
      final cleanOutput = AnsiStripper.strip(stdoutData);

      return AgentResult.fromCommand(
        command: command,
        stdout: cleanOutput,
        stderr: '',
        exitCode: 0,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return AgentResult(
        success: false,
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
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

  /// 从 AI 响应中提取 :::choose A|B|C::: 选项
  List<String> _extractOptions(String content) {
    final regex = RegExp(r':::choose\s+(.+?):::');
    final match = regex.firstMatch(content);
    if (match == null) return [];
    final optionsStr = match.group(1);
    if (optionsStr == null) return [];
    return optionsStr
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
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
    } catch (_) {}
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
    } catch (_) {
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
        _memory.rememberSystemInfo('已收集 $cat 信息', category: cat);
      }
    } catch (_) {}
  }
}
