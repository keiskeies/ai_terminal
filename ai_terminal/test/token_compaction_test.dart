import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// O7 token 化压缩测试：token 阈值、滚动摘要、pinned 事实、旧数据兼容。
///
/// provider 路径与 agent_steering_provider_test 同口径：DbInit 未初始化，
/// 落库失败必须 surface（R8）；内存缓存层的压缩结果仍可断言。

/// 按脚本应答的 AI provider：String → 分两块流式返回；Exception → 抛出。
/// 记录每次收到的 prompt，供断言滚动合并输入。
class _ScriptedAIProvider implements AIProvider {
  _ScriptedAIProvider(this.responses);

  final List<Object> responses;
  final List<String> prompts = [];
  int calls = 0;

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
    prompts.add(prompt);
    final r = responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (r is Exception) throw r;
    final text = r as String;
    final mid = text.length ~/ 2;
    return Stream.fromIterable([text.substring(0, mid), text.substring(mid)]);
  }
}

AIModelConfig _makeConfig() => AIModelConfig.create(
      id: 'test',
      provider: 'openai',
      name: 'Test Model',
      apiKey: 'test-key',
      baseUrl: 'https://test.example.com/v1',
      modelName: 'test-model',
      maxTokens: 4096,
      contextWindow: 0,
    );

AgentEngine _makeEngine(AIProvider ai) => AgentEngine(
      aiProvider: ai,
      modelConfig: _makeConfig(),
      memory: AgentMemory(),
      hostId: 'h-comp',
    );

Conversation _makeConv(int messageCount, {String content = '你好'}) {
  final conv = Conversation.create(id: 'c-comp', hostId: 'h-comp', title: 't');
  for (int i = 0; i < messageCount; i++) {
    conv.addMessage(ConvMessage.create(
      role: i.isEven ? 'user' : 'assistant',
      content: '$content $i',
    ));
  }
  return conv;
}

class _TestNotifier extends AgentNotifier {
  void setStateForTest(AgentState s) {
    state = s;
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('Conversation token 口径', () {
    test('同字符数中英文 token 估算差 3 倍以上（字符阈值的病灶）', () {
      final cjk = Conversation.create(id: 'a', hostId: 'h', title: 't')
        ..addMessage(ConvMessage.create(role: 'user', content: '中' * 4000));
      final ascii = Conversation.create(id: 'b', hostId: 'h', title: 't')
        ..addMessage(ConvMessage.create(role: 'user', content: 'a' * 4000));
      expect(cjk.totalTokens, greaterThan(ascii.totalTokens * 3));
    });

    test('rolledUp 消息不计入 token，滚动摘要只计一次', () {
      final conv = _makeConv(4, content: 'x' * 400);
      final before = conv.totalTokens;
      conv.messages[0].rolledUp = true;
      conv.messages[1].rolledUp = true;
      conv.rollingSummary = '摘要' * 10;
      final after = conv.totalTokens;
      expect(after, lessThan(before));
      // 剩余 2 条原文 + 1 条摘要消息（各 +4 结构开销）
      expect(after, greaterThan(200));
    });

    test('needsCompaction：中文内容按 token 提前触发，英文同字符数不触发', () {
      final cjk = _makeConv(2, content: '中' * 150);
      final ascii = _makeConv(2, content: 'a' * 150);
      expect(
          cjk.needsCompaction(tokenThreshold: 200, roundThreshold: 999), isTrue);
      expect(
          ascii.needsCompaction(tokenThreshold: 200, roundThreshold: 999), isFalse);
    });

    test('needsCompaction：轮次阈值仍生效，rolledUp 与旧摘要不计轮次', () {
      final conv = _makeConv(40);
      expect(
          conv.needsCompaction(tokenThreshold: 1 << 30, roundThreshold: 20), isTrue);
      for (final m in conv.messages) {
        m.rolledUp = true;
      }
      expect(
          conv.needsCompaction(tokenThreshold: 1 << 30, roundThreshold: 20), isFalse);
      final legacy = _makeConv(40);
      for (final m in legacy.messages) {
        m.summary = '旧摘要';
      }
      expect(
          legacy.needsCompaction(tokenThreshold: 1 << 30, roundThreshold: 20),
          isFalse);
    });
  });

  group('buildAiHistory 重建口径', () {
    test('滚动摘要注入首条，rolledUp 跳过，system 跳过', () {
      final conv = _makeConv(4);
      conv.messages.insert(
          0, ConvMessage.create(role: 'system', content: '系统提示'));
      conv.rollingSummary = '【关键事实】\n- Ubuntu 22.04';
      conv.messages[1].rolledUp = true;
      conv.messages[2].rolledUp = true;
      final history = conv.buildAiHistory();
      expect(history.length, 3);
      expect(history.first.role, 'user');
      expect(history.first.content, contains('【早期对话摘要】'));
      expect(history.first.content, contains('Ubuntu 22.04'));
      expect(history[1].content, '你好 2');
      expect(history[2].content, '你好 3');
    });

    test('旧逐条 summary 兼容：未 rolledUp 的消息用 effectiveContent', () {
      final conv = _makeConv(2);
      conv.messages[0].summary = '早期压缩摘要';
      final history = conv.buildAiHistory();
      expect(history[0].content, '早期压缩摘要');
      expect(history[1].content, '你好 1');
    });

    test('无摘要时与旧行为一致：全部非 system 原文', () {
      final conv = _makeConv(3);
      final history = conv.buildAiHistory();
      expect(history.length, 3);
      expect(history.every((m) => m.content.startsWith('你好')), isTrue);
    });

    test('rolledUp 默认 false，create 可显式指定', () {
      expect(ConvMessage.create(role: 'user', content: 'x').rolledUp, isFalse);
      expect(
          ConvMessage.create(role: 'user', content: 'x', rolledUp: true).rolledUp,
          isTrue);
    });
  });

  group('AgentEngine.summarizeRolling', () {
    test('空输入不调 AI 直接返回 null', () async {
      final ai = _ScriptedAIProvider(['x']);
      final engine = _makeEngine(ai);
      expect(await engine.summarizeRolling(messages: []), isNull);
      expect(ai.calls, 0);
      engine.cancelTask();
    });

    test('prompt 携带已有摘要与 pinned 规则，输出整体摘要', () async {
      final ai = _ScriptedAIProvider(
          ['【关键事实】\n- Ubuntu 22.04\n【对话进展】\n- 已安装 nginx']);
      final engine = _makeEngine(ai);
      final result = await engine.summarizeRolling(
        previousSummary: '【关键事实】\n- 主机名 web1',
        messages: [
          (role: 'user', content: '装 nginx', command: null, commandSuccess: null),
          (
            role: 'assistant',
            content: '完成',
            command: 'apt install nginx',
            commandSuccess: true
          ),
        ],
      );
      expect(result, contains('Ubuntu 22.04'));
      expect(ai.prompts.single, contains('主机名 web1'));
      expect(ai.prompts.single, contains('【关键事实】'));
      expect(ai.prompts.single, contains('逐字保留'));
      expect(ai.prompts.single, contains('apt install nginx'));
      expect(ai.prompts.single, contains('成功'));
      engine.cancelTask();
    });

    test('首次压缩无已有摘要时标注（无，首次压缩）', () async {
      final ai = _ScriptedAIProvider(['摘要']);
      final engine = _makeEngine(ai);
      await engine.summarizeRolling(messages: [
        (role: 'user', content: 'x', command: null, commandSuccess: null),
      ]);
      expect(ai.prompts.single, contains('首次压缩'));
      engine.cancelTask();
    });

    test('去掉 markdown 代码块包裹', () async {
      final ai = _ScriptedAIProvider(['```\n【关键事实】\n- x\n```']);
      final engine = _makeEngine(ai);
      final result = await engine.summarizeRolling(messages: [
        (role: 'user', content: 'x', command: null, commandSuccess: null),
      ]);
      expect(result, '【关键事实】\n- x');
      engine.cancelTask();
    });

    test('超发摘要截断到 4000 字符硬上限（保头，pinned 段在开头）', () async {
      final ai = _ScriptedAIProvider(['【关键事实】${'长' * 5000}']);
      final engine = _makeEngine(ai);
      final result = await engine.summarizeRolling(messages: [
        (role: 'user', content: 'x', command: null, commandSuccess: null),
      ]);
      expect(result!.length, 4000);
      expect(result, startsWith('【关键事实】'));
      engine.cancelTask();
    });

    test('AI 返回空 → null；AI 抛错 → null（调用方保持原状）', () async {
      final empty = _makeEngine(_ScriptedAIProvider(['   ']));
      expect(
          await empty.summarizeRolling(messages: [
            (role: 'user', content: 'x', command: null, commandSuccess: null),
          ]),
          isNull);
      empty.cancelTask();
      final broken = _makeEngine(_ScriptedAIProvider([Exception('网络错误')]));
      expect(
          await broken.summarizeRolling(messages: [
            (role: 'user', content: 'x', command: null, commandSuccess: null),
          ]),
          isNull);
      broken.cancelTask();
    });
  });

  group('AgentNotifier.compact 滚动压缩', () {
    late _TestNotifier notifier;
    late _ScriptedAIProvider ai;
    late Conversation conv;

    setUp(() {
      ai = _ScriptedAIProvider(['【关键事实】\n- Ubuntu 22.04\n【对话进展】\n- 已装 nginx']);
      notifier = _TestNotifier();
      notifier.switchTab('t-comp', hostId: 'h-comp');
      notifier.init(modelConfig: _makeConfig(), aiProvider: ai);
      conv = _makeConv(20);
      ConversationsDao.cacheOnly(conv);
      notifier.setStateForTest(
          notifier.state.copyWith(conversationId: conv.id));
    });

    tearDown(() {
      notifier.dispose();
    });

    test('成功压缩：滚动摘要写入 + 早期消息标记 rolledUp + 最近 6 轮保留', () async {
      await notifier.compact('t-comp');
      expect(conv.rollingSummary, contains('Ubuntu 22.04'));
      // 20 条 - 保留 12 条 = 前 8 条被吸收
      for (int i = 0; i < 8; i++) {
        expect(conv.messages[i].rolledUp, isTrue, reason: '消息 $i 应被吸收');
      }
      for (int i = 8; i < 20; i++) {
        expect(conv.messages[i].rolledUp, isFalse, reason: '消息 $i 应保留原文');
      }
      expect(notifier.state.isCompacting, isFalse);
      // 测试环境无 DbInit：落库失败必须 surface（R8），不得静默
      expect(notifier.state.error, isNotNull);
    });

    test('二次压缩把已有摘要传给 AI 滚动合并', () async {
      conv.rollingSummary = '【关键事实】\n- 主机名 web1';
      await notifier.compact('t-comp');
      expect(ai.prompts.last, contains('主机名 web1'));
      expect(conv.rollingSummary, contains('Ubuntu 22.04'));
    });

    test('AI 返回空：不标记、不写摘要、无错误残留', () async {
      final emptyAi = _ScriptedAIProvider(['']);
      notifier.init(modelConfig: _makeConfig(), aiProvider: emptyAi);
      await notifier.compact('t-comp');
      expect(conv.rollingSummary, isNull);
      expect(conv.messages.every((m) => !m.rolledUp), isTrue);
      expect(notifier.state.isCompacting, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('消息数不足保留窗口：不触发 AI', () async {
      final small = _makeConv(12);
      ConversationsDao.cacheOnly(small);
      notifier.setStateForTest(
          notifier.state.copyWith(conversationId: small.id));
      await notifier.compact('t-comp');
      expect(ai.calls, 0);
      expect(small.rollingSummary, isNull);
    });

    test('isCompacting 并发锁：压缩进行中再次调用直接返回', () async {
      notifier.setStateForTest(notifier.state.copyWith(isCompacting: true));
      await notifier.compact('t-comp');
      expect(ai.calls, 0);
    });

    test('旧逐条 summary 消息并入滚动摘要（输入用 effectiveContent）', () async {
      conv.messages[0].summary = '旧机制摘要内容';
      await notifier.compact('t-comp');
      expect(ai.prompts.last, contains('旧机制摘要内容'));
      expect(conv.messages[0].rolledUp, isTrue);
    });
  });
}