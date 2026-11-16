import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';

/// O4/WP6 计划跟踪与 finish 完整性门控测试。
/// mock 模式参照 test/agent_engine_resilience_test.dart。

/// 用于集成测试的 Mock CommandExecutor
class _MockExecutor implements CommandExecutor {
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
  }) async {
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
      failureReason: 'mock 不支持 PTY 写文件',
    );
  }

  @override
  void writeToTerminal(String data) {}
}

/// 用于集成测试的 Mock AIProvider（与 resilience 测试同款）
class _MockAIProvider implements AIProvider {
  int callCount = 0;
  final List<Object> _responses = [];

  /// 每次调用时收到的 history 快照（浅拷贝列表；引擎替换 system 消息时
  /// 创建新对象，因此历史快照里的 content 不会被后续轮次改写）
  List<List<ChatMessage>> receivedHistories = [];

  void enqueueError(Exception e) {
    _responses.add(e);
  }

  void enqueueStream(List<String> chunks) {
    _responses.add(chunks);
  }

  void enqueueHangingStream() {
    _responses.add('HANG');
  }

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
    final next = _responses.removeAt(0);

    if (next is Exception) {
      throw next;
    }
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

const _startMarker = '【当前计划进度】';
const _endMarker = '【/当前计划进度】';

int _countMarker(String content, String marker) =>
    marker.allMatches(content).length;

/// 门控发出的 info 事件（文案含「未完成项」）
List<AgentEvent> _gateEvents(List<AgentEvent> events) => events
    .where((e) => e.isInfo && (e.text ?? '').contains('未完成项'))
    .toList();

const _executeTurn = '思考: 执行检查\n动作: execute\n命令: echo hi\n';
const _finishTurn =
    '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n动作: finish\n';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  AgentEngine makeEngine({
    required AIProvider provider,
    int maxSteps = 8,
  }) {
    return AgentEngine(
      aiProvider: provider,
      modelConfig: _makeConfig(),
      memory: AgentMemory(),
      maxSteps: maxSteps,
      hostId: 'test-host',
    );
  }

  group('finish 计划完整性门控', () {
    test('计划有未完成项时 finish 被拦截并注入更新计划消息', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 先检查\n计划:\n- [x] 检查环境\n- [ ] 安装 Nginx\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      // 计划未更新就 finish → 门控拦截
      provider.enqueueStream([_finishTurn]);
      // 模型按要求更新计划后再 finish → 放行
      provider.enqueueStream([
        '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n'
            '计划:\n- [x] 检查环境\n- [x] 安装 Nginx\n'
            '动作: finish\n',
      ]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('安装 Nginx', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 3);
      expect(_gateEvents(events), hasLength(1));
      expect(engine.planFinishRetryCountForTesting, 1);
      // 第 3 次调用的历史里必须有门控注入的 user 消息，点名未完成项
      final gateMsg = provider.receivedHistories[2].last;
      expect(gateMsg.role, 'user');
      expect(gateMsg.content, contains('未完成项'));
      expect(gateMsg.content, contains('安装 Nginx'));
      expect(gateMsg.content, contains('跳过'));
    });

    test('提醒 2 次后仍未完成则放行，不死循环', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 先检查\n计划:\n- [x] 检查环境\n- [ ] 安装 Nginx\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      // 连续 3 次 finish 都不更新计划：前 2 次被拦截，第 3 次放行
      provider.enqueueStream([_finishTurn]);
      provider.enqueueStream([_finishTurn]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('安装 Nginx', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed,
          reason: '计数耗尽后必须放行，避免死循环');
      expect(provider.callCount, 4);
      expect(_gateEvents(events), hasLength(2));
      expect(engine.planFinishRetryCountForTesting, 2);
      expect(events.where((e) => e.isFinish).single.finishState,
          AgentFinishState.success);
    });

    test('无计划任务不受门控影响', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([_executeTurn]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('检查状态', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 2);
      expect(_gateEvents(events), isEmpty);
      expect(engine.planFinishRetryCountForTesting, 0);
    });

    test('全完成计划直接 finish', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 执行\n计划:\n- [x] 检查环境\n- [x] 安装 Nginx\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('安装 Nginx', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 2);
      expect(_gateEvents(events), isEmpty);
    });

    test('仅含失败/跳过项的计划不触发门控（白名单判据）', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 执行\n计划:\n- [x] 检查环境\n- [!] 安装 Nginx\n- [-] 验证服务\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('安装 Nginx', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 2);
      expect(_gateEvents(events), isEmpty,
          reason: 'failed/skipped 是终态，不应拦截 finish');
    });

    test('门控计数器新任务归零（R5 独立计数器）', () async {
      final provider = _MockAIProvider();
      // 两个任务各自消耗 2 次提醒后放行
      for (var task = 0; task < 2; task++) {
        provider.enqueueStream([
          '思考: 先检查\n计划:\n- [ ] 步骤一\n动作: execute\n命令: echo hi\n',
        ]);
        provider.enqueueStream([_finishTurn]);
        provider.enqueueStream([_finishTurn]);
        provider.enqueueStream([_finishTurn]);
      }

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('任务一', _MockExecutor());
      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(engine.planFinishRetryCountForTesting, 2);

      await engine.startTask('任务二', _MockExecutor());
      expect(engine.currentTask?.status, AgentStatus.completed);
      // 若计数器未归零，任务二第一次 finish 就会放行（callCount 只会 +2）
      expect(provider.callCount, 8);
      expect(_gateEvents(events), hasLength(4));
    });

    test('clearHistory 归零门控计数器', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 先检查\n计划:\n- [ ] 步骤一\n动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([_finishTurn]);
      provider.enqueueStream([_finishTurn]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      await engine.startTask('任务一', _MockExecutor());
      expect(engine.planFinishRetryCountForTesting, 2);
      engine.clearHistory();
      expect(engine.planFinishRetryCountForTesting, 0);
    });
  });

  group('R5 终态路径枚举：门控只作用于 finish 分支', () {
    test('maxSteps 耗尽路径不经过门控', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 第一步\n计划:\n- [ ] 步骤一\n- [ ] 步骤二\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([
        '思考: 第二步\n计划:\n- [x] 步骤一\n- [ ] 步骤二\n'
            '动作: execute\n命令: echo hi\n',
      ]);

      final engine = makeEngine(provider: provider, maxSteps: 2);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('两步任务', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.failed,
          reason: 'maxSteps 耗尽是异常终止（R5）');
      expect(_gateEvents(events), isEmpty,
          reason: '计划未完成也不得在 maxSteps 路径插入门控重试');
      final finish = events.where((e) => e.isFinish).single;
      expect(finish.finishState, AgentFinishState.interrupted);
    });

    test('AI 异常 failed 路径不经过门控', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 第一步\n计划:\n- [ ] 步骤一\n动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueError(Exception('model exploded'));

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      await engine.startTask('异常任务', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.failed);
      expect(_gateEvents(events), isEmpty);
      final finish = events.where((e) => e.isFinish).single;
      expect(finish.finishState, AgentFinishState.failed);
    });

    test('cancel 路径不经过门控', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 第一步\n计划:\n- [ ] 步骤一\n动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueHangingStream();

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      final running = engine.startTask('取消任务', _MockExecutor());
      await _waitUntil(() => provider.callCount >= 2);
      engine.cancelTask();
      await running;

      expect(engine.currentTask?.status, AgentStatus.cancelled);
      expect(_gateEvents(events), isEmpty);
      final report = events.where((e) => e.isReport).single.operationReport!;
      expect(report.finishState, 'cancelled');
    });

    test('pause 不触发门控，resume 后计划注入继续', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 第一步\n计划:\n- [x] 检查环境\n- [ ] 安装 Nginx\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueHangingStream();
      provider.enqueueStream([
        '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n'
            '计划:\n- [x] 检查环境\n- [x] 安装 Nginx\n'
            '动作: finish\n',
      ]);

      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor();

      final running = engine.startTask('暂停恢复任务', executor);
      await _waitUntil(() => provider.callCount >= 2);
      engine.pauseTask();
      await running;
      expect(engine.currentTask?.status, AgentStatus.paused);
      expect(_gateEvents(events), isEmpty);

      await engine.resumeTask(executor);
      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(_gateEvents(events), isEmpty);
      // 恢复后 system 消息重建，循环顶部必须重新注入保留的计划快照
      final resumedSystem = provider.receivedHistories[2].first;
      expect(resumedSystem.role, 'system');
      expect(resumedSystem.content, contains(_startMarker));
      expect(resumedSystem.content, contains('[ ] 安装 Nginx'));
      expect(_countMarker(resumedSystem.content, _startMarker), 1);
    });
  });

  group('每轮计划进度注入', () {
    test('多轮只有一段计划快照，且随计划更新整段替换', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 第一步\n计划:\n- [x] 检查环境\n- [ ] 安装 Nginx\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([
        '思考: 第二步\n计划:\n- [x] 检查环境\n- [x] 安装 Nginx\n- [ ] 验证服务\n'
            '动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([_executeTurn]); // 不输出计划，沿用上一份
      provider.enqueueStream([
        '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n'
            '计划:\n- [x] 检查环境\n- [x] 安装 Nginx\n- [x] 验证服务\n'
            '动作: finish\n',
      ]);

      final engine = makeEngine(provider: provider);
      await engine.startTask('安装并验证', _MockExecutor());
      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 4);

      // 第 1 轮调用时尚无计划 → 无注入段
      expect(provider.receivedHistories[0].first.content,
          isNot(contains(_startMarker)));

      // 第 2 轮调用看到计划 A
      final sys2 = provider.receivedHistories[1].first.content;
      expect(_countMarker(sys2, _startMarker), 1);
      expect(_countMarker(sys2, _endMarker), 1);
      expect(sys2, contains('[ ] 安装 Nginx'));
      expect(sys2, contains('finish 前不得遗留待处理/进行中项'));

      // 第 3 轮调用看到更新后的计划 B（整段替换，不累积）
      final sys3 = provider.receivedHistories[2].first.content;
      expect(_countMarker(sys3, _startMarker), 1);
      expect(_countMarker(sys3, _endMarker), 1);
      expect(sys3, contains('[x] 安装 Nginx'));
      expect(sys3, contains('[ ] 验证服务'));
      expect(sys3, isNot(contains('[ ] 安装 Nginx')));

      // 第 4 轮调用仍看到计划 B（finish 响应里的计划 C 在调用之后才解析）
      final sys4 = provider.receivedHistories[3].first.content;
      expect(_countMarker(sys4, _startMarker), 1);
      expect(sys4, contains('[ ] 验证服务'));
    });

    test('计划置空后段移除；重复同步幂等（单元）', () {
      final engine = makeEngine(provider: _MockAIProvider());
      const basePrompt = '你是 AI 助手，可以执行命令。';
      engine.seedHistoryForTesting([
        ChatMessage.create(role: 'system', content: basePrompt),
        ChatMessage.create(role: 'user', content: '任务'),
      ]);

      // 无计划：同步不改变 system 消息
      engine.syncPlanProgressForTesting();
      expect(engine.conversationHistoryForTesting.first.content, basePrompt);

      // 注入计划 A
      engine.setPlanForTesting([
        const PlanStep(title: '检查环境', status: PlanStepStatus.completed),
        const PlanStep(title: '安装 Nginx'),
      ]);
      engine.syncPlanProgressForTesting();
      var content = engine.conversationHistoryForTesting.first.content;
      expect(content, contains(_startMarker));
      expect(content, contains(_endMarker));
      expect(content, contains('[x] 检查环境'));
      expect(content, contains('[ ] 安装 Nginx'));
      expect(content, startsWith(basePrompt));

      // 重复同步：仍只有一段，内容不变
      engine.syncPlanProgressForTesting();
      content = engine.conversationHistoryForTesting.first.content;
      expect(_countMarker(content, _startMarker), 1);
      expect(_countMarker(content, _endMarker), 1);

      // 计划更新：整段替换为最新状态
      engine.setPlanForTesting([
        const PlanStep(title: '检查环境', status: PlanStepStatus.completed),
        const PlanStep(title: '安装 Nginx', status: PlanStepStatus.inProgress),
        const PlanStep(title: '验证服务', status: PlanStepStatus.skipped),
      ]);
      engine.syncPlanProgressForTesting();
      content = engine.conversationHistoryForTesting.first.content;
      expect(_countMarker(content, _startMarker), 1);
      expect(content, contains('[>] 安装 Nginx'));
      expect(content, contains('[-] 验证服务'));
      expect(content, isNot(contains('[ ] 安装 Nginx')));

      // 计划置空：整段移除，还原原始 system 内容
      engine.setPlanForTesting([]);
      engine.syncPlanProgressForTesting();
      content = engine.conversationHistoryForTesting.first.content;
      expect(content, isNot(contains(_startMarker)));
      expect(content, isNot(contains(_endMarker)));
      expect(content, basePrompt);
    });

    test('新任务重建 system 消息，无旧计划段残留', () async {
      final provider = _MockAIProvider();
      // 任务一：带计划
      provider.enqueueStream([
        '思考: 执行\n计划:\n- [x] 步骤一\n动作: execute\n命令: echo hi\n',
      ]);
      provider.enqueueStream([_finishTurn]);
      // 任务二：无计划
      provider.enqueueStream([_executeTurn]);
      provider.enqueueStream([_finishTurn]);

      final engine = makeEngine(provider: provider);
      await engine.startTask('任务一', _MockExecutor());
      expect(provider.receivedHistories[1].first.content,
          contains(_startMarker));

      await engine.startTask('任务二', _MockExecutor());
      expect(engine.currentTask?.status, AgentStatus.completed);
      // 任务二的每一轮 system 消息都不含计划段
      for (var i = 2; i < provider.receivedHistories.length; i++) {
        expect(provider.receivedHistories[i].first.content,
            isNot(contains(_startMarker)));
      }
    });
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}