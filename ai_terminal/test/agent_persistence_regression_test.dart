import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/providers/chat_provider.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/conversation_service.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

class _TestNotifier extends AgentNotifier {
  void setStateForTest(AgentState state) {
    this.state = state;
  }
}

class _NoCallAIProvider implements AIProvider {
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
    throw StateError('测试不应触发 AI 调用');
  }
}

class _ImmediateAIProvider implements AIProvider {
  final String response;
  _ImmediateAIProvider(this.response);

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
  }) async =>
      Stream.value(response);
}

class _DeferredAIProvider implements AIProvider {
  final Completer<void> started = Completer<void>();
  final List<Completer<String>> responses = [Completer<String>()];
  int calls = 0;

  Completer<String> get response => responses.first;

  Completer<String> enqueueResponse() {
    final next = Completer<String>();
    responses.add(next);
    return next;
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
    void Function(List<ToolCall> calls)? onToolCalls,
  }) async {
    final current =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (!started.isCompleted) started.complete();
    return Stream.value(await current.future);
  }
}

class _RecordingExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  int runOnceCalls = 0;

  @override
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    runOnceCalls++;
    return 'test-system-info';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedExecutor extends _RecordingExecutor {
  final Completer<void> gate = Completer<void>();
  final Completer<void> started = Completer<void>();

  @override
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    runOnceCalls++;
    if (!started.isCompleted) started.complete();
    await gate.future;
    return 'test-system-info';
  }
}

class _ControlledDatabase implements Database {
  final Map<String, Map<String, Object?>> rows = {};
  final Map<String, String> settingsRows = {};
  Object? settingsError;
  Object? insertError;
  Completer<void>? insertGate;
  final Completer<void> insertStarted = Completer<void>();

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (table == 'settings') {
      final error = settingsError;
      if (error != null) throw error;
      settingsRows[values['key']! as String] = values['value']! as String;
      return 1;
    }
    final gate = insertGate;
    if (gate != null) {
      if (!insertStarted.isCompleted) insertStarted.complete();
      await gate.future;
    }
    final error = insertError;
    if (error != null) {
      insertError = null;
      throw error;
    }
    rows[values['id']! as String] = Map<String, Object?>.from(values);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SseServer {
  _SseServer._(this.server, this.started, this.release, this.finished);

  final HttpServer server;
  final Completer<void> started;
  final Completer<void> release;
  final Completer<void> finished;

  static Future<_SseServer> start({String content = '测试回复'}) async {
    final started = Completer<void>();
    final release = Completer<void>();
    final finished = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      final payload = jsonEncode({
        'choices': [
          {
            'delta': {'content': content},
            'finish_reason': null,
          },
        ],
      });
      request.response.add(utf8.encode('data: $payload\n\n'));
      await request.response.flush();
      if (!started.isCompleted) started.complete();
      await release.future;
      try {
        request.response.add(utf8.encode('data: [DONE]\n\n'));
        await request.response.flush();
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      } finally {
        if (!finished.isCompleted) finished.complete();
      }
    });
    return _SseServer._(server, started, release, finished);
  }

  AIModelConfig config() => AIModelConfig.create(
        id: 'sse-test',
        provider: 'openai',
        name: 'SSE Test',
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        modelName: 'test-model',
        maxTokens: 128,
        contextWindow: 0,
      );

  Future<void> finish() async {
    if (!release.isCompleted) release.complete();
    await finished.future.timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

Future<void> _waitForChatIdle(ChatNotifier notifier) async {
  if (!notifier.state.isLoading) return;
  final done = Completer<void>();
  void listener(ChatState value) {
    if (!value.isLoading && !done.isCompleted) done.complete();
  }

  notifier.addListener(listener);
  await done.future.timeout(const Duration(seconds: 5));
}

AIModelConfig _config() => AIModelConfig.create(
      id: 'test',
      provider: 'openai',
      name: 'Test Model',
      apiKey: 'test-key',
      baseUrl: 'https://test.example.com/v1',
      modelName: 'test-model',
      maxTokens: 4096,
      contextWindow: 0,
    );

AgentEngine _engine(String hostId, {AIProvider? ai}) => AgentEngine(
      aiProvider: ai ?? _NoCallAIProvider(),
      modelConfig: _config(),
      memory: AgentMemory(),
      hostId: hostId,
    );

Conversation _compactConversation({
  String id = 'compact-conversation',
  String hostId = 'compact-host',
  int messageCount = 20,
}) {
  final conv = Conversation.create(
    id: id,
    hostId: hostId,
    title: 'compact',
  );
  for (var i = 0; i < messageCount; i++) {
    conv.addMessage(ConvMessage.create(
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i',
    ));
  }
  return conv;
}

void main() {
  late _ControlledDatabase db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  setUp(() {
    db = _ControlledDatabase();
    ConversationService().resetForTesting();
    ConversationsDao.resetForTesting();
    ConversationsDao.databaseOverride = db;
    SettingsDao.databaseOverride = db;
  });

  tearDown(() async {
    ConversationService().resetForTesting();
    await agentLogger.flush();
    SettingsDao.databaseOverride = null;
    ConversationsDao.databaseOverride = null;
    ConversationsDao.resetForTesting();
  });

  test('onError 填充空 assistant 时保留命令事件与命令元数据', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('error-tab', hostId: 'error-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final engine = notifier.registryForTesting.getEngine('error-tab')!;
    final conv = ConversationService().createSession(hostId: 'error-host');
    conv.addMessage(ConvMessage.create(
      role: 'assistant',
      content: '',
      command: 'systemctl status nginx',
      commandSuccess: false,
    ));
    engine.conversationId = conv.id;
    final command = AgentEvent.command('systemctl status nginx');
    final result = AgentEvent.result(
      commandId: command.id,
      success: false,
      error: 'connection lost',
    );
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: conv.id,
      chatItems: [
        ChatItem(
          role: 'assistant',
          content: '',
          command: command.command,
          commandSuccess: false,
          events: [command, result],
          isStreaming: true,
        ),
      ],
    ));

    engine.onError!('network failed');
    final item = notifier.state.chatItems.single;
    expect(item.content, contains('network failed'));
    expect(item.events, [command, result]);
    expect(item.command, 'systemctl status nginx');
    expect(item.commandSuccess, isFalse);
    expect(item.isStreaming, isFalse);

    await Future<void>.delayed(Duration.zero);
    final messages =
        jsonDecode(db.rows[conv.id]!['messages']! as String) as List;
    final persisted = messages.single as Map<String, dynamic>;
    expect(persisted['command'], 'systemctl status nginx');
    expect((persisted['events'] as List), hasLength(2));
  });

  test('setExecutor 重连刷新系统信息，后台 scope 也更新自己的 future', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('tab-a', hostId: 'host-a');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    notifier.switchTab('tab-b', hostId: 'host-b');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());

    final firstExecutor = _RecordingExecutor();
    notifier.setExecutor(firstExecutor, hostId: 'host-a', tabId: 'tab-a');
    final firstFuture = notifier.registryForTesting.getSysInfoFuture('tab-a');
    expect(firstFuture, isNotNull);
    await firstFuture;
    expect(firstExecutor.runOnceCalls, 4);

    final secondExecutor = _RecordingExecutor();
    notifier.setExecutor(secondExecutor, hostId: 'host-a', tabId: 'tab-a');
    final secondFuture = notifier.registryForTesting.getSysInfoFuture('tab-a');
    expect(secondFuture, isNotNull);
    expect(identical(firstFuture, secondFuture), isFalse);
    await secondFuture;
    await firstFuture;
    expect(secondExecutor.runOnceCalls, 4);
    expect(notifier.state.hostId, 'host-b', reason: '后台刷新不能污染活跃 tab');
  });

  test('setExecutor 串行刷新在 await 后使用当前 engine，不写回旧 engine', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('sysinfo-engine-tab', hostId: 'sysinfo-engine-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final firstExecutor = _GatedExecutor();
    notifier.setExecutor(firstExecutor,
        hostId: 'sysinfo-engine-host', tabId: 'sysinfo-engine-tab');
    final firstFuture =
        notifier.registryForTesting.getSysInfoFuture('sysinfo-engine-tab')!;
    await firstExecutor.started.future;

    final replacement = _engine('sysinfo-engine-host');
    notifier.registryForTesting.setEngine('sysinfo-engine-tab', replacement);
    final secondExecutor = _RecordingExecutor();
    notifier.setExecutor(secondExecutor,
        hostId: 'sysinfo-engine-host', tabId: 'sysinfo-engine-tab');
    final secondFuture =
        notifier.registryForTesting.getSysInfoFuture('sysinfo-engine-tab')!;

    firstExecutor.gate.complete();
    await firstFuture;
    await secondFuture;
    expect(secondExecutor.runOnceCalls, 4);
    expect(notifier.registryForTesting.getEngine('sysinfo-engine-tab'),
        same(replacement));
  });

  test('_setGoal 异步存盘失败会显式 surface，不静默丢目标', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('goal-tab', hostId: 'goal-host');
    db.settingsError = StateError('settings write failed');

    final goal = notifier.createGoal('goal-host', '完成部署');
    expect(goal, isNotNull);
    expect(notifier.goalFor('goal-host'), same(goal));
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.error, contains('目标保存失败'));
    expect(notifier.state.error, contains('settings write failed'));
    expect(notifier.goalFor('goal-host'), same(goal));
  });

  test('deleteSession 拒绝删除正在执行或正被其他 scope 查看的会话', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('running-tab', hostId: 'running-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final engine = notifier.registryForTesting.getEngine('running-tab')!;
    engine.setTaskStatusForTesting(AgentStatus.executing);
    final conv = ConversationService().createSession(hostId: 'running-host');
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));

    await notifier.deleteSession(conv.id);
    expect(notifier.state.error, contains('正在执行任务'));
    expect(ConversationsDao.getCachedById(conv.id), same(conv));

    final shared = _TestNotifier();
    addTearDown(shared.dispose);
    shared.switchTab('shared-a', hostId: 'shared-host');
    shared.switchTab('shared-b', hostId: 'shared-host');
    final sharedConv =
        ConversationService().createSession(hostId: 'shared-host');
    shared.registryForTesting.setState(
      'shared-a',
      AgentState(hostId: 'shared-host', conversationId: sharedConv.id),
    );
    shared
        .setStateForTest(shared.state.copyWith(conversationId: sharedConv.id));

    await shared.deleteSession(sharedConv.id);
    expect(shared.state.error, contains('其他标签中查看'));
    expect(ConversationsDao.getCachedById(sharedConv.id), same(sharedConv));
  });

  test('startTask 首条消息 insert 失败：退出 thinking、清启动锁并可重试', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('insert-fail-tab', hostId: 'insert-fail-host');
    notifier.init(
      modelConfig: _config(),
      aiProvider: _ImmediateAIProvider('回答: 成功\n动作: finish'),
    );
    notifier.setExecutor(_RecordingExecutor(),
        hostId: 'insert-fail-host', tabId: 'insert-fail-tab');
    final conv =
        ConversationService().createSession(hostId: 'insert-fail-host');
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));
    db.insertError = StateError('insert failed');

    await notifier.startTask('第一条消息');

    expect(notifier.state.status, AgentStatus.failed);
    expect(notifier.state.error, contains('insert failed'));
    expect(notifier.state.chatItems, isEmpty);
    expect(
        notifier.registryForTesting.getEngine('insert-fail-tab')!.currentTask,
        isNull);
    expect(notifier.isRunningFor('insert-fail-tab'), isFalse);
    expect(conv.messages, isEmpty);

    await notifier.startTask('重试消息');
    expect(notifier.state.status, AgentStatus.completed);
    expect(notifier.state.chatItems, hasLength(2));
  });

  test('startTask 落盘窗口取消：UI 与磁盘都保留取消占位，无空白 assistant', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('startup-tab', hostId: 'startup-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final conv = ConversationService().createSession(hostId: 'startup-host');
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));
    db.insertGate = Completer<void>();

    final starting = notifier.startTask('执行任务');
    await db.insertStarted.future;
    expect(notifier.state.chatItems, hasLength(2));
    expect(notifier.state.chatItems.last.content, isEmpty);

    await notifier.deleteSession(conv.id);
    expect(notifier.state.error, contains('正在启动或保存'));
    notifier.cancel();
    expect(notifier.state.chatItems.last.content, L10n.str.taskCancelled);

    db.insertGate!.complete();
    await starting;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.status, AgentStatus.cancelled);
    expect(notifier.state.chatItems.last.content, L10n.str.taskCancelled);
    expect(notifier.state.chatItems.last.isStreaming, isFalse);
    final messages =
        jsonDecode(db.rows[conv.id]!['messages']! as String) as List;
    expect(messages, hasLength(2));
    final assistant = messages.last as Map<String, dynamic>;
    expect(assistant['role'], 'assistant');
    expect(assistant['content'], L10n.str.taskCancelled);
    expect(notifier.registryForTesting.getEngine('startup-tab')!.currentTask,
        isNull);
  });

  test('启动落盘期间关闭 tab：磁盘固化取消占位，不留下空白 assistant', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('close-startup-tab', hostId: 'close-startup-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final conv =
        ConversationService().createSession(hostId: 'close-startup-host');
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));
    db.insertGate = Completer<void>();

    final starting = notifier.startTask('关闭中的任务');
    await db.insertStarted.future;
    notifier.removeTab('close-startup-tab');
    db.insertGate!.complete();
    await starting;
    await Future<void>.delayed(Duration.zero);

    final messages =
        jsonDecode(db.rows[conv.id]!['messages']! as String) as List;
    expect(messages, hasLength(2));
    final assistant = messages.last as Map<String, dynamic>;
    expect(assistant['content'], L10n.str.taskCancelled);
  });

  test('ChatNotifier 首条 user 写盘失败立即停止且不产生孤儿 assistant', () async {
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('chat-tab', hostId: 'chat-host');
    db.insertError = StateError('chat insert failed');

    await notifier.sendMessage('不会发送', config: _config());

    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.error, contains('chat insert failed'));
    expect(db.rows, isEmpty);
  });

  test('ChatNotifier 清除会话期间到达的取消结果不能回填旧对话', () async {
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    final conv = ConversationService().createSession(hostId: 'chat-clear-host');
    await ConversationService().appendMessage(
      'chat-clear-host',
      role: 'user',
      content: '旧消息',
      conversationId: conv.id,
    );
    notifier.switchTab('chat-clear-tab', hostId: 'chat-clear-host');
    notifier.switchTab('chat-clear-other-tab', hostId: 'chat-clear-other-host');
    notifier.switchTab('chat-clear-tab', hostId: 'chat-clear-host');
    db.insertGate = Completer<void>();

    final sending = notifier.sendMessage('待清除', config: _config());
    await db.insertStarted.future;
    final clearing = notifier.clearSession();
    db.insertGate!.complete();
    await sending;
    await clearing;
    await Future<void>.delayed(Duration.zero);

    expect(conv.messages, isEmpty);
    final messages =
        jsonDecode(db.rows[conv.id]!['messages']! as String) as List;
    expect(messages, isEmpty);
    expect(notifier.state.messages, isEmpty);
  });

  test('移除活跃 host 时使当前会话代际失效而非旧缓存会话', () async {
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    const cachedHost = 'chat-remove-cached-host';
    const activeHost = 'chat-remove-active-host';
    notifier.switchTab('cached-tab', hostId: cachedHost);
    final cached = ConversationService().createSession(hostId: cachedHost);
    await ConversationService().appendMessage(
      cachedHost,
      role: 'user',
      content: '缓存消息',
      conversationId: cached.id,
    );
    notifier.switchTab('active-tab', hostId: activeHost);
    final active = ConversationService().createSession(hostId: activeHost);
    await ConversationService().appendMessage(
      activeHost,
      role: 'user',
      content: '活跃消息',
      conversationId: active.id,
    );
    db.insertGate = Completer<void>();

    final sending = notifier.sendMessage('关闭中的消息', config: _config());
    await db.insertStarted.future;
    notifier.removeTab('active-tab', hostId: activeHost);
    db.insertGate!.complete();
    await sending;

    final messages =
        jsonDecode(db.rows[active.id]!['messages']! as String) as List;
    expect(messages, hasLength(2));
    expect((messages.last as Map)['role'], 'user');
    expect(messages.any((m) => (m as Map)['role'] == 'assistant'), isFalse,
        reason: '活跃会话已关闭，陈旧取消占位不得再次落盘');
  });

  test('关闭后台 host 不取消当前 host 的流式请求', () async {
    final savedHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = savedHttpOverrides);
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    final server = await _SseServer.start();
    addTearDown(server.close);
    final conv =
        ConversationService().createSession(hostId: 'chat-active-host');
    await ConversationService().appendMessage(
      'chat-active-host',
      role: 'user',
      content: '已有消息',
      conversationId: conv.id,
    );
    notifier.switchTab('chat-background-tab', hostId: 'chat-background-host');
    notifier.switchTab('chat-active-tab', hostId: 'chat-active-host');

    final sending = notifier.sendMessage('后台关闭',
        hostId: 'chat-active-host', config: server.config());
    await server.started.future.timeout(const Duration(seconds: 5));
    notifier.removeTab('chat-background-tab', hostId: 'chat-background-host');
    expect(notifier.state.currentHostId, 'chat-active-host');
    expect(notifier.state.isLoading, isTrue);
    await server.finish();
    await sending;
    await _waitForChatIdle(notifier);

    expect(notifier.state.messages, hasLength(3));
    expect(notifier.state.messages.last.content, '测试回复');
    expect(notifier.state.error, isNull);
  });

  test('关闭同 host 的另一个 tab 不取消共享聊天流', () async {
    final savedHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = savedHttpOverrides);
    final server = await _SseServer.start();
    addTearDown(server.close);
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('chat-shared-a', hostId: 'chat-shared-host');
    notifier.switchTab('chat-shared-b', hostId: 'chat-shared-host');

    final sending = notifier.sendMessage('共享标签', config: server.config());
    await server.started.future.timeout(const Duration(seconds: 5));
    notifier.removeTab('chat-shared-a', hostId: 'chat-shared-host');
    expect(notifier.state.isLoading, isTrue);
    await server.finish();
    await sending;
    await _waitForChatIdle(notifier);

    expect(notifier.state.messages, hasLength(2));
    expect(notifier.state.messages.last.content, '测试回复');
  });

  test('后台终端输出只更新所属 host 的聊天上下文', () {
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('output-a', hostId: 'output-host-a');
    notifier.updateLastOutput('A1', hostId: 'output-host-a');
    notifier.switchTab('output-b', hostId: 'output-host-b');

    notifier.updateLastOutput('A2', hostId: 'output-host-a');
    expect(notifier.state.lastCommandOutput, isEmpty);
    notifier.switchTab('output-a', hostId: 'output-host-a');
    expect(notifier.state.lastCommandOutput, 'A2');
  });

  test('旧会话清除失败不覆盖新 host 的模型错误', () async {
    final notifier = ChatNotifier();
    addTearDown(notifier.dispose);
    final conv =
        ConversationService().createSession(hostId: 'chat-old-error-host');
    await ConversationService().appendMessage(
      'chat-old-error-host',
      role: 'user',
      content: '旧消息',
      conversationId: conv.id,
    );
    // 先落盘会话，再首次进入该 host，避免 switchTab 缓存一个
    // conversationId 为 null 的旧状态。
    notifier.switchTab('chat-old-error-tab', hostId: 'chat-old-error-host');
    notifier.switchTab('chat-old-error-other-tab',
        hostId: 'chat-old-error-other-host');
    notifier.switchTab('chat-old-error-tab', hostId: 'chat-old-error-host');
    db.insertGate = Completer<void>();
    final clearing = notifier.clearSession();
    await db.insertStarted.future;

    db.insertError = StateError('old clear failed');
    db.insertGate!.complete();
    notifier.switchTab('chat-new-error-tab', hostId: 'chat-new-error-host');
    await notifier.sendMessage('不会发送');
    await clearing;

    expect(notifier.state.currentHostId, 'chat-new-error-host');
    expect(notifier.state.error, '请先配置 AI 模型');
    expect(notifier.state.error, isNot(contains('old clear failed')));
  });

  test('steer 落盘期间任务代际变化：保留已落盘消息但不注入新任务', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('steer-generation-tab', hostId: 'steer-generation-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final conv =
        ConversationService().createSession(hostId: 'steer-generation-host');
    final engine =
        notifier.registryForTesting.getEngine('steer-generation-tab')!;
    engine.conversationId = conv.id;
    engine.setTaskStatusForTesting(AgentStatus.executing);
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: conv.id,
      status: AgentStatus.executing,
      chatItems: [
        ChatItem(role: 'user', content: '原任务'),
        ChatItem(role: 'assistant', content: '执行中'),
      ],
    ));
    db.insertGate = Completer<void>();

    final steering = notifier.steer('补充指令');
    await db.insertStarted.future;
    engine.cancelTask();
    engine.setTaskStatusForTesting(AgentStatus.executing);
    db.insertGate!.complete();
    await steering;

    expect(engine.pendingSteeringCount, 0);
    expect(conv.messages.any((m) => m.content == '用户补充: 补充指令'), isTrue);
    expect(notifier.state.chatItems, hasLength(4));
    expect(notifier.state.chatItems.last.isStreaming, isFalse);
    expect(notifier.state.chatItems.last.content, isEmpty);
  });

  test('steer 落盘失败按对象身份回滚，不误删同内容旧消息', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('steer-rollback-tab', hostId: 'steer-rollback-host');
    notifier.init(modelConfig: _config(), aiProvider: _NoCallAIProvider());
    final conv =
        ConversationService().createSession(hostId: 'steer-rollback-host');
    final engine = notifier.registryForTesting.getEngine('steer-rollback-tab')!;
    engine.conversationId = conv.id;
    engine.setTaskStatusForTesting(AgentStatus.executing);
    const duplicateContent = '用户补充: 相同内容';
    final originalUser = ChatItem(role: 'user', content: duplicateContent);
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: conv.id,
      status: AgentStatus.executing,
      chatItems: [
        originalUser,
        ChatItem(role: 'assistant', content: '执行中'),
      ],
    ));
    db.insertError = StateError('steer insert failed');

    await notifier.steer('相同内容');

    expect(engine.pendingSteeringCount, 0);
    expect(notifier.state.chatItems, hasLength(2));
    expect(notifier.state.chatItems.first, same(originalUser));
    expect(notifier.state.chatItems.last.content, '执行中');
    expect(notifier.state.error, contains('steer insert failed'));
  });

  test('旧任务结束不得自动压缩 scope 当前的新会话', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('autocompact-tab', hostId: 'autocompact-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final original = _compactConversation(
      id: 'autocompact-a',
      hostId: 'autocompact-host',
      messageCount: 40,
    );
    ConversationsDao.cacheOnly(original);
    final engine = notifier.registryForTesting.getEngine('autocompact-tab')!;
    engine.conversationId = original.id;
    notifier
        .setStateForTest(notifier.state.copyWith(conversationId: original.id));

    final starting = notifier.startTask('旧任务');
    await ai.started.future;
    final replacement = _compactConversation(
      id: 'autocompact-b',
      hostId: 'autocompact-host',
      messageCount: 40,
    );
    ConversationsDao.cacheOnly(replacement);
    engine.conversationId = replacement.id;
    notifier.setStateForTest(
        notifier.state.copyWith(conversationId: replacement.id));
    notifier.cancel();
    await starting;
    await Future<void>.delayed(Duration.zero);

    expect(ai.calls, 1, reason: '旧任务结束不能对新会话发起摘要 AI 调用');
    expect(replacement.rollingSummary, isNull);
    expect(replacement.messages.every((m) => !m.rolledUp), isTrue);
  });

  test('compact A→B→A：旧压缩令牌失效，不能写回恢复后的 A', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('compact-token-tab', hostId: 'compact-token-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final a = _compactConversation(
      id: 'compact-token-a',
      hostId: 'compact-token-host',
    );
    final b = _compactConversation(
      id: 'compact-token-b',
      hostId: 'compact-token-host',
    );
    ConversationsDao.cacheOnly(a);
    ConversationsDao.cacheOnly(b);
    final engine = notifier.registryForTesting.getEngine('compact-token-tab')!;
    engine.conversationId = a.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: a.id));

    final first = notifier.compact('compact-token-tab');
    await ai.started.future;
    engine.conversationId = b.id;
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: b.id,
      isCompacting: false,
    ));
    final second = notifier.compact('compact-token-tab');
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 2);

    engine.conversationId = a.id;
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: a.id,
      isCompacting: true,
    ));
    ai.response.complete('过期摘要');
    await first;
    await second;

    expect(a.rollingSummary, isNull);
    expect(a.messages.every((m) => !m.rolledUp), isTrue);
    expect(b.rollingSummary, isNull);
    expect(notifier.state.isCompacting, isFalse);
  });

  test('旧压缩 upsert 失败不回滚或污染已成功的新压缩', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('compact-overlap-tab', hostId: 'compact-overlap-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final a = _compactConversation(
      id: 'compact-overlap-a',
      hostId: 'compact-overlap-host',
    );
    final b = _compactConversation(
      id: 'compact-overlap-b',
      hostId: 'compact-overlap-host',
    );
    ConversationsDao.cacheOnly(a);
    ConversationsDao.cacheOnly(b);
    final engine =
        notifier.registryForTesting.getEngine('compact-overlap-tab')!;
    engine.conversationId = a.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: a.id));

    db.insertGate = Completer<void>();
    final firstGate = db.insertGate!;
    final first = notifier.compact('compact-overlap-tab');
    await ai.started.future;
    ai.response.complete('旧压缩摘要');
    await db.insertStarted.future;
    expect(a.rollingSummary, '旧压缩摘要', reason: '旧压缩已进入被阻塞的 upsert');

    // 第二次压缩要能成功落库，先用一次不受门控的写入观察旧压缩失败。
    db.insertGate = null;
    engine.conversationId = b.id;
    notifier.setStateForTest(notifier.state.copyWith(
      conversationId: b.id,
      isCompacting: false,
    ));
    final secondResponse = ai.enqueueResponse();
    final second = notifier.compact('compact-overlap-tab');
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 2);
    secondResponse.complete('新压缩摘要');
    // 第二次写盘排在旧压缩的 host 写链之后，先让旧写入失败放行。
    await Future<void>.delayed(Duration.zero);
    db.insertError = StateError('old compact insert failed');
    firstGate.complete();
    await second;
    await first;

    expect(b.rollingSummary, '新压缩摘要');
    expect(notifier.state.isCompacting, isFalse);

    expect(a.rollingSummary, isNull);
    expect(a.messages.every((m) => !m.rolledUp), isTrue);
    expect(b.rollingSummary, '新压缩摘要');
    expect(b.messages.take(8).every((m) => m.rolledUp), isTrue);
    expect(notifier.state.conversationId, b.id);
    expect(notifier.state.isCompacting, isFalse);
    expect(notifier.state.error, isNull, reason: '旧压缩失败不能把错误写到新会话');
  });

  test('compact upsert 失败回滚 summary、rolledUp 与 updatedAt', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    notifier.switchTab('compact-fail-tab', hostId: 'compact-fail-host');
    notifier.init(
      modelConfig: _config(),
      aiProvider: _ImmediateAIProvider('未落盘摘要'),
    );
    final conv = _compactConversation(
      id: 'compact-fail-conversation',
      hostId: 'compact-fail-host',
    )
      ..rollingSummary = '旧摘要'
      ..updatedAt = DateTime.fromMillisecondsSinceEpoch(1234);
    conv.messages.first.rolledUp = true;
    ConversationsDao.cacheOnly(conv);
    final engine = notifier.registryForTesting.getEngine('compact-fail-tab')!;
    engine.conversationId = conv.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));
    final oldFlags = conv.messages.map((m) => m.rolledUp).toList();
    db.insertError = StateError('compact insert failed');

    await notifier.compact('compact-fail-tab');

    expect(conv.rollingSummary, '旧摘要');
    expect(conv.messages.map((m) => m.rolledUp).toList(), oldFlags);
    expect(conv.updatedAt.millisecondsSinceEpoch, 1234);
    expect(notifier.state.isCompacting, isFalse);
    expect(notifier.state.error, contains('compact insert failed'));
    expect(db.rows, isEmpty);
  });

  test('compact 摘要等待期间切会话：不写旧摘要，只清当前 scope 的锁', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('compact-tab', hostId: 'compact-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final conv = _compactConversation();
    ConversationsDao.cacheOnly(conv);
    final engine = notifier.registryForTesting.getEngine('compact-tab')!;
    engine.conversationId = conv.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));

    final compacting = notifier.compact('compact-tab');
    await ai.started.future;
    final other = Conversation.create(
      id: 'other-conversation',
      hostId: 'compact-host',
      title: 'other',
    );
    ConversationsDao.cacheOnly(other);
    notifier.setStateForTest(notifier.state.copyWith(conversationId: other.id));
    ai.response.complete('旧会话摘要');
    await compacting;

    expect(conv.rollingSummary, isNull);
    expect(conv.messages.every((m) => !m.rolledUp), isTrue);
    expect(other.rollingSummary, isNull);
    expect(notifier.state.conversationId, other.id);
    expect(notifier.state.isCompacting, isFalse);
  });

  test('compact 摘要等待期间换 engine：不污染新 engine 或旧会话', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('compact-engine-tab', hostId: 'compact-engine-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final conv = _compactConversation();
    ConversationsDao.cacheOnly(conv);
    final oldEngine =
        notifier.registryForTesting.getEngine('compact-engine-tab')!;
    oldEngine.conversationId = conv.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));

    final compacting = notifier.compact('compact-engine-tab');
    await ai.started.future;
    final replacement = _engine('compact-engine-host');
    replacement.conversationId = conv.id;
    notifier.registryForTesting.setEngine('compact-engine-tab', replacement);
    ai.response.complete('旧 engine 摘要');
    await compacting;

    expect(conv.rollingSummary, isNull);
    expect(conv.messages.every((m) => !m.rolledUp), isTrue);
    expect(notifier.state.isCompacting, isFalse);
    expect(notifier.registryForTesting.getEngine('compact-engine-tab'),
        same(replacement));
  });

  test('compact 摘要等待期间任务代际变化：放弃旧结果', () async {
    final notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    final ai = _DeferredAIProvider();
    notifier.switchTab('compact-task-tab', hostId: 'compact-task-host');
    notifier.init(modelConfig: _config(), aiProvider: ai);
    final conv = _compactConversation();
    ConversationsDao.cacheOnly(conv);
    final engine = notifier.registryForTesting.getEngine('compact-task-tab')!;
    engine.conversationId = conv.id;
    notifier.setStateForTest(notifier.state.copyWith(conversationId: conv.id));

    final compacting = notifier.compact('compact-task-tab');
    await ai.started.future;
    engine.setTaskStatusForTesting(AgentStatus.thinking);
    ai.response.complete('旧任务摘要');
    await compacting;

    expect(conv.rollingSummary, isNull);
    expect(conv.messages.every((m) => !m.rolledUp), isTrue);
    expect(notifier.state.isCompacting, isFalse);
  });
}
