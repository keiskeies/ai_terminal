import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/settings_catalog.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/pages/settings_page.dart';

/// 设置页曾经是三层的：设置 → 点开一组 → 点「打开完整页面」进二级页面，
/// 而那个二级页面又是另一套配色。这组测试盯两件事：
/// 1. 八组设置**一次全部**渲染出来，不用点开；
/// 2. 需要在别处才能做的操作（加端点、加服务器、加规则、填 Webhook）现在都在原地。
void main() {
  Future<void> pumpSettings(WidgetTester tester) async {
    // 默认 800×600 的视口只够渲染前两组，ListView 懒加载会让后面的分组根本
    // 不被构建，断言就会误报「没渲染」。把视口拉高，一次全建出来。
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsPage(),
      ),
    ));
    await tester.pump();
  }

  testWidgets('八组设置常驻可见，没有折叠箭头也没有「打开完整页面」', (tester) async {
    await pumpSettings(tester);

    for (final entry in kSettingsEntries) {
      expect(find.text(entry.title), findsWidgets,
          reason: '分组「${entry.title}」没有直接出现在设置页里');
    }

    // 展开式 rowcard 的向下箭头、跳转式卡片的「打开完整页面」都不该出现在这八组上
    expect(find.textContaining('打开完整页面'), findsNothing);
    expect(find.textContaining('打开完整设置'), findsNothing);
  });

  testWidgets('高频开关不用点开就能改', (tester) async {
    await pumpSettings(tester);

    // 终端：缓冲/会话日志/快捷键（主题·配色·字号已移到顶栏浮层，不在设置里）
    expect(find.text('回滚缓冲行数'), findsOneWidget);
    expect(find.text('自动会话日志'), findsOneWidget);
    expect(find.text('终端快捷键'), findsOneWidget);

    // Agent：三个步进器
    expect(find.text('最大执行步数'), findsOneWidget);
    expect(find.text('单步响应超时'), findsOneWidget);
    expect(find.text('命令超时倍数'), findsOneWidget);

    // 通知：Webhook 直接可填
    expect(find.text('Webhook 地址'), findsOneWidget);
  });

  testWidgets('增删改的入口都在组内，不需要进二级页面', (tester) async {
    await pumpSettings(tester);

    // AI 端点 / MCP 服务器 / 内部规范 各自的添加入口
    expect(find.text('端点'), findsOneWidget);
    expect(find.text('添加端点'), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('添加规则'), findsOneWidget);
  });

  testWidgets('管理入口与关于区也在同一页里', (tester) async {
    await pumpSettings(tester);

    // 设置是一份清单：八组配置之后的「管理」（独立功能页）和「关于」
    // （语言 / 版本 / 诊断）都得在，抽屉里调的是同两个组件。
    for (final s in settingsShortcuts()) {
      expect(find.text(s.title), findsOneWidget,
          reason: '缺少管理入口「${s.title}」');
    }
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
  });

  testWidgets('本地文件授权与清除数据也在设置页里', (tester) async {
    await pumpSettings(tester);

    // 这一块以前只在 Agent 设置页里，想改授权目录得再进一层
    expect(find.textContaining('允许 Agent 读写'), findsOneWidget);
    expect(find.text('授权目录'), findsOneWidget);
    expect(find.text('添加目录'), findsOneWidget);
    // 危险操作留在原地，但要带确认
    expect(find.text('清除本机数据'), findsOneWidget);
  });
}
