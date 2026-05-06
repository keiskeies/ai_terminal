import 'dart:async';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/agent_model.dart';
import '../models/agent_memory.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../services/ai_service.dart';
import '../services/ssh_service.dart';
import '../services/command_executor.dart';
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
  AgentMode _mode = AgentMode.assistant;
  String _accumulatedMessage = '';  // 跟踪累积的消息
  Completer<bool>? _confirmCompleter; // 等待用户确认危险命令的 Completer
  String? _pendingConfirmCommand; // 当前等待确认的命令

  void Function(String)? onThinking;
  void Function(String)? onCommandGenerated;
  void Function(AgentResult)? onCommandExecuted;
  void Function(String)? onError;
  void Function(AgentTask)? onTaskUpdated;
  void Function(String)? onMessage;
  void Function(String)? onCompleted;

  int maxSteps = 10;

  AgentEngine({
    required AIProvider aiProvider,
    required AIModelConfig modelConfig,
    required AgentMemory memory,
    this.maxSteps = 10,
  })  : _aiProvider = aiProvider,
        _modelConfig = modelConfig,
        _memory = memory;

  AgentMode get mode => _mode;
  AgentTask? get currentTask => _currentTask;
  bool get isRunning =>
      _currentTask?.status == AgentStatus.thinking ||
      _currentTask?.status == AgentStatus.executing;
  bool get hasPendingConfirm => _confirmCompleter != null && !_confirmCompleter!.isCompleted;
  String? get pendingConfirmCommand => _pendingConfirmCommand;

  void setMode(AgentMode mode) => _mode = mode;

  /// 启动 Agent 任务
  /// [goal] 用户目标
  /// [executor] 命令执行器，支持 SSHService（远程）或 LocalTerminalService（本地）
  Future<void> startTask(String goal, CommandExecutor? executor) async {
    agentLogger.info('AgentEngine', '=== 开始任务 ===');
    agentLogger.info('AgentEngine', '目标: $goal');
    agentLogger.info('AgentEngine', '模式: $_mode');
    agentLogger.info('AgentEngine', '执行器: ${executor != null ? (executor.isConnected ? "已连接" : "未连接") : "无"}');
    _accumulatedMessage = '';  // 重置累积消息

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

    try {
      if (_mode == AgentMode.automatic) {
        agentLogger.info('AgentEngine', '执行自动模式');
        await _executeAutomatic(goal, executor);
      } else {
        agentLogger.info('AgentEngine', '执行辅助模式');
        await _executeAssistant(goal, executor);
      }
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '执行异常: $e\n$stack');
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.failed,
        completedAt: DateTime.now(),
      );
      onError?.call('执行出错: $e');
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

  Future<void> _executeAssistant(String goal, CommandExecutor? executor) async {
    final systemPrompt = _buildSystemPrompt(executor, autoExecute: false);
    final messages = <ChatMessage>[];

    onMessage?.call('🤔 正在分析你的需求...\n');

    String fullResponse = '';
    final stream = await _aiProvider.chatStream(
      history: messages,
      prompt: goal,
      config: _modelConfig,
      systemPrompt: systemPrompt,
    );

    await for (final chunk in stream) {
      fullResponse += chunk;
      _accumulatedMessage += chunk;
      onMessage?.call(chunk);
    }

    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.waitingConfirm,
      currentStep: '等待用户确认命令',
    );
    onTaskUpdated?.call(_currentTask!);
  }

  Future<void> _executeAutomatic(String goal, CommandExecutor? executor) async {
    agentLogger.info('AutoExec', '=== 开始自动执行 ===');

    if (executor == null || !executor.isConnected) {
      final type = executor == null ? '无执行器' : '未连接';
      agentLogger.error('AutoExec', '$type!');
      onError?.call('需要连接到终端才能使用自动模式');
      return;
    }

    agentLogger.info('AutoExec', '执行器连接状态: ${executor.isConnected}');

    final maxSteps = this.maxSteps;
    var stepCount = 0;

    _accumulatedMessage = '🚀 开始自动执行任务...\n\n';
    onMessage?.call('🚀 开始自动执行任务...\n\n');

    final messages = <ChatMessage>[];
    messages.add(ChatMessage.create(
      role: 'system',
      content: _buildSystemPrompt(executor, autoExecute: true),
    ));
    messages.add(ChatMessage.create(
      role: 'user',
      content: '任务: $goal\n\n请分析任务并开始执行。',
    ));

    final memoryContext = _memory.buildContext();
    if (memoryContext.isNotEmpty) {
      messages.add(ChatMessage.create(role: 'user', content: '\n$memoryContext\n'));
      agentLogger.info('AutoExec', '添加记忆上下文: ${memoryContext.length} 字符');
    }

    agentLogger.info('AutoExec', '开始执行循环 (最多 $maxSteps 步)');

    while (stepCount < maxSteps) {
      stepCount++;
      agentLogger.info('AutoExec', '--- 步骤 $stepCount ---');

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中... (第 $stepCount 步)',
      );
      onTaskUpdated?.call(_currentTask!);
      onThinking?.call('🤔 正在思考下一步...');

      String fullResponse = '';
      agentLogger.info('AutoExec', '调用 AI 模型...');
      agentLogger.debug('AutoExec', '消息历史: ${messages.length} 条');

      try {
        final stream = await _aiProvider.chatStream(
          history: messages,
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
        agentLogger.info('AutoExec', 'AI响应完成，共 $chunkCount 个数据块');
        agentLogger.debug('AutoExec', '响应长度: ${fullResponse.length} 字符');

        final command = _extractCommand(fullResponse);
        agentLogger.info('AutoExec', '提取命令: ${command != null ? "找到" : "未找到"}');

        if (command != null) {
          agentLogger.info('AutoExec', '提取的命令: $command');
        } else {
          agentLogger.info('AutoExec', 'AI完整响应:\n$fullResponse');
        }

        if (command == null) {
          if (_isTaskComplete(fullResponse)) {
            agentLogger.info('AutoExec', '任务完成 (检测到完成关键词)');
            _currentTask = _currentTask!.copyWith(
              status: AgentStatus.completed,
              completedAt: DateTime.now(),
            );
            onTaskUpdated?.call(_currentTask!);
            return;
          }
          // 没有命令也没有完成关键词：AI 可能是纯文字回答（问答类任务）
          // 直接视为任务完成，不再强制 AI 继续执行命令
          agentLogger.info('AutoExec', 'AI未生成命令，视为任务完成（纯问答或已回答）');
          _currentTask = _currentTask!.copyWith(
            status: AgentStatus.completed,
            completedAt: DateTime.now(),
          );
          onTaskUpdated?.call(_currentTask!);
          return;
        }

        final safetyLevel = SafetyGuard.check(command);
        agentLogger.info('AutoExec', '安全检查结果: $safetyLevel');

        if (safetyLevel == SafetyLevel.blocked) {
          agentLogger.warn('AutoExec', '命令被安全系统拦截: $command');
          final msg = '\n\n🚫 命令被安全系统拦截: $command\n';
          _accumulatedMessage += msg;
          onMessage?.call(msg);
          messages.add(ChatMessage.create(role: 'assistant', content: fullResponse));
          messages.add(ChatMessage.create(
            role: 'user',
            content: '该命令被安全系统拦截，请换一个方法。',
          ));
          continue;
        }

        // warn 级别的命令（安装/升级/替换/修改环境等）在自动模式下暂停，等待用户确认
        if (safetyLevel == SafetyLevel.warn) {
          agentLogger.warn('AutoExec', '高风险命令需要确认: $command');

          // 设置等待确认状态，UI 会显示确认/拒绝按钮
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
            agentLogger.info('AutoExec', '任务在等待确认期间被取消');
            return;
          }

          if (confirmed) {
            // 用户确认执行
            agentLogger.info('AutoExec', '用户确认执行危险命令: $command');
            final confirmMsg = '\n✅ 用户已确认，开始执行...\n';
            _accumulatedMessage += confirmMsg;
            onMessage?.call(confirmMsg);
            // 不 continue，继续往下执行命令
          } else {
            // 用户拒绝执行
            agentLogger.info('AutoExec', '用户拒绝执行危险命令: $command');
            final rejectMsg = '\n❌ 用户拒绝执行此命令。\n';
            _accumulatedMessage += rejectMsg;
            onMessage?.call(rejectMsg);
            messages.add(ChatMessage.create(role: 'assistant', content: fullResponse));
            messages.add(ChatMessage.create(
              role: 'user',
              content: '用户拒绝执行上述命令。请换一个不需要修改系统的方法，或者仅用只读命令收集信息。如果任务无法在不修改系统的前提下完成，请说明情况并结束任务。',
            ));
            continue;
          }
        }

        _currentTask = _currentTask!.copyWith(
          status: AgentStatus.executing,
          currentStep: command,
        );
        onTaskUpdated?.call(_currentTask!);
        onCommandGenerated?.call(command);

        if (safetyLevel == SafetyLevel.info) {
          agentLogger.info('AutoExec', '低风险操作提示: $command');
        }

        agentLogger.info('AutoExec', '执行命令: $command');
        final result = await _executeCommand(executor, command);
        agentLogger.info('AutoExec', '命令执行结果: success=${result.success}');
        agentLogger.debug('AutoExec', '输出: ${result.output ?? "无"}');
        agentLogger.debug('AutoExec', '错误: ${result.error ?? "无"}');

        onCommandExecuted?.call(result);

        await _memory.rememberCommand(command);
        await _memory.rememberResult(
          command,
          result.output ?? result.error ?? '',
          success: result.success,
        );

        messages.add(ChatMessage.create(role: 'assistant', content: fullResponse));

        final resultMsg = result.success
            ? '✅ 命令执行成功\n结果: ${_truncateOutput(result.output)}'
            : '❌ 命令执行失败\n错误: ${_truncateOutput(result.error)}';

        messages.add(ChatMessage.create(role: 'user', content: resultMsg));

        // 累积到 UI 显示消息
        _accumulatedMessage += '\n$resultMsg';
        onMessage?.call('\n$resultMsg');

        if (_currentTask?.status == AgentStatus.cancelled) {
          agentLogger.info('AutoExec', '任务被取消');
          return;
        }
      } catch (e, stack) {
        agentLogger.error('AutoExec', '步骤执行异常: $e\n$stack');
        break;
      }
    }

    _currentTask = _currentTask!.copyWith(
      status: stepCount >= maxSteps ? AgentStatus.failed : AgentStatus.completed,
      completedAt: DateTime.now(),
    );
    onTaskUpdated?.call(_currentTask!);
    agentLogger.info('AutoExec', '=== 执行结束 ===');

    if (stepCount >= maxSteps) {
      agentLogger.warn('AutoExec', '达到最大执行步数 $maxSteps');
      final msg = '\n\n⚠️ 达到最大执行步数 ($maxSteps)，任务被中断';
      _accumulatedMessage += msg;
      onMessage?.call(msg);
    } else {
      // 任务正常完成，通知保存消息
      if (_accumulatedMessage.isNotEmpty) {
        onCompleted?.call(_accumulatedMessage);
      }
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
          sub?.cancel();
          return stdoutData;
        },
      );

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

  bool _isTaskComplete(String response) {
    final keywords = [
      '任务完成', '任务已完成', '✅ 任务完成', '✅任务完成',
    ];
    for (final k in keywords) {
      if (response.contains(k)) return true;
    }
    return false;
  }

  String _buildSystemPrompt(CommandExecutor? executor, {required bool autoExecute}) {
    final buffer = StringBuffer();

    buffer.writeln('你是 AI 助手，可以执行命令。');

    if (autoExecute) {
      buffer.writeln('【自动执行模式】');
      buffer.writeln('1. 分析用户需求');
      buffer.writeln('2. 每次只执行一条命令');
      buffer.writeln('3. 分析结果后继续');
      buffer.writeln('4. 完成后说明结果');
      buffer.writeln();
      buffer.writeln(prompts.agentAutoRule);
    } else {
      buffer.writeln('【辅助模式】');
      buffer.writeln('生成命令供用户确认执行。');
    }

    buffer.writeln();
    buffer.writeln(prompts.commandFormatRule);
    buffer.writeln();
    buffer.writeln(prompts.behaviorBoundaryRule);

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

  /// 截断命令输出，保留尾部（长输出有价值的信息通常在末尾，如 "Complete!"）
  /// 最多保留 [maxLines] 行，或 [maxChars] 字符
  String _truncateOutput(String? output, {int maxLines = 30, int maxChars = 2000}) {
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
            sub?.cancel();
            return output;
          },
        );

        final clean = AnsiStripper.strip(output);
        await _memory.rememberSystemInfo('已收集 $cat 信息', category: cat);
      }
    } catch (_) {}
  }
}
