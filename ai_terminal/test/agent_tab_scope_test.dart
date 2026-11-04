import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/services/agent_host_registry.dart';
import 'package:ai_terminal/services/agent_logger.dart';
import 'package:ai_terminal/services/command_executor.dart';

class _FakeExecutor implements CommandExecutor {
  _FakeExecutor({required this.isConnected});

  @override
  final bool isConnected;

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
  }) =>
      throw UnimplementedError();

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 5)}) =>
      throw UnimplementedError();

  @override
  void writeToTerminal(String data) {}
}

void main() {
  group('AgentHostRegistry 按 tab 隔离', () {
    test('同一服务器的两个 scope 状态互不覆盖', () {
      final registry = AgentHostRegistry()
        ..setScopeHost('tabA', 'host1')
        ..setScopeHost('tabB', 'host1')
        ..setState('tabA', AgentState(hostId: 'host1'))
        ..setState('tabB', AgentState(hostId: 'host1'));

      registry.updateState(
          'tabA', (s) => s.copyWith(error: 'only-A'));

      expect(registry.getState('tabA')!.error, 'only-A');
      expect(registry.getState('tabB')!.error, isNull);
      expect(registry.scopesForHost('host1').toSet(), {'tabA', 'tabB'});
      expect(registry.getHostId('tabA'), 'host1');
    });

    test('多机编排按 host 解析时优先活跃 tab 的 executor', () {
      final execA = _FakeExecutor(isConnected: true);
      final execB = _FakeExecutor(isConnected: true);
      final registry = AgentHostRegistry()
        ..setScopeHost('tabA', 'host1')
        ..setScopeHost('tabB', 'host1')
        ..setScopeExecutor('tabA', execA)
        ..setScopeExecutor('tabB', execB);

      registry.setActive('tabB');
      expect(identical(registry.getExecutor('host1'), execB), isTrue);

      registry.setActive('tabA');
      expect(identical(registry.getExecutor('host1'), execA), isTrue);
    });

    test('移除一个 tab 不会清掉同 host 的另一个 tab', () {
      final registry = AgentHostRegistry()
        ..setScopeHost('tabA', 'host1')
        ..setScopeHost('tabB', 'host1')
        ..setState('tabA', AgentState(hostId: 'host1'))
        ..setState('tabB', AgentState(hostId: 'host1'));

      registry.removeScope('tabA');

      expect(registry.hasState('tabA'), isFalse);
      expect(registry.hasState('tabB'), isTrue);
      expect(registry.scopesForHost('host1'), ['tabB']);
    });
  });

  group('AgentNotifier 多 tab 会话', () {
    test('同服务器切 tab 保留各自的 Agent 状态', () {
      final notifier = AgentNotifier();
      notifier.switchTab('tabA', hostId: 'host1');
      expect(notifier.state.hostId, 'host1');

      notifier.setReadOnlyForHost('host1', enabled: true);
      expect(notifier.state.isReadOnlyMode, isTrue);

      notifier.switchTab('tabB', hostId: 'host1');
      expect(notifier.state.hostId, 'host1');
      expect(notifier.state.isReadOnlyMode, isFalse,
          reason: 'tabB 是新会话，不能继承 tabA 的状态');

      notifier.switchTab('tabA', hostId: 'host1');
      expect(notifier.state.isReadOnlyMode, isTrue,
          reason: '切回 tabA 必须恢复它自己的状态');
    });

    test('同 host 已有 Agent 执行时，新 tab 使用空白会话', () {
      final notifier = AgentNotifier();
      notifier.switchTab('tabA', hostId: 'host1');

      // 模拟同 host 的另一个 tab 正在执行任务
      notifier.registryForTesting
        ..setScopeHost('tabRunning', 'host1')
        ..setState(
            'tabRunning',
            AgentState(
              hostId: 'host1',
              status: AgentStatus.executing,
            ));
      expect(notifier.hasRunningAgentForHostForTesting('host1'), isTrue);

      notifier.switchTab('tabB', hostId: 'host1');

      expect(notifier.state.hostId, 'host1');
      expect(notifier.state.conversationId, isNull,
          reason: '不能加载 tabRunning 正在使用的会话');
      expect(notifier.state.isRunning, isFalse);
      expect(notifier.state.chatItems, isEmpty);
    });

    test('Agent 日志按任务会话路由，而不是按 host 的 active 会话', () async {
      final events = <String?>[];
      final unsubscribe = agentLogger.subscribe(
          (level, tag, message, timestamp, hostId, conversationId) {
        events.add(conversationId);
      });

      agentLogger.currentHostId = 'host1';
      await agentLogger.runWithConversation('conv-A', () async {
        agentLogger.info('Test', 'first');
        await Future<void>.delayed(Duration.zero);
        agentLogger.info('Test', 'after-await');
      });
      agentLogger.info('Test', 'outside-task');
      unsubscribe();

      expect(events.take(2), everyElement('conv-A'),
          reason: 'await 之后的日志也必须留在启动任务的会话里');
      expect(events.last, isNull, reason: '任务外的日志不应被错误绑定到会话');
    });

    test('启动窗口内点停止会立即退出运行态并记录取消意图', () {
      final notifier = AgentNotifier();
      notifier.switchTab('tabA', hostId: 'host1');
      notifier.beginStartupForTesting('tabA');
      expect(notifier.isRunningFor('tabA'), isTrue,
          reason: '任务已显示运行中、但 engine 还没 startTask 的窗口也算忙碌');

      notifier.cancel();

      expect(notifier.state.status, AgentStatus.cancelled);
      expect(notifier.isStartupCancelRequestedForTesting('tabA'), isTrue,
          reason: 'startTask 必须在下一个 await 后看到该标记并放弃启动');
      notifier.endStartupForTesting('tabA');
    });

    test('isRunningFor 能识别后台 tab 的任务', () {
      final notifier = AgentNotifier();
      notifier.switchTab('tabA', hostId: 'host1');
      notifier.registryForTesting
        ..setScopeHost('tabRunning', 'host1')
        ..setState(
            'tabRunning',
            AgentState(
              hostId: 'host1',
              status: AgentStatus.executing,
            ));

      expect(notifier.isRunningFor('tabRunning'), isTrue,
          reason: '关闭后台 tab 前必须能识别它自己的任务');
      expect(notifier.isRunningFor('tabA'), isFalse);
    });
  });
}
