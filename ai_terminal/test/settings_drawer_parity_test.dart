import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/settings_catalog.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/widgets/nav_drawer.dart';

/// 抽屉里的「设置」曾经只有八组配置，而整页设置还有「管理」和「关于」。
/// 于是同一件事有两份不同的清单：用户看抽屉里那八行，会以为设置就这些；
/// 进了整页又冒出一堆没见过的项，只能怀疑自己记错了。
///
/// 这组测试锁的是**同一份清单**：抽屉里点得到的东西，和整页设置里完全一致，
/// 没有「其余的去设置页」这种把用户往外推的半成品清单。
void main() {
  Future<void> pumpDrawer(WidgetTester tester, {String? initialGroup}) async {
    // 抽屉里是懒加载 ListView，视口不够高的话下面的分组根本不会构建，
    // 断言会误报「没有这一项」。拉高视口一次全建出来。
    tester.view.physicalSize = const Size(420, 3200);
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
            section: NavDrawer.sectionSettings,
            initialGroup: initialGroup,
            onOpenHost: (_) {},
            onRunSnippet: (_) {},
            onRunRunbook: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('八组配置一项不少', (tester) async {
    await pumpDrawer(tester);

    for (final entry in kSettingsEntries) {
      expect(find.text(entry.title), findsOneWidget,
          reason: '抽屉设置里缺少分组「${entry.title}」');
    }
  });

  testWidgets('顶部分区标签能切到主机，且不是关掉抽屉', (tester) async {
    await pumpDrawer(tester);

    // 标签是「主机」，标题才是「主机管理」。
    await tester.tap(find.text('主机').first);
    await tester.pumpAndSettle();

    expect(find.text('主机管理'), findsOneWidget);
    // 抽屉还在：五个分区标签都还在（标签不是下钻，切过去不会把它自己也切掉）。
    for (final s in NavDrawer.shortTitles.values) {
      expect(find.text(s), findsWidgets, reason: '切分区后少了标签「$s」');
    }
  });

  testWidgets('「关于」区在抽屉里也在', (tester) async {
    await pumpDrawer(tester);

    expect(find.text('关于'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
  });

  testWidgets('没有「其余的去设置页」这种半份清单的尾巴', (tester) async {
    await pumpDrawer(tester);

    // 下面这些文案以前就是「这里只有一部分」的自我说明。清单补齐之后它们
    // 既不该出现，也不该以任何形式暗示「还有东西在别处」。
    expect(find.text('打开设置页'), findsNothing);
    expect(find.textContaining('进整页'), findsNothing);
    expect(find.textContaining('常用开关'), findsNothing);
    expect(find.textContaining('打开完整'), findsNothing);
  });

  testWidgets('配色浮层的「更多」能直接落到终端组', (tester) async {
    await pumpDrawer(tester, initialGroup: 'terminal');

    // 组是展开状态：展开区里的控件直接可见，不用再点一次。
    expect(find.text('回滚缓冲行数'), findsOneWidget);
    expect(find.text('自动会话日志'), findsOneWidget);
  });
}
