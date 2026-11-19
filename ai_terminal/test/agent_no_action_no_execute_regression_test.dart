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
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// 回归测试：AI 正文未声明 `动作:` 时，任何围栏/文本行都不得被当成命令执行。
/// 真实故障（用户环境 CSYF4250327K00T）：模型把磁盘分析文本直接贴进正文，
/// 引擎把「binlog 位置: … → appvg-applv (/app, 57%)」「2026-11-17 ████ 44 个…」
/// 逐行敲进远端终端（-bash: command not found / syntax error）。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  test('无动作行的分析正文（含围栏）不产生任何命令执行', () async {
    final provider = _MockAIProvider();
    // 第 1 轮：真实故障回复形状 —— 纯分析 + 两个围栏，零个 动作: 行
    provider.enqueueStream([
      '## 磁盘与 binlog 盘点\n\n',
      'binlog 位置:  /app/docker_volume/mysql/data/  →  appvg-applv  (/app,  57%, 剩 176G)\n\n',
      '```\n磁盘告急的:   /var  →  sysvg-varlv  (/var, 98%, 剩 145M)\n```\n',
      '```\n2026-11-17  ████  44 个 ≈ 48G   ← 异常\n```\n',
    ]);
    // 第 2 轮：收到格式提示后按协议收尾；纯分析任务没执行过命令，
    // 会被 finish 幻觉门控拦一次（引擎设计），第 3 轮声明纯问答放行
    provider.enqueueStream(['思考: 已完成盘点。\n动作: finish\n回答: 盘点完成。']);
    provider.enqueueStream([
      '思考: 纯问答，无需执行命令。已有输出足够盘点。\n动作: finish\n回答: 盘点完成。',
    ]);

    final executor = _RecordingExecutor();
    final engine = AgentEngine(
      aiProvider: provider,
      modelConfig: _makeConfig(),
      memory: AgentMemory(),
      maxSteps: 5,
      hostId: 'test-host',
    );
    final events = <AgentEvent>[];
    engine.onEvent = events.add;

    await engine.startTask('盘点磁盘和 binlog', executor);

    // 引擎侧：不允许出现任何 command 事件
    final cmds = events.where((e) => e.isCommand).map((e) => e.command).toList();
    expect(cmds, isEmpty, reason: '无动作行时任何行都不得变成命令: $cmds');
    // 执行器侧：一条命令都不该被下发
    expect(executor.executed, isEmpty, reason: '不得向终端下发任何命令: ${executor.executed}');
    // 任务不挂死：正常走完（第 2 轮 finish）
    expect(provider.callCount, greaterThanOrEqualTo(2));
    expect(engine.currentTask?.status, AgentStatus.completed);
  });

  test('显式声明 动作: execute 时命令仍正常执行', () async {
    final provider = _MockAIProvider();
    provider.enqueueStream([
      '思考: 需要看 binlog 目录。\n说明: 列出 binlog 目录文件。\n动作: execute\n命令: ls /app/docker_volume/mysql/data\n',
    ]);
    provider.enqueueStream(['思考: 完成。\n动作: finish\n回答: 完成。']);

    final executor = _RecordingExecutor();
    final engine = AgentEngine(
      aiProvider: provider,
      modelConfig: _makeConfig(),
      memory: AgentMemory(),
      maxSteps: 5,
      hostId: 'test-host',
    );
    engine.onEvent = (e) {};

    await engine.startTask('看 binlog 目录', executor);

    expect(executor.executed, contains('ls /app/docker_volume/mysql/data'));
    expect(engine.currentTask?.status, AgentStatus.completed);
  });
}

class _RecordingExecutor implements CommandExecutor {
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
      stdout: 'ok',
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
      stderr: 'mock',
      exitCode: -1,
      duration: Duration.zero,
      failureKind: CommandFailureKind.unknown,
      failureReason: 'mock',
    );
  }

  @override
  void writeToTerminal(String data) {}
}

class _MockAIProvider implements AIProvider {
  int callCount = 0;
  final List<Object> _responses = [];

  void enqueueStream(List<String> chunks) {
    _responses.add(chunks);
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
    callCount++;
    if (_responses.isEmpty) {
      throw StateError('No enqueued response. callCount=$callCount');
    }
    final chunks = (_responses.removeAt(0) as List).cast<String>();
    return (() async* {
      for (final c in chunks) {
        yield c;
      }
    })();
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
