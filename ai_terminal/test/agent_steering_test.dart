import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// O5 steering（运行中用户补充指令）引擎单测。
/// 模式参照 agent_engine_resilience_test.dart：Mock executor + Mock AI provider，
/// 用 ask/确认等待把循环停在 await 上，验证队列在下一轮循环边界注入。

class _MockExecutor implements CommandExecutor {
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

class _MockAIProvider implements AIProvider {
  int callCount = 0;
  final List<Object> _responses = [];
  final List<List<ChatMessage>> receivedHistories = [];

  void enqueueStream(List<String> chunks) => _responses.add(chunks);

  void enqueueHangingStream() => _responses.add('HANG');

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
    callCount++;
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      throw StateError('No enqueued response. callCount=$callCount');
    }
    final next = _responses.removeAt(0);
    if (next == 'HANG') {
      final controller = StreamController<String>();
      if (cancelToken != null) {
        cancelToken.whenCancel.then((err) {
          if (!controller.isClosed) {
            controller.addError(err);
            controller.close();
          }
        });
      }
      return controller.stream;
    }
    if (next is List) {
      final chunks = next.cast<String>();
      return (() async* {
        for (final c in chunks) {
          yield c;
        }
      })();
    }
    throw StateError('Unknown enqueued response type: $next');
  }
}

AIModelConfig _makeConfig() {
  return AIModelConfig.create(
    id: 'test',
    provider: 'openai',
    name: 'Test Model',
    apiKey: 'test-key',
    baseUrl: 'https://test.example.com/v1',
    modelName: 'test-model',
    maxTokens: 4096,
    contextWindow: 0,
  );
}

const _finishTurn =
    '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n动作: finish\n';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  AgentEngine makeEngine(_MockAIProvider provider) {
    return AgentEngine(
      aiProvider: provider,
      modelConfig: _makeConfig(),
      memory: AgentMemory(),
      maxSteps: 8,
      hostId: 'test-host',
    );
  }

  Future<void> waitUntil(bool Function() condition,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待条件超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 把循环停在 ask 等待上，注入补充后点选继续，返回第二轮收到的历史
  Future<List<ChatMessage>> steerDuringAsk(
    AgentEngine engine,
    _MockAIProvider provider,
    List<String> steerings,
  ) async {
    provider.enqueueStream(['思考: 请选择\n选项: 继续 | 停止\n']);
    provider.enqueueStream([
      '思考: 收到补充\n动作: execute\n命令: echo ok\n',
    ]);
    provider.enqueueStream([_finishTurn]);

    final running = engine.startTask('steering 测试', _MockExecutor());
    await waitUntil(() => engine.hasPendingChoice);
    for (final s in steerings) {
      engine.addUserSteering(s);
    }
    engine.selectChoice('继续');
    await running;
    return provider.receivedHistories[1];
  }

  group('addUserSteering 入队规则', () {
    test('空串与纯空白忽略', () {
      final engine = makeEngine(_MockAIProvider());
      engine.addUserSteering('');
      engine.addUserSteering('   \n\t ');
      expect(engine.pendingSteeringCount, 0);
    });

    test('trim 后入队，保持顺序', () {
      final engine = makeEngine(_MockAIProvider());
      engine.addUserSteering('  第一条  ');
      engine.addUserSteering('第二条');
      expect(engine.pendingSteeringCount, 2);
    });

    test('超长保尾截断到 maxSteeringChars（R8）', () async {
      final provider = _MockAIProvider();
      final engine = makeEngine(provider);
      final long = '${'A' * 4500}TAIL';
      engine.addUserSteering(long);
      expect(engine.pendingSteeringCount, 1);

      // startTask 会重置瞬态（清空队列），故在 ask 等待期间入队验证注入内容
      final history = await steerDuringAsk(engine, provider, [long]);
      // drain 后应出现在第二轮历史末尾（提问引导消息紧随其后）
      final last = history[history.length - 2];
      expect(history.last.content, contains('若是提问而非指令'));
      expect(last.role, 'user');
      expect(last.content.endsWith('TAIL'), isTrue, reason: '截断必须保留尾部');
      // 注：_trimMessages 对 >4000 字符的单条消息还有一层既有保尾截断（带标记前缀），
      // 故不精确断言总长，改为断言 A 的数量 == 上限-4（保尾截断语义，剔除 TAIL 中的 A）。
      final body = last.content.substring(0, last.content.length - 4);
      expect('A'.allMatches(body).length, AgentEngine.maxSteeringChars - 4,
          reason: 'steering 入队时应保尾截断到 maxSteeringChars');
      expect(last.content.length, lessThan(long.length),
          reason: '超长内容必须被截断');
    });

    test('队列条数有上限，超出丢弃最早一条（R8）', () async {
      final provider = _MockAIProvider();
      final engine = makeEngine(provider);
      for (var i = 0; i < 25; i++) {
        engine.addUserSteering('s$i');
      }
      expect(engine.pendingSteeringCount, 20);

      // startTask 会重置瞬态（清空队列），故在 ask 等待期间入队验证注入内容
      final history = await steerDuringAsk(
          engine, provider, [for (var i = 0; i < 25; i++) 's$i']);
      final injected = history
          .where((m) => m.role == 'user' && m.content.startsWith('用户补充: s'))
          .map((m) => m.content)
          .toList();
      expect(injected, hasLength(20));
      expect(injected.first, '用户补充: s5', reason: '最早的 5 条被丢弃');
      expect(injected.last, '用户补充: s24');
    });
  });

  group('循环边界注入', () {
    test('ask 等待期间入队，下一轮按顺序注入 user 消息并发 info 事件', () async {
      final provider = _MockAIProvider();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      provider.enqueueStream(['思考: 请选择\n选项: 继续 | 停止\n']);
      provider.enqueueStream([
        '思考: 收到补充\n动作: execute\n命令: echo ok\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final running = engine.startTask('安装服务', _MockExecutor());
      await waitUntil(() => engine.hasPendingChoice);

      engine.addUserSteering('先检查磁盘');
      engine.addUserSteering('再看内存');
      // 等待期间不立即注入
      expect(engine.pendingSteeringCount, 2);
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('用户补充')),
        isFalse,
        reason: 'ask 等待期间补充只入队，不注入',
      );

      engine.selectChoice('继续');
      await running;

      expect(engine.pendingSteeringCount, 0);
      final history = provider.receivedHistories[1];
      final ia = history.indexWhere((m) => m.content == '用户补充: 先检查磁盘');
      final ib = history.indexWhere((m) => m.content == '用户补充: 再看内存');
      expect(ia, greaterThan(0));
      expect(ib, ia + 1, reason: '注入顺序必须与入队顺序一致');
      expect(history[ia].role, 'user');
      expect(history[ib].role, 'user');
      expect(history[history.length - 2].content, '用户补充: 再看内存',
          reason: '补充必须在 _callAI 之前注入，成为第二轮历史的末尾（引导消息紧随其后）');
      expect(history.last.content, contains('若是提问而非指令'),
          reason: '补充批次后附提问引导，防止把提问当指令继续执行');

      final infos = events
          .where((e) => e.isInfo && (e.text ?? '').startsWith('💬 用户补充:'))
          .map((e) => e.text)
          .toList();
      expect(infos, ['💬 用户补充: 先检查磁盘', '💬 用户补充: 再看内存']);
    });

    test('等待确认期间入队不立即注入，确认后下一轮生效', () async {
      const blockedCmd = 'rm -f /etc/systemd/system/virt-edid.service';
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 清理服务文件\n动作: execute\n命令: $blockedCmd\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider);
      engine.setPermissionMode(AgentPermissionMode.ask);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      final running = engine.startTask('清理服务文件', _MockExecutor());
      await waitUntil(() => engine.hasPendingConfirm);

      engine.addUserSteering('改用 nginx');
      expect(engine.pendingSteeringCount, 1);
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('用户补充')),
        isFalse,
        reason: '等待确认期间不注入',
      );

      engine.confirmDangerousCommand();
      await running;

      expect(engine.pendingSteeringCount, 0);
      expect(
        provider.receivedHistories[1]
            .any((m) => m.role == 'user' && m.content == '用户补充: 改用 nginx'),
        isTrue,
      );
    });
  });

  group('取消 / 重置 / 代际失效', () {
    test('cancelTask 清空队列，代际失效后不注入旧补充', () async {
      final provider = _MockAIProvider();
      provider.enqueueHangingStream();
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      final running = engine.startTask('取消测试', _MockExecutor());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      engine.addUserSteering('别注入我');
      expect(engine.pendingSteeringCount, 1);

      engine.cancelTask();
      await running;
      expect(engine.pendingSteeringCount, 0, reason: 'cancel 必须清空队列');
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('用户补充')),
        isFalse,
      );

      // 新任务不能看到旧任务的补充
      provider.enqueueStream([_finishTurn]);
      await engine.startTask('新任务', _MockExecutor());
      expect(
        provider.receivedHistories.last
            .any((m) => m.content.contains('用户补充')),
        isFalse,
        reason: '代际失效后旧补充不得污染新任务历史',
      );
    });

    test('clearHistory / restoreHistory 清空队列（_resetTransientState）', () {
      final engine = makeEngine(_MockAIProvider());
      engine.addUserSteering('x');
      expect(engine.pendingSteeringCount, 1);
      engine.clearHistory();
      expect(engine.pendingSteeringCount, 0);

      engine.addUserSteering('y');
      engine.restoreHistory([]);
      expect(engine.pendingSteeringCount, 0);
    });
  });
}