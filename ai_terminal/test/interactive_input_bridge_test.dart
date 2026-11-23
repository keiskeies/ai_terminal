import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/command_markers.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// WP5（O3）：交互式命令输入桥接。
///
/// 执行器层用 SSHService 的测试缝隙（isConnectedForTesting + outputController
/// 注入输出）驱动真实 evaluate 循环：_session==null 时写入为空操作，
/// 可以确定性地复现"提示到达 → 桥接回调 → 答案写 stdin → marker 完成"。
/// 本地 PTY 的桥接接线与 SSH 完全同构（同一检测器/应答器/门槛），
/// 套件里没有真 PTY 测试先例，不在 CI 引入 ConPTY 时序抖动。
///
/// 引擎层锁 R1：cancelTask / pauseTask / 10 分钟超时必须把等待中的
/// Completer complete(null)，await 不能挂死；答案只进事件时间线，
/// 不进对话历史（用第二次 AI 调用收到的 history 断言）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
    // 测试里硬编码 EXITCODE_1:0 注入输出，固定 marker 格式（空 nonce 回退旧格式）
    CommandMarkers.nonceForTesting = '';
  });
  tearDownAll(() => CommandMarkers.nonceForTesting = null);

  group('SSH 执行器桥接', () {
    HostConfig makeConfig() => HostConfig.create(
          id: 'bridge-test',
          name: 'bridge-test',
          host: '127.0.0.1',
          username: 'tester',
          authType: 'password',
        );

    Future<void> waitUntil(bool Function() cond,
        {Duration timeout = const Duration(seconds: 3)}) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsed > timeout) {
          fail('waitUntil 超时（${timeout.inMilliseconds}ms）');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('回调给出答案 → 继续等到 marker，退出码正常', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      String? seenPrompt;
      final promptSeen = Completer<void>();
      final future = ssh.executeAndWait(
        'ssh user@host',
        timeout: const Duration(seconds: 5),
        onInteractivePrompt: (prompt) async {
          seenPrompt = prompt;
          if (!promptSeen.isCompleted) promptSeen.complete();
          return 'yes';
        },
      );

      // 门槛：elapsed>=300ms 且回显行已结束（缓冲含换行）
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('ssh user@host\r\n'
          'Are you sure you want to continue connecting (yes/no/[fingerprint])? ');
      await promptSeen.future.timeout(const Duration(seconds: 3));
      ssh.outputController.add('yes\r\nEXITCODE_1:0\r\n');

      final result = await future;
      expect(seenPrompt, contains('yes/no'));
      expect(result.exitCode, 0);
      expect(result.failureKind, CommandFailureKind.none);
    });

    test('回调返回 null（取消/超时）→ interactivePrompt 中断', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      final future = ssh.executeAndWait(
        'ssh user@host',
        timeout: const Duration(seconds: 5),
        onInteractivePrompt: (_) async => null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('ssh user@host\r\n'
          'Are you sure you want to continue connecting (yes/no)? ');

      final result = await future;
      expect(result.failureKind, CommandFailureKind.interactivePrompt);
      expect(result.failureReason, contains('交互式'));
    });

    test('等待答案期间 recheck 不重复触发回调', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      var calls = 0;
      final promptSeen = Completer<void>();
      final answerGate = Completer<String?>();
      final future = ssh.executeAndWait(
        'ssh user@host',
        timeout: const Duration(seconds: 10),
        onInteractivePrompt: (_) {
          calls++;
          if (!promptSeen.isCompleted) promptSeen.complete();
          return answerGate.future;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('ssh user@host\r\nContinue? [Y/n] ');
      await promptSeen.future.timeout(const Duration(seconds: 3));

      // 跨过至少两个 400ms recheck 周期：等待期间同一提示不得再触发
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(calls, 1);

      answerGate.complete('Y');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ssh.outputController.add('Y\r\nEXITCODE_1:0\r\n');

      final result = await future;
      expect(result.exitCode, 0);
      expect(calls, 1);
    });

    test('未提供回调 → 保持旧行为：确认提示直接中断', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      final future = ssh.executeAndWait('ssh user@host',
          timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('ssh user@host\r\n'
          'Are you sure you want to continue connecting (yes/no)? ');

      final result = await future;
      expect(result.failureKind, CommandFailureKind.interactivePrompt);
    });

    test('密码提示即使提供回调也中断、不触发桥接（R7）', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      var calls = 0;
      final future = ssh.executeAndWait(
        'ssh user@host',
        timeout: const Duration(seconds: 5),
        onInteractivePrompt: (_) async {
          calls++;
          return 'leak';
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('ssh user@host\r\nPassword: ');

      final result = await future;
      expect(result.failureKind, CommandFailureKind.interactivePrompt);
      expect(calls, 0);
    });

    test('命令链里的第二个确认提示（下标前进）再次桥接', () async {
      final ssh = SSHService(makeConfig());
      ssh.isConnectedForTesting = true;
      addTearDown(() => ssh.outputController.close());

      final prompts = <String>[];
      const answers = ['yes', 'N'];
      final future = ssh.executeAndWait(
        'install-thing',
        timeout: const Duration(seconds: 10),
        onInteractivePrompt: (prompt) async {
          prompts.add(prompt);
          return answers[prompts.length - 1];
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      ssh.outputController.add('install-thing\r\nContinue? [Y/n] ');
      await waitUntil(() => prompts.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ssh.outputController.add('yes\r\nOverwrite? [y/N] ');
      await waitUntil(() => prompts.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ssh.outputController.add('N\r\nEXITCODE_1:0\r\n');

      final result = await future;
      expect(result.exitCode, 0);
      expect(prompts, hasLength(2));
      expect(prompts[1], contains('Overwrite'));
    });
  });

  group('引擎交互输入桥', () {
    AgentEngine makeEngine(_ScriptedAI provider) => AgentEngine(
          aiProvider: provider,
          modelConfig: AIModelConfig.create(
            id: 'test',
            provider: 'openai',
            name: 'Test Model',
            apiKey: 'test-key',
            baseUrl: 'https://test.example.com/v1',
            modelName: 'test-model',
            maxTokens: 4096,
          ),
          memory: AgentMemory(),
          maxSteps: 5,
          hostId: 'test-host',
        );

    const executeResponse = '思考: 执行\n动作: execute\n命令: echo hi\n';
    const finishResponse =
        '思考: 结论: 完成\n现状: ok\n变更: 无\n建议: 无\n动作: finish\n';

    Future<void> waitUntil(bool Function() cond,
        {Duration timeout = const Duration(seconds: 5)}) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsed > timeout) {
          fail('waitUntil 超时（${timeout.inMilliseconds}ms）');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('UI 答案写回执行器，且只进事件时间线、不进对话历史', () async {
      const answer = 'BRIDGE_ANSWER_42';
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      engine.onInteractiveInputRequest = (prompt) async => answer;
      final exec = _BridgeExecutor(prompt: 'Continue? [Y/n]: ');

      await engine.startTask('测试目标', exec);

      expect(exec.lastAnswer, answer);
      // 答案只作为 info 事件出现在时间线
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains(answer)),
        isTrue,
        reason: '答案应进事件时间线',
      );
      // 第二次 AI 调用（finish）收到的 history 里不得有答案：
      // 执行器 stdout 是 'ok'，唯一能把答案带进历史的只有桥接自己
      expect(provider.receivedHistories.length, greaterThanOrEqualTo(2));
      for (final history in provider.receivedHistories) {
        for (final m in history) {
          expect(m.content.contains(answer), isFalse,
              reason: '答案不得进对话历史（模型上下文）');
        }
      }
    });

    test('提示+答案的回显不进观测，模型不会把它当命令执行（O3 真机缺陷）',
        () async {
      const answer = 'y';
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      engine.onInteractiveInputRequest = (prompt) async => answer;
      // 真机形状：PTY 把提示行和用户输入回显进 stdout
      final exec = _BridgeExecutor(
        prompt: 'Continue? ',
        stdout: 'Continue? y\ngot-y',
      );

      await engine.startTask('测试目标', exec);

      // 第二次调用（finish 轮）的上下文里不得出现回显行：
      // 真机上模型正是看到它才发出了 `命令: Continue? y`
      final secondHistory = provider.receivedHistories.last
          .map((m) => m.content)
          .join('\n');
      expect(secondHistory, contains('got-y'), reason: '真实输出必须保留');
      expect(secondHistory, isNot(contains('Continue? y')),
          reason: '提示+答案的回显不得进入观测');

      // 结果事件里的 output 同样要干净（UI 与证据层都基于它）
      final resultEvent = events.lastWhere((e) => e.isResult);
      expect(resultEvent.output ?? '', isNot(contains('Continue? y')));
    });

    test('cancelTask 立即 complete(null)，await 不挂死（R1）', () async {
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final uiHang = Completer<String?>(); // UI 永不作答
      engine.onInteractiveInputRequest = (_) => uiHang.future;
      final exec = _BridgeExecutor(prompt: 'Continue? [Y/n]: ');

      final taskFuture = engine.startTask('测试目标', exec);
      await waitUntil(() => engine.pendingInteractiveInputForTesting != null);
      expect(engine.currentTask?.status, AgentStatus.waitingConfirm);
      final pending = engine.pendingInteractiveInputForTesting!;

      engine.cancelTask();

      expect(await pending.future.timeout(const Duration(seconds: 3)), isNull);
      await taskFuture.timeout(const Duration(seconds: 5));
      expect(exec.lastAnswer, isNull);
      expect(engine.currentTask?.status, AgentStatus.cancelled);
    });

    test('pauseTask 同样唤醒等待中的输入 Completer（R1）', () async {
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final uiHang = Completer<String?>();
      engine.onInteractiveInputRequest = (_) => uiHang.future;
      final exec = _BridgeExecutor(prompt: 'Continue? [Y/n]: ');

      final taskFuture = engine.startTask('测试目标', exec);
      await waitUntil(() => engine.pendingInteractiveInputForTesting != null);
      final pending = engine.pendingInteractiveInputForTesting!;

      engine.pauseTask();

      expect(await pending.future.timeout(const Duration(seconds: 3)), isNull);
      await taskFuture.timeout(const Duration(seconds: 5));
      expect(exec.lastAnswer, isNull);
    });

    test('10 分钟超时收口为 null，任务继续走失败观测', () async {
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final uiHang = Completer<String?>();
      engine.onInteractiveInputRequest = (_) => uiHang.future;
      final exec = _BridgeExecutor(prompt: 'Continue? [Y/n]: ');

      final taskFuture = engine.startTask('测试目标', exec);
      await waitUntil(() => engine.pendingInteractiveInputForTesting != null);
      final pending = engine.pendingInteractiveInputForTesting!;

      engine.expireInteractiveInputTimeoutForTesting();

      expect(await pending.future.timeout(const Duration(seconds: 3)), isNull);
      await taskFuture.timeout(const Duration(seconds: 5));
      expect(exec.lastAnswer, isNull);
      expect(exec.lastFailureKind, CommandFailureKind.interactivePrompt);
    });

    test('自动应答开关打开：[Y/n] 命中规则直接答 Y，不弹 UI', () async {
      await SettingsDao.set('agentAutoAnswerEnabled', true);
      addTearDown(() => SettingsDao.set('agentAutoAnswerEnabled', false));

      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      final events = <AgentEvent>[];
      engine.onEvent = events.add;
      var uiCalls = 0;
      engine.onInteractiveInputRequest = (_) async {
        uiCalls++;
        return 'UI';
      };
      final exec =
          _BridgeExecutor(prompt: 'Do you want to continue? [Y/n] ');

      await engine.startTask('测试目标', exec);

      expect(exec.lastAnswer, 'Y');
      expect(uiCalls, 0);
      expect(
        events.any((e) => e.isInfo && (e.text ?? '').contains('自动应答')),
        isTrue,
      );
    });

    test('自动应答开关打开：无安全默认值仍走 UI', () async {
      await SettingsDao.set('agentAutoAnswerEnabled', true);
      addTearDown(() => SettingsDao.set('agentAutoAnswerEnabled', false));

      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      var uiCalls = 0;
      engine.onInteractiveInputRequest = (_) async {
        uiCalls++;
        return 'yes';
      };
      final exec = _BridgeExecutor(prompt: '(yes/no)? ');

      await engine.startTask('测试目标', exec);

      expect(uiCalls, 1);
      expect(exec.lastAnswer, 'yes');
    });

    test('自动应答默认关闭：[Y/n] 也走 UI', () async {
      // 不设置开关（默认 false）。前两个用例的 tearDown 已复位。
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      var uiCalls = 0;
      engine.onInteractiveInputRequest = (_) async {
        uiCalls++;
        return 'Y';
      };
      final exec =
          _BridgeExecutor(prompt: 'Do you want to continue? [Y/n] ');

      await engine.startTask('测试目标', exec);

      expect(uiCalls, 1);
      expect(exec.lastAnswer, 'Y');
    });

    test('未接 UI 回调：按 interactivePrompt 中断（旧行为）', () async {
      final provider = _ScriptedAI([executeResponse, finishResponse]);
      final engine = makeEngine(provider);
      // 不设置 onInteractiveInputRequest
      final exec = _BridgeExecutor(prompt: 'Continue? [Y/n]: ');

      await engine.startTask('测试目标', exec);

      expect(exec.lastAnswer, isNull);
      expect(exec.lastFailureKind, CommandFailureKind.interactivePrompt);
    });
  });
}

/// 脚本化 AI provider：按顺序返回预设响应，记录每次收到的 history。
class _ScriptedAI implements AIProvider {
  final List<String> responses;
  final List<List<ChatMessage>> receivedHistories = [];
  int _index = 0;

  _ScriptedAI(this.responses);

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
    receivedHistories.add(List.from(history));
    final text = responses[_index < responses.length ? _index : responses.length - 1];
    _index++;
    return (() async* {
      yield text;
    })();
  }
}

/// 桥接测试执行器：把 onInteractivePrompt 真的调用一遍，
/// 答案非 null → 成功结果；null → interactivePrompt 失败（模拟执行器中断）。
class _BridgeExecutor implements CommandExecutor {
  final String prompt;

  /// 应答后的 stdout；真机上 PTY 会把「提示 + 用户输入」回显进这段输出
  final String stdout;
  String? lastAnswer;
  CommandFailureKind lastFailureKind = CommandFailureKind.none;
  int bridgeCalls = 0;

  _BridgeExecutor({required this.prompt, this.stdout = 'ok'});

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
    if (onInteractivePrompt == null) {
      return CommandResult(
        stdout: 'ok',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );
    }
    bridgeCalls++;
    final answer = await onInteractivePrompt(prompt);
    lastAnswer = answer;
    if (answer == null) {
      lastFailureKind = CommandFailureKind.interactivePrompt;
      return CommandResult(
        stdout: '',
        stderr: '',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.interactivePrompt,
        failureReason: '交互式确认提示被取消或超时，命令无法继续',
      );
    }
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
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: -1,
        duration: Duration.zero,
      );

  @override
  void writeToTerminal(String data) {}
}