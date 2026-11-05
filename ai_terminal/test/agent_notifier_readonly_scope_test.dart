import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/providers/agent_provider.dart';

/// `/plan` 的按 host 权限档位写入（§6.14）的可测边界。
///
/// 这里刻意只测不依赖 DB 与引擎的部分：`AgentNotifier` 的构造只读 SettingsDao
/// 缓存并订阅日志，不需要注册表里有任何 host。测出来的"静默 no-op"是**已知边界**，
/// 不是期望行为——它说明 `setPermissionModeForHost` 只对活跃 host 或已注册 host 生效。
void main() {
  group('setPermissionModeForHost / permissionModeFor 的边界', () {
    test('未注册的后台 host 上是静默 no-op', () {
      final notifier = AgentNotifier();

      // /plan 的调用方永远处在"该 host 就是活跃 host"的前提下，所以线上不受影响；
      // 但若将来有人拿它去改一个后台 host，这行会告诉他：什么都没发生。
      notifier.setPermissionModeForHost(
          'ghost-host', AgentPermissionMode.readOnly);

      expect(notifier.permissionModeFor('ghost-host'), AgentPermissionMode.ask,
          reason: '注册表里没有该 host 的状态时，_updateHostState 不会凭空建一份');
    });

    test('未激活时读任何 host 都回默认询问，不抛', () {
      final notifier = AgentNotifier();

      expect(notifier.permissionModeFor('local'), AgentPermissionMode.ask);
      expect(notifier.permissionModeFor(''), AgentPermissionMode.ask);
    });
  });
}
