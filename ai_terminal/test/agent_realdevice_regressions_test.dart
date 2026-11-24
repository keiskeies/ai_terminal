import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';
import 'package:dio/dio.dart';

/// 2026-11-17 真机验证发现的执行链路缺陷回归测试。
///
/// 三个缺陷（均在 demo server 真机复现）：
/// 1. finish/ask 轮次正文里的代码围栏被解析成 command 并送进 PTY
///    （把 sshd_config 内容当命令执行，终端出现 `-bash: L1: command not found`）。
/// 2. 该提前执行在任务已 finish 后仍把状态改回 executing，
///    UI 永久停在「运行中」，补充指令永远等不到下一轮循环边界。
/// 3. 交互输入弹窗关闭时立即 dispose TextEditingController，
///    关闭动画期间 TextField 仍 build → Flutter 断言红屏（UI 修复见 terminal_page）。

class _RecordingExecutor implements CommandExecutor {
  final List<String> executed = [];

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
    executed.add(command);
    return CommandResult(
      stdout: 'ok',
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
      failureReason: 'mock 不支持 PTY 写文件',
    );
  }

  @override
  void writeToTerminal(String data) {}
}

class _ScriptedProvider implements AIProvider {
  final List<List<String>> _responses = [];
  final List<List<ChatMessage>> receivedHistories = [];

  void enqueue(List<String> chunks) => _responses.add(chunks);

  /// 直接返回一份整包响应，并把这份响应打包成单块流
  void enqueueText(String text) => _responses.add([text]);

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
    void Function(List<ToolCall> calls)? onToolCalls,
  }) async {
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      throw StateError('未排队的响应，调用次数=${receivedHistories.length}');
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
      contextWindow: 0,
    );

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  AgentEngine makeEngine(_ScriptedProvider provider) => AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 8,
        hostId: 'test-host',
      );

  Future<void> waitUntil(bool Function() condition,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('finish/ask 正文围栏不得当作命令执行', () {
    test('finish 轮里引用文件内容的围栏不进执行器，也不产出 command 事件', () async {
      final provider = _ScriptedProvider();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      provider.enqueueText('思考: 先看一下 sshd 配置\n');
      provider
          .enqueueText('动作: execute\n命令: cat /etc/ssh/sshd_config | head -3\n');
      // 真机复现形状：工具观测回传后，模型在 finish 正文里贴回带行号的围栏
      provider.enqueueText(
        '前 3 行都是注释，尚未出现生效配置。\n'
        '```\n'
        'L1: #  \$OpenBSD: sshd_config,v 1.103 2018-04-09\n'
        'L2: #  This is the sshd server system-wide configuration file.\n'
        'L3: #  sshd_config(5) for more information.\n'
        '```\n'
        '动作: finish\n回答: 已按要求读取前 3 行。\n',
      );

      final executor = _RecordingExecutor();
      await engine.startTask('读 sshd 配置前 3 行', executor);

      expect(executor.executed, ['cat /etc/ssh/sshd_config | head -3'],
          reason: 'finish 正文里的围栏是引用内容，绝不能作为命令执行');

      final commandEvents = events.where((e) => e.isCommand).toList();
      expect(commandEvents.length, 1, reason: '只有 execute 轮的命令能产出 command 事件');
      expect(commandEvents.single.command, contains('sshd_config'));
    });

    test('思考里的示例围栏排在 execute 之前时也不执行', () async {
      final provider = _ScriptedProvider();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      // 流式提前检测会在动作行到达前先看到这段示例围栏
      provider.enqueueText(
        '思考: 我要查端口，写法类似：\n'
        '```\n'
        'echo this-is-only-an-example\n'
        '```\n'
        '动作: execute\n'
        '命令: grep -n Port /etc/ssh/sshd_config\n',
      );
      provider.enqueueText('动作: finish\n回答: 端口为 22。\n');

      final executor = _RecordingExecutor();
      await engine.startTask('查端口', executor);

      expect(executor.executed, ['grep -n Port /etc/ssh/sshd_config'],
          reason: '只有动作行之后的命令才进入执行器');
      final commandEvents = events.where((e) => e.isCommand).toList();
      expect(commandEvents.length, 1);
      expect(commandEvents.single.command, isNot(contains('example')));
    });

    test('ask 轮正文围栏同样不执行', () async {
      final provider = _ScriptedProvider();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      provider
          .enqueueText('动作: execute\n命令: grep -n Port /etc/ssh/sshd_config\n');
      provider.enqueueText(
        '```\n'
        'L17: #Port 22\n'
        'L18: #AddressFamily any\n'
        '```\n'
        '动作: ask\n'
        '要不要把 Port 改成 2222？\n'
        '选项: 改成 2222 | 保持 22\n',
      );
      provider.enqueueText('动作: finish\n回答: 保持 22，不做改动。\n');

      final executor = _RecordingExecutor();
      final running = engine.startTask('确认端口改动', executor);
      await waitUntil(() => engine.hasPendingChoice);

      expect(executor.executed, ['grep -n Port /etc/ssh/sshd_config'],
          reason: 'ask 轮的围栏内容不能进执行器');

      engine.selectChoice('保持 22');
      await running;

      expect(executor.executed, ['grep -n Port /etc/ssh/sshd_config']);
      expect(events.where((e) => e.isCommand).length, 1);
    });
  });

  group('终态任务不被提前执行复活', () {
    test('finish 之后到达的提前执行不得把状态改回 executing', () async {
      final provider = _ScriptedProvider();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      provider.enqueueText('动作: execute\n命令: echo first\n');
      provider.enqueueText('动作: finish\n回答: 完成\n');

      final executor = _RecordingExecutor();
      await engine.startTask('单命令任务', executor);

      await waitUntil(() => !engine.isRunning);
      expect(engine.isRunning, isFalse);
      expect(engine.isPaused, isFalse);
      expect(executor.executed, ['echo first']);
    });

    test('已取消任务上调用命令执行直接拒绝，不改状态', () async {
      final provider = _ScriptedProvider();
      final engine = makeEngine(provider);
      provider.enqueueText('动作: execute\n命令: echo long\n');

      final executor = _RecordingExecutor();
      final running = engine.startTask('长任务', executor);
      await waitUntil(() => executor.executed.isNotEmpty);

      engine.cancelTask();
      await running;
      expect(engine.isRunning, isFalse);
    });
  });
}
