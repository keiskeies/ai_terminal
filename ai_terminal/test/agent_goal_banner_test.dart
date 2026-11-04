import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/agent_goal.dart';
import 'package:ai_terminal/widgets/agent_goal_banner.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.darkTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Builder(builder: (context) => child),
        ),
      ),
    );

AgentGoal _goal({
  AgentGoalStatus status = AgentGoalStatus.active,
  int roundsUsed = 3,
  int maxRounds = 24,
  String? note,
}) {
  final now = DateTime(2026, 11, 1);
  return AgentGoal(
    id: 'g1',
    hostId: 'web1',
    objective: '把 nginx 日志轮转配好并验证切割生效',
    status: status,
    roundsUsed: roundsUsed,
    maxRounds: maxRounds,
    note: note,
    createdAt: now,
    updatedAt: now,
  );
}

/// 目标横幅测试。
///
/// 重点是三个操作必须在横幅上：任务运行中输入框被禁用（`AIPromptInput._send`
/// 遇 isRunning 直接 return），只靠 `/goal` 命令用户就没法中途停下自动续跑。
void main() {
  Future<void> pumpBanner(
    WidgetTester tester,
    AgentGoal goal, {
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onFinish,
    ValueChanged<String>? onEdit,
  }) async {
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => AgentGoalBanner(
        goal: goal,
        tc: ThemeColors.of(context),
        onPause: onPause,
        onResume: onResume,
        onFinish: onFinish,
        onEdit: onEdit,
      ),
    )));
  }

  testWidgets('进行中：标题、目标原文与轮次余量同屏', (tester) async {
    await pumpBanner(tester, _goal());

    expect(find.text('进行中的目标'), findsOneWidget);
    expect(find.textContaining('nginx 日志轮转'), findsOneWidget);
    expect(find.text('轮次 3/24'), findsOneWidget);
    expect(find.text('剩 21 轮'), findsOneWidget);
  });

  testWidgets('进行中：暂停与结束都在，且不需要输入框', (tester) async {
    var paused = false;
    var finished = false;
    await pumpBanner(tester, _goal(),
        onPause: () => paused = true, onFinish: () => finished = true);

    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(find.byTooltip('编辑目标'), findsOneWidget);
    expect(find.byTooltip('结束目标'), findsOneWidget);

    await tester.tap(find.byTooltip('暂停'));
    expect(paused, isTrue);
    expect(finished, isFalse);
  });

  testWidgets('结束目标走二次确认，确认后才回调', (tester) async {
    var finished = false;
    await pumpBanner(tester, _goal(), onFinish: () => finished = true);

    await tester.tap(find.byTooltip('结束目标'));
    await tester.pumpAndSettle();
    expect(finished, isFalse, reason: '未确认前不该结束长期目标');
    expect(find.text('结束这个目标？'), findsOneWidget);

    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
  });

  testWidgets('已暂停：出现恢复而不是暂停，并显示暂停原因', (tester) async {
    var resumed = false;
    await pumpBanner(
      tester,
      _goal(status: AgentGoalStatus.paused, note: '上一轮任务失败，目标已暂停'),
      onResume: () => resumed = true,
    );

    expect(find.text('已暂停的目标'), findsOneWidget);
    expect(find.text('上一轮任务失败，目标已暂停'), findsOneWidget);
    expect(find.byTooltip('恢复'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsNothing);

    await tester.tap(find.byTooltip('恢复'));
    expect(resumed, isTrue);
  });

  testWidgets('已结束：按钮变成清除记录，且直接生效不弹确认', (tester) async {
    var cleared = false;
    await pumpBanner(
      tester,
      _goal(status: AgentGoalStatus.finished, note: '轮次预算耗尽（24/24）'),
      onFinish: () => cleared = true,
    );

    expect(find.text('已结束的目标'), findsOneWidget);
    expect(find.byTooltip('清除记录'), findsOneWidget);
    // 预算用尽的说明要留在界面上，否则用户不知道为什么不动了
    expect(find.text('轮次预算耗尽（24/24）'), findsOneWidget);
    // 已结束不再显示"剩几轮"
    expect(find.textContaining('剩'), findsNothing);

    await tester.tap(find.byTooltip('清除记录'));
    expect(cleared, isTrue);
  });

  testWidgets('预算用尽的进行中目标显示用尽而不是剩 0 轮', (tester) async {
    await pumpBanner(tester, _goal(roundsUsed: 24, maxRounds: 24));

    expect(find.text('轮次已用尽'), findsOneWidget);
    expect(find.textContaining('剩'), findsNothing);
  });
}
