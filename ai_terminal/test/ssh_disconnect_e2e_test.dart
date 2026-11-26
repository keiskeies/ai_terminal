import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// 断线链路的端到端验收（AGENTS.md R9：流/格式改动光靠单测不够）。
///
/// 单测各自能过，但历史上"每块都对、拼起来是坏的"出现过三次（R9 列举）。
/// 这条用例把真实形状串起来跑完：
/// 真实 [SSHService]（只替换传输层 ping 钩子）→ 看门狗判定 disconnected →
/// `ReActObservation.format()` 渲染 → 引擎塞回对话历史 → 下一次请求里
/// AI 真的看到 `失败类型: disconnected` 与「请停手」指引。
///
/// 三段单独测都能过而拼起来断的点：
/// - 执行器的 failureKind 名与观测文本是否一致（格式化层改名就断）；
/// - 「请停手」指引出现的时机是否等于预算（预算算术与观测文本的耦合）；
/// - 放宽预算后是否真的不再下发指引（C4 与 C1 的交界）。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  late SSHService ssh;

  SSHService makeService() {
    final svc = SSHService(HostConfig.create(
      id: 'e2e',
      name: 'e2e-host',
      host: '127.0.0.1',
      username: 'tester',
      authType: 'password',
    ))
      ..isConnectedForTesting = true
      // 看门狗阈值压到毫秒级：本用例要的是链路形状，不是等 10 s 静默
      ..silenceLimitForTesting = const Duration(milliseconds: 120);
    // 跳过 connect() 的"刚确认活着"标记：让每条命令都走完整预检路径
    return svc;
  }

  setUp(() {
    ssh = makeService();
  });

  tearDown(() {
    ssh.dispose();
  });

  /// 半开连接：写不报错、读无响应、ping 无应答——真实掉线最难发现的那一档
  void killLink() {
    ssh.livenessProbeForTesting = () async {
      throw StateError('ping 无响应');
    };
  }

  String turn(String command) => '思考: 执行\n动作: execute\n命令: $command\n';
  const finishTurn = '思考: 链路断了\n动作: finish\n';

  /// 跑一轮任务，返回 AI 每次请求实际看到的断线观测文本（按顺序）。
  ///
  /// [restoreAfter] 非空时，在第 N 条命令执行后注入一次自愈事件——
  /// 不真的换 executor，因为这里只证明"门限算术作用在真实观测文本上"。
  Future<List<String>> runTask({int? restoreAfter}) async {
    final provider = _MockAIProvider();
    final engine = AgentEngine(
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
      maxSteps: 8,
    )..setPermissionMode(AgentPermissionMode.auto);
    killLink();

    provider.onCall = (call) {
      if (restoreAfter != null && call == restoreAfter) {
        engine.noteConnectionRestored();
      }
    };
    for (final cmd in ['uptime', 'df -h', 'free -m', 'ss -lntp', 'vmstat']) {
      provider.enqueueStream([turn(cmd)]);
    }
    provider.enqueueStream([
      '思考: 不再尝试\n$finishTurn',
    ]);

    await engine.startTask('断线链路端到端', ssh);

    // 历史是累积快照，最后一次请求即全过程
    return provider.receivedHistories.last
        .where((m) =>
            m.content.startsWith('观测: ') && m.content.contains('disconnected'))
        .map((m) => m.content)
        .toList();
  }

  test('AI 收到的观测文本里带 disconnected 失败类型（不是伪装成 timeout）', () async {
    final obs = await runTask();

    expect(obs, isNotEmpty, reason: '命令必须真的被判断线');
    for (final o in obs) {
      expect(o, contains('失败类型: disconnected'),
          reason: '格式化层若丢字段，AI 就只能靠猜——C3 修的正是这个');
      expect(o, isNot(contains('timeout')),
          reason: '断线不得伪装成超时，否则 AI 会加重试而不是问用户');
    }
  });

  test('断线观测在门限处升级为「请停手」指引，且不提前', () async {
    final obs = await runTask();

    bool begs(int i) => obs[i].contains('请立即使用 动作: ask');
    final first = List.generate(obs.length, begs).indexOf(true);

    expect(first, 2, reason: '默认门限 3：第 3 次断线起才要求停手，前两次仍给重连机会');
    expect(obs[0], contains('请使用 动作: ask'), reason: '未到门限时也要引导，只是不禁止再试');
    for (var i = first; i < obs.length; i++) {
      expect(begs(i), isTrue, reason: '升级后不应回落');
    }
  });

  test('自愈过一次后门限放宽到 6：真实观测里不再出现停手指引', () async {
    final obs = await runTask(restoreAfter: 0);

    expect(obs.length, greaterThanOrEqualTo(4),
        reason: '放宽后任务能撑过更多轮断线，等得到后台退避跑完');
    expect(obs.any((o) => o.contains('请立即使用 动作: ask')), isFalse,
        reason: '重连已在后台跑 1+2+4+8+16+32s，判死等于把自愈成果扔掉');
  });
}

class _MockAIProvider implements AIProvider {
  final List<List<String>> _responses = [];
  final List<List<ChatMessage>> receivedHistories = [];

  void Function(int call)? onCall;

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
    onCall?.call(receivedHistories.length);
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      // 耗尽后回 finish，避免门限相关的用例因为步数而抛异常
      return (() async* {
        yield '思考: 结束\n动作: finish\n';
      })();
    }
    final chunks = _responses.removeAt(0);
    return (() async* {
      for (final c in chunks) {
        yield c;
      }
    })();
  }
}
