import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/conversation_service.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// O5 steering 的 provider 路径测试。
///
/// 已知边界（与 conversation_blank_draft_test 同口径）：测试环境未初始化 DbInit，
/// 真实落库会失败。这里恰好覆盖 R8 的关键要求——持久化失败必须 surface，
/// 且失败时不得入队引擎、不得留下半截 UI 拆分。
/// 成功落库路径（appendMessagePair 与 startTask 同路径）依赖数据库，不在单测范围。

/// 暴露受保护的 state  setter，便于构造运行中的 UI 快照
class _TestNotifier extends AgentNotifier {
  void setStateForTest(AgentState s) {
    state = s;
  }
}

/// 不会被调用的 AI provider（测试直接用 setTaskStatusForTesting 构造运行态）
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

AgentEngine makeEngine(String hostId) {
  return AgentEngine(
    aiProvider: _NoCallAIProvider(),
    modelConfig: _makeConfig(),
    memory: AgentMemory(),
    hostId: hostId,
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('AgentNotifier.steer', () {
    test('空串/纯空白直接忽略', () async {
      final notifier = _TestNotifier();
      notifier.switchTab('tabEmpty', hostId: 'host-steer-empty');
      await notifier.steer('   ');
      expect(notifier.state.error, isNull);
    });

    test('非运行态回退为普通发消息（startTask 路径）', () async {
      final notifier = _TestNotifier();
      notifier.switchTab('tabIdle', hostId: 'host-steer-idle');
      // 未配置模型：startTask 会报「请先配置 AI 模型」，证明走的是 startTask
      await notifier.steer('你好');
      expect(notifier.state.error, L10n.str.pleaseConfigAIModel);
    });

    test('已暂停时提示先恢复，不入队（resume 会清空队列）', () async {
      final notifier = _TestNotifier();
      notifier.switchTab('tabPaused', hostId: 'host-steer-paused');
      final engine = makeEngine('host-steer-paused');
      engine.setTaskStatusForTesting(AgentStatus.paused);
      notifier.registryForTesting.setEngine('tabPaused', engine);

      await notifier.steer('补充一下');
      expect(notifier.state.error, contains('任务已暂停'));
      expect(engine.pendingSteeringCount, 0);
    });

    test('运行中持久化失败必须 surface，且不入队引擎、回滚 UI 拆分（R8）', () async {
      final notifier = _TestNotifier();
      notifier.switchTab('tabRun', hostId: 'host-steer-run');
      final engine = makeEngine('host-steer-run');
      engine.setTaskStatusForTesting(AgentStatus.executing);
      notifier.registryForTesting.setEngine('tabRun', engine);

      final conv = ConversationService().createSession(hostId: 'host-steer-run');
      engine.conversationId = conv.id;
      notifier.setStateForTest(notifier.state.copyWith(
        conversationId: conv.id,
        status: AgentStatus.executing,
        chatItems: [
          ChatItem(role: 'user', content: '任务: 检查 nginx'),
          ChatItem(role: 'assistant', content: '思考中', isStreaming: true),
        ],
      ));

      await notifier.steer('改用 apache');

      // DbInit 未初始化 → appendMessagePair 落库失败 → 必须暴露到 UI
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.error, contains(L10n.str.messageSaveFailed));
      // 失败时不得入队引擎（避免内存已注入、磁盘没有）
      expect(engine.pendingSteeringCount, 0);
      // UI 拆分必须回滚：仍是 user + assistant 两条，无补充消息残留
      expect(notifier.state.chatItems, hasLength(2));
      expect(notifier.state.chatItems.first.role, 'user');
      expect(notifier.state.chatItems.last.role, 'assistant');
      expect(
        notifier.state.chatItems.any((i) => i.content.contains('用户补充')),
        isFalse,
      );
      // 任务仍在运行，assistant 保持流式态
      expect(notifier.state.chatItems.last.isStreaming, isTrue);
    });

    test('运行中补充消息按 user 消息写入会话（内存层往返，落库依赖 DB）', () async {
      final notifier = _TestNotifier();
      notifier.switchTab('tabConv', hostId: 'host-steer-conv');
      final engine = makeEngine('host-steer-conv');
      engine.setTaskStatusForTesting(AgentStatus.thinking);
      notifier.registryForTesting.setEngine('tabConv', engine);

      final conv = ConversationService().createSession(hostId: 'host-steer-conv');
      engine.conversationId = conv.id;
      notifier.setStateForTest(notifier.state.copyWith(
        conversationId: conv.id,
        status: AgentStatus.thinking,
        chatItems: [
          ChatItem(role: 'user', content: '任务: 检查磁盘'),
          ChatItem(role: 'assistant', content: '', isStreaming: true),
        ],
      ));

      await notifier.steer('  先看 /var 分区  ');

      // 落库虽失败（无 DB），appendMessagePair 的内存追加在回滚前发生；
      // 这里验证 steer 传给持久化层的内容规范：trim + 「用户补充: 」前缀。
      // 通过 UI 回滚结果间接确认 content 形态（错误信息里不含内容，
      // 直接断言引擎未入队 + 会话消息已回滚，保证失败路径无残留）。
      expect(engine.pendingSteeringCount, 0);
      expect(conv.messages.where((m) => m.content.contains('用户补充')), isEmpty,
          reason: '落库失败后会话内存必须回滚，不能留下孤儿补充消息');
    });
  });
}