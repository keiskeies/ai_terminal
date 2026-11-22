import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// 断线自愈与 Agent 的交接（docs/ssh-disconnect-resilience-design.md C4/C5）。
///
/// 覆盖三段此前各自断裂的链路：
/// 1. 引擎在重连后放宽连续失败预算（否则后台退避跑到第 4 档时任务已被判死）；
/// 2. 重连后向模型注入**一次**"新会话状态已丢失"提示，避免直接重跑非幂等命令；
/// 3. notifier 按 tabId 把重连事件路由到该 tab 的引擎（不能用活跃引擎）。
///
/// 时序用真实形状：提示注入发生在两步之间的循环边界，而不是 noteConnectionRestored
/// 的调用栈里——后者正是 R5 禁止的（旧任务的重连事件会漏进新任务历史）。
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
        maxSteps: 6,
      );

  const finishTurn =
      '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

  String turn(String command) => '思考: 执行\n动作: execute\n命令: $command\n';

  test('重连后门限放宽到 6，且下一个任务归零', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([finishTurn]);
    final engine = makeEngine(provider);
    final executor = _MockExecutor();

    expect(engine.connFailBudgetForTesting, 3,
        reason: '默认门限保持原值，纯离线场景不放宽');

    engine.noteConnectionRestored();
    expect(engine.connFailBudgetForTesting, 6);
    expect(engine.hasPendingStateNoteForTesting, isTrue);

    // 下一个任务不继承"本次任务途中放宽"的预算，但提示必须留着：
    // 断线终止后用户接着发的下一条任务，第一条命令最容易被当成"重跑上一步"。
    provider.enqueueStream([finishTurn]);
    await engine.startTask('再来一轮', executor);
    expect(engine.connFailBudgetForTesting, 3,
        reason: '放宽只对本次任务途中发生过重连生效（R5）');
    expect(engine.hasPendingStateNoteForTesting, isFalse,
        reason: '新任务开局消费掉提示，不留到第三条命令之后');
    expect(
        provider.receivedHistories.last.any((m) => m.content.contains('重连后的新会话')),
        isTrue);
  });

  test('连续断线门限默认 3 次，自愈过一次放宽到 6 次', () async {
    /// 隔离门限算术：起跑时链路正常（否则循环入口直接终止，走不到
    /// `_executeCommand` 的连续失败计数），第一条命令后链路断掉，之后每条
    /// 命令都在执行前预检处失败并累加计数。
    ///
    /// 刻意只调 `noteConnectionRestored()` 而不换执行器——真实重连后命令会成功、
    /// 计数会归零；那条完整路径由提示注入用例与调度测试覆盖，
    /// 这里要证明的只有"门限本身变了"。
    /// [restoreAt] 非空时，在该次 AI 请求前注入一次自愈事件。
    Future<List<String>> run({int? restoreAt}) async {
      final provider = _MockAIProvider();
      final engine = makeEngine(provider);
      provider.onCall = (call) {
        if (restoreAt != null && call == restoreAt) {
          engine.noteConnectionRestored();
        }
      };
      final executor = _MockExecutor();
      var ran = 0;
      executor.onExecute = () {
        // 第一条命令跑完后链路断掉：模拟任务途中掉线
        if (++ran == 1) executor.connected = false;
      };
      for (final cmd in ['uptime', 'df -h', 'free -m', 'ss -lntp', 'vmstat']) {
        provider.enqueueStream([turn(cmd)]);
      }
      provider.enqueueStream(['思考: 纯问答，无需执行命令\n动作: finish\n']);
      await engine.startTask('断线空转测试', executor);
      // 历史是累积快照，取最后一次请求即为全过程：每条观测只出现一次，
      // 顺序就是命令顺序（expand 全部快照会把同一条观测数 N 遍）。
      return provider.receivedHistories.last
          .where((m) =>
              m.content.startsWith('观测: ') && m.content.contains('disconnected'))
          .map((m) => m.content)
          .toList();
    }

    // 「请停手」提示第一次出现的下标（0 基，只数断线观测）
    int firstGiveUp(List<String> obs) {
      for (var i = 0; i < obs.length; i++) {
        if (obs[i].contains('已连续失败')) return i;
      }
      return -1;
    }

    final without = await run();
    expect(without.length, 4);
    expect(firstGiveUp(without), 2,
        reason: '未重连时第 3 次断线就要求 AI 停手（纯离线场景不放宽）');

    final withReconnect = await run(restoreAt: 0);
    expect(firstGiveUp(withReconnect), -1,
        reason: '自愈过一次后门限放宽到 6，第 3、4 次断线不该判死');
    expect(withReconnect.length, 4);
  });

  test('重连提示只出现一次：注入在重连后的下一步，且不再重复', () async {
    final provider = _MockAIProvider();
    final engine = makeEngine(provider);
    final executor = _MockExecutor();

    // 第 1 步执行期间链路自愈一次（真实时序：自动重连在 await 空隙里完成）；
    // 之后的命令不再重复上报，否则测不出"一次性"。
    var reported = false;
    executor.onExecute = () {
      if (reported) return;
      reported = true;
      engine.noteConnectionRestored();
    };

    provider.enqueueStream([turn('uptime')]);
    provider.enqueueStream([turn('df -h')]);
    provider.enqueueStream([finishTurn]);

    await engine.startTask('重连提示测试', executor);

    expect(provider.receivedHistories.length, 3,
        reason: 'execute → execute → finish 三步');
    // 历史是累积快照：提示一旦写入就留在后续每次请求里。
    // 所以"一次性"的正确断言是全量历史里只有 1 条，而不是某次请求里为 0。
    int notesIn(int call) => provider.receivedHistories[call]
        .where((m) => m.content.contains('重连后的新会话'))
        .length;

    expect(notesIn(0), 0, reason: '重连发生在第一步执行期间，之前的请求不该带提示');
    expect(notesIn(1), 1, reason: '重连后的下一步必须告知模型状态已丢');
    expect(notesIn(2), 1, reason: '同一条提示留在上下文里即可，再注入一条才是污染');
  });

  test('重连提示文案必须点明非幂等命令风险', () async {
    final provider = _MockAIProvider();
    final engine = makeEngine(provider);
    final executor = _MockExecutor()
      ..onExecute = () => engine.noteConnectionRestored();

    provider.enqueueStream([turn('uptime')]);
    provider.enqueueStream([finishTurn]);
    await engine.startTask('检查提示文案', executor);

    final note = provider.receivedHistories.last
        .firstWhere((m) => m.content.contains('重连后的新会话'));
    expect(note.role, 'user');
    expect(note.content, contains('工作目录'));
    expect(note.content, contains('sudo'));
    expect(note.content, contains('先核验'));
  });

  test('未注册 tab 的重连通知是静默 no-op，不抛', () {
    final notifier = AgentNotifier();
    expect(() => notifier.noteConnectionRestored('ghost-tab'), returnsNormally);
  });

  test('中途换 executor 后命令走新连接，旧连接的断开不再累计失败', () async {
    // _finishReconnect 依赖的正是这条引擎侧契约：重连只换 executor，
    // 任务不取消、不判死。断线期间排的空转预算必须在新连接上归零。
    final provider = _MockAIProvider();
    final engine = makeEngine(provider);
    final stale = _MockExecutor();
    final fresh = _MockExecutor();
    final ranOnFresh = <String>[];
    fresh.onExecute = () => ranOnFresh.add('hit');

    // 第 1 条命令跑完就掉线；同一时刻模拟 notifier 把新 service 塞进来。
    var swapped = false;
    stale.onExecute = () {
      stale.connected = false;
      if (!swapped) {
        swapped = true;
        engine.setExecutor(fresh);
        engine.noteConnectionRestored();
      }
    };

    provider.enqueueStream([turn('uptime')]);
    provider.enqueueStream([turn('df -h')]);
    provider.enqueueStream([turn('free -m')]);
    provider.enqueueStream([finishTurn]);
    await engine.startTask('重连续跑测试', stale);

    expect(ranOnFresh.length, 2, reason: '掉线之后的两条命令都该落在新连接上');
    expect(engine.consecutiveConnFailuresForTesting, 0,
        reason: '新连接成功执行即归零，不留残留计数');
    final obs = provider.receivedHistories.last
        .where((m) => m.content.startsWith('观测: '))
        .map((m) => m.content)
        .toList();
    expect(obs.any((o) => o.contains('disconnected')), isFalse,
        reason: '换 executor 成功就不该产生断线观测');
    expect(obs.length, 3);
  });

  test('重连通知按 tabId 命中该 tab 的引擎，而不是活跃引擎', () {
    final notifier = AgentNotifier();
    notifier.switchTab('tabActive', hostId: 'host1');
    final activeEngine = makeEngine(_MockAIProvider());
    final bgEngine = makeEngine(_MockAIProvider());
    notifier.registryForTesting
      ..setScopeHost('tabBg', 'host2')
      ..setEngine('tabActive', activeEngine)
      ..setEngine('tabBg', bgEngine);

    notifier.noteConnectionRestored('tabBg');

    expect(bgEngine.connFailBudgetForTesting, 6,
        reason: '后台 tab 重连必须由它自己的引擎接收（R3）');
    expect(activeEngine.connFailBudgetForTesting, 3,
        reason: '活跃 tab 没有重连，不能被顺带放宽');
  });
}

class _MockExecutor implements CommandExecutor {
  bool connected = true;

  /// 每次 executeAndWait 前触发——用来在"命令等待期间"注入重连事件。
  void Function()? onExecute;

  @override
  bool get isConnected => connected;

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
    onExecute?.call();
    return CommandResult(
      stdout: 'ok\n',
      // 真实执行器契约：stderr 恒空
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
  final List<List<ChatMessage>> receivedHistories = [];

  /// 每次请求前回调（0 基），用于在指定的步骤边界注入重连事件。
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
