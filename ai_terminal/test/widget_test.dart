// 应用冒烟测试：验证 App 能启动并路由到首页（终端页）。
//
// 注意：完整启动流程（DbInit/凭据）在 main() 里，测试环境不执行；
// 这里只验证 Widget 树能构建、GoRouter 初始路由落在 TerminalPage。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ai_terminal/main.dart';
import 'package:ai_terminal/pages/terminal_page.dart';
import 'package:ai_terminal/providers/terminal_provider.dart';

/// 冒烟测试不启动真实 PTY：Process.start 在 fake async 下会留下 pending timer。
class _NoConnectTerminalNotifier extends TerminalNotifier {
  _NoConnectTerminalNotifier(super.ref);

  @override
  Future<TerminalTab?> connectLocalTab(
    TerminalTab tab, {
    bool? hadConnectedBefore,
  }) async {
    return null;
  }
}

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          terminalProvider
              .overrideWith((ref) => _NoConnectTerminalNotifier(ref)),
        ],
        child: const AISTerminalApp(),
      ),
    );
    await tester.pump();

    expect(find.byType(TerminalPage), findsOneWidget);
  });
}
