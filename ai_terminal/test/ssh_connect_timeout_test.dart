import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/ssh_connection_pool.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// C7：`config.timeout` 此前只存不用（建连恒 15 s），用户设置完全无效
/// （docs/ssh-disconnect-resilience-design.md F10）。
/// 这两个纯函数是修复后的唯一真源，断言的是"设置生效且池不会抢先掐断"。
void main() {
  HostConfig cfg(int timeout) => HostConfig.create(
        id: 'h1',
        name: 'test',
        host: '127.0.0.1',
        username: 'tester',
        authType: 'password',
        timeout: timeout,
      );

  group('SSHService.connectTimeoutFor', () {
    test('中间值原样生效——这是本条修复的全部意义', () {
      expect(
          SSHService.connectTimeoutFor(cfg(45)), const Duration(seconds: 45));
      expect(
          SSHService.connectTimeoutFor(cfg(30)), const Duration(seconds: 30));
    });

    test('夹到 UI 滑杆区间 10–120 s', () {
      // 滑杆本身不给越界的机会，但存档/导入的 SSH config 可以带任意值进来。
      expect(SSHService.connectTimeoutFor(cfg(1)), const Duration(seconds: 10));
      expect(SSHService.connectTimeoutFor(cfg(0)), const Duration(seconds: 10));
      expect(SSHService.connectTimeoutFor(cfg(9999)),
          const Duration(seconds: 120));
    });
  });

  group('SSHConnectionPool.overallConnectTimeoutFor', () {
    test('池侧必须晚于单次建连超时，否则调大设置反而更容易失败', () {
      for (final seconds in [10, 30, 60, 120]) {
        final overall =
            SSHConnectionPool.overallConnectTimeoutFor(cfg(seconds));
        expect(overall > SSHService.connectTimeoutFor(cfg(seconds)), isTrue,
            reason: 'timeout=$seconds 时池先掐断，用户永远看不到真实建连异常');
      }
    });

    test('无跳板机时是一段建连加余量', () {
      expect(SSHConnectionPool.overallConnectTimeoutFor(cfg(30)),
          const Duration(seconds: 45));
    });

    test('跳板机段按自己的超时算，不按主机配置猜', () {
      // 调用方合成的跳板机 HostConfig 不带 timeout（恒默认 30 s），
      // 所以两段并不相等：主机 10 s + 跳板 30 s 需要 40 s，
      // 若按"主机 ×2"只给 35 s，池会在真实建连成功前先掐断。
      final jump = cfg(30); // 合成的跳板机配置恒用默认 30 s
      final overall = SSHConnectionPool.overallConnectTimeoutFor(cfg(10),
          jumpHostConfig: jump);
      final legs = SSHService.connectTimeoutFor(cfg(10)) +
          SSHService.connectTimeoutFor(jump);
      expect(legs, const Duration(seconds: 40));
      expect(overall, const Duration(seconds: 55));
      expect(overall > legs, isTrue);
    });
  });
}
