import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
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

/// O2 观测分级截断端到端测试（R9）
///
/// 真实链路：模型响应文本 → 解析出命令 → mock 执行器返回长输出 →
/// 引擎观测组装（分级截断）→ result 事件 / 下一轮 AI 历史。
/// 单测截断纯函数不够 —— 这里验证成功/失败/查询三条路径在引擎里的实际接线。
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

  const finishTurn =
      '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

  test('非查询失败：观测保留报错头部与尾部，中间标注省略', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([
      '思考: 开始构建\n动作: execute\n命令: echo build-start\n',
    ]);
    provider.enqueueStream([finishTurn]);

    // 真实执行器契约（事实 A）：stderr 恒空，报错全在 stdout
    final stderr = 'HEAD_ERR_MARKER: recipe failed at step 1\n'
        '${'m' * 20000}\n'
        'TAIL_ERR_MARKER: make aborted';
    final executor = _MockExecutor()
      ..exitCode = 1
      ..stdout = stderr;

    final engine = makeEngine(provider);
    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    await engine.startTask('构建项目', executor);

    final result = events.firstWhere(
      (e) => e.isResult && e.toolName == 'exec_command',
    );
    expect(result.success, isFalse);
    expect(result.error, contains('HEAD_ERR_MARKER'),
        reason: '失败观测必须保留报错头部，否则模型只能瞎猜重试');
    expect(result.error, contains('TAIL_ERR_MARKER'));
    expect(result.error, contains('中间省略'));
    expect(result.outputTotalChars, stderr.length);
    expect(result.outputTruncated, isTrue);

    // 下一轮 AI 请求的历史里带上了失败观测（尾部必然可见；
    // 注意：历史单条消息另有 4000 字符尾保留裁剪，属既有全局策略）
    final observationMsg = provider.receivedHistories.last
        .firstWhere((m) => m.content.contains('TAIL_ERR_MARKER'));
    expect(observationMsg.content, contains('TAIL_ERR_MARKER'));
  });

  test('非查询成功：只保留尾 2000 字符，头部丢弃', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([
      '思考: 执行\n动作: execute\n命令: echo hi\n',
    ]);
    provider.enqueueStream([finishTurn]);

    final stdout = 'HEAD_OK_MARKER\n${'n' * 5000}\nTAIL_OK_MARKER';
    final executor = _MockExecutor()..stdout = stdout;

    final engine = makeEngine(provider);
    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    await engine.startTask('输出测试', executor);

    final result = events.firstWhere(
      (e) => e.isResult && e.toolName == 'exec_command',
    );
    expect(result.success, isTrue);
    expect(result.output, contains('TAIL_OK_MARKER'));
    expect(result.output, isNot(contains('HEAD_OK_MARKER')));
    expect(result.output, contains('输出过长'));
    expect(result.outputTruncated, isTrue);
    // 证据层 outputTail 保留原始输出（≤8000 全量）
    expect(result.outputTail, stdout);
  });

  test('查询命令：尾 20000 字符规则不变', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([
      '思考: 看日志\n动作: execute\n命令: cat /var/log/big.log\n',
    ]);
    provider.enqueueStream([finishTurn]);

    final stdout = 'HEAD_Q_MARKER${'q' * 25000}TAIL_Q_MARKER';
    final executor = _MockExecutor()..stdout = stdout;

    final engine = makeEngine(provider);
    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    await engine.startTask('查日志', executor);

    final result = events.firstWhere(
      (e) => e.isResult && e.toolName == 'exec_command',
    );
    expect(result.success, isTrue);
    expect(result.output, contains('TAIL_Q_MARKER'));
    expect(result.output, isNot(contains('HEAD_Q_MARKER')));
    expect(result.output,
        contains('已截断前 ${stdout.length - 20000} 字符'));
  });

  test('短失败输出不截断，头尾完整', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([
      '思考: 执行\n动作: execute\n命令: echo hi\n',
    ]);
    provider.enqueueStream([finishTurn]);

    const stderr = 'permission denied\nplease use sudo';
    final executor = _MockExecutor()
      ..exitCode = 1
      ..stdout = stderr;

    final engine = makeEngine(provider);
    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    await engine.startTask('短输出测试', executor);

    final result = events.firstWhere(
      (e) => e.isResult && e.toolName == 'exec_command',
    );
    expect(result.error, contains('permission denied'));
    expect(result.error, contains('please use sudo'));
    expect(result.error, isNot(contains('中间省略')));
    expect(result.outputTruncated, isFalse);
  });
}

class _MockExecutor implements CommandExecutor {
  String stdout = '';
  String stderr = '';
  int exitCode = 0;

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
  }) async =>
      CommandResult(
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        duration: Duration.zero,
      );

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