// 应用冒烟测试：验证 App 能启动并路由到首页（终端页）。
//
// 注意：完整启动流程（DbInit/凭据）在 main() 里，测试环境不执行；
// 这里只验证 Widget 树能构建、GoRouter 初始路由落在 TerminalPage。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ai_terminal/main.dart';
import 'package:ai_terminal/pages/terminal_page.dart';

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: AISTerminalApp()));
    await tester.pump();

    expect(find.byType(TerminalPage), findsOneWidget);
  });
}