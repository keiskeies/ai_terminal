import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/models/command_snippet.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';

class FakeAIProvider implements AIProvider {
  final List<String> responses;
  int _index = 0;

  FakeAIProvider(this.responses);

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
  }) async {
    final response = responses[_index % responses.length];
    _index++;
    final controller = StreamController<String>();
    // 模拟流式输出
    Future(() async {
      for (final char in response.split('')) {
        controller.add(char);
        await Future.delayed(const Duration(milliseconds: 2));
      }
      await controller.close();
    });
    return controller.stream;
  }
}

class FakeCommandExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;

  StreamController<String>? _controller;

  @override
  Stream<String> get output {
    _controller ??= StreamController<String>.broadcast();
    return _controller!.stream;
  }

  @override
  void execute(String command) {
    final ctrl = _controller ??= StreamController<String>.broadcast();
    Future.delayed(const Duration(milliseconds: 10), () {
      ctrl.add('fake output for $command');
      ctrl.close();
      _controller = null;
    });
  }

  @override
  void writeToTerminal(String data) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
  }) async {
    return CommandResult(
      stdout: 'fake output for $command',
      stderr: '',
      exitCode: 0,
      duration: const Duration(milliseconds: 10),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    Hive.init('/Users/cjm/Documents');
    Hive.registerAdapter(HostConfigAdapter());
    Hive.registerAdapter(AIModelConfigAdapter());
    Hive.registerAdapter(ChatSessionAdapter());
    Hive.registerAdapter(ChatMessageAdapter());
    Hive.registerAdapter(CommandBlockAdapter());
    Hive.registerAdapter(CommandSnippetAdapter());
    Hive.registerAdapter(ConvMessageAdapter());
    Hive.registerAdapter(ConvAgentLogAdapter());
    Hive.registerAdapter(ConversationAdapter());
    Hive.registerAdapter(AgentEventAdapter());
    Hive.registerAdapter(AgentEventTypeAdapter());
    await Hive.openBox<Conversation>('conversations');
  });

  tearDownAll(() async {
    await Hive.close();
  });

  test('agent message should be persisted', () async {
    final notifier = AgentNotifier();
    final config = AIModelConfig()
      ..id = 'test-model'
      ..name = 'Test Model'
      ..provider = 'openai'
      ..apiKey = 'test-key'
      ..baseUrl = 'http://localhost'
      ..modelName = 'test-model'
      ..isDefault = true;

    final provider = FakeAIProvider([
      '思考: 第一步\n动作: execute\n命令: echo step1\n',
      '思考: 第二步完成\n动作: finish\n',
    ]);

    notifier.switchTab('test-tab', hostId: 'test-host-persistence');
    notifier.setExecutor(FakeCommandExecutor());
    notifier.init(modelConfig: config, aiProvider: provider);

    await notifier.startTask('测试任务');

    // 等待异步保存完成
    await Future.delayed(const Duration(seconds: 1));

    final box = Hive.box<Conversation>('conversations');
    final conv = box.values.firstWhere((c) => c.hostId == 'test-host-persistence');
    print('Messages: ${conv.messages.length}');
    for (final m in conv.messages) {
      print('role=${m.role} contentLength=${m.content.length} content="${m.content}" events=${m.events?.length}');
    }

    final assistantMsgs = conv.messages.where((m) => m.role == 'assistant').toList();
    expect(assistantMsgs, isNotEmpty);
    expect(assistantMsgs.last.content, isNotEmpty, reason: 'assistant content should not be empty after normal finish');
  });

  test('cancelled agent message should still save streamed content', () async {
    final notifier = AgentNotifier();
    final config = AIModelConfig()
      ..id = 'test-model'
      ..name = 'Test Model'
      ..provider = 'openai'
      ..apiKey = 'test-key'
      ..baseUrl = 'http://localhost'
      ..modelName = 'test-model'
      ..isDefault = true;

    // 长时间执行的响应（命令执行需要等待30秒超时）
    final provider = FakeAIProvider([
      '思考: 会执行很久\n动作: execute\n命令: sleep 30\n',
    ]);

    notifier.switchTab('test-tab', hostId: 'test-host-cancel');
    notifier.setExecutor(FakeCommandExecutor());
    notifier.init(modelConfig: config, aiProvider: provider);

    final task = notifier.startTask('测试取消');
    await Future.delayed(const Duration(milliseconds: 200));
    notifier.cancel();
    await task;

    await Future.delayed(const Duration(seconds: 1));

    final box = Hive.box<Conversation>('conversations');
    final conv = box.values.firstWhere((c) => c.hostId == 'test-host-cancel');
    print('Cancelled task messages: ${conv.messages.length}');
    for (final m in conv.messages) {
      print('role=${m.role} contentLength=${m.content.length} content="${m.content}" events=${m.events?.length}');
    }

    final assistantMsgs = conv.messages.where((m) => m.role == 'assistant').toList();
    expect(assistantMsgs, isNotEmpty);
    expect(assistantMsgs.last.content, isNotEmpty, reason: 'cancelled assistant content should save streamed text');
  });
}
