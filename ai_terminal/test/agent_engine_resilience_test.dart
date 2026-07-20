import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';

/// 用于集成测试的 Mock CommandExecutor
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
  }) async {
    return CommandResult(
      stdout: '',
      stderr: '',
      exitCode: 0,
      duration: Duration.zero,
    );
  }

  @override
  void writeToTerminal(String data) {}
}

/// 用于集成测试的 Mock AIProvider
/// 行为可配置：每次调用 chatStream 时返回预设的 Stream 或抛预设的异常
class _MockAIProvider implements AIProvider {
  /// 调用次数（用于断言）
  int callCount = 0;

  /// 第 N 次调用的行为：抛出异常或返回流
  /// 如果对应的 List 元素是 Exception，则抛出；否则作为 stream 处理
  final List<Object> _responses = [];

  /// 调用时收到的 history
  List<List<ChatMessage>> receivedHistories = [];

  /// 配置：下次调用抛出异常
  void enqueueError(Exception e) {
    _responses.add(e);
  }

  /// 配置：下次调用返回给定 chunks 的流
  void enqueueStream(List<String> chunks) {
    _responses.add(chunks);
  }

  /// 配置：下次调用返回一个永不完成的流（用于取消测试）
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
    List<Map<String, dynamic>>? tools,
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
      // 永不 close，cancelToken.whenCancel 触发时由调用方处理
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
      // 用 async* 生成器：能正确处理异步投递。
      // 之前用 StreamController.add + close 后 listen 的方式在 close 后注册
      // listener 可能丢失 buffered events（实测在 _callAI 中挂起）。
      // Mock 不需要响应 cancelToken 取消（测试场景下不会触发取消）。
      return (() async* {
        for (final c in chunks) {
          yield c;
        }
      })();
    }
    throw StateError('Unknown enqueued response type: $next');
  }
}

AIModelConfig _makeConfig({
  int contextWindow = 0,
  String? fallbackModelId,
  int maxTokens = 4096,
  String modelName = 'test-model',
}) {
  return AIModelConfig.create(
    id: 'test',
    provider: 'openai',
    name: 'Test Model',
    apiKey: 'test-key',
    baseUrl: 'https://test.example.com/v1',
    modelName: modelName,
    maxTokens: maxTokens,
    contextWindow: contextWindow,
    fallbackModelId: fallbackModelId,
  );
}

void main() {
  // 初始化 Flutter binding 和 L10n（agent_engine 内部多处依赖 L10n.str）
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  AgentEngine makeEngine({
    required _MockAIProvider provider,
    AIModelConfig? config,
    AIProvider? fallbackProvider,
    AIModelConfig? fallbackConfig,
  }) {
    return AgentEngine(
      aiProvider: provider,
      modelConfig: config ?? _makeConfig(),
      memory: AgentMemory(),
      maxSteps: 5,
      hostId: 'test-host',
      fallbackProvider: fallbackProvider,
      fallbackConfig: fallbackConfig,
    );
  }

  group('_trimMessages token-aware 裁剪', () {
    test('contextWindow=0 时使用默认 32768，小上下文不裁剪', () {
      final engine = makeEngine(provider: _MockAIProvider());
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: 'hello'),
        ChatMessage.create(role: 'assistant', content: 'hi there'),
      ];
      engine.trimMessagesForTesting(messages);
      expect(messages.length, 2);
    });

    test('超出 contextWindow*0.7 时丢弃最早消息', () {
      final engine = makeEngine(
        provider: _MockAIProvider(),
        config: _makeConfig(contextWindow: 100), // 预算 = 70 tokens
      );
      // 构造 6 条消息，每条约 30 tokens（中文 30 字 = 30 tokens）
      final messages = <ChatMessage>[];
      for (int i = 0; i < 6; i++) {
        messages.add(ChatMessage.create(
          role: i % 2 == 0 ? 'user' : 'assistant',
          content: '一二三四五六七八九十一二三四五六七八九十一二三四五', // 30 中文 = 30 tokens + 4 = 34
        ));
      }
      engine.trimMessagesForTesting(messages);
      // 总 token = 6*34 = 204，预算 70，应该丢弃到只剩 2 条
      expect(messages.length, lessThanOrEqualTo(3));
      expect(messages.length, greaterThanOrEqualTo(2));
    });

    test('单条消息过长会被截断到 _maxMessageChars', () {
      final engine = makeEngine(provider: _MockAIProvider());
      final longContent = 'a' * 10000; // 10000 ASCII ≈ 2500 tokens
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: longContent),
      ];
      engine.trimMessagesForTesting(messages);
      // 截断后内容长度应小于原长度
      expect(messages.first.content.length, lessThan(10000));
      expect(messages.first.content, contains('已截断'));
    });

    test('system 消息保留不被裁剪', () {
      final engine = makeEngine(
        provider: _MockAIProvider(),
        config: _makeConfig(contextWindow: 50),
      );
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'system', content: 'you are an agent'),
        ChatMessage.create(role: 'user', content: '一二三四五六七八九十一二三四五六七八九十'),
        ChatMessage.create(role: 'assistant', content: '一二三四五六七八九十一二三四五六七八九十'),
        ChatMessage.create(role: 'user', content: '一二三四五六七八九十一二三四五六七八九十'),
      ];
      engine.trimMessagesForTesting(messages);
      // system 消息应保留
      expect(messages.where((m) => m.role == 'system').length, 1);
    });
  });

  group('AgentEngine 构造与 fallback 注入', () {
    test('未配置 fallback 时 _callAI 失败直接抛出', () async {
      final provider = _MockAIProvider();
      // 第 1/2/3 次都抛网络错误（可重试），第 4 次也抛（maxRetries 后切换 fallback 但无 fallback 配置）
      for (int i = 0; i < 10; i++) {
        provider.enqueueError(DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/test'),
          message: 'connection refused',
        ));
      }
      final engine = makeEngine(provider: provider);
      // 调用 startTask 应失败（无 fallback，主模型重试耗尽后抛出）
      await engine.startTask('test goal', _MockExecutor());
      // 验证：引擎未挂起，且 provider 至少被调用了 maxRetries 次
      expect(provider.callCount, greaterThanOrEqualTo(3));
    });

    test('配置 fallback 时主模型失败后切换到 fallback', () async {
      final mainProvider = _MockAIProvider();
      // 主模型连续 4 次都失败（> maxRetries=3）
      for (int i = 0; i < 4; i++) {
        mainProvider.enqueueError(DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/test'),
          message: 'main model down',
        ));
      }
      // fallback 模型正常返回（含 finish 关键词）
      final fallbackProvider = _MockAIProvider();
      fallbackProvider.enqueueStream(['思考: done\n动作: finish\n']);
      final engine = makeEngine(
        provider: mainProvider,
        fallbackProvider: fallbackProvider,
        fallbackConfig: _makeConfig(modelName: 'fallback-model'),
      );
      await engine.startTask('test goal', _MockExecutor());
      // 验证：fallback provider 被调用过
      expect(fallbackProvider.callCount, greaterThanOrEqualTo(1));
    });
  });
}
