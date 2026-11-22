import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/providers/agent_provider.dart';
import 'package:ai_terminal/providers/terminal_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late TerminalNotifier notifier;

  HostConfig host(String id) => HostConfig.create(
        id: id,
        name: 'test-$id',
        host: '127.0.0.1',
        username: 'tester',
        authType: 'password',
      );

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(terminalProvider.notifier);
  });

  tearDown(() {
    container.dispose();
  });

  test('lost tab 调度重连；取消后计数与定时器都清空', () {
    final tab = notifier.registerTab(host('h1'));
    tab.status = TabStatus.lost;

    notifier.scheduleAutoReconnect(tab.id);
    expect(notifier.pendingReconnectCount, 1);

    notifier.cancelAutoReconnect(tab.id);
    expect(notifier.pendingReconnectCount, 0);
    expect(notifier.reconnectAttemptsFor(tab.id), 0);
  });

  test('非 lost / 本地 tab 不调度；同一 tab 不重复调度', () {
    final ssh = notifier.registerTab(host('h2'));
    ssh.status = TabStatus.connected;
    notifier.scheduleAutoReconnect(ssh.id);
    expect(notifier.pendingReconnectCount, 0,
        reason: 'connected 不该触发自动重连');

    final local = notifier.registerLocalTab();
    local.status = TabStatus.lost;
    notifier.scheduleAutoReconnect(local.id);
    expect(notifier.pendingReconnectCount, 0,
        reason: '本地 PTY 退出是正常结束，不自动重启');

    ssh.status = TabStatus.lost;
    notifier.scheduleAutoReconnect(ssh.id);
    notifier.scheduleAutoReconnect(ssh.id);
    expect(notifier.pendingReconnectCount, 1);
  });

  test('任务运行中照样调度重连（C4：不再因任务占用而放弃自愈）', () {
    // 掉线事件只有 onDisconnected 一个入口。任务跑着时拒掉这一次调度，
    // 就没有"稍后再排"的下一次了——半开连接上的任务只能干等到超时。
    final tab = notifier.registerTab(host('h5'));
    tab.status = TabStatus.lost;
    final agent = container.read(agentProvider.notifier)
      ..beginStartupForTesting(tab.id);
    expect(agent.isRunningFor(tab.id), isTrue,
        reason: '前置条件：该 tab 上确有任务在跑');

    notifier.scheduleAutoReconnect(tab.id);
    expect(notifier.pendingReconnectCount, 1,
        reason: '重连只换 executor，不碰任务状态，无需与任务互斥');

    agent.endStartupForTesting(tab.id);
  });

  test('退避到点后递增尝试次数并释放调度槽位', () async {
    final tab = notifier.registerTab(host('h3'));
    tab.status = TabStatus.lost;
    notifier.scheduleAutoReconnect(tab.id);
    expect(notifier.pendingReconnectCount, 1);

    // ReconnectPolicy 第 0 档是 1s；这里只验证调度器自身行为，
    // 不依赖真实主机（找不到 host 配置时重连会安全退出）。
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(notifier.pendingReconnectCount, 0);
    expect(notifier.reconnectAttemptsFor(tab.id), 1);
  });

  test('关闭 tab 时撤销待执行的重连', () async {
    final tab = notifier.registerTab(host('h4'));
    tab.status = TabStatus.lost;
    notifier.scheduleAutoReconnect(tab.id);
    expect(notifier.pendingReconnectCount, 1);

    await notifier.closeTab(tab.id);
    expect(notifier.pendingReconnectCount, 0);
    expect(notifier.reconnectAttemptsFor(tab.id), 0);
  });
}
