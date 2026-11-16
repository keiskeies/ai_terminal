import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/software_guide.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/knowledge_service.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// knowledge_search 工具契约测试（WP4 / O6）
///
/// 覆盖：注册与作用域、query 必填校验、结果截断边界（单条 1500 / 总量 8000，
/// R8 恰好等于上限不截断）、无结果路径，以及 ReAct 文本 → 解析 → 工具分发 →
/// 观测的端到端链路（R9：组件单测通过不代表组装后可用）。
///
/// 本文件不 mock path_provider：KnowledgeService.init() 在测试环境必然失败
/// （平台通道缺失），searchKnowledge 优雅降级为空列表 —— 正好驱动"未命中"路径。
/// 真实检索路径见 knowledge_search_service_test.dart。

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
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
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

const String _finishTurn = '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

/// 构造一条备注长度为 [notesLen] 的条目（其余字段固定，便于精确计算截断边界）
KnowledgeSearchEntry _entryWithNotes(int notesLen, {bool user = false}) =>
    KnowledgeSearchEntry(
      guide: SoftwareGuide(
        softwareName: 'x',
        opType: 'install',
        notes: 'a' * notesLen,
      ),
      score: 1.0,
      isUserExperience: user,
    );

/// 单条目格式化后的条目正文（去掉头部行）
String _singleEntryText(int notesLen) {
  final out =
      KnowledgeSearchTool.formatEntries('q', [_entryWithNotes(notesLen)]);
  const header = '知识库检索 "q"：命中 1 条\n';
  expect(out.startsWith(header), isTrue);
  return out.substring(header.length);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('注册与契约', () {
    test('本地与 SSH 会话都可见，只读免确认、不进变更台账', () {
      final registry = AgentToolRegistry();
      expect(
        registry.visibleFor(isLocalSession: true).map((t) => t.name),
        contains('knowledge_search'),
      );
      expect(
        registry.visibleFor(isLocalSession: false).map((t) => t.name),
        contains('knowledge_search'),
      );
      final tool = registry.get('knowledge_search')!;
      expect(tool.kind, ToolKind.read);
      expect(tool.isReadOnly, isTrue);
      expect(tool.recordsChanges, isFalse);
      expect(registry.isChangeRecordingTool('knowledge_search'), isFalse);
    });

    test('paramSpec 是多行 key:value 形状，FC schema 声明 query 必填', () {
      final tool = KnowledgeSearchTool();
      expect(tool.paramSpec.trim().startsWith('{'), isFalse);
      expect(tool.paramSpec, contains('query'));
      final schema = tool.toJsonSchema()!;
      expect(schema['required'], contains('query'));
      final props = schema['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(['query', 'platform']));
    });

    test('描述写明中途检索场景（使用指引在工具描述里，不改 prompts）', () {
      final tool = KnowledgeSearchTool();
      expect(tool.description, contains('安装'));
      expect(tool.description, contains('排障'));
      expect(tool.description, contains('web_search'));
    });
  });

  group('参数校验', () {
    test('query 缺失抛 ToolArgException（engine 转成失败观测）', () async {
      final tool = KnowledgeSearchTool();
      await expectLater(
        tool.execute(executor: _MockExecutor(), args: const ToolArgs({})),
        throwsA(isA<ToolArgException>()),
      );
    });

    test('query 全空白同样拒绝', () async {
      final tool = KnowledgeSearchTool();
      await expectLater(
        tool.execute(
          executor: _MockExecutor(),
          args: const ToolArgs({'query': '   '}),
        ),
        throwsA(isA<ToolArgException>()),
      );
    });
  });

  group('截断边界（R8）', () {
    test('单条恰好 1500 字符不截断', () {
      // 先测出固定字段的开销，再反推恰好填满上限所需的备注长度
      final overhead = _singleEntryText(1).length - 1;
      final text = _singleEntryText(1500 - overhead);
      expect(text.length, KnowledgeSearchTool.maxEntryChars);
      expect(text, isNot(contains('本条已截断')));
    });

    test('单条超过 1500 字符截断并标注，结果不超过上限', () {
      final overhead = _singleEntryText(1).length - 1;
      final text = _singleEntryText(1500 - overhead + 1);
      expect(text.length, lessThanOrEqualTo(KnowledgeSearchTool.maxEntryChars));
      expect(text, contains('本条已截断'));
      expect(text, contains('原文共'));
    });

    test('总量恰好 8000 字符不截断', () {
      final overhead = _singleEntryText(1).length - 1;
      final entries =
          List.generate(5, (_) => _entryWithNotes(1500 - overhead));
      final base = KnowledgeSearchTool.formatEntries('q', entries);
      // 头部行含 query 原文：加长 query 把总长精确推到 8000
      final query = 'q${'a' * (8000 - base.length)}';
      final out = KnowledgeSearchTool.formatEntries(query, entries);
      expect(out.length, KnowledgeSearchTool.maxTotalChars);
      expect(out, isNot(contains('总量超限')));
    });

    test('总量超过 8000 字符截断并标注，结果不超过上限', () {
      final overhead = _singleEntryText(1).length - 1;
      final entries =
          List.generate(5, (_) => _entryWithNotes(1500 - overhead));
      final base = KnowledgeSearchTool.formatEntries('q', entries);
      final query = 'q${'a' * (8000 - base.length + 1)}';
      final out = KnowledgeSearchTool.formatEntries(query, entries);
      expect(out.length, lessThanOrEqualTo(KnowledgeSearchTool.maxTotalChars));
      expect(out, contains('总量超限'));
    });

    test('大量长条目：双层截断后总量仍有硬上限', () {
      final entries = List.generate(10, (_) => _entryWithNotes(5000));
      final out = KnowledgeSearchTool.formatEntries('docker', entries);
      expect(out.length, lessThanOrEqualTo(KnowledgeSearchTool.maxTotalChars));
      expect(out, contains('本条已截断'));
      expect(out, contains('总量超限'));
    });

    test('用户经验与官方库来源标注', () {
      final out = KnowledgeSearchTool.formatEntries('q', [
        _entryWithNotes(10, user: true),
        _entryWithNotes(10),
      ]);
      expect(out, contains('本机验证经验'));
      expect(out, contains('官方知识库'));
    });
  });

  group('无结果路径', () {
    test('知识库未初始化/未命中时返回明确的未命中文本（success）', () async {
      // 测试环境无 path_provider mock，init 失败 → searchKnowledge 返回空
      final result = await KnowledgeSearchTool().execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'query': 'docker'}),
      );
      expect(result.success, isTrue);
      expect(result.output, contains('未命中'));
      expect(result.output, contains('web_search'));
    });

    test('取消令牌已完成时不检索，直接失败', () async {
      final ct = Completer<void>()..complete();
      final tool = KnowledgeSearchTool()..cancelToken = ct;
      final result = await tool.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'query': 'docker'}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('取消'));
    });
  });

  group('ReAct 端到端（R9：文本 → 解析 → 分发 → 观测）', () {
    test('模型按多行 key:value 调用 knowledge_search，观测回传未命中文本', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 需要 docker 安装指引\n动作: tool\n工具: knowledge_search\n参数:\n  query: docker\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('查 docker 安装指引', _MockExecutor());

      final result = events.firstWhere(
        (e) => e.isResult && e.toolName == 'knowledge_search',
      );
      expect(result.success, isTrue);
      expect(result.output, contains('未命中'));
      // 第二轮请求必须带上工具观测，AI 才知道检索结果
      expect(
        provider.receivedHistories.last
            .any((m) => m.content.contains('知识库未命中')),
        isTrue,
      );
    });

    test('query 缺失时引擎把 ToolArgException 转成失败观测', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 查知识库\n动作: tool\n工具: knowledge_search\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('查知识库', _MockExecutor());

      final result = events.firstWhere(
        (e) => e.isResult && e.toolName == 'knowledge_search',
      );
      expect(result.success, isFalse);
      expect(result.error, contains('query'));
      expect(
        provider.receivedHistories.last
            .any((m) => m.content.contains('缺少必填参数')),
        isTrue,
      );
    });

    test('只读模式放行 knowledge_search（只读免确认）', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 需要安装指引\n动作: tool\n工具: knowledge_search\n参数:\n  query: docker\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      engine.setPermissionMode(AgentPermissionMode.readOnly);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('查安装指引', _MockExecutor());

      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('只读模式')),
        isFalse,
        reason: '只读工具不该被拦',
      );
      expect(
        events.any((e) => e.isResult && e.toolName == 'knowledge_search'),
        isTrue,
      );
    });
  });
}