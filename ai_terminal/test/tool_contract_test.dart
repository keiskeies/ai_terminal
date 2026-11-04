import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/agent_host_registry.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// 最小 mock executor：既不是 SSHService 也不是 LocalTerminalService，
/// 用于驱动引擎走到工具分发那一步（工具本身会在 mock 环境下失败，但我们只关心门禁）。
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
  int callCount = 0;

  void enqueueStream(List<String> chunks) => _responses.add(chunks);

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
  }) async {
    callCount++;
    receivedHistories.add(List.from(history));
    if (_responses.isEmpty) {
      throw StateError('No enqueued response. callCount=$callCount');
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

const String _finishTurn =
    '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('ToolArgs 类型化访问', () {
    test('getString 兼容 List 与标量', () {
      const args = ToolArgs({'path': '/etc/hosts', 'hostIds': ['a', 'b']});
      expect(args.getString('path'), '/etc/hosts');
      expect(args.getString('hostIds'), 'a,b');
      expect(args.getString('missing'), '');
      expect(args.getString('missing', defaultValue: 'd'), 'd');
    });

    test('requireString 缺失或全空白时抛 ToolArgException', () {
      const args = ToolArgs({'path': '  '});
      expect(() => args.requireString('path'), throwsA(isA<ToolArgException>()));
      expect(() => args.requireString('nope'), throwsA(isA<ToolArgException>()));
      expect(const ToolArgs({'path': '/x'}).requireString('path'), '/x');
    });

    test('getStringList 处理 List / 逗号 / 方括号 / 中文逗号', () {
      expect(const ToolArgs({'h': ['a', 'b']}).getStringList('h'), ['a', 'b']);
      expect(const ToolArgs({'h': 'a,b'}).getStringList('h'), ['a', 'b']);
      // AI 常把列表写成 JSON 数组字面量；早期实现会得到 ['[a', ' b]']
      expect(const ToolArgs({'h': '[a, b]'}).getStringList('h'), ['a', 'b']);
      expect(const ToolArgs({'h': 'a，b'}).getStringList('h'), ['a', 'b']);
      expect(const ToolArgs({}).getStringList('h', defaultValue: ['z']), ['z']);
    });

    test('getBool / getInt 处理字符串形式', () {
      const args = ToolArgs({'r': 'true', 'n': '30', 'b': true, 'm': 7});
      expect(args.getBool('r'), isTrue);
      expect(args.getBool('b'), isTrue);
      expect(args.getBool('missing'), isFalse);
      expect(args.getInt('n'), 30);
      expect(args.getInt('m'), 7);
      expect(args.getInt('missing', defaultValue: 5), 5);
    });

    test('firstOf 按顺序取第一个非空键', () {
      const args = ToolArgs({'remoteDir': '/r'});
      expect(args.firstOf(const ['remote', 'remoteDir']), '/r');
      expect(args.firstOf(const ['nope', 'nope2'], defaultValue: 'x'), 'x');
    });

    test('has 与 containsKey 的差别是空值', () {
      const args = ToolArgs({'content': ''});
      expect(args.containsKey('content'), isTrue,
          reason: 'file_write 靠这个区分"没写"和"写了空值"');
      expect(args.has('content'), isFalse);
    });

    test('describe 截断长值，避免把整个文件内容打进日志', () {
      final args = ToolArgs({'content': 'x' * 200});
      final text = args.describe(maxValueChars: 10);
      expect(text, contains('xxxxxxxxxx'));
      expect(text, contains('(200 字符)'));
      expect(text.length, lessThan(60));
      expect(const ToolArgs({}).describe(), '(无参数)');
    });
  });

  group('注册表作用域与 kind 派生', () {
    test('本地项目工具只在本地会话可见（修 D1）', () {
      final registry = AgentToolRegistry();
      final local = registry.visibleFor(isLocalSession: true).map((t) => t.name);
      final ssh = registry.visibleFor(isLocalSession: false).map((t) => t.name);
      expect(local, containsAll(['project_analyze', 'build_project', 'package_project']));
      for (final name in ['project_analyze', 'build_project', 'package_project']) {
        expect(ssh, isNot(contains(name)), reason: '$name 要求本地 executor，SSH 会话不该看到');
      }
    });

    test('台账集合由 kind 派生，不靠工具名清单（修 F8）', () {
      final registry = AgentToolRegistry();
      expect(registry.isChangeRecordingTool('file_write'), isTrue);
      expect(registry.isChangeRecordingTool('file_patch'), isTrue);
      expect(registry.isChangeRecordingTool('sftp_upload'), isTrue);
      expect(registry.isChangeRecordingTool('cert_check'), isFalse);
      expect(registry.isChangeRecordingTool('unknown_tool'), isFalse);
      // 构建/打包改的是产物目录，不产生可回滚的文件级变更
      expect(registry.get('build_project')!.kind, ToolKind.write);
      expect(registry.get('build_project')!.recordsChanges, isFalse);
    });

    test('mcpDescriptor 暴露 MCP 形状的注解', () {
      final registry = AgentToolRegistry();
      final d = registry.get('cert_check')!.mcpDescriptor;
      expect(d['name'], 'cert_check');
      expect(d, contains('inputSchema'));
      final annotations = d['annotations'] as Map<String, dynamic>;
      expect(annotations['readOnlyHint'], isTrue);
      expect(annotations['destructiveHint'], isFalse);
    });

    test('每个已注册工具的 mcpDescriptor 都是合法 MCP 形状', () {
      // "预留 MCP 接口"是用户定的范围决定：将来接外部 server 不该再改契约。
      // 只测一个工具等于没测 —— 新工具忘了写 schema、或 toJsonSchema 返回 null，
      // 都会让描述符变成 MCP 客户端拒收的形状。
      final registry = AgentToolRegistry()
        ..enableWebTools()
        // 编排工具（exec_on / exec_batch / broadcast_upload …）是这批里最危险的，
        // 不开就等于不验。AgentHostRegistry 无参可构造，注册它们不需要真连接。
        ..enableOrchestrator(AgentHostRegistry());
      final tools = registry.all;
      expect(tools.length, greaterThan(20),
          reason: '默认 + 联网 + 编排应覆盖全部内置工具，太少说明遍历没生效');

      for (final tool in tools) {
        final d = tool.mcpDescriptor;
        expect(d['name'], tool.name, reason: '${tool.name} name 不一致');
        expect((d['description'] as String).trim().isNotEmpty, isTrue,
            reason: '${tool.name} 描述为空，外部 client 无从选择');

        final schema = d['inputSchema'];
        expect(schema, isA<Map<String, dynamic>>(),
            reason: '${tool.name} 的 inputSchema 必须是对象，MCP 不接受 null');
        expect((schema as Map)['type'], 'object');
        expect(schema['properties'], isA<Map>());

        final a = d['annotations'] as Map<String, dynamic>;
        expect(a.keys,
            containsAll(['readOnlyHint', 'destructiveHint', 'openWorldHint']));
        expect(a['readOnlyHint'], tool.kind == ToolKind.read);
        expect(a['destructiveHint'], tool.kind == ToolKind.destructive);
        expect(a['openWorldHint'], tool.kind == ToolKind.network);
        expect(
          (a['readOnlyHint'] == true) && (a['destructiveHint'] == true),
          isFalse,
          reason: '${tool.name} 不可能既只读又具破坏性',
        );
      }
    });

    test('没有任何工具的 paramSpec 用 JSON 形状', () {
      // D2 的病灶就是提示词里教 JSON：文本协议下 AI 会照抄，而参数块的主格式是
      // 多行 key:value。解析器虽能兜住 `{`，但 26 个工具里 3 个教 JSON，
      // 就是在教模型两套互相冲突的调用格式。
      final registry = AgentToolRegistry()
        ..enableWebTools()
        ..enableOrchestrator(AgentHostRegistry());
      for (final tool in registry.all) {
        final spec = tool.paramSpec.trim();
        expect(spec.isEmpty, isFalse, reason: '${tool.name} 没有参数说明');
        expect(spec.startsWith('{'), isFalse,
            reason: '${tool.name} 的 paramSpec 仍是 JSON 形状，'
                '应改成"参数列表（多行 key:value 格式）"');
      }
    });

    test('不参与 FC 的工具（toJsonSchema 返回 null）仍给出合法描述符', () async {
      final d = _NullSchemaTool().mcpDescriptor;
      final schema = d['inputSchema'];
      expect(schema, isA<Map<String, dynamic>>());
      expect(schema['type'], 'object');
      expect(schema['additionalProperties'], isTrue);
      // paramSpec 不能丢：那是唯一还能告诉客户端怎么调参数的东西
      expect(schema['description'], contains('path'));
    });
  });

  group('system prompt 与注册表一致性（D1/D2 回归守卫）', () {
    test('提示词里出现的每个工具名都已注册', () {
      final engine = AgentEngine(
        aiProvider: _MockAIProvider(),
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      final registry = engine.toolsForTesting;
      final visibleLocal =
          registry.visibleFor(isLocalSession: true).map((t) => t.name).toSet();

      for (final isLocal in [true, false]) {
        final prompt = engine.buildSystemPromptForTesting(_MockExecutor());
        final mentioned = RegExp(r'工具: ([a-z_]+)')
            .allMatches(prompt)
            .map((m) => m.group(1)!)
            .toSet();
        expect(mentioned, isNotEmpty, reason: '提示词应至少列出工具');
        for (final name in mentioned) {
          expect(registry.has(name), isTrue,
              reason: '提示词宣传了未注册的工具 $name —— AI 照做必然撞未知工具');
        }
        // 本地会话判据：mock executor 非 SSH，因此按 local 过滤
        if (isLocal) {
          expect(mentioned.difference(visibleLocal), isEmpty);
        }
      }
    });

    test('部署工作流的参数示例必须是多行 key:value，不能是 JSON', () {
      final engine = AgentEngine(
        aiProvider: _MockAIProvider(),
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      final prompt = engine.buildSystemPromptForTesting(_MockExecutor());
      expect(prompt, contains('【本地项目部署工作流】'));
      expect(RegExp(r'参数: \{').hasMatch(prompt), isFalse,
          reason: 'parser 明确拒绝 JSON 参数，示例不能教 AI 那么写');
      expect(prompt, contains('  artifact_dir: build/web'));
    });
  });

  group('只读模式拦截工具（D3）', () {
    test('只读模式下写入类工具被拒绝执行，且回带观测', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 需要写配置文件\n动作: tool\n工具: file_patch\n参数:\n  path: /etc/hosts\n  old: a\n  new: b\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      engine.setReadOnlyMode(true);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('改 hosts', _MockExecutor());

      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('只读模式')),
        isTrue,
        reason: '必须给用户一条只读拦截提示',
      );
      expect(
        events.where((e) => e.isResult).map((e) => e.toolName),
        isNot(contains('file_patch')),
        reason: '只读模式下工具不得真正执行',
      );
      // 第二轮请求必须带上"只读模式"观测，AI 才知道要改 finish
      final secondHistory = provider.receivedHistories.last;
      expect(
        secondHistory.any((m) => m.content.contains('当前为只读模式')),
        isTrue,
      );
    });

    test('只读模式放行只读工具', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 先看证书\n动作: tool\n工具: cert_check\n参数:\n  mode: ssh_hostkey\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );
      engine.setReadOnlyMode(true);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('查证书', _MockExecutor());

      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('只读模式')),
        isFalse,
        reason: '只读工具不该被拦',
      );
      expect(events.any((e) => e.isCommand && e.toolName == 'cert_check'), isTrue);
    });
  });

  group('破坏性工具确认通道', () {
    test('local_file_delete 必须等用户确认，拒绝时不执行', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 删掉临时文件\n动作: tool\n工具: local_file_delete\n参数:\n  path: /tmp/x.txt\n',
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

      final running = engine.startTask('删文件', _MockExecutor());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(engine.hasPendingConfirm, isTrue,
          reason: 'destructive 工具必须停在确认上，不能自己跑过去');
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('需要确认')),
        isTrue,
      );
      expect(
        events.where((e) => e.isResult).map((e) => e.toolName),
        isNot(contains('local_file_delete')),
        reason: '等待确认期间不得产生执行结果',
      );

      engine.rejectDangerousCommand();
      await running;

      final rejected = events.firstWhere(
        (e) => e.isResult && e.toolName == 'local_file_delete',
      );
      expect(rejected.success, isFalse);
      expect(rejected.error, contains('拒绝'));
      expect(
        provider.receivedHistories.last.any((m) => m.content.contains('用户拒绝执行')),
        isTrue,
        reason: 'AI 必须收到"用户拒绝"的观测，否则会反复重试同一次删除',
      );
    });

    test('用户确认后工具才真正执行', () async {
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 删掉临时文件\n动作: tool\n工具: local_file_delete\n参数:\n  path: /tmp/x.txt\n',
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
      AgentTask? lastTask;
      engine.onTaskUpdated = (t) => lastTask = t;

      final running = engine.startTask('删文件', _MockExecutor());
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      expect(engine.hasPendingConfirm, isTrue);

      // 真的多等 1.1 秒再放行：等待时长必须被累计（tok/s 的分母要减掉它）
      await Future.delayed(const Duration(milliseconds: 1100));
      engine.confirmDangerousCommand();
      await running;

      expect(engine.confirmWaitSecondsForTesting, greaterThanOrEqualTo(1),
          reason: '破坏性工具确认的等待没有累计进计量');
      expect(lastTask?.confirmWaitSeconds, greaterThanOrEqualTo(1),
          reason: '等待秒数没写进任务，指标带就拿不到、扣不了分母');

      final result = events.firstWhere(
        (e) => e.isResult && e.toolName == 'local_file_delete',
      );
      // 本地文件访问默认未授权，所以执行了但被策略拒绝 —— 重点是"确实执行过"
      expect(result.success, isFalse);
      expect(result.error, isNot(contains('拒绝执行该操作')));
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('需要确认')),
        isTrue,
      );
    });
  });

  group('暂停/恢复不得丢弃等待中的 awaiter（R1）', () {
    test('等确认时暂停再恢复，旧的确认等待要被唤醒而不是被丢弃', () async {
      // 走查顺序：pauseTask 明确接受 waitingConfirm 状态，而 resumeTask 开头调
      // _resetTransientState —— 后者原本只是 `_confirmCompleter = null`。
      // 于是"破坏性工具等确认 → 点暂停 → 点恢复"会让那一轮的 await 永远醒不过来，
      // result/finish 事件不再发出，任务永久挂死（R1 的头号挂死模式）。
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 要删本机文件\n动作: tool\n工具: local_file_delete\n参数:\n  path: D:\\x\\a.txt\n',
      ]);
      provider.enqueueStream([_finishTurn]);

      final engine = AgentEngine(
        aiProvider: provider,
        modelConfig: _makeConfig(),
        memory: AgentMemory(),
        maxSteps: 5,
        hostId: 'test-host',
      );

      // 破坏性工具会挂在用户确认上，所以不能 await
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final task = engine.startTask('删掉本机文件', _MockExecutor());
      await pumpEventQueue();
      expect(engine.hasPendingConfirm, isTrue,
          reason: '前置条件：任务确实停在等待确认');

      final pending = engine.pendingConfirmForTesting!;
      engine.pauseTask();
      expect(engine.isPaused, isTrue);

      await engine.resumeTask(_MockExecutor());
      await pumpEventQueue();

      expect(pending.isCompleted, isTrue,
          reason: 'R1：置 null 之前必须 complete，否则旧 await 永久挂死');
      // Completer 没有 .value，只能从 future 读；此时已完成，不会挂住
      expect(await pending.future, isFalse,
          reason: '被重置的确认一律按"未批准"收口，绝不能默认放行破坏性操作');

      // 收口成 false 不能被写成"用户拒绝了"：用户只是点了暂停。
      // 这依赖一个顺序 —— resumeTask 里 generation++ 与重置同帧完成，而 await 的
      // 续体在之后的微任务里跑，所以旧循环先在代际检查处静默退出。顺序一旦被
      // 重排，历史里就会出现一句用户从未做过的拒绝（V3 的同型问题）。
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('用户拒绝执行此操作')),
        isFalse,
        reason: '暂停/恢复不得伪造"用户拒绝执行此操作"',
      );
      expect(
        events.where((e) => e.isResult).map((e) => e.error),
        isNot(contains('用户拒绝执行该操作')),
      );

      engine.cancelTask();
      await Future.any([task, Future.delayed(const Duration(seconds: 2))]);
    });

    test('确认超时不得写成用户拒绝', () async {
      // 10 分钟没人点 = 系统行为。写成"用户拒绝执行此操作"会在历史里留下一件
      // 用户从没做过的事，还会让模型以为被否决而不再重试。
      final provider = _MockAIProvider();
      provider.enqueueStream([
        '思考: 要删本机文件\n动作: tool\n工具: local_file_delete\n参数:\n  path: D:\\x\\a.txt\n',
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

      final task = engine.startTask('删掉本机文件', _MockExecutor());
      await pumpEventQueue();
      expect(engine.hasPendingConfirm, isTrue);

      engine.expireConfirmTimeoutForTesting('local_file_delete');
      await pumpEventQueue();

      final info =
          events.where((e) => e.isInfo).map((e) => e.text ?? '').join('\n');
      expect(info, contains('超时'));
      expect(info, isNot(contains('用户拒绝')),
          reason: '超时不是拒绝，归因错了用户会在历史里看到自己没做过的事');
      final result = events.lastWhere((e) => e.isResult);
      expect(result.error, contains('超时'));

      engine.cancelTask();
      await Future.any([task, Future.delayed(const Duration(seconds: 2))]);
    });
  });

  group('provide_password', () {
    test('SSH 与本地会话都可见，且不进变更台账', () {
      final registry = AgentToolRegistry();
      expect(
        registry.visibleFor(isLocalSession: true).map((t) => t.name),
        contains('provide_password'),
      );
      expect(
        registry.visibleFor(isLocalSession: false).map((t) => t.name),
        contains('provide_password'),
      );
      // 特权密码是本机凭据，不是主机上的文件变更；进台账只会在审计列表里
      // 多出一条敏感记录，而且根本没有回滚语义
      expect(registry.isChangeRecordingTool('provide_password'), isFalse);
    });

    test('成功后引导 AI 重试原命令，而不是自己处理密码', () async {
      final tool = ProvidePasswordTool()
        ..sudoPasswordRequest = (reason) async => true;
      final result = await tool.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'reason': 'sudo apt update 需要特权密码'}),
      );
      expect(result.success, isTrue);
      expect(result.output, contains('重试'));
      expect(result.output, contains('自动应答'));
    });

    test('未接入 UI 回调时失败并指向配置入口', () async {
      final result = await ProvidePasswordTool().execute(
        executor: _MockExecutor(),
        args: const ToolArgs({}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('sudo 密码'));
    });

    test('用户取消时把决定权交回用户，而不是让 AI 硬重试', () async {
      final tool = ProvidePasswordTool()
        ..sudoPasswordRequest = (reason) async => false;
      final result = await tool.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('ask'));
    });
  });
}

/// 只用来验证描述符形状：它故意不参与 Function Calling
class _NullSchemaTool extends AgentTool {
  @override
  String get name => 'null_schema_tool';

  @override
  String get description => '仅测试用工具';

  @override
  String get paramSpec => '  path: 文件路径（必填）';

  @override
  Map<String, dynamic>? toJsonSchema() => null;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async =>
      ToolResult.success('ok');
}

