import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// P2：AI 流超时且缓冲非空 → 半截响应一律丢弃（设计文档 §5.3）
///
/// 修复前：缓冲非空时半截响应被当完整执行——写了一半的 heredoc 会被发给
/// 远端 shell，干等 EOF 直到命令超时。修复后：只要 watchdog 触发就抛
/// TimeoutException，本轮不得产出任何 command 事件。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  test('流超时且缓冲非空：丢弃半截响应，无命令事件，重试轮干净续跑', () async {
    final provider = _HangingAIProvider();
    final engine = AgentEngine(
      aiProvider: provider,
      modelConfig: AIModelConfig.create(
        id: 'test',
        provider: 'openai',
        name: 'Test Model',
        apiKey: 'test-key',
        baseUrl: 'https://test.example.com/v1',
        modelName: 'test-model',
        maxTokens: 4096,
        contextWindow: 0,
      ),
      memory: AgentMemory(),
      maxSteps: 3,
      aiResponseTimeout: const Duration(milliseconds: 300),
    );

    final events = <AgentEvent>[];
    engine.onEvent = events.add;
    // 第 1 轮流超时（watchdog 300ms）→ TimeoutException → 1s 退避重试；
    // 第 2 轮 provider 直接给 finish → 任务正常收口。
    await engine
        .startTask('写配置文件', _NoopExecutor())
        .timeout(const Duration(seconds: 20));

    final commandEvents = events.where((e) => e.isCommand);
    expect(commandEvents, isEmpty,
        reason: '半截响应（含写了一半的 heredoc）绝不能被当完整响应执行');
    expect(provider.emitted.first, contains('cat > /etc/x.conf <<EOF'),
        reason: '本用例的前提：超时前缓冲里确实已有内容');
    expect(provider.calls, greaterThan(1),
        reason: '丢弃后必须真的重试（探针曾证实旧实现 calls=1 直接 failed——'
            '抛错落在流建立重试循环之外，重试路径根本没被走到）');
    // 重试轮的历史不得包含半截响应（抛错路径不写会话历史）
    final lastHistory = provider.histories.last;
    expect(
        lastHistory.any((m) => m.content.contains('<<EOF')), isFalse,
        reason: '被丢弃的半截响应不得进入重试轮的对话历史');
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// 第 1 次调用：发出含 heredoc 开头的 chunk 后永久挂起（watchdog 中断）；
/// 之后的调用：直接返回 finish —— 验证重试路径干净续跑。
class _HangingAIProvider implements AIProvider {
  final List<String> emitted = [];
  final List<List<ChatMessage>> histories = [];
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
    histories.add(List.from(history));
    calls++;
    if (calls > 1) {
      return Stream.value(
          '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n');
    }
    final chunk = '思考: 写入配置\n动作: execute\n命令: '
        'cat > /etc/x.conf <<EOF\nkey=value\n';
    emitted.add(chunk);
    // 用 controller 而非 async* 生成器：引擎 cancel() 时 generator 式挂起
    // 会拖住 await sub.cancel()；真实 Dio 流 cancel 即刻返回，controller 同构。
    final controller = StreamController<String>();
    controller.add(chunk); // 不 close：等待 watchdog 中断
    return controller.stream;
  }
}

class _NoopExecutor implements CommandExecutor {
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
      CommandResult(stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

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
      CommandResult(stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

  @override
  void writeToTerminal(String data) {}
}
