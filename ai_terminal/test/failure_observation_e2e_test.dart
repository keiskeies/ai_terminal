import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
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
import 'package:ai_terminal/utils/output_processor.dart'
    show kNoOutputPlaceholder;
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// F1 失败观测重建端到端测试（R9）
///
/// mock 执行器严格按真实契约返回（事实 A：stderr 恒空、报错在 stdout），
/// 验证失败观测把真实报错、退出码、failureKind/failureReason 送达 AI 历史
/// 与结果事件。旧实现观测正文取恒空的 error → AI 看到的失败观测恒为
/// "(无输出)"，这条链路修复前本文件全部用例必须红。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  AgentEngine makeEngine(_MockAIProvider provider) => AgentEngine(
        aiProvider: provider,
        modelConfig: AIModelConfig.create(
          id: 'test',
          provider: 'openai',
          name: 'Test Model',
          apiKey: 'test-key',
          baseUrl: 'https://test.example.com/v1',
          modelName: 'test-model',
          maxTokens: 4096,
          contextWindow: 0,
        ),
        memory: AgentMemory(),
        maxSteps: 5,
      );

  const finishTurn = '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

  /// 从最后一段历史里取引擎写入的观测消息（format() 以「观测: 」开头）。
  /// 不能用「执行失败」等词直接 firstWhere —— 系统提示里也含这些词。
  ChatMessage observationOf(List<ChatMessage> history) => history
      .lastWhere((m) => m.role == 'user' && m.content.startsWith('观测: '));

  Future<({AgentEvent result, List<ChatMessage> obsHistory})> runFailure({
    required String command,
    required _MockExecutor executor,
    List<String> finishTurns = const [finishTurn],
  }) async {
    final provider = _MockAIProvider();
    provider.enqueueStream(['思考: 执行\n动作: execute\n命令: $command\n']);
    for (final turn in finishTurns) {
      provider.enqueueStream([turn]);
    }
    final engine = makeEngine(provider);
    engine.setPermissionMode(AgentPermissionMode.auto);
    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    await engine.startTask('失败观测测试', executor);
    final result = events.firstWhere(
      (e) => e.isResult && e.toolName == 'exec_command',
    );
    // 命令执行后、finish 请求前的最后一段历史携带观测消息
    final obsHistory = provider.receivedHistories.last;
    return (result: result, obsHistory: obsHistory);
  }

  /// 未执行任何命令时 finish 会被幻觉门控拦下两轮，所以被预检拦截的用例
  /// 必须先声明纯问答，才轮到 finish 放行。
  const qaFinishTurn = '思考: 纯问答，无需执行命令\n'
      '结论: 命令被拦下\n现状: 未执行\n变更: 无\n建议: 无\n'
      '动作: finish\n';

  test('退出码 127：观测含真实报错与退出码（修复前恒为 "(无输出)"）', () async {
    final executor = _MockExecutor()
      ..exitCode = 127
      ..stdout = '-bash: foo: command not found';

    final (:result, :obsHistory) =
        await runFailure(command: 'foo --version', executor: executor);

    expect(result.success, isFalse);
    expect(result.error, contains('-bash: foo: command not found'),
        reason: '结果卡展示真实报错，不再显示 "(无输出)"');
    expect(result.exitCode, 127);

    // 先取观测消息再做断言，找不到即 StateError
    final observationMsg = observationOf(obsHistory);
    expect(observationMsg.content, contains('-bash: foo: command not found'));
    expect(observationMsg.content, contains('127'));
    expect(observationMsg.content, isNot(contains('错误:\n(无输出)')));
  });

  test('超时：failureReason 诊断到达观测（事实 B 修复）', () async {
    final executor = _MockExecutor()
      ..exitCode = -1
      ..stdout = 'download 42%...'
      ..timedOut = true
      ..failureKind = 'timeout'
      ..failureReason = '命令执行超时 (60s)';

    final (:result, :obsHistory) =
        await runFailure(command: 'wget http://slow/file', executor: executor);

    expect(result.success, isFalse);
    final observationMsg = observationOf(obsHistory);
    expect(observationMsg.content, contains('失败类型: timeout'));
    expect(observationMsg.content, contains('诊断: 命令执行超时 (60s)'));
    expect(observationMsg.content, contains('download 42%...'),
        reason: '已收到的部分输出也要进观测');
  });

  test('交互提示中断：kind 与提示文本同时到达（sudo provide_password 依据）', () async {
    final executor = _MockExecutor()
      ..exitCode = -1
      ..stdout = 'Reading package lists... Done\n[sudo] password for root: '
      ..failureKind = 'interactivePrompt'
      ..failureReason = '命令进入交互式密码提示，无法在非交互模式完成';

    final run = await runFailure(command: 'apt update', executor: executor);

    final observationMsg = observationOf(run.obsHistory);
    expect(observationMsg.content, contains('失败类型: interactivePrompt'));
    expect(observationMsg.content, contains('password for root'),
        reason: '提示原文经输出段到达，AI 才能按规则走 provide_password');
  });

  test('失败事件 outputTail 取真实 stdout 尾部（5b）', () async {
    final longErr = '${'e' * 12000}\nFATAL_TAIL: build aborted';
    final executor = _MockExecutor()
      ..exitCode = 2
      ..stdout = longErr;

    final run = await runFailure(command: 'make install', executor: executor);

    expect(run.result.outputTail, endsWith('FATAL_TAIL: build aborted'),
        reason: '失败时证据层必须拿到真实报错尾部，而不是恒空的 error');
    expect(run.result.outputTotalChars, longErr.length);
    expect(run.result.outputTruncated, isTrue);
  });

  group('预检拦截的命令：拦截原因不能塌成 "(无输出)"', () {
    test('交互式命令：结果卡正文取 error 里的拦截原因，命令未进执行器', () async {
      final executor = _MockExecutor();

      final (:result, :obsHistory) = await runFailure(
        command: 'top',
        executor: executor,
        finishTurns: const [qaFinishTurn],
      );

      expect(executor.executeAndWaitCalls, 0,
          reason: '预检拦截的命令从未进 shell，执行器一次都不该被调用');
      expect(result.success, isFalse);
      // 修复前：error 与 output 同为占位串，卡片上只写着「(无输出)」
      expect(result.output, kNoOutputPlaceholder,
          reason: 'output 保持占位串：截断徽标与 outputTail 逻辑都以它为准');
      expect(result.error, contains('交互式命令会持续运行不返回'),
          reason: '真实拦截原因必须落在 error，供结果卡与时间线取用');
      expect(result.error, isNot(equals(kNoOutputPlaceholder)));
      expect(result.failureKind, 'syntaxError');

      final observationMsg = observationOf(obsHistory);
      expect(observationMsg.content, contains('检测到交互式命令'),
          reason: 'AI 要拿到改写建议（ps aux 代替 top），否则下一轮还交同一条');
    });

    test('未闭合命令：拦截原因进 error，观测带补全指引', () async {
      final executor = _MockExecutor();

      final (:result, :obsHistory) = await runFailure(
        command: "echo \"未闭合的引号",
        executor: executor,
        finishTurns: const [qaFinishTurn],
      );

      expect(executor.executeAndWaitCalls, 0);
      expect(result.output, kNoOutputPlaceholder);
      expect(result.error, contains('命令未闭合'),
          reason: '未闭合命令的 shell 报错永远不会出现，唯一的原因在这里');

      final observationMsg = observationOf(obsHistory);
      expect(observationMsg.content, contains('命令未闭合'));
      expect(observationMsg.content, contains('引号/圆括号必须成对'));
    }, skip: Platform.isWindows
        ? '闭合预检按 POSIX 规则判定，Windows 本地 shell 直接放行'
        : false);
  });

  group('ReActObservation.format() 四形态', () {
    test('成功：不变', () {
      const o = ReActObservation(command: 'ls', output: 'file1');
      expect(o.format(), startsWith('观测: 命令 `ls` 执行成功'));
      expect(o.format(), contains('file1'));
    });

    test('失败：标题带退出码 + 输出段带真实报错', () {
      const o = ReActObservation(
        command: 'foo',
        output: 'boom',
        success: false,
        exitCode: 127,
      );
      final t = o.format();
      expect(t, contains('执行失败 (退出码: 127)'));
      expect(t, contains('输出:\nboom'));
      expect(t, isNot(contains('(无输出)')));
    });

    test('失败带诊断：失败类型/诊断行', () {
      const o = ReActObservation(
        command: 'sleep 999',
        output: '(无输出)',
        success: false,
        exitCode: -1,
        failureKind: 'timeout',
        failureReason: '命令执行超时 (5s)',
      );
      final t = o.format();
      expect(t, contains('失败类型: timeout · 诊断: 命令执行超时 (5s)'));
      expect(t, contains('(无输出)'));
    });

    test('失败双空：只输出 (无输出)', () {
      const o = ReActObservation(command: 'true', output: '', success: false);
      final t = o.format();
      expect(t, contains('执行失败'));
      expect(t, contains('(无输出)'));
      expect(t, isNot(contains('输出:')));
    });
  });
}

class _MockExecutor implements CommandExecutor {
  String stdout = '';
  int exitCode = 0;
  bool timedOut = false;
  String? failureKind;
  String? failureReason;

  /// 真正下发到 shell 的次数（预检拦截的命令必须保持 0）
  int executeAndWaitCalls = 0;

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
    executeAndWaitCalls++;
    return CommandResult(
      stdout: stdout,
      // 真实执行器契约：stderr 恒空
      stderr: '',
      exitCode: exitCode,
      duration: Duration.zero,
      timedOut: timedOut,
      failureKind: failureKind == null
          ? CommandFailureKind.none
          : CommandFailureKind.values.firstWhere((k) => k.name == failureKind),
      failureReason: failureReason,
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
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );

  @override
  void writeToTerminal(String data) {}
}

class _MockAIProvider implements AIProvider {
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
    void Function(List<ToolCall> calls)? onToolCalls,
  }) async {
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      throw StateError('No enqueued response');
    }
    final chunks = _responses.removeAt(0);
    return (() async* {
      for (final c in chunks) {
        yield c;
      }
    })();
  }
}
