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

/// 设置分区的两件事：能搜、能看出自己改过什么。
///
/// 钉死这几条：
/// 1. 设置是五个分区里唯一有几十个选项的，必须有搜索框；
/// 2. 搜到就自动展开 —— 搜到了还要再点一下才看得见，等于没搜；
/// 3. 全默认时「已修改」区不渲染（零占位），改过才出现；
/// 4. 组序是上手顺序，不是功能分类序。
void main() {
  setUp(() {
    McpManager.instance.loadConfigsForTesting([]);
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
    // 读一次缓存，确保「已修改」区在测试里看到的是真实默认值（全默认 → 不渲染）。
    SettingsDao.cachedMap;
  });

  tearDown(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(900, 1400),
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
        home: const Scaffold(
          body: NavDrawer(section: NavDrawer.sectionSettings),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField).first, q);
    await tester.pumpAndSettle();
  }

  testWidgets('设置分区有搜索框，输入「超时」只剩 Agent 组', (tester) async {
    await pumpSettings(tester);

    // 五个分区里唯独设置此前没有搜索框，这里必须有。
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('搜索设置项'), findsOneWidget);

    await search(tester, '超时');

    expect(find.text('Agent'), findsOneWidget, reason: '「超时」属于 Agent 组');
    expect(find.text('终端'), findsNothing, reason: '没命中的组要隐藏');
    expect(find.text('通知'), findsNothing);
  });

  testWidgets('搜索命中后该组自动展开，直接看到选项', (tester) async {
    await pumpSettings(tester);
    await search(tester, '超时');

    // 展开才会渲染出来的字段标签。
    expect(find.text('单步响应超时'), findsOneWidget,
        reason: '命中即展开，不该再要求点一次');
  });

  testWidgets('搜组名也能命中，且点开是同一个组', (tester) async {
    await pumpSettings(tester);
    await search(tester, 'mcp');
    expect(find.text('MCP 服务器'), findsOneWidget);

    await search(tester, '终端');
    // 搜索框输入文字与组标题同名，两处都会命中，用 findsWidgets。
    expect(find.text('终端'), findsWidgets);
    expect(find.text('MCP 服务器'), findsNothing);
  });

  testWidgets('搜索无命中给空态，不显示八组', (tester) async {
    await pumpSettings(tester);
    await search(tester, 'zzz不存在');

    expect(find.textContaining('没有叫'), findsOneWidget);
    expect(find.text('终端'), findsNothing);
    expect(find.text('关于'), findsNothing);
  });

  testWidgets('清空搜索后八组恢复，关于区回归', (tester) async {
    await pumpSettings(tester);
    await search(tester, '超时');
    expect(find.text('终端'), findsNothing);

    await search(tester, '');
    for (final e in kSettingsEntries) {
      expect(find.text(e.title), findsOneWidget, reason: '恢复后缺「${e.title}」');
    }
    await tester.scrollUntilVisible(find.text('关于'), 240,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('搜索时「关于」区隐藏', (tester) async {
    await pumpSettings(tester);
    await search(tester, '字号');
    expect(find.text('关于'), findsNothing);
  });

  testWidgets('组序是上手顺序：终端 → AI → Agent → 安全 → MCP → 联网 → 规范 → 通知',
      (tester) async {
    await pumpSettings(tester);
    final order = kSettingsEntries.map((e) => e.title).toList();
    expect(order, [
      '终端',
      'AI 模型',
      'Agent',
      '安全',
      'MCP 服务器',
      '联网搜索',
      '内部规范',
      '通知',
    ]);
  });

  testWidgets('全默认时没有「已修改」区', (tester) async {
    await pumpSettings(tester);
    expect(find.text('已修改'), findsNothing,
        reason: '全默认时整块不渲染，不给一个永远空着的区块');
  });

  testWidgets('改过缓冲后出现「已修改」区，点行展开终端组', (tester) async {
    // 先改一项：缓冲行数 10000 → 50000。
    await SettingsDao.set('terminalScrollback', 50000);
    addTearDown(() => SettingsDao.set('terminalScrollback', 10000));

    await pumpSettings(tester);

    expect(find.text('已修改'), findsOneWidget);
    expect(find.text('5 万行'), findsOneWidget, reason: '摘要要显示当前值');

    // 点这一行 → 终端组展开（展开后才会出现「自动会话日志」这类字段标签）。
    await tester.tap(find.text('5 万行'));
    await tester.pumpAndSettle();
    expect(find.text('自动会话日志'), findsOneWidget);
  });

  testWidgets('改回默认后「已修改」区消失', (tester) async {
    await SettingsDao.set('terminalScrollback', 50000);
    await pumpSettings(tester);
    expect(find.text('已修改'), findsOneWidget);

    await SettingsDao.set('terminalScrollback', 10000);
    // 触发重建：搜索一次再清空。
    await search(tester, '缓冲');
    await search(tester, '');
    expect(find.text('已修改'), findsNothing);
  });

  testWidgets('手机宽度 360 下设置搜索与组列表不溢出', (tester) async {
    await pumpSettings(tester, size: const Size(360, 780));
    expect(tester.takeException(), isNull);

    await search(tester, '超时');
    expect(tester.takeException(), isNull);
  });

  // —— 以下是审查后补的回归：搜组标题、清空按钮、搜索态可折叠 ——

  testWidgets('搜组标题必须命中（用户是照着组名念的）', (tester) async {
    await pumpSettings(tester);

    // 索引表里没有「终端」「安全」这两个词，标题若不参与匹配就会给空态。
    // 断言用 `findsWidgets` 而不是 `findsOneWidget`：搜索框里的输入文字
    // 本身也是一个 Text（EditableText），搜「终端」时会出现两处。
    for (final title in ['终端', '安全', 'AI 模型', 'MCP 服务器']) {
      await search(tester, title);
      expect(find.textContaining('没有叫'), findsNothing,
          reason: '搜组标题「$title」不该落空');
      expect(find.text(title), findsWidgets, reason: '「$title」应当命中自身');
    }
  });

  testWidgets('搜英文关键词能命中（英文 locale 的兜底）', (tester) async {
    await pumpSettings(tester);

    for (final (query, expectTitle) in [
      ('terminal', '终端'),
      ('scrollback', '终端'),
      ('timeout', 'Agent'),
      ('endpoint', 'AI 模型'),
    ]) {
      await search(tester, query);
      expect(find.text(expectTitle), findsWidgets,
          reason: '搜「$query」应当命中「$expectTitle」');
    }
  });

  testWidgets('搜索框有内容时出现 ✕，点击清空并恢复八组', (tester) async {
    await pumpSettings(tester);

    // 搜索框内的 ✕ 用 find.descendant 限定，否则会撞上抽屉头部的关闭按钮
    // （两者都是 Icons.close_rounded）。
    Finder clearBtn() => find.descendant(
          of: find.byType(TextField).first,
          matching: find.byIcon(Icons.close_rounded),
        );

    expect(clearBtn(), findsNothing, reason: '空查询不该有清空按钮');

    await search(tester, '超时');
    expect(clearBtn(), findsOneWidget);

    await tester.tap(clearBtn());
    await tester.pumpAndSettle();

    expect(clearBtn(), findsNothing, reason: '清空后按钮应当消失');
    for (final e in kSettingsEntries) {
      expect(find.text(e.title), findsOneWidget, reason: '恢复后缺「${e.title}」');
    }
  });

  testWidgets('搜索命中后点卡片能收起（不是硬性展开）', (tester) async {
    await pumpSettings(tester);
    await search(tester, '超时');

    // 命中即展开：能看到组内选项。
    expect(find.text('单步响应超时'), findsOneWidget);

    // 点一下应收起来 —— 以前 expanded 写死 `searching || ...`，点了没反应。
    await tester.tap(find.text('Agent'));
    await tester.pumpAndSettle();
    expect(find.text('单步响应超时'), findsNothing,
        reason: '搜索态下卡片也必须是可折叠的，否则点击无反馈');

    // 再点一下还能展开回来。
    await tester.tap(find.text('Agent'));
    await tester.pumpAndSettle();
    expect(find.text('单步响应超时'), findsOneWidget);
  });

  testWidgets('「已修改」超过 5 项时折叠并显示「还有 N 项」', (tester) async {
    // _changedSettings() 只追踪 6 个键（缓冲/会话日志/步数/超时/超时倍数/应用锁），
    // 所以「超过 5 项」只可能是 6 项 —— 造满这 6 个。
    await SettingsDao.set('terminalScrollback', 50000);
    await SettingsDao.set('sessionLogEnabled', true);
    await SettingsDao.set('agentMaxSteps', 40);
    await SettingsDao.set('agentAiTimeoutSeconds', 300);
    await SettingsDao.set('commandTimeoutMultiplier', 2.0);
    await SettingsDao.set('appLockEnabled', true);
    addTearDown(() async {
      await SettingsDao.set('terminalScrollback', 10000);
      await SettingsDao.set('sessionLogEnabled', false);
      await SettingsDao.set('agentMaxSteps', 0);
      await SettingsDao.set('agentAiTimeoutSeconds', 120);
      await SettingsDao.set('commandTimeoutMultiplier', 1.0);
      await SettingsDao.set('appLockEnabled', false);
    });

    await pumpSettings(tester);

    expect(find.text('已修改'), findsOneWidget);
    // 6 项 > kChangedPreview(5)：多出来的那项必须明说，不能静默丢掉。
    expect(find.text('还有 1 项'), findsOneWidget,
        reason: '超过 5 项要给「还有 N 项」而不是静默截断');

    // 点一下 → 摊开全部，折叠提示变成「收起」。
    await tester.tap(find.text('还有 1 项'));
    await tester.pumpAndSettle();
    expect(find.text('还有 1 项'), findsNothing);
    expect(find.text('收起'), findsOneWidget);
  });
}