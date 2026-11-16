import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/safety_guard.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/utils/command_heuristics.dart';
import 'package:ai_terminal/utils/react_stream_parser.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';

/// WP1（O1）：只读管道/链式命令放开 + 修改类链接硬拦截
/// 覆盖：安全分级拆分、heuristics 组合判定、ReAct 解析 e2e、引擎 guard 拦截路径。

/// 记录实际执行命令的 Mock 执行器（模式参照 agent_engine_resilience_test.dart）
class _RecordingExecutor implements CommandExecutor {
  final List<String> executedCommands = [];
  String stdout = '';

  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async {
    executedCommands.add(command);
    return CommandResult(
      stdout: stdout,
      stderr: '',
      exitCode: 0,
      duration: Duration.zero,
    );
  }

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 5)}) async =>
      '';

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async {
    return CommandResult(
      stdout: '',
      stderr: 'mock 不支持 PTY 写文件',
      exitCode: -1,
      duration: Duration.zero,
      failureKind: CommandFailureKind.unknown,
    );
  }

  @override
  void writeToTerminal(String data) {}
}

/// 伪装成本地 Windows 终端（PowerShell 5.1）的执行器：
/// 只用于触发引擎 guard 的类型判定分支，不启动真实 PTY。
class _FakeWindowsLocalExecutor extends LocalTerminalService {
  final List<String> executedCommands = [];

  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 5)}) async =>
      '';

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async {
    executedCommands.add(command);
    return CommandResult(
      stdout: '',
      stderr: '',
      exitCode: 0,
      duration: Duration.zero,
    );
  }
}

class _MockAIProvider implements AIProvider {
  int callCount = 0;
  final List<List<String>> _responses = [];
  List<List<ChatMessage>> receivedHistories = [];

  void enqueueStream(List<String> chunks) => _responses.add(chunks);

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
  }) async {
    callCount++;
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      throw StateError('No enqueued response. callCount=$callCount');
    }
    final chunks = _responses.removeAt(0);
    return (() async* {
      for (final c in chunks) {
        yield c;
      }
    })();
  }
}

AIModelConfig _makeConfig() => AIModelConfig.create(
      id: 'test',
      provider: 'openai',
      name: 'Test Model',
      apiKey: 'test-key',
      baseUrl: 'https://test.example.com/v1',
      modelName: 'test-model',
      maxTokens: 4096,
    );

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('SafetyGuard 组合命令分级', () {
    test('ps aux | grep nginx 返回 safe', () {
      expect(SafetyGuard.check('ps aux | grep nginx'), SafetyLevel.safe);
    });

    test('grep -n "error" app.log | tail -50 返回 safe', () {
      expect(
        SafetyGuard.check('grep -n "error" app.log | tail -50'),
        SafetyLevel.safe,
      );
    });

    test('df -h && free -m 返回 safe', () {
      expect(SafetyGuard.check('df -h && free -m'), SafetyLevel.safe);
    });

    test('cat a && rm b 等级 ≥ warn', () {
      final level = SafetyGuard.check('cat a && rm b');
      expect(level.index, greaterThanOrEqualTo(SafetyLevel.warn.index));
    });

    test('cat a && sudo apt install nginx 等级 ≥ warn', () {
      final level = SafetyGuard.check('cat a && sudo apt install nginx');
      expect(level.index, greaterThanOrEqualTo(SafetyLevel.warn.index));
    });

    test('引号内的修改命令不被误判为子命令', () {
      expect(SafetyGuard.check('echo "rm x"'), SafetyLevel.safe);
    });
  });

  group('splitSubCommands 引号/heredoc 感知拆分', () {
    List<String> nonEmpty(String cmd) => SafetyGuard.splitSubCommands(cmd)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    test('管道拆成两条子命令', () {
      expect(nonEmpty('ps aux | grep nginx'), ['ps aux', 'grep nginx']);
    });

    test('&& 与 ; 拆分', () {
      expect(nonEmpty('df -h && free -m'), ['df -h', 'free -m']);
      expect(nonEmpty('ls; pwd'), ['ls', 'pwd']);
    });

    test('双引号内的 | 不被误拆', () {
      expect(nonEmpty('grep "a|b" file'), ['grep "a|b" file']);
    });

    test('单引号内的 && 不被误拆', () {
      expect(nonEmpty("echo 'x && y'"), ["echo 'x && y'"]);
    });

    test('反斜杠转义的 | 不被误拆', () {
      expect(nonEmpty(r'grep a\|b file'), [r'grep a\|b file']);
    });

    test('2>&1 重定向不被拆分', () {
      expect(nonEmpty('ls 2>&1'), ['ls 2>&1']);
    });

    test('heredoc 内容保持整体（内容行不是子命令）', () {
      const cmd = "cat > /tmp/a.sh << 'EOF'\nrm -rf /tmp/x\nEOF";
      expect(nonEmpty(cmd), [cmd]);
    });

    test('heredoc 结束后的命令独立成段', () {
      expect(nonEmpty('cat <<EOF\nhi\nEOF\nls'), [
        'cat <<EOF\nhi\nEOF',
        'ls',
      ]);
    });

    test('containsUnquotedOperator 识别引号外的 &&', () {
      expect(SafetyGuard.containsUnquotedOperator('a && b', '&&'), isTrue);
      expect(
          SafetyGuard.containsUnquotedOperator('echo "a && b"', '&&'), isFalse);
      expect(
          SafetyGuard.containsUnquotedOperator(r'a \&\& b', '&&'), isFalse);
    });
  });

  group('command_heuristics 组合命令', () {
    test('只读管道：所有子命令均为查询 → true', () {
      expect(isQueryCommand('ps aux | grep nginx'), isTrue);
      expect(isQueryCommand('grep -n "error" app.log | tail -50'), isTrue);
      expect(isQueryCommand('df -h && free -m'), isTrue);
    });

    test('含修改子命令 → false', () {
      expect(isQueryCommand('cat a && rm b'), isFalse);
      expect(isQueryCommand('ls | sudo apt install nginx'), isFalse);
    });

    test('含交互式子命令 → false', () {
      expect(isQueryCommand('ls | top'), isFalse);
      expect(isQueryCommand('cat a | tail -f x'), isFalse);
    });

    test('单一命令行为不变', () {
      expect(isQueryCommand('ls -la'), isTrue);
      expect(isQueryCommand('sudo apt install nginx'), isFalse);
      expect(isQueryCommand('grep "a|b" file'), isTrue);
    });

    test('heredoc 写文件仍按单条命令判定', () {
      expect(
        isQueryCommand("cat > /tmp/a.sh << 'EOF'\nrm x\nEOF"),
        isTrue,
      );
    });

    test('超时取子命令最大档位：ps aux(3min) | grep(60s) → 3min', () {
      expect(
        getCommandTimeout('ps aux | grep nginx'),
        const Duration(minutes: 3),
      );
    });

    test('超时取子命令最大档位：cat(60s) && apt install(10min) → 10min', () {
      expect(
        getCommandTimeout('cat a && apt install b'),
        const Duration(minutes: 10),
      );
    });

    test('全默认档组合仍为 60s', () {
      expect(getCommandTimeout('ls | grep x'), const Duration(seconds: 60));
    });

    test('journalctl | grep | tail → 3min', () {
      expect(
        getCommandTimeout('journalctl -u nginx | grep err | tail -50'),
        const Duration(minutes: 3),
      );
    });

    test('单一命令与 heredoc 超时行为不变', () {
      expect(getCommandTimeout('grep "a|b" file'), const Duration(seconds: 60));
      expect(
        getCommandTimeout('sudo cat > /tmp/a.sh << EOF\necho hi\nEOF'),
        const Duration(seconds: 60),
      );
    });
  });

  group('ReAct 管道命令端到端解析（R9）', () {
    test('含管道的模型响应 → 命令完整提取，不被 | 截断', () {
      const response = '''思考: 需要确认 nginx 进程是否在运行，用管道一次完成过滤
说明: 列出所有进程并过滤出 nginx 相关行，只读取信息，不会修改系统
动作: execute
命令: ps aux | grep nginx | grep -v grep''';

      final events = ReActStreamParser.parse(response);
      final command =
          events.firstWhere((e) => e.type == AgentEventType.command);
      expect(command.command, 'ps aux | grep nginx | grep -v grep');
      expect(command.description, '列出所有进程并过滤出 nginx 相关行，只读取信息，不会修改系统');
    });

    test('流式分块在管道符处切断 → 拼接后仍完整解析', () {
      const chunks = [
        '思考: 过滤进程\n说明: 只读过滤\n动作: execute\n命令: ps aux ',
        '| grep nginx | grep',
        ' -v grep\n',
      ];
      final full = chunks.join();
      final events = ReActStreamParser.parse(full);
      final command =
          events.firstWhere((e) => e.type == AgentEventType.command);
      expect(command.command, 'ps aux | grep nginx | grep -v grep');
    });

    test('链式只读命令完整提取', () {
      const response = '思考: 查看磁盘与内存\n动作: execute\n命令: df -h && free -m';
      final events = ReActStreamParser.parse(response);
      final command =
          events.firstWhere((e) => e.type == AgentEventType.command);
      expect(command.command, 'df -h && free -m');
    });
  });

  group('引擎 chain guard 拦截路径', () {
    const finishTurn =
        '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

    AgentEngine makeEngine(_MockAIProvider provider) => AgentEngine(
          aiProvider: provider,
          modelConfig: _makeConfig(),
          memory: AgentMemory(),
          maxSteps: 5,
          hostId: 'test-host',
        );

    test('全自动档：链式修改命令被硬拦截，观测回传指导拆分', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 查看并清理\n动作: execute\n命令: cat a && rm b\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _RecordingExecutor();

      await engine.startTask('查看并清理', executor);

      expect(executor.executedCommands, isEmpty,
          reason: '全自动档也不能执行链式修改命令（硬保证，不依赖权限门控）');
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('链式命令包含修改类操作')),
        isTrue,
      );
      expect(provider.receivedHistories[1].last.content,
          contains('链式命令包含修改类操作，请拆分为多轮逐条执行'),
          reason: '拦截必须以失败观测回传给模型，而不是静默丢弃');
      expect(engine.currentTask?.status, AgentStatus.completed,
          reason: '拦截分支 shouldContinue=true，模型收到观测后可正常 finish');
    });

    test('询问档：链式修改命令不进入确认流程，直接拦截', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 查看并清理\n动作: execute\n命令: cat a && rm b\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.ask);
      final executor = _RecordingExecutor();

      await engine.startTask('查看并清理', executor);

      expect(engine.hasPendingConfirm, isFalse);
      expect(executor.executedCommands, isEmpty);
    });

    test('链式 blocked 命令同样被拦截', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 危险操作\n动作: execute\n命令: ls && rm -rf /\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final executor = _RecordingExecutor();

      await engine.startTask('危险操作', executor);

      expect(executor.executedCommands, isEmpty);
    });

    test('只读管道命令正常执行（e2e：解析 → guard 放行 → 执行）', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 需要确认 nginx 进程\n说明: 只读过滤进程列表\n动作: execute\n'
            '命令: ps aux | grep nginx | grep -v grep\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _RecordingExecutor()..stdout = 'nginx: master process';

      await engine.startTask('检查 nginx', executor);

      expect(executor.executedCommands, ['ps aux | grep nginx | grep -v grep'],
          reason: '管道命令必须原样完整执行，不能被拆分或截断');
      expect(
        events.where((e) => e.isResult && e.success == true),
        isNotEmpty,
      );
    });

    test('只读链式命令正常执行', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 查看磁盘与内存\n动作: execute\n命令: df -h && free -m\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final executor = _RecordingExecutor();

      await engine.startTask('查看资源', executor);

      expect(executor.executedCommands, ['df -h && free -m']);
    });

    test('单条修改命令不受 chain guard 影响（权限门控行为不变）', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 清理临时文件\n动作: execute\n命令: rm /tmp/foo.txt\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final executor = _RecordingExecutor();

      await engine.startTask('清理临时文件', executor);

      expect(executor.executedCommands, ['rm /tmp/foo.txt']);
    });

    test('Windows PowerShell 5.1：含 && 的命令回传改用 ; 的观测', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 查看进程\n动作: execute\n命令: ps aux && grep nginx\n',
      ]);
      provider.enqueueStream([finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.fullAuto);
      final executor = _FakeWindowsLocalExecutor();

      await engine.startTask('查看进程', executor);

      expect(executor.executedCommands, isEmpty);
      expect(provider.receivedHistories[1].last.content, contains('不支持 &&'));
      expect(provider.receivedHistories[1].last.content, contains(';'));
    }, skip: !Platform.isWindows ? '仅 Windows 本地终端分支' : null);
  });
}