import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/core/settings_catalog.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/widgets/nav_drawer.dart';

/// 抽屉的五层结构：一个载体，内部分层。
///
/// 钉死这几条：
/// 1. 五个分区用顶部标签平级切换，不关闭抽屉、不开第二个浮层；
/// 2. 进入编辑（新增主机 / 新建命令 / 新建工作流）时抽屉不下钻成新页面，
///    顶栏出现 ← 返回；
/// 3. 手机宽度（360）下五个分区 + 各类编辑表单都不溢出。
void main() {
  setUp(() {
    McpManager.instance.loadConfigsForTesting([]);
    // 主机表单读 L10n.str（非 Widget 路径），这里补上初始化。
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  tearDown(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  Future<void> pumpDrawer(
    WidgetTester tester, {
    String section = NavDrawer.sectionSnippets,
    Size size = const Size(900, 1400),
    bool withTerminalActions = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NavDrawer(
            section: section,
            onOpenHost: withTerminalActions ? (_) {} : null,
            onRunSnippet: withTerminalActions ? (_) {} : null,
            onRunRunbook: withTerminalActions ? (_) {} : null,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('五个分区是同一条顶栏上的标签，切换不关抽屉', (tester) async {
    await pumpDrawer(tester);

    for (final s in NavDrawer.kDrawerSections) {
      expect(find.text(NavDrawer.shortTitles[s]!), findsOneWidget,
          reason: '缺少分区标签「${NavDrawer.shortTitles[s]}」');
    }

    // 切到审计：标题变「审计日志」，标签还在（说明抽屉没关也没新开）。
    await tester.tap(find.text('审计'));
    await tester.pumpAndSettle();
    expect(find.text('审计日志'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.byType(NavDrawer), findsOneWidget);
  });

  testWidgets('新建快捷命令是抽屉内下钻，顶栏出现返回', (tester) async {
    await pumpDrawer(tester);

    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    await tester.tap(find.text('新建快捷命令'));
    await tester.pumpAndSettle();

    // 同一层抽屉里换成了表单：标题变了，返回出现，✕ 仍可整体关闭。
    expect(find.text('新建快捷命令'), findsWidgets);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);

    // 返回退回列表，抽屉还在。
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.text('快捷命令'), findsOneWidget);
  });

  testWidgets('新建工作流也是同一条路径', (tester) async {
    await pumpDrawer(tester, section: NavDrawer.sectionRunbooks);

    await tester.tap(find.text('新建工作流'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    // 表单里的关键字段在（图标 / 名称 / 类型 / 分类 / 内容）
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
  });

  testWidgets('新增主机用的是同一份主机表单，不是第二个页面', (tester) async {
    await pumpDrawer(tester, section: NavDrawer.sectionHosts);

    await tester.tap(find.text('新增主机'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    // 主机表单自己的字段（不是另做一份简版）
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('主机地址 *'), findsOneWidget);
    // 没有 push 新路由：屏幕上的 Scaffold 还是同一个（抽屉自带一个）。
    expect(find.byType(NavDrawer), findsOneWidget);
  });

  testWidgets('手机宽度 360 下五个分区都不溢出', (tester) async {
    await pumpDrawer(tester, size: const Size(360, 780));

    for (final s in NavDrawer.kDrawerSections) {
      await tester.tap(find.text(NavDrawer.shortTitles[s]!));
      await tester.pumpAndSettle();
      // 溢出会被 Flutter 记为异常，这里直接断言没有。
      expect(tester.takeException(), isNull,
          reason: '分区「${NavDrawer.shortTitles[s]}」在 360 宽下溢出了');
    }
  });

  testWidgets('手机宽度 360 下新建快捷命令表单不溢出', (tester) async {
    await pumpDrawer(tester, size: const Size(360, 780));

    await tester.tap(find.text('新建快捷命令'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('命令'), findsWidgets);
  });

  testWidgets('手机宽度 360 下设置八组展开都不溢出', (tester) async {
    await pumpDrawer(tester,
        section: NavDrawer.sectionSettings, size: const Size(360, 900));

    for (final entry in kSettingsEntries) {
      // 360×900 一屏放不下八组，逐个滚到眼前再点。
      await tester.scrollUntilVisible(find.text(entry.title), 240,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.title).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '设置组「${entry.title}」在 360 宽下溢出了');
    }
  });

  testWidgets('手机宽度 360 下关于区（语言 / 诊断）不溢出', (tester) async {
    await pumpDrawer(tester,
        section: NavDrawer.sectionSettings, size: const Size(360, 900));

    await tester.scrollUntilVisible(find.text('语言'), 240,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('语言'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('审计条目在抽屉里就能展开看命令和输出，不用跳整页', (tester) async {
    // 有记录才谈得上展开；一条都没有时这一屏只该是空态。
    await AuditLogsDao.add(
      hostId: 'h1',
      command: 'rm -rf /tmp/foo',
      safetyLevel: 'blocked',
      output: 'blocked by policy',
      executed: false,
    );

    await pumpDrawer(tester, section: NavDrawer.sectionAudit);
    await tester.pumpAndSettle();

    // 折叠态：命令在标题行，拦掉的记录带「拦截」标记。
    expect(find.textContaining('rm -rf /tmp/foo'), findsOneWidget);
    expect(find.text('拦截'), findsOneWidget);
    // 输出默认收着。
    expect(find.text('blocked by policy'), findsNothing);

    await tester.tap(find.textContaining('rm -rf /tmp/foo'));
    await tester.pumpAndSettle();

    // 展开后输出就在这一层里，没有第二个页面、没有对话框。
    expect(find.text('blocked by policy'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('没有终端上下文时抽屉不摆「执行」按钮', (tester) async {
    // 聊天页这类地方打开抽屉只能看和改：给了「执行」却没有会话可执行，
    // 等于骗一次点击。
    await pumpDrawer(tester, withTerminalActions: false);
    await tester.tap(find.text('新建快捷命令'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '看磁盘');
    await tester.enterText(find.byType(TextField).at(1), 'df -h');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 回到列表。条目默认收着，先展开才看得到行内动作。
    await tester.tap(find.textContaining('看磁盘'));
    await tester.pumpAndSettle();

    // 命令看得到，「编辑」还在（抽屉自己就能改），但没有「执行」。
    expect(find.textContaining('df -h'), findsWidgets);
    expect(find.text('执行'), findsNothing);
    expect(find.text('编辑'), findsOneWidget, reason: '编辑仍然要在，抽屉自己就能改');
  });
}
