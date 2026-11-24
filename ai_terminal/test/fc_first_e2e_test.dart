import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_goal.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:ai_terminal/utils/goal_continuation.dart';

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
    test('execute→finish：命令事件唯一、说明保留、结果关联、操作单来自结构化字段', () async {
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
          events.any(
              (e) => e.isInfo && (e.text ?? '').contains('忽略多余的工具调用: finish')),
          isTrue);
      expect(engine.currentTask?.status, AgentStatus.completed);
      // 第一轮不能直接收尾：finish 被忽略后必须还有第二轮
      expect(provider.callCount, 2);
    });

    test('提前执行只认首个 tool_call：后续 execute 不得幽灵执行', () {
      // 首个调用是 think、第二个是 execute 时，_stepFromFcCalls 只消费首个，
      // 提前执行若扫描全部调用，就会把本轮不会消费的命令先跑掉。
      expect(AgentEngine.earlyExecuteCandidate([]), isNull);
      expect(AgentEngine.earlyExecuteCandidate([_executeCall('ls')])?.name,
          'execute');
      expect(
        AgentEngine.earlyExecuteCandidate([
          ToolCall(
            id: 'call_think',
            name: 'think',
            arguments: jsonEncode({'thought': '先梳理步骤'}),
          ),
          _executeCall('echo ghost'),
        ]),
        isNull,
      );
      expect(
        AgentEngine.earlyExecuteCandidate([
          ToolCall(
            id: 'call_empty',
            name: 'execute',
            arguments: jsonEncode({'command': '   '}),
          ),
        ]),
        isNull,
      );
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
          events
              .any((e) => e.isThought && (e.text ?? '').contains('先梳理一下排查思路')),
          isTrue);
      expect(engine.currentTask?.status, AgentStatus.completed);
    });

    test('老模型把参数套进 {"args": {...}} 时引擎解包，工具正常执行', () async {
      // 真机缺陷：默认 schema 曾把参数包成 args 对象，模型照做后 file_write
      // 读不到 path，连续两轮报「参数缺失」。schema 已改平铺，但线上模型仍可能
      // 按旧习惯发嵌套形状，引擎必须在分发前解包。
      final provider = _FcMockProvider();
      provider.enqueueFc([], [
        ToolCall(
          id: 'call_nested',
          name: 'nested_args_probe',
          arguments: jsonEncode({
            'args': {'query': 'docker'},
          }),
        ),
      ]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);
      engine.toolsForTesting.register(_NestedArgsProbeTool());
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('查 docker 指引', _MockExecutor());

      final result = events.firstWhere(
        (e) => e.isResult && e.toolName == 'nested_args_probe',
      );
      expect(result.success, isTrue,
          reason: '嵌套参数必须被解包，否则 query 读不到（${result.error}）');
      expect(result.error ?? '', isNot(contains('缺少必填参数')));
      // 不止"没报错"：解包后的值必须真的传到工具手里
      expect(result.output, contains('docker'));
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
      final names =
          tools.map((t) => (t['function'] as Map)['name'] as String).toList();
      expect(names, containsAll(['execute', 'finish', 'ask']));
      // 注册工具仍然在列
      expect(names, contains('cert_check'));
      final execSchema = tools.firstWhere(
              (t) => (t['function'] as Map)['name'] == 'execute')['function']
          as Map;
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
      final textPrompt =
          textEngine.buildSystemPromptForTesting(_MockExecutor());
      expect(textPrompt, contains('严格格式要求'));
      expect(textPrompt, isNot(contains('Function Calling 模式')));
    });

    test('用户禁止执行命令：未执行任何命令也能直接 finish', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc([
        '用户要求不执行命令，直接基于会话内容作答'
      ], [
        _finishCall(
          answer: '根据本会话内容，结论如下……',
          conclusion: '未执行命令，依据为会话内容',
        )
      ]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      final executor = _MockExecutor();

      await engine.startTask('严禁执行任何命令，只根据本会话内容总结进展', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, isEmpty);
      // 幻觉门控让路：一次 AI 调用即收尾，没有被强制继续
      expect(provider.callCount, 1);
      expect(engine.finishWithoutExecCountForTesting, 0);
      expect(engine.userForbadeCommandsForTesting, isTrue);
      expect(
        events.where((e) => e.text != null && e.text!.contains('未实际执行命令')),
        isEmpty,
      );
    });

    test('用户未禁止：未执行命令就 finish 仍被门控拦下（回归）', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['我判断服务正常'], [_finishCall(conclusion: '服务正常')]);
      provider.enqueueFc(['再确认一次'], [_finishCall(conclusion: '服务正常')]);
      provider.enqueueFc(['完成'], [_finishCall(conclusion: '服务正常')]);
      final engine = makeEngine(provider: provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;

      await engine.startTask('检查 nginx 服务状态', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(engine.finishWithoutExecCountForTesting, 2);
      expect(engine.userForbadeCommandsForTesting, isFalse);
      expect(provider.callCount, 3);
      expect(
        events.where((e) => e.text != null && e.text!.contains('未实际执行命令')),
        isNotEmpty,
      );
      // 强制继续的指令要求模型实际执行命令
      expect(
        provider.receivedHistories.last
            .any((m) => m.role == 'user' && m.content.contains('实际执行命令验证')),
        isTrue,
      );
      // 驳回文案必须给出纯问答合法出口，否则模型只能被迫去执行命令
      expect(
        provider.receivedHistories.last
            .any((m) => m.role == 'user' && m.content.contains('纯问答，无需执行命令')),
        isTrue,
      );
    });

    test('运行中补充禁止命令：后续 finish 不再被强制继续', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['需要确认是否允许执行命令'],
        [
          ToolCall(
            id: 'call_ask',
            name: 'ask',
            arguments: jsonEncode({
              'question': '可以执行只读命令吗？',
              'options': ['可以', '不要执行'],
            }),
          ),
        ],
      );
      provider.enqueueFc(['按用户要求直接作答'], [_finishCall(answer: '基于会话内容的总结')]);
      final engine = makeEngine(provider: provider);

      final future = engine.startTask('总结本次会话做了什么', _MockExecutor());
      for (var i = 0; i < 200 && !engine.hasPendingChoice; i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.hasPendingChoice, isTrue);
      engine.addUserSteering('禁止执行任何命令，直接用文字回答');
      engine.selectChoice('不要执行');
      await future;

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(provider.callCount, 2);
      expect(engine.finishWithoutExecCountForTesting, 0);
      expect(engine.userForbadeCommandsForTesting, isTrue);
    });

    test('禁止命令时空动作的继续提示不再催促执行', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['我想执行一下看看'], [_executeCall('')]);
      provider.enqueueFc(['直接给结论'], [_finishCall(answer: '无需命令即可回答')]);
      final engine = makeEngine(provider: provider);

      await engine.startTask('不要执行命令，直接说明原因', _MockExecutor());

      expect(engine.currentTask?.status, AgentStatus.completed);
      final prompts = provider.receivedHistories.last
          .where((m) => m.role == 'user' && m.content.contains('请继续'))
          .toList();
      expect(prompts, isNotEmpty);
      expect(prompts.last.content, contains('不要执行任何命令'));
      expect(prompts.last.content, isNot(contains('命令: [要执行的命令]')));
    });
  });

  group('纯问答端到端（提问不被逼去执行命令）', () {
    test('FC：提问 + 声明纯问答 → 零命令一次收尾', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['纯问答，无需执行命令。用户在问上一任务的方案取舍，直接基于上下文解释。'],
        [_finishCall(answer: '压缩是为了保证备份一致性……')],
      );
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('你刚数据库复制为何不直接复制文件非要用压缩', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, isEmpty);
      expect(provider.callCount, 1);
      expect(engine.finishWithoutExecCountForTesting, 0);
    });

    test('FC：首次 finish 无声明被驳回，按提示声明后放行', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['直接解释一下'], [_finishCall(answer: '因为……')]);
      provider.enqueueFc(
        ['纯问答，无需执行命令。这是对上一任务的提问。'],
        [_finishCall(answer: '因为……')],
      );
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('为何不直接复制文件', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, isEmpty);
      expect(provider.callCount, 2);
      expect(engine.finishWithoutExecCountForTesting, 1);
    });

    test('FC：answer 里声明纯问答同样放行', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(
        ['用户只是提问'],
        [_finishCall(answer: '纯问答，无需执行命令。\n\n原因是……')],
      );
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('压缩和直接复制有什么区别', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, isEmpty);
      expect(provider.callCount, 1);
    });

    test('文本协议：思考行声明纯问答 → 零命令收尾', () async {
      final provider = _FcMockProvider();
      provider.enqueueText([
        '思考: 纯问答，无需执行命令。直接解释原因。\n'
            '动作: finish\n'
            '回答: 因为压缩能节省带宽……\n',
      ]);
      final engine = makeEngine(provider: provider, fc: false);
      final executor = _MockExecutor();

      await engine.startTask('为何要用压缩', executor);

      expect(engine.currentTask?.status, AgentStatus.completed);
      expect(executor.executed, isEmpty);
      expect(provider.callCount, 1);
      expect(engine.finishWithoutExecCountForTesting, 0);
    });

    test('操作任务不带声明的幻觉 finish 仍被拦（反幻觉不回归）', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['服务应该正常'], [_finishCall(conclusion: '服务正常')]);
      provider.enqueueFc(['我确定正常'], [_finishCall(conclusion: '服务正常')]);
      provider.enqueueFc(['好吧完成'], [_finishCall(conclusion: '服务正常')]);
      final engine = makeEngine(provider: provider);

      await engine.startTask('检查 nginx 服务状态', _MockExecutor());

      expect(engine.finishWithoutExecCountForTesting, 2);
      expect(provider.callCount, 3);
    });

    test('消息包装：新对话意图中性；旧历史新问题标记为独立请求', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['纯问答，无需执行命令。'], [_finishCall(answer: '好的')]);
      provider.enqueueFc(['纯问答，无需执行命令。'], [_finishCall(answer: '解释如下')]);
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('帮我备份数据库', executor);
      await engine.startTask('为何不直接复制文件非要用压缩', executor);

      // 首条消息不再强制"开始执行"
      final firstUser =
          provider.receivedHistories.first.firstWhere((m) => m.role == 'user');
      expect(firstUser.content, contains('请先判断意图'));
      expect(firstUser.content, isNot(contains('请分析任务并开始执行')));
      // 第二轮的新问题带独立请求框架，防止被当成上一任务续跑
      final secondUsers = provider.receivedHistories.last
          .where((m) => m.role == 'user')
          .toList();
      expect(secondUsers.last.content, contains('独立的新请求'));
      expect(secondUsers.last.content, contains('为何不直接复制文件非要用压缩'));
    });

    test('system prompt 两套规则都含纯提问分支', () {
      final fcPrompt = makeEngine(provider: _FcMockProvider(), fc: true)
          .buildSystemPromptForTesting(_MockExecutor());
      expect(fcPrompt, contains('纯提问直接回答'));
      final textPrompt = makeEngine(provider: _FcMockProvider(), fc: false)
          .buildSystemPromptForTesting(_MockExecutor());
      expect(textPrompt, contains('纯提问直接回答'));
    });

    test('目标续跑轮：包装不标"独立新请求"，任务带目标轮标记', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['执行目标第一步'], [_executeCall('uptime')]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      provider.enqueueFc(['纯问答，无需执行命令。'], [_finishCall(answer: '解释')]);
      final engine = makeEngine(provider: provider);
      final executor = _MockExecutor();

      await engine.startTask('配置日志轮转', executor);
      expect(engine.currentTaskIsGoalRound, isFalse);

      final prompt = buildGoalContinuationPrompt(AgentGoal(
        id: 'g1',
        hostId: 'test-host',
        objective: '配置日志轮转',
        maxRounds: 24,
        createdAt: DateTime(2026, 11, 1),
        updatedAt: DateTime(2026, 11, 1),
      ));
      await engine.startTask(prompt, executor, isGoalRound: true);

      expect(engine.currentTaskIsGoalRound, isTrue);
      final lastUser =
          provider.receivedHistories.last.lastWhere((m) => m.role == 'user');
      expect(lastUser.content, contains('自动续跑轮'));
      expect(lastUser.content, isNot(contains('独立的新请求')));
    });

    test('运行中补充是提问：注入提问引导，不让模型当指令继续执行', () async {
      final provider = _FcMockProvider();
      provider.enqueueFc(['先看磁盘'], [_executeCall('df -h')]);
      provider.enqueueFc(['完成'], [_finishCall()]);
      final engine = makeEngine(provider: provider);

      final future = engine.startTask('检查磁盘', _MockExecutor());
      engine.addUserSteering('刚才为何用压缩不直接复制');
      await future;

      expect(engine.currentTask?.status, AgentStatus.completed);
      final history = provider.receivedHistories.last;
      expect(
        history
            .any((m) => m.role == 'user' && m.content == '用户补充: 刚才为何用压缩不直接复制'),
        isTrue,
      );
      expect(
        history.any((m) => m.role == 'user' && m.content.contains('若是提问而非指令')),
        isTrue,
      );
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

/// 仅测试用：把收到的 query 原样回显，用来证明嵌套参数解包后值真的到了工具手里。
/// 不用真实工具是因为存活工具要么打真实文件系统/网络，要么自行 catch 参数缺失，
/// 断言会随环境漂移。
class _NestedArgsProbeTool extends AgentTool {
  @override
  String get name => 'nested_args_probe';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '仅测试用工具：回显 query 参数';

  @override
  String get paramSpec => '  query: 查询词（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    return ToolResult.success('query=${args.requireString('query')}');
  }
}
