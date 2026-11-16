import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// O8 FC-first 端到端测试（R9：流式/协议改动必须覆盖组装后的完整链路）。
///
/// 两层覆盖：
/// 1. Provider 层：真实 SSE 字节流（本地 HttpServer）→ ToolCallAccumulator →
///    onToolCalls 结构化投递 / 旧版 ReAct 文本投递，含跨包 arguments 拼接、
///    finish_reason 提前投递、无 [DONE] 兜底、不重复投递。
/// 2. 引擎层：结构化 tool_calls → 事件发射（去重）→ 动作执行 → 观测回注 →
///    finish/ask/多命令/混合调用/文本兜底/非 FC 回归/计划门控。

class _MockExecutor implements CommandExecutor {
  String stdout = 'ok';
  final List<String> executed = [];

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
  }) async {
    executed.add(command);
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

/// 脚本化 provider：文本轮 / FC 轮分别入队。
/// FC 轮在文本 chunk 发完后、流关闭前回调 onToolCalls，
/// 模拟真实网关 finish_reason='tool_calls' 先于 [DONE] 到达的时序。
class _FcMockProvider implements AIProvider {
  int callCount = 0;
  final List<Object> _responses = [];
  final List<List<ChatMessage>> receivedHistories = [];
  final List<List<Map<String, dynamic>>?> receivedTools = [];

  void enqueueText(List<String> chunks) => _responses.add(chunks);

  void enqueueFc(List<String> textChunks, List<ToolCall> calls) =>
      _responses.add((textChunks, calls));

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
    callCount++;
    receivedHistories.add(List.from(history));
    receivedTools.add(tools);
    if (_responses.isEmpty) {
      throw StateError('No enqueued response. callCount=$callCount');
    }
    final next = _responses.removeAt(0);
    if (next is List<String>) {
      return (() async* {
        for (final c in next) {
          yield c;
        }
      })();
    }
    if (next is (List<String>, List<ToolCall>)) {
      final (chunks, calls) = next;
      return (() async* {
        for (final c in chunks) {
          yield c;
        }
        if (calls.isNotEmpty) onToolCalls?.call(calls);
      })();
    }
    throw StateError('Unknown enqueued response type: $next');
  }
}

AIModelConfig _makeConfig({bool fc = true}) => AIModelConfig.create(
      id: 'test',
      provider: 'openai',
      name: 'Test Model',
      apiKey: 'test-key',
      baseUrl: 'https://test.example.com/v1',
      modelName: 'test-model',
      maxTokens: 4096,
      supportsFunctionCalling: fc,
    );

ToolCall _executeCall(String command, {String? description}) => ToolCall(
      id: 'call_${command.hashCode}',
      name: 'execute',
      arguments: jsonEncode({
        'command': command,
        if (description != null) 'description': description,
      }),
    );

ToolCall _finishCall({
  String answer = '任务完成',
  String conclusion = '目标已达成',
  String status = '输出正常',
  String changes = '无',
  String suggestion = '无',
}) =>
    ToolCall(
      id: 'call_finish',
      name: 'finish',
      arguments: jsonEncode({
        'answer': answer,
        'conclusion': conclusion,
        'status': status,
        'changes': changes,
        'suggestion': suggestion,
      }),
    );

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  AgentEngine makeEngine({
    required AIProvider provider,
    bool fc = true,
  }) {
    return AgentEngine(
      aiProvider: provider,
      modelConfig: _makeConfig(fc: fc),
      memory: AgentMemory(),
      maxSteps: 8,
      hostId: 'test-host',
    );
  }

  group('引擎 FC-first 端到端', () {
    test('execute→finish：命令事件唯一、说明保留、结果关联、操作单来自结构化字段',
        () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['先查看 Java 版本'],
        [_executeCall('java -version', description: '查看当前 Java 版本，只读')],
      );
      provider.enqueueFc(
        ['版本正确，任务完成'],
        [_finishCall(answer: '## Java 17 已安装', conclusion: 'Java 17 就绪')],
      );
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor()..stdout = 'openjdk 17.0.1';

      await engine.startTask('检查 Java 版本', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, ['java -version']);
      // 提前执行回调与流结束合并各生成一次命令事件，stableId 去重后只发一条
      final cmdEvents = events.where((e) => e.isCommand).toList();
      expect(cmdEvents, hasLength(1));
      expect(cmdEvents.single.command, 'java -version');
      expect(cmdEvents.single.description, '查看当前 Java 版本，只读');
      final result = events.where((e) => e.isResult).single;
      expect(result.commandId, cmdEvents.single.id);
      expect(result.success, isTrue);
      // 正文作为思考事件呈现，而不是协议文本
      expect(events.any((e) => e.isThought && e.text!.contains('先查看 Java 版本')),
          isTrue);
      final report = events.where((e) => e.isReport).single.operationReport!;
      expect(report.conclusion, 'Java 17 就绪');
      expect(report.answerBody, '## Java 17 已安装');
      expect(report.finishState, 'success');
      // 历史里动作按文本协议记录，供后续轮次（含 fallback 模型）阅读
      final assistantMsgs = provider.receivedHistories.last
          .where((m) => m.role == 'assistant')
          .toList();
      expect(assistantMsgs.first.content, contains('动作: execute'));
      expect(assistantMsgs.first.content, contains('命令: java -version'));
      expect(assistantMsgs.first.content, contains('说明: 查看当前 Java 版本，只读'));
      // 观测回注
      expect(
          provider.receivedHistories.last
              .any((m) => m.role == 'user' && m.content.contains('观测:')),
          isTrue);
    });

    test('ask：事件带问题与选项，选择回写事件并回注观测', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['发现多个可行方案，需要用户决定'],
        [
          ToolCall(
            id: 'call_ask',
            name: 'ask',
            arguments: jsonEncode({
              'question': '选择安装方式？',
              'options': ['apt 安装', '源码编译'],
            }),
          ),
        ],
      );
      provider.enqueueFc(['按用户选择执行'], [_executeCall('apt install -y nginx')]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      final future = engine.startTask('安装 nginx', _MockExecutor());
      for (var i = 0; i < 200 && !engine.hasPendingChoice; i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.hasPendingChoice, isTrue);
      expect(engine.pendingOptions, ['apt 安装', '源码编译']);
      final askEvent = events.where((e) => e.isAsk).single;
      expect(askEvent.question, '选择安装方式？');
      expect(askEvent.options, ['apt 安装', '源码编译']);

      engine.selectChoice('apt 安装');
      await future;

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(askEvent.chosenAnswer, 'apt 安装');
      expect(
          provider.receivedHistories.last.any(
              (m) => m.role == 'user' && m.content.contains('用户选择了 "apt 安装"')),
          isTrue);
    });

    test('同轮多个 execute：逐条执行，结果各自关联自己的命令 id', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['一次收集两项只读信息'],
        [_executeCall('df -h'), _executeCall('free -m')],
      );
      provider.enqueueFc(['信息齐全'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor();

      await engine.startTask('收集磁盘与内存信息', executor);

      expect(executor.executed, ['df -h', 'free -m']);
      final cmds = events.where((e) => e.isCommand).toList();
      expect(cmds, hasLength(2));
      final results = events.where((e) => e.isResult).toList();
      expect(results, hasLength(2));
      // R4：每条结果关联自己的命令，不能都挂到最后一条
      expect(results.map((r) => r.commandId).toSet(),
          cmds.map((c) => c.id).toSet());
    });

    test('execute+finish 混合：只执行第一个动作，多余 finish 忽略并提示', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['先执行再看'],
        [_executeCall('echo hi'), _finishCall()],
      );
      provider.enqueueFc(['确认完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor();

      await engine.startTask('测试混合调用', executor);

      expect(executor.executed, ['echo hi']);
      expect(
          events.any((e) =>
              e.isInfo && (e.text ?? '').contains('忽略多余的工具调用: finish')),
          isTrue);
      expect(engine.currentTask?.status, AgentStatus.completed);
      // 第一轮不能直接收尾：finish 被忽略后必须还有第二轮
      expect(provider.callCount, 2);
    });

    test('注册工具别名 think：走 _handleToolAction 路由，记录思考', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc([], [
        ToolCall(
          id: 'call_think',
          name: 'think',
          arguments: jsonEncode({'thought': '先梳理一下排查思路'}),
        ),
      ]);
      provider.enqueueFc(['开始执行'], [_executeCall('uptime')]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('排查负载', _MockExecutor());

      expect(engine.toolCallsForTesting, 1);
      expect(
          events.any(
              (e) => e.isThought && (e.text ?? '').contains('先梳理一下排查思路')),
          isTrue);
      expect(engine.currentTask?.status, AgentStatus.completed);
    });

    test('FC 正文里的代码围栏只是思考示例，不会被当命令执行', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['我在思考里示范一段脚本：\n```bash\nrm -rf /tmp/demo\n```\n但本轮只执行只读查询'],
        [_executeCall('ls /tmp')],
      );
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor();

      await engine.startTask('查看临时目录', executor);

      // 围栏里的 rm 绝不能被执行；只有 tool_calls 里的 ls 执行了
      expect(executor.executed, ['ls /tmp']);
      final cmds = events.where((e) => e.isCommand).toList();
      expect(cmds, hasLength(1));
      expect(cmds.single.command, 'ls /tmp');
    });

    test('FC 模型回纯文本协议：自动落回文本解析', () async {
      final provider = _FcMockProvider();
      provider.enqueueText(['思考: 查看负载\n动作: execute\n命令: uptime\n']);
      provider.enqueueText(['思考: 完成\n动作: finish\n']);
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('查看负载', executor);

      expect(executor.executed, ['uptime']);
      expect(engine.currentTask?.status, AgentStatus.completed);
    });

    test('非 FC 配置：不传 tools schema，文本协议照常工作', () async {
      final provider = _FcMockProvider();
      provider.enqueueText(['思考: 查看\n动作: execute\n命令: whoami\n']);
      provider.enqueueText(['思考: 好\n动作: finish\n']);
      final engine = makeEngine(provider: provider, fc: false);
      final executor = _MockExecutor();

      await engine.startTask('查看用户', executor);

      expect(provider.receivedTools.every((t) => t == null), isTrue);
      expect(executor.executed, ['whoami']);
      expect(engine.currentTask?.status, AgentStatus.completed);
    });

    test('FC 配置：tools schema 含 execute/finish/ask 动作工具', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['直接收尾说明'], [_executeCall('true')]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);

      await engine.startTask('测试 schema', _MockExecutor());

      final tools = provider.receivedTools.first!;
      final names = tools
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(names, containsAll(['execute', 'finish', 'ask']));
      // 注册工具仍然在列
      expect(names, contains('knowledge_search'));
      final execSchema = tools.firstWhere(
          (t) => (t['function'] as Map)['name'] == 'execute')['function'] as Map;
      final params = execSchema['parameters'] as Map;
      expect((params['required'] as List), contains('command'));
      expect((params['properties'] as Map).containsKey('description'), isTrue);
    });

    test('FC 正文计划块 + finish 门控（WP6 约定保留）', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['计划:\n- [>] 检查服务\n- [ ] 验证端口\n'],
        [_executeCall('systemctl is-active nginx')],
      );
      // 计划仍有未完成项就 finish → 门控拦截
      provider.enqueueFc(['做完了'], [_finishCall()]);
      // 更新计划后收尾
      provider.enqueueFc(
        ['计划:\n- [x] 检查服务\n- [x] 验证端口\n'],
        [_finishCall(conclusion: '服务正常')],
      );
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('检查 nginx', _MockExecutor()..stdout = 'active');

      expect(events.any((e) => e.isPlan), isTrue);
      expect(engine.planFinishRetryCountForTesting, 1);
      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 3);
    });

    test('system prompt 按 FC 能力分支', () {
      final fcEngine = makeEngine(provider: _FcMockProvider(), fc: true);
      final fcPrompt = fcEngine.buildSystemPromptForTesting(_MockExecutor());
      expect(fcPrompt, contains('Function Calling 模式'));
      expect(fcPrompt, contains('已通过 Function Calling 暴露'));
      expect(fcPrompt, isNot(contains('严格格式要求')));
      // 降级兼容条款必须在：fallback 到非 FC 模型时仍能工作
      expect(fcPrompt, contains('降级兼容'));

      final textEngine = makeEngine(provider: _FcMockProvider(), fc: false);
      final textPrompt = textEngine.buildSystemPromptForTesting(_MockExecutor());
      expect(textPrompt, contains('严格格式要求'));
      expect(textPrompt, isNot(contains('Function Calling 模式')));
    });
  });

  group('OpenAIProvider SSE 结构化投递（真实字节流）', () {
    late HttpServer server;
    late String baseUrl;
    late List<String> sseLines;
    late bool sendDone;
    HttpOverrides? savedOverrides;

    setUp(() async {
      // TestWidgetsFlutterBinding 默认把所有 HttpClient 请求 mock 成 400；
      // 这组测试要跑真实 loopback SSE 字节流，临时恢复真实 HttpClient。
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      sendDone = true;
      sseLines = [
        'data: {"choices":[{"delta":{"content":"先查看版本"},"index":0}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"execute","arguments":""}}]},"index":0}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"java -"}}]},"index":0}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"version\\"}"}}]},"index":0,"finish_reason":"tool_calls"}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}',
      ];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}/v1';
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        for (final line in sseLines) {
          req.response.add(utf8.encode('$line\n\n'));
          await req.response.flush();
        }
        if (sendDone) {
          req.response.add(utf8.encode('data: [DONE]\n\n'));
          await req.response.flush();
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = savedOverrides;
    });

    AIModelConfig localConfig() => AIModelConfig.create(
          id: 'local',
          provider: 'openai',
          name: 'Local',
          apiKey: 'sk-test',
          baseUrl: baseUrl,
          modelName: 'test-model',
          supportsFunctionCalling: true,
        );

    final tools = [
      {
        'type': 'function',
        'function': {
          'name': 'execute',
          'description': '执行命令',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
            },
            'required': ['command'],
          },
        },
      }
    ];

    test('onToolCalls：跨包 arguments 拼接完整，正文不混入 ReAct 文本', () async {
      final provider = OpenAIProvider();
      final batches = <List<ToolCall>>[];
      final text = StringBuffer();
      TokenUsage? usage;
      final stream = await provider.chatStream(
        history: const [],
        prompt: '检查 java',
        config: localConfig(),
        tools: tools,
        onUsage: (u) => usage = u,
        onToolCalls: batches.add,
      );
      await for (final chunk in stream) {
        text.write(chunk);
      }
      expect(text.toString(), '先查看版本');
      expect(batches, hasLength(1));
      final call = batches.single.single;
      expect(call.name, 'execute');
      expect(jsonDecode(call.arguments), {'command': 'java -version'});
      expect(usage?.totalTokens, 15);
    });

    test('不提供 onToolCalls：维持旧版 ReAct 文本投递', () async {
      final provider = OpenAIProvider();
      final text = StringBuffer();
      final stream = await provider.chatStream(
        history: const [],
        prompt: '检查 java',
        config: localConfig(),
        tools: tools,
      );
      await for (final chunk in stream) {
        text.write(chunk);
      }
      final out = text.toString();
      expect(out, contains('先查看版本'));
      expect(out, contains('动作: tool'));
      expect(out, contains('工具: execute'));
      expect(out, contains('command: java -version'));
    });

    test('网关不发 [DONE]：finish_reason 投递一次，onDone 兜底不重复', () async {
      sendDone = false;
      final provider = OpenAIProvider();
      final batches = <List<ToolCall>>[];
      final stream = await provider.chatStream(
        history: const [],
        prompt: '检查 java',
        config: localConfig(),
        tools: tools,
        onToolCalls: batches.add,
      );
      await stream.drain<void>();
      expect(batches, hasLength(1));
      expect(jsonDecode(batches.single.single.arguments),
          {'command': 'java -version'});
    });
  });
}