import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// 等待期活性看门狗（docs/ssh-disconnect-resilience-design.md C1/C3）。
///
/// 用 SSHService 既有的测试缝隙：不建真连接，靠 isConnectedForTesting 放行、
/// 靠 outputController 注入输出、靠 livenessProbeForTesting 替换传输层 ping。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SSHService ssh;
  late int probes;

  setUp(() {
    ssh = SSHService(HostConfig.create(
      id: 'h1',
      name: 'probe-host',
      host: '127.0.0.1',
      username: 'tester',
      authType: 'password',
    ));
    ssh.isConnectedForTesting = true;
    // 真机上 connect() 会把连接标记为"刚刚确认活着"；测试缝隙跳过 connect，
    // 这里补上，避免每条命令都被开工前的活性预检拦下（那是另一条用例）。
    ssh.confirmAliveForTesting();
    probes = 0;
  });

  tearDown(() {
    ssh.dispose();
  });

  /// 探测恒失败（模拟半开连接：写不报错、读无响应、ping 无应答）
  void probeDead({Duration? latency}) {
    ssh.livenessProbeForTesting = () async {
      probes++;
      if (latency != null) await Future<void>.delayed(latency);
      throw StateError('ping 无响应');
    };
  }

  /// 探测恒成功（链路真活着，只是命令安静）
  void probeAlive() {
    ssh.livenessProbeForTesting = () async {
      probes++;
    };
  }

  group('静默阈值', () {
    test('按命令超时收敛在 10–30s', () {
      expect(SSHService.silenceLimitFor(const Duration(seconds: 30)),
          const Duration(seconds: 10));
      expect(SSHService.silenceLimitFor(const Duration(seconds: 60)),
          const Duration(seconds: 15));
      expect(SSHService.silenceLimitFor(const Duration(minutes: 3)),
          const Duration(seconds: 30));
      expect(SSHService.silenceLimitFor(const Duration(minutes: 10)),
          const Duration(seconds: 30));
    });
  });

  test('静默且探测失败 → 远早于命令超时按 disconnected 返回', () async {
    probeDead();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 300);
    final started = DateTime.now();

    final result = await ssh.executeAndWait(
      'sleep 999',
      // 看门狗应在 ~1s 内判定断连；留 30s 作为"没修好"的失败判据
      timeout: const Duration(seconds: 30),
    );
    final elapsed = DateTime.now().difference(started);

    expect(result.failureKind, CommandFailureKind.disconnected);
    expect(result.timedOut, isFalse, reason: '不能再伪装成 timeout');
    expect(result.failureReason, contains('探测无响应'));
    expect(elapsed, lessThan(const Duration(seconds: 10)),
        reason: '必须秒级发现，而不是干等 30s');
    expect(probes, greaterThanOrEqualTo(2), reason: '需连续两次失败才判死');
    expect(ssh.isConnected, isFalse);
  });

  test('单次探测失败不判死（弱网抖动）', () async {
    ssh.silenceLimitForTesting = const Duration(milliseconds: 250);
    ssh.livenessProbeForTesting = () async {
      probes++;
      if (probes == 1) throw StateError('一次抖动');
    };

    final pending =
        ssh.executeAndWait('sleep 1', timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(probes, greaterThan(0));
    ssh.outputController.add('ok\r\nEXITCODE_1:0\r\n');
    final result = await pending;

    expect(result.exitCode, 0);
    expect(result.failureKind, CommandFailureKind.none);
    expect(ssh.isConnected, isTrue, reason: '一次抖动不该拆掉连接');
  });

  test('静默但探测正常 → 继续等到 marker，不误判', () async {
    probeAlive();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 250);

    final pending = ssh.executeAndWait('quiet-but-alive',
        timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(probes, greaterThan(0), reason: '静默期必须主动探测');
    expect(pending, completes);

    ssh.outputController.add('still running\r\nEXITCODE_1:0\r\n');
    final result = await pending;

    expect(result.exitCode, 0);
    expect(result.failureKind, CommandFailureKind.none);
    expect(ssh.isConnected, isTrue);
  });

  test('输出持续到达时不探测', () async {
    probeAlive();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 400);

    final pending =
        ssh.executeAndWait('tailing', timeout: const Duration(seconds: 30));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      ssh.outputController.add('line $i\n');
    }
    ssh.outputController.add('done\r\nEXITCODE_1:0\r\n');
    final result = await pending;

    expect(result.exitCode, 0);
    expect(probes, 0, reason: '有输出 = 证据充分，不该花 RTT');
  });

  test('已完成的命令不会被探测（marker 先到）', () async {
    probeAlive();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 200);

    final pending =
        ssh.executeAndWait('echo hi', timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    ssh.outputController.add('hi\r\nEXITCODE_1:0\r\n');
    final result = await pending;
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(result.exitCode, 0);
    expect(probes, 0, reason: '收尾后定时器必须已停');
  });

  test('取消令牌优先：取消后不再判成断连', () async {
    probeDead();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 200);
    final cancel = Completer<void>();

    final pending = ssh.executeAndWait('sleep 999',
        timeout: const Duration(seconds: 30), cancelToken: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    cancel.complete();

    final result = await pending;
    expect(result.failureKind, isNot(CommandFailureKind.timeout));
  });

  test('无探测能力时绝不判死（没 client ≠ 断连）', () async {
    // 不注入探针、也没有真实 SSHClient：探测无从进行
    ssh.silenceLimitForTesting = const Duration(milliseconds: 200);

    final pending =
        ssh.executeAndWait('x', timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    ssh.outputController.add('EXITCODE_1:0\r\n');
    final result = await pending;

    expect(result.exitCode, 0, reason: '没有探测能力时行为必须与改动前一致');
    expect(ssh.isConnected, isTrue);
  });

  test('空闲后的下一条命令先验活（覆盖两条命令之间掉线）', () async {
    // 第一条命令：探测正常，正常收尾
    probeAlive();
    ssh.silenceLimitForTesting = const Duration(milliseconds: 200);
    final first = ssh.executeAndWait('first',
        timeout: const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    ssh.outputController.add('EXITCODE_1:0\r\n');
    expect((await first).exitCode, 0);

    // 期间链路死掉（模拟空闲 30s 以上）：无需等静默阈值，
    // 第二条命令开工前就应被发现
    probeDead();
    ssh.expireAliveConfirmationForTesting();
    ssh.silenceLimitForTesting = const Duration(seconds: 30);
    final second = await ssh.executeAndWait('second',
        timeout: const Duration(seconds: 30));

    expect(second.failureKind, CommandFailureKind.disconnected);
    expect(second.duration, Duration.zero);
    expect(probes, greaterThanOrEqualTo(1));
  });

  test('从未确认过活性时，第一条命令先验活', () async {
    // 模拟"连接建立后一直没跑过命令"：没有任何活性证据，开工前必须探一次
    ssh = SSHService(HostConfig.create(
      id: 'h9',
      name: 'fresh',
      host: '127.0.0.1',
      username: 'tester',
      authType: 'password',
    ))
      ..isConnectedForTesting = true
      ..silenceLimitForTesting = const Duration(seconds: 30);
    probeDead();

    final result = await ssh.executeAndWait('first after idle',
        timeout: const Duration(seconds: 30));

    expect(result.failureKind, CommandFailureKind.disconnected);
    expect(probes, greaterThanOrEqualTo(1));
  });

  test('刚确认活着时开工前不重复探测（连发命令零额外 RTT）', () async {
    probeDead();
    ssh.confirmAliveForTesting();
    ssh.silenceLimitForTesting = const Duration(seconds: 30);

    final pending =
        ssh.executeAndWait('x', timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    ssh.outputController.add('EXITCODE_1:0\r\n');
    final result = await pending;

    expect(result.exitCode, 0);
    expect(probes, 0, reason: '30s 内刚确认过，不该为同一条链路再付 RTT');
  });
}
