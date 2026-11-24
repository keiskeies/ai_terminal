import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/ssh_connection_pool.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// 不连真实服务器的假服务：继承真实 SSHService 以复用它的
/// outputController / dispose 语义，只把建连与 isConnected 换掉。
class _FakeSSHService extends SSHService {
  _FakeSSHService(super.config);

  @override
  bool get isConnected => true;

  @override
  Future<void> connect({
    String? password,
    String? privateKeyContent,
    String? passphrase,
    HostConfig? jumpHostConfig,
    String? jumpPassword,
    String? jumpPrivateKeyContent,
  }) async {}
}

HostConfig _config(String id) => HostConfig.create(
      id: id,
      name: 'test-$id',
      host: '127.0.0.1',
      port: 22,
      username: 'tester',
      authType: 'password',
    );

void main() {
  late List<_FakeSSHService> created;

  setUp(() {
    created = [];
    SSHConnectionPool.serviceFactoryForTesting = (config) {
      final svc = _FakeSSHService(config);
      created.add(svc);
      return svc;
    };
  });

  tearDown(() async {
    await SSHConnectionPool.dispose();
    SSHConnectionPool.serviceFactoryForTesting = null;
  });

  test('release 归零后移出池，并关闭 outputController', () async {
    final a = await SSHConnectionPool.acquire('tab-a', _config('host-a'));
    final b = await SSHConnectionPool.acquire('tab-a', _config('host-a'));
    expect(identical(a, b), isTrue);
    expect(SSHConnectionPool.stats['totalConnections'], 1);

    SSHConnectionPool.release('tab-a');
    expect(SSHConnectionPool.stats['totalConnections'], 1,
        reason: '还有 1 个持有者时不销毁');
    expect(a.outputController.isClosed, isFalse);

    SSHConnectionPool.release('tab-a');
    expect(SSHConnectionPool.stats['totalConnections'], 0);
    expect(a.outputController.isClosed, isTrue,
        reason: '归零必须 dispose，不能只 disconnect');
  });

  test('forceDisconnect 释放连接对象，dispose 幂等', () async {
    final svc = await SSHConnectionPool.acquire('tab-b', _config('host-b'));

    await SSHConnectionPool.forceDisconnect('tab-b');
    expect(SSHConnectionPool.stats['totalConnections'], 0);
    expect(svc.outputController.isClosed, isTrue);

    // 重复 dispose 不应抛 StateError（向已关闭流 add）
    expect(() => svc.dispose(), returnsNormally);
    await SSHConnectionPool.forceDisconnect('tab-b');
  });

  test('pool.dispose 关闭所有 service', () async {
    final a = await SSHConnectionPool.acquire('tab-c1', _config('host-c1'));
    final b = await SSHConnectionPool.acquire('tab-c2', _config('host-c2'));
    expect(SSHConnectionPool.stats['totalConnections'], 2);

    await SSHConnectionPool.dispose();
    expect(SSHConnectionPool.stats['totalConnections'], 0);
    expect(a.outputController.isClosed, isTrue);
    expect(b.outputController.isClosed, isTrue);
  });

  test('空闲清理回收无借用者的过期条目，跳过仍被借用的条目', () async {
    final idle =
        await SSHConnectionPool.acquire('tab-idle', _config('host-idle'));
    final busy =
        await SSHConnectionPool.acquire('tab-busy', _config('host-busy'));
    await SSHConnectionPool.acquire('tab-busy', _config('host-busy'));
    expect(created.length, 2);

    // 负 timeout 让所有条目都视为"过期"，只由 refCount 决定去留
    SSHConnectionPool.cleanupForTesting(const Duration(seconds: -1));

    expect(SSHConnectionPool.stats['totalConnections'], 1,
        reason: 'refCount=2 的条目不能被回收');
    expect(idle.outputController.isClosed, isTrue);
    expect(busy.outputController.isClosed, isFalse);
  });
}
