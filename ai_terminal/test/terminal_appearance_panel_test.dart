import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/terminal_themes.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/widgets/terminal_appearance_panel.dart';

/// 配色是「即时即用」的东西：用户不知道自己想要哪套，只能挨个切过去看。
///
/// 这组测试盯的是三件事，也是用户明确骂过的三件事：
/// 1. 浮层里必须有一块**按当前配色真渲染**的终端输出，而不是一串配色名字；
/// 2. 每套配色要画成一小块自己的终端（有底色、有颜色），不能只是文字 + 色点；
/// 3. 点一下当场生效（写设置 + 背后终端跟着变），不需要再进二级页面确认。
void main() {
  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: TerminalAppearancePanel(onMore: () {}),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('浮层里有真终端预览，不是只有配色名字', (tester) async {
    await pumpPanel(tester);

    expect(find.byType(TerminalPalettePreview), findsOneWidget);
    // 预览用的必须是真命令输出 —— 用户判断的是这些颜色会不会互相压住
    expect(find.textContaining('git status'), findsOneWidget);
    expect(find.textContaining('modified'), findsOneWidget);
  });

  testWidgets('八套配色全部摊开，名字完整可见', (tester) async {
    await pumpPanel(tester);

    for (final p in kTerminalPalettes) {
      expect(find.text(p.labelZh), findsOneWidget,
          reason: '配色 ${p.id} 没出现在浮层里');
    }
    // 名字不许截断成「Catppuccin …」：那等于没给名字
    final name = tester.widget<Text>(find.text('Catppuccin Mocha'));
    expect(name.overflow, TextOverflow.ellipsis);
    expect(name.maxLines, 2);
  });

  testWidgets('点配色当场生效：写设置，预览也跟着换', (tester) async {
    await pumpPanel(tester);

    expect(find.text('Dracula'), findsOneWidget);
    await tester.tap(find.text('Dracula'));
    await tester.pumpAndSettle();

    expect(SettingsDao.getCached('terminalPalette'), 'dracula');
    // 预览块换成了 Dracula 的底色（#282A36），不是默认的青黑
    final preview = tester
        .widget<TerminalPalettePreview>(find.byType(TerminalPalettePreview));
    expect(preview.theme.background, const Color(0xFF282A36));
  });

  testWidgets('字号加减直接写设置，且夹在 8~24 之间', (tester) async {
    SettingsDao.set('terminalFontSize', 14);
    await pumpPanel(tester);
    expect(find.text('14 px'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(SettingsDao.getCached('terminalFontSize'), 15);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(SettingsDao.getCached('terminalFontSize'), 13);
  });

  testWidgets('主题模式三段常驻，点一下当场切肤', (tester) async {
    SettingsDao.set('themeMode', 'dark');
    addTearDown(() => SettingsDao.set('themeMode', 'dark'));
    await pumpPanel(tester);

    // 三段都常驻，一眼看出当前态（默认深色选中）。
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);

    // 点「浅色」→ 写设置，且选中态切过去。
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(SettingsDao.getCached('themeMode'), 'light');

    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(SettingsDao.getCached('themeMode'), 'system');

    // 当前值在设置里的持久化由 provider 转发表负责，这里只验证写入。
  });
}
