import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/terminal_themes.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/widgets/nav_drawer.dart';
import 'package:ai_terminal/widgets/settings_inline_panel.dart';
import 'package:ai_terminal/widgets/terminal_appearance_panel.dart';

/// 抽屉里的设置曾经展开是空的（detail 传了 const []），只有折叠箭头没有内容。
/// 这组测试盯的就是「展开之后真的有能用的控件」。
void main() {
  Future<void> pumpPanel(WidgetTester tester, String id) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: SettingsInlinePanel(settingsId: id),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> pumpDrawer(WidgetTester tester) async {
    // 抽屉里现在也带「关于」区（语言/版本/诊断），要拿 AppLocalizations，
    // 所以得挂本地化 delegate，否则设置分区直接抛空。
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NavDrawer(
            section: NavDrawer.sectionSettings,
            onOpenHost: (_) {},
            onRunSnippet: (_) {},
            onRunRunbook: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('外观面板的胶囊按内容收缩，三个主题在同一行', (tester) async {
    await pumpPanel(tester, 'appearance');

    // Container 带 alignment 时会在 Wrap 的宽松约束下横向撑满，整组 chip 就变成
    // 一列全宽按钮（抽屉里八个配色竖着占满一屏）。这条测试锁住"按内容收缩"。
    double chipWidth(String label) => tester
        .getSize(find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first)
        .width;

    expect(chipWidth('深色'), lessThan(120));
    expect(chipWidth('跟随系统'), lessThan(140));

    // 同一行的三个 chip 垂直中线必须一致（竖排会错开一格）。
    final yDark = tester.getCenter(find.text('深色')).dy;
    final yLight = tester.getCenter(find.text('浅色')).dy;
    final ySystem = tester.getCenter(find.text('跟随系统')).dy;
    expect(yDark, yLight);
    expect(yLight, ySystem);
  });

  testWidgets('外观面板给出主题、配色、字号的真实控件', (tester) async {
    await pumpPanel(tester, 'appearance');

    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);

    expect(find.text('终端配色'), findsOneWidget);
    // 每个预设都要能选，缩在抽屉里也不能只给一半
    for (final p in kTerminalPalettes) {
      expect(find.text(p.label(isZh: true)), findsWidgets,
          reason: '配色 ${p.id} 没有出现在抽屉里');
    }

    expect(find.text('字号'), findsOneWidget);
    expect(find.text('13px'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
  });

  testWidgets('通知面板能改开关、提醒时机，并直接填 Webhook', (tester) async {
    await pumpPanel(tester, 'notification');
    expect(find.text('任务完成提醒'), findsOneWidget);
    expect(find.text('仅失败'), findsOneWidget);
    expect(find.text('每次都提醒'), findsOneWidget);
    // 以前这里只显示「Webhook 未配置」，填地址得再进一个页面
    expect(find.text('Webhook 地址'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('联网搜索面板列出后端胶囊，而不是只给一个计数', (tester) async {
    await pumpPanel(tester, 'web_search');
    expect(find.text('允许 AI 联网搜索'), findsOneWidget);
    expect(find.text('后端'), findsOneWidget);
    // 默认只有 Bing RSS；能点掉、也能再加
    expect(find.text('Bing RSS'), findsOneWidget);
    expect(find.textContaining('添加'), findsWidgets);
  });

  testWidgets('安全面板给的是真开关，不是只读状态', (tester) async {
    await pumpPanel(tester, 'security');
    expect(find.text('应用锁'), findsOneWidget);
    expect(find.text('凭据存储'), findsOneWidget);
    expect(find.text('高危命令'), findsOneWidget);
    // 以前这里只有一行「应用锁 未开启」，想开还得进安全页
    expect(find.text('已关闭'), findsOneWidget);
  });

  testWidgets('Agent 面板给的是步数/超时的加减控件', (tester) async {
    await pumpPanel(tester, 'agent');
    expect(find.text('最大执行步数'), findsOneWidget);
    expect(find.text('单步响应超时'), findsOneWidget);
    // command_heuristics 一直在读这个键，但此前没有任何写入入口，
    // 等于「文档说有、实际设不了」，这条断言防止它再被删掉。
    expect(find.text('命令超时倍数'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsWidgets);
    expect(find.byIcon(Icons.remove), findsWidgets);
  });

  testWidgets('命令超时倍数的加号能把倍数推上去', (tester) async {
    await pumpPanel(tester, 'agent');
    // 默认 1.0x：库里的键从未被写过
    expect(find.text('1.0x'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('命令超时倍数'),
      matching: find.byType(Row),
    );
    final plus =
        find.descendant(of: row.first, matching: find.byIcon(Icons.add));
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
  });

  testWidgets('AI 模型面板在没有模型时说明去哪儿配', (tester) async {
    await pumpPanel(tester, 'ai');
    expect(find.textContaining('模型'), findsWidgets);
  });

  testWidgets('MCP 面板有总开关', (tester) async {
    await pumpPanel(tester, 'mcp');
    expect(find.text('启用 MCP'), findsOneWidget);
  });

  testWidgets('设置面板只给操作，不解释设计（回归）', (tester) async {
    // 曾经每个面板底部都挂一段「为什么这样设计」的说明，比如 AI 面板的
    // 「这里选的是「这次用哪个」，不是配置里的默认项」。这类句子既不改变值，
    // 也不提示异常，只让用户多读一遍——已经全删。这条测试防止它们被重新加回来。
    const banned = [
      '这次用哪个',
      '默认项',
      '立即生效',
      '安全页里',
      '常识性资料',
      '每次执行都会读',
      '步数用完',
      '等于没开',
      '发不出去也',
    ];
    for (final id in [
      'appearance',
      'ai',
      'agent',
      'security',
      'mcp',
      'web_search',
      'knowledge_rules',
      'notification',
    ]) {
      await pumpPanel(tester, id);
      for (final phrase in banned) {
        expect(find.textContaining(phrase), findsNothing,
            reason: '「$id」面板里又冒出说明文字：$phrase');
      }
    }
  });

  testWidgets('外观组把原独立页里的三项也搬齐了', (tester) async {
    await pumpPanel(tester, 'appearance');

    // 这三项原来只在「外观」独立页里。路由收掉之后如果不搬过来，
    // 用户就再也改不了回滚行数 / 会话日志 / 快捷键了。
    expect(find.text('回滚缓冲行数'), findsOneWidget);
    expect(find.text('自动会话日志'), findsOneWidget);
    expect(find.text('终端快捷键'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    // 配色必须给预览，不能只给名字
    expect(find.byType(TerminalPalettePreview), findsOneWidget);
  });

  testWidgets('抽屉里展开「外观」能看到控件而不是空块', (tester) async {
    await pumpDrawer(tester);

    // 收起态：只有副标题，没有控件
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题模式'), findsNothing);

    await tester.tap(find.text('外观'));
    await tester.pump();

    // 展开态：真的渲染出面板
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.byType(SettingsInlinePanel), findsWidgets);
  });

  testWidgets('抽屉设置项副标题读的是状态而不是固定文案', (tester) async {
    await pumpDrawer(tester);
    // 外观副标题 = 主题 + 字号，至少要有 px
    expect(find.textContaining('px'), findsWidgets);
    // 每个分组都应有 rowcard（8 项）。设置分区顶部有搜索框，末组会落在
    // 视口之外（ListView 懒加载不会构建它），所以逐个滚到可见再断言。
    for (final title in const [
      '外观',
      'AI 模型',
      'Agent',
      '安全',
      'MCP 服务器',
      '联网搜索',
      '内部规范',
      '通知',
    ]) {
      await tester.scrollUntilVisible(find.text(title), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(title), findsOneWidget, reason: '缺少分组 $title');
    }
  });
}
