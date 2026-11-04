import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';
import 'package:ai_terminal/widgets/operation_sheet.dart';
import 'package:ai_terminal/widgets/plan_panel.dart';

Widget _wrapWithTheme(
  Widget child,
  ThemeData theme, {
  Locale locale = const Locale('zh'),
}) {
  return MaterialApp(
    theme: theme,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Builder(
          builder: (context) => child,
        ),
      ),
    ),
  );
}

Widget _wrap(Widget child) => _wrapWithTheme(child, AppTheme.darkTheme);

Widget _wrapLight(Widget child) => _wrapWithTheme(child, AppTheme.lightTheme);

Widget _wrapEnglish(Widget child) =>
    _wrapWithTheme(child, AppTheme.darkTheme, locale: const Locale('en'));

void main() {
  group('OperationSheet', () {
    testWidgets('renders goal, conclusion, status and evidence toggle',
        (tester) async {
      const report = OperationReport(
        operationId: 'op-1',
        goal: '在 web-01 上部署 Nginx',
        hostId: 'web-01',
        elapsedSeconds: 252,
        stepIndex: 9,
        commandSuccessCount: 8,
        commandFailureCount: 1,
        conclusion: 'Nginx 已安装并运行。',
        details: '结论: Nginx 已安装并运行。\n现状: active',
        changeRecordIds: ['chg-1', 'chg-2'],
        stateBadges: [
          OperationBadge(text: 'nginx 运行中', level: 'success'),
          OperationBadge(text: '端口 443 监听', level: 'success'),
        ],
        changes: [
          OperationChange(
            id: 'chg-1',
            command: 'apt install nginx',
            type: 'install',
            rollbackCommand: 'apt remove nginx',
            success: true,
            additions: 3,
            deletions: 1,
          ),
          OperationChange(
            id: 'chg-2',
            command: 'systemctl restart nginx',
            type: 'restartService',
            success: true,
          ),
        ],
        plan: [
          PlanStep(title: '检查系统', status: PlanStepStatus.completed),
          PlanStep(title: '安装 Nginx', status: PlanStepStatus.completed),
          PlanStep(title: '验证服务', status: PlanStepStatus.completed),
        ],
        nextActions: ['配置 HTTPS'],
        aiGenerated: true,
        finishState: 'success',
      );

      var auditOpened = false;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const Text('EVIDENCE'),
          onOpenAudit: () => auditOpened = true,
        ),
      )));

      expect(find.text('在 web-01 上部署 Nginx'), findsOneWidget);
      expect(find.text('Nginx 已安装并运行。'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('AI 结论'), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('4m12s'), findsOneWidget);
      expect(find.text('第 9 步'), findsOneWidget);
      expect(find.text('9 条命令'), findsOneWidget);
      expect(find.text('1 失败'), findsOneWidget);
      expect(find.text('2 项变更'), findsOneWidget);
      expect(find.text('nginx 运行中'), findsOneWidget);
      expect(find.text('端口 443 监听'), findsOneWidget);
      expect(find.text('执行清单'), findsOneWidget);
      expect(find.textContaining('3 项 · 3 完成'), findsOneWidget);
      expect(find.textContaining('计划仍有未收尾步骤'), findsNothing);
      expect(find.text('安装 Nginx'), findsOneWidget);
      expect(find.text('变更与回滚'), findsOneWidget);
      expect(find.text('可回滚'), findsOneWidget);
      expect(find.text('需人工'), findsOneWidget);
      expect(find.textContaining('回滚：apt remove nginx'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(find.text('配置 HTTPS'), findsOneWidget);
      expect(find.text('继续任务'), findsNothing);
      expect(find.text('审计记录'), findsOneWidget);
      await tester.tap(find.text('审计记录'));
      expect(auditOpened, isTrue);
      expect(find.text('过程与证据'), findsOneWidget);
      expect(find.text('EVIDENCE'), findsNothing);

      await tester.tap(find.text('过程与证据'));
      await tester.pump();

      expect(find.text('完整总结'), findsOneWidget);
      expect(find.text('EVIDENCE'), findsOneWidget);
    });

    testWidgets('renders answer body in the conclusion layer, not the fold',
        (tester) async {
      const report = OperationReport(
        operationId: 'op-2',
        goal: '检查 GDM 状态',
        hostId: 'web-01',
        elapsedSeconds: 8,
        stepIndex: 2,
        commandSuccessCount: 2,
        commandFailureCount: 0,
        conclusion: 'GDM 运行状态正常。',
        answerBody: '## GDM 运行状态正常\n\nsystemd-logind 与 gdm 均在运行。',
        aiGenerated: true,
        finishState: 'success',
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const Text('EVIDENCE'),
        ),
      )));

      expect(find.textContaining('systemd-logind 与 gdm 均在运行'), findsOneWidget,
          reason: '回答正文必须默认可见，不能藏在"过程与证据"里');
      expect(find.text('EVIDENCE'), findsNothing);

      await tester.tap(find.text('过程与证据'));
      await tester.pump();
      expect(find.text('EVIDENCE'), findsOneWidget);
    });

    testWidgets('does not repeat the answer body when it equals the conclusion',
        (tester) async {
      const report = OperationReport(
        operationId: 'op-3',
        goal: '检查状态',
        elapsedSeconds: 2,
        stepIndex: 1,
        commandSuccessCount: 1,
        commandFailureCount: 0,
        conclusion: '服务运行正常。',
        answerBody: '## 服务运行正常。',
        aiGenerated: true,
        finishState: 'success',
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const Text('EVIDENCE'),
        ),
      )));

      expect(find.text('服务运行正常。'), findsOneWidget);
    });

    testWidgets('failed report shows failure label and no AI badge',
        (tester) async {
      const report = OperationReport(
        operationId: 'op-2',
        goal: '清理日志',
        elapsedSeconds: 12,
        stepIndex: 2,
        commandSuccessCount: 1,
        commandFailureCount: 1,
        conclusion: '任务执行失败：权限不足',
        finishState: 'failed',
      );

      var continued = false;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const SizedBox.shrink(),
          hasEvidence: false,
          onContinueOperation: () => continued = true,
        ),
      )));

      expect(find.text('失败'), findsOneWidget);
      expect(find.text('AI 结论'), findsNothing);
      expect(find.text('任务执行失败：权限不足'), findsOneWidget);
      expect(find.text('继续任务'), findsOneWidget);
      await tester.tap(find.text('继续任务'));
      expect(continued, isTrue);
    });
  });

  group('计划收尾', () {
    testWidgets('success report with unfinished plan shows warning',
        (tester) async {
      const report = OperationReport(
        operationId: 'op-plan',
        goal: '检查系统',
        elapsedSeconds: 5,
        stepIndex: 2,
        commandSuccessCount: 1,
        commandFailureCount: 0,
        conclusion: '检查完成',
        plan: [
          PlanStep(title: '检查系统', status: PlanStepStatus.completed),
          PlanStep(title: '输出总结', status: PlanStepStatus.inProgress),
        ],
        finishState: 'success',
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const SizedBox.shrink(),
          hasEvidence: false,
        ),
      )));

      expect(find.textContaining('计划仍有未收尾步骤'), findsOneWidget);
    });
  });

  group('回滚操作', () {
    const report = OperationReport(
      operationId: 'op-r',
      goal: '安装 Nginx',
      hostId: 'web-01',
      elapsedSeconds: 10,
      stepIndex: 2,
      commandSuccessCount: 1,
      commandFailureCount: 0,
      conclusion: '已安装',
      changeRecordIds: ['chg-r'],
      changes: [
        OperationChange(
          id: 'chg-r',
          command: 'sudo apt install nginx',
          type: 'install',
          rollbackCommand: 'sudo apt remove nginx',
          success: true,
        ),
      ],
      finishState: 'success',
    );

    OperationSheet buildSheet(
      BuildContext context, {
      void Function(OperationChange change, String? hostId)? onRollback,
      Set<String> rolledBack = const {},
      bool busy = false,
    }) {
      return OperationSheet(
        report: report,
        tc: ThemeColors.of(context),
        markdownBuilder: (text, tc) => Text(text),
        evidenceBuilder: () => const SizedBox.shrink(),
        hasEvidence: false,
        rolledBackChangeIds: rolledBack,
        onRollbackChange: onRollback,
        rollbackBusy: busy,
      );
    }

    testWidgets('rollback button passes change and host to callback',
        (tester) async {
      OperationChange? selected;
      String? selectedHost;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => buildSheet(
          context,
          onRollback: (change, hostId) {
            selected = change;
            selectedHost = hostId;
          },
        ),
      )));

      expect(find.text('回滚'), findsOneWidget);
      await tester.tap(find.text('回滚'));
      await tester.pump();

      expect(selected?.id, 'chg-r');
      expect(selectedHost, 'web-01');
    });

    testWidgets('rolled back change shows completed state without button',
        (tester) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => buildSheet(
          context,
          onRollback: (_, __) {},
          rolledBack: const {'chg-r'},
        ),
      )));

      expect(find.text('已回滚'), findsOneWidget);
      expect(find.text('已执行回滚'), findsOneWidget);
      expect(find.text('回滚'), findsNothing);
    });

    testWidgets('busy state disables rollback button', (tester) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => buildSheet(
          context,
          onRollback: (_, __) {},
          busy: true,
        ),
      )));

      expect(find.text('回滚中'), findsOneWidget);
      expect(find.text('回滚'), findsNothing);
    });
  });

  group('PlanPanel', () {
    testWidgets('long plan is collapsed until tapped', (tester) async {
      final steps = List.generate(
        10,
        (i) => PlanStep(
          title: '步骤 ${i + 1}',
          status: i == 0
              ? PlanStepStatus.completed
              : i == 1
                  ? PlanStepStatus.inProgress
                  : PlanStepStatus.pending,
        ),
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => PlanPanel(
          steps: steps,
          tc: ThemeColors.of(context),
        ),
      )));

      expect(find.text('执行清单'), findsOneWidget);
      expect(
          find.textContaining('10 项 · 1 完成 · 1 进行中 · 8 待处理'), findsOneWidget);
      expect(find.text('步骤 1'), findsNothing);

      await tester.tap(find.text('执行清单'));
      await tester.pump();

      expect(find.text('步骤 1'), findsOneWidget);
      expect(find.text('步骤 10'), findsOneWidget);
    });

    testWidgets('贴底限高：长计划卡内滚动，头部固定', (tester) async {
      final steps = List.generate(20, (i) => PlanStep(title: '步骤 ${i + 1}'));
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => PlanPanel(
          steps: steps,
          tc: ThemeColors.of(context),
          initiallyExpanded: true,
          maxHeight: 168,
        ),
      )));

      // 头部 + 分隔线之外，展开区被限高；否则长计划会把输入框顶出屏幕。
      // 实测头部约 43.5px，留 48 的余量。
      expect(tester.getSize(find.byType(PlanPanel)).height,
          lessThanOrEqualTo(168 + 48));
      // 测试外壳自己就套了一层 SingleChildScrollView，必须只数卡内那层
      final innerScroll = find.descendant(
          of: find.byType(PlanPanel),
          matching: find.byType(SingleChildScrollView));
      expect(innerScroll, findsOneWidget);
      // 12 行可见步骤超出 168px，靠后的在视口外。SingleChildScrollView 会一次性
      // 构建全部子节点，find.text 不管滚没滚到都能找到，所以用 hitTestable 判可见。
      expect(find.text('步骤 12').hitTestable(), findsNothing);
      await tester.scrollUntilVisible(find.text('步骤 12'), 60,
          scrollable: find.descendant(
              of: find.byType(PlanPanel), matching: find.byType(Scrollable)));
      expect(find.text('步骤 12').hitTestable(), findsOneWidget);
    });

    testWidgets('不限高时不套滚动视图（会话流历史回看用法不变）', (tester) async {
      final steps = List.generate(20, (i) => PlanStep(title: '步骤 ${i + 1}'));
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => PlanPanel(
          steps: steps,
          tc: ThemeColors.of(context),
          initiallyExpanded: true,
        ),
      )));

      expect(
          find.descendant(
              of: find.byType(PlanPanel),
              matching: find.byType(SingleChildScrollView)),
          findsNothing);
      expect(find.text('步骤 12'), findsOneWidget);
    });

    testWidgets('shows the running command under the current step',
        (tester) async {
      const steps = [
        PlanStep(title: '检查系统', status: PlanStepStatus.completed),
        PlanStep(title: '安装 Nginx', status: PlanStepStatus.inProgress),
        PlanStep(title: '验证服务'),
      ];

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => PlanPanel(
          steps: steps,
          tc: ThemeColors.of(context),
          currentCommand: 'systemctl restart nginx',
        ),
      )));

      expect(find.text('systemctl restart nginx'), findsOneWidget);
    });

    testWidgets('more than 12 steps shows expand-all action', (tester) async {
      final steps = List.generate(
        14,
        (i) => PlanStep(title: '步骤 ${i + 1}'),
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => PlanPanel(
          steps: steps,
          tc: ThemeColors.of(context),
          initiallyExpanded: true,
        ),
      )));

      expect(find.text('步骤 12'), findsOneWidget);
      expect(find.text('步骤 13'), findsNothing);
      expect(find.text('展开全部 14 项'), findsOneWidget);

      await tester.tap(find.text('展开全部 14 项'));
      await tester.pump();

      expect(find.text('步骤 14'), findsOneWidget);
    });
  });

  group('窄屏布局', () {
    testWidgets('OperationSheet does not overflow at 360px', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const report = OperationReport(
        operationId: 'op-3',
        goal: '在这台远程主机上安装 Nginx 并开启 HTTPS，同时配置反向代理和自动续期',
        hostId: 'production-web-01.example.com',
        elapsedSeconds: 3725,
        stepIndex: 30,
        commandSuccessCount: 18,
        commandFailureCount: 2,
        conclusion: 'Nginx 已安装并运行，HTTPS 已配置，网站现在可以通过 https://example.com 访问。',
        changeRecordIds: ['c1', 'c2', 'c3'],
        nextActions: ['把 80 端口跳转到 HTTPS', '配置 HSTS', '设置证书自动续期'],
        finishState: 'success',
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const SizedBox.shrink(),
          hasEvidence: false,
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('dangerous command shows impact and rollback at 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final command = AgentEvent.command(
        'sudo systemctl restart nginx',
        id: 'cmd-risk',
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [command],
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('变更影响'), findsOneWidget);
      expect(find.textContaining('重启服务'), findsWidgets);
      expect(find.textContaining('无自动回滚'), findsOneWidget);
    });

    testWidgets('disconnected failure offers reconnect and retry',
        (tester) async {
      final command = AgentEvent.command('ls', id: 'cmd-net');
      final result = AgentEvent.result(
        commandId: 'cmd-net',
        success: false,
        command: 'ls',
        error: 'connection reset by peer',
        failureKind: 'disconnected',
      );
      AgentEvent? reconnected;
      AgentEvent? retried;

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [command, result],
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          onReconnectHost: (event) => reconnected = event,
          onRetryFailedCommand: (event) => retried = event,
        ),
      )));

      expect(find.text('重连'), findsOneWidget);
      expect(find.text('让 AI 重试'), findsOneWidget);

      await tester.tap(find.text('重连'));
      expect(reconnected?.command, 'ls');

      await tester.tap(find.text('让 AI 重试'));
      expect(retried?.command, 'ls');
    });

    testWidgets('result card metadata does not overflow at 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final command = AgentEvent.command(
        'apt install nginx',
        id: 'cmd-1',
        toolName: 'exec_command',
      );
      final result = AgentEvent.result(
        commandId: 'cmd-1',
        success: false,
        command: 'apt install nginx',
        error: 'permission denied',
        durationMs: 1234,
        exitCode: 1,
        failureKind: 'permissionDenied',
        outputTotalChars: 5000,
        outputTruncated: true,
        outputTail: 'permission denied\nplease use sudo\nfull detail',
      );

      AgentEvent? retried;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [command, result],
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          onRetryFailedCommand: (event) => retried = event,
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 时间线里这一行显示的是真实结果，不再是命令块的"已运行"状态
      expect(find.text('失败'), findsWidgets);
      expect(find.textContaining('权限不足'), findsWidgets);
      expect(find.textContaining('使用 sudo 重试'), findsOneWidget);
      expect(find.textContaining('退出码 1'), findsOneWidget);
      expect(find.textContaining('已截断 5000 字符'), findsOneWidget);
      expect(find.textContaining('原始输出尾部'), findsOneWidget);
      expect(find.textContaining('full detail'), findsNothing);

      await tester.tap(find.textContaining('原始输出尾部'));
      await tester.pump();
      expect(find.textContaining('full detail'), findsOneWidget);

      expect(find.text('让 AI 重试'), findsOneWidget);
      await tester.tap(find.text('让 AI 重试'));
      expect(retried?.command, 'apt install nginx');
    });

    testWidgets('OperationSheet renders in light theme without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const report = OperationReport(
        operationId: 'op-light',
        goal: '检查服务器安全配置并给出迁移建议',
        hostId: 'web-01',
        elapsedSeconds: 42,
        stepIndex: 11,
        commandSuccessCount: 5,
        commandFailureCount: 4,
        conclusion: '服务器存在 SSH 配置风险，建议先备份再修改。',
        changeRecordIds: ['c1'],
        nextActions: ['备份 sshd_config', '限制 22 端口来源 IP'],
        plan: [
          PlanStep(title: '检查系统版本', status: PlanStepStatus.completed),
          PlanStep(title: '检查高危组件', status: PlanStepStatus.inProgress),
        ],
        finishState: 'success',
      );

      await tester.pumpWidget(_wrapLight(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const Text('EVIDENCE'),
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('检查高危组件'), findsOneWidget);
      expect(find.text('备份 sshd_config'), findsOneWidget);
    });

    testWidgets('OperationSheet renders English Agent chrome', (tester) async {
      const report = OperationReport(
        operationId: 'op-en',
        goal: 'Check the server version',
        hostId: 'web-01',
        elapsedSeconds: 3,
        stepIndex: 2,
        commandSuccessCount: 1,
        commandFailureCount: 0,
        conclusion: 'CentOS 8.4.2105 is running and is EOL.',
        plan: [
          PlanStep(title: 'Check release', status: PlanStepStatus.completed),
          PlanStep(title: 'Check packages', status: PlanStepStatus.inProgress),
        ],
        finishState: 'success',
      );

      await tester.pumpWidget(_wrapEnglish(Builder(
        builder: (context) => OperationSheet(
          report: report,
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          evidenceBuilder: () => const Text('EVIDENCE'),
        ),
      )));
      await tester.pump();

      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Execution Plan'), findsOneWidget);
      expect(find.text('AI plan'), findsOneWidget);
      expect(find.text('2 items · 1 done · 1 in progress'), findsOneWidget);
      expect(find.text('Conclusion'), findsOneWidget);
      expect(find.text('Process & evidence'), findsOneWidget);
      expect(find.text('Step 2'), findsOneWidget);
      expect(find.text('1 command'), findsOneWidget);
    });
  });

  group('LiveOperationBar', () {
    testWidgets('shows goal, phase, step and triggers pause/stop',
        (tester) async {
      var paused = false;
      var stopped = false;
      final task = AgentTask(
        id: 't1',
        operationId: 'op1',
        goal: '部署 Nginx',
        status: AgentStatus.thinking,
        phase: '检查环境',
        stepIndex: 3,
        successCount: 2,
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => LiveOperationBar(
          task: task,
          status: AgentStatus.thinking,
          tc: ThemeColors.of(context),
          onPause: () => paused = true,
          onStop: () => stopped = true,
          plan: const [
            PlanStep(title: '检查', status: PlanStepStatus.completed),
            PlanStep(title: '安装', status: PlanStepStatus.inProgress),
            PlanStep(title: '验证'),
          ],
        ),
      )));

      expect(find.text('部署 Nginx'), findsOneWidget);
      expect(find.textContaining('检查环境', findRichText: true), findsOneWidget);
      // `第 N 步`（循环计数）已从运行条撤下：底边条的 `N 步` 是执行数，
      // 同屏两个"步"含义不同等于让用户猜。
      expect(find.textContaining('第 3 步', findRichText: true), findsNothing);
      expect(find.textContaining('计划 1/3', findRichText: true), findsOneWidget);

      await tester.tap(find.byTooltip('暂停'));
      await tester.tap(find.byTooltip('停止'));
      expect(paused, isTrue);
      expect(stopped, isTrue);
    });

    testWidgets('paused status shows resume action', (tester) async {
      var resumed = false;
      final task = AgentTask(
        id: 't2',
        operationId: 'op2',
        goal: '部署 Nginx',
        status: AgentStatus.paused,
      );

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => LiveOperationBar(
          task: task,
          status: AgentStatus.paused,
          tc: ThemeColors.of(context),
          onResume: () => resumed = true,
        ),
      )));

      expect(find.textContaining('已暂停', findRichText: true), findsOneWidget);
      await tester.tap(find.byTooltip('恢复'));
      expect(resumed, isTrue);
    });
  });

  // 指标带的规则来自设计 §3.1.2：数字必须有出处，缺出处的项整项不渲染。
  // 指标从运行条搬到输入框之下的底边条之后，这一组改测真正承载指标的控件；
  // 规则本身（≈ / 整项不渲染 / 分母）一条没改，只是换了渲染者。
  group('底边指标条（运行中）', () {
    Future<void> pump(WidgetTester tester, AgentTask task,
        {int? contextWindow}) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentMetricsBar(
          task: task,
          tc: ThemeColors.of(context),
          contextWindow: contextWindow,
          running: true,
        ),
      )));
    }

    testWidgets('全实测时不带 ≈，并给出速率', (tester) async {
      await pump(
        tester,
        AgentTask(
          id: 'm1',
          goal: '部署 Nginx',
          rounds: 16,
          tokenTotal: 1300,
          elapsedSeconds: 10,
        ),
        contextWindow: 32000,
      );

      expect(find.textContaining('≈'), findsNothing);
      expect(
          find.textContaining('1.3k tok', findRichText: true), findsOneWidget);
      expect(find.textContaining('16 轮', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('130 tok/s', findRichText: true), findsOneWidget);
    });

    testWidgets('含估算时带 ≈，并且不给速率', (tester) async {
      await pump(
        tester,
        AgentTask(
          id: 'm2',
          goal: '部署 Nginx',
          rounds: 4,
          tokenTotal: 1300,
          hasEstimatedTokens: true,
          elapsedSeconds: 10,
        ),
      );

      expect(
          find.textContaining('≈1.3k tok', findRichText: true), findsOneWidget);
      // 估算 token 除以真实秒数会得到一个看着像实测的速率，所以不显示
      expect(find.textContaining('tok/s', findRichText: true), findsNothing);
    });

    testWidgets('elapsed 为 0 时不给速率（防除零）', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm3', goal: '部署 Nginx', tokenTotal: 1300),
      );

      expect(
          find.textContaining('1.3k tok', findRichText: true), findsOneWidget);
      expect(find.textContaining('tok/s', findRichText: true), findsNothing);
    });

    testWidgets('等确认的墙钟不进速率分母', (tester) async {
      await pump(
        tester,
        AgentTask(
          id: 'm3b',
          goal: '部署 Nginx',
          tokenTotal: 1300,
          elapsedSeconds: 60,
          confirmWaitSeconds: 45,
        ),
      );

      // 60 秒墙钟里有 45 秒是等人按确认：速率按 1300/15=86，
      // 按旧口径会得到 1300/60=21，那测的是人的反应速度。
      expect(
          find.textContaining('86 tok/s', findRichText: true), findsOneWidget);
      expect(find.textContaining('21 tok/s', findRichText: true), findsNothing);
    });

    testWidgets('时间几乎全花在等确认上 → 整项不渲染，而不是 0 tok/s', (tester) async {
      await pump(
        tester,
        AgentTask(
          id: 'm3c',
          goal: '部署 Nginx',
          tokenTotal: 1300,
          elapsedSeconds: 30,
          confirmWaitSeconds: 30,
        ),
      );

      expect(
          find.textContaining('1.3k tok', findRichText: true), findsOneWidget);
      expect(find.textContaining('tok/s', findRichText: true), findsNothing);
    });

    testWidgets('provider 没给 cached_tokens 时整项不渲染', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm4', goal: '部署 Nginx', tokenTotal: 500),
      );

      expect(find.textContaining('缓存', findRichText: true), findsNothing);
    });

    testWidgets('缓存命中 0% 是真实值，必须渲染出来', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm5', goal: '部署 Nginx', cacheHitPercent: 0),
      );

      // 与"没给数据"区分开：0 表示 provider 明确回答没有命中，不是未知
      expect(
          find.textContaining('缓存命中 0%', findRichText: true), findsOneWidget);
    });

    testWidgets('步数 = 执行过的命令/工具数，排在轮之后', (tester) async {
      await pump(
        tester,
        AgentTask(
          id: 'm5b',
          goal: '部署 Nginx',
          rounds: 11,
          stepIndex: 12,
          successCount: 400,
          failureCount: 18,
        ),
      );

      // stepIndex 是引擎循环计数，与"轮"几乎相等，并排显示等于同一件事说两遍；
      // 参考界面的 `11 轮 418 步` 里那个大数是执行数。
      expect(find.textContaining('11 轮', findRichText: true), findsOneWidget);
      expect(find.textContaining('418 步', findRichText: true), findsOneWidget);
      expect(find.textContaining('12 步', findRichText: true), findsNothing);
    });

    testWidgets('一条命令都没执行时不渲染 0 步', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm5c', goal: '部署 Nginx', rounds: 1, stepIndex: 1),
      );

      expect(find.textContaining('轮', findRichText: true), findsOneWidget);
      expect(find.textContaining('步', findRichText: true), findsNothing);
    });

    testWidgets('上下文分母缺失时不渲染占用环', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm6', goal: '部署 Nginx', contextTokens: 14000),
      );

      expect(find.textContaining('上下文', findRichText: true), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('有分母时渲染占用环与百分比', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm7', goal: '部署 Nginx', contextTokens: 14000),
        contextWindow: 32000,
      );

      expect(
          find.textContaining('上下文 44%', findRichText: true), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('占用超过窗口时封顶 100%，不出现 130%', (tester) async {
      await pump(
        tester,
        AgentTask(id: 'm8', goal: '部署 Nginx', contextTokens: 42000),
        contextWindow: 32000,
      );

      expect(
          find.textContaining('上下文 100%', findRichText: true), findsOneWidget);
    });
    testWidgets('窄面板下折行而不是溢出报错（§4-P3 的验收项）', (tester) async {
      // 默认右侧布局 + 0.15 最小比例时面板可窄到 ~200px；
      // 长目标文案 + 阶段/步/用时/计划进度 + 三个按钮挤进来，规则是折行不是溢出
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => SizedBox(
          width: 220,
          child: LiveOperationBar(
            task: AgentTask(
              id: 'n1',
              goal: '把 nginx 日志轮转配好并验证切割生效后清理旧日志',
              status: AgentStatus.thinking,
              phase: '检查环境',
              stepIndex: 12,
              rounds: 16,
              tokenTotal: 340000,
              cacheHitPercent: 99,
              contextTokens: 30000,
              successCount: 9,
              failureCount: 3,
              elapsedSeconds: 45,
            ),
            status: AgentStatus.thinking,
            tc: ThemeColors.of(context),
            plan: const [
              PlanStep(title: '检查日志目录与现有配置'),
              PlanStep(title: '写入 logrotate 配置'),
            ],
          ),
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 指标已经搬去底边条，运行条再显示一遍就是同一屏两个数字来源
      expect(find.textContaining('tok', findRichText: true), findsNothing);
    });

    testWidgets('底边条在窄面板下同样折行不溢出', (tester) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => SizedBox(
          width: 220,
          child: AgentMetricsBar(
            task: AgentTask(
              id: 'n2',
              goal: '把 nginx 日志轮转配好并验证切割生效后清理旧日志',
              rounds: 16,
              stepIndex: 16,
              successCount: 400,
              failureCount: 18,
              tokenTotal: 340000,
              cacheHitPercent: 99,
              contextTokens: 30000,
              elapsedSeconds: 45,
            ),
            tc: ThemeColors.of(context),
            contextWindow: 32000,
            running: true,
          ),
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 6 项指标 + 步数在 220px 下必须都还在（折行），而不是被裁掉
      expect(find.textContaining('16 轮', findRichText: true), findsOneWidget);
      expect(find.textContaining('418 步', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('缓存命中 99%', findRichText: true), findsOneWidget);
    });
  });

  // 常驻指标条：任务结束后接管运行条的位置（参照 UI 的底部模块不随任务消失）。
  group('AgentMetricsBar', () {
    Future<void> pumpBar(WidgetTester tester, AgentTask task,
        {int? contextWindow}) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentMetricsBar(
          task: task,
          tc: ThemeColors.of(context),
          contextWindow: contextWindow,
        ),
      )));
    }

    testWidgets('完成态仍保留轮 / token / 占用环', (tester) async {
      await pumpBar(
        tester,
        AgentTask(
          id: 'b1',
          goal: '部署 Nginx',
          status: AgentStatus.completed,
          rounds: 16,
          tokenTotal: 5600,
          contextTokens: 14000,
          elapsedSeconds: 28,
        ),
        contextWindow: 32000,
      );

      expect(find.textContaining('完成', findRichText: true), findsOneWidget);
      expect(find.textContaining('16 轮', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('5.6k tok', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('上下文 44%', findRichText: true), findsOneWidget);
    });

    testWidgets('取消态显示取消而不是完成', (tester) async {
      await pumpBar(
        tester,
        AgentTask(
          id: 'b2',
          goal: '部署 Nginx',
          status: AgentStatus.cancelled,
          elapsedSeconds: 74,
        ),
      );

      expect(find.textContaining('已取消', findRichText: true), findsOneWidget);
      expect(find.textContaining('完成', findRichText: true), findsNothing);
    });

    testWidgets('没有任何计量时不硬凑数字', (tester) async {
      await pumpBar(
        tester,
        AgentTask(id: 'b3', goal: '部署 Nginx', status: AgentStatus.failed),
        contextWindow: 32000,
      );

      expect(find.textContaining('失败', findRichText: true), findsOneWidget);
      expect(find.textContaining('轮', findRichText: true), findsNothing);
      expect(find.textContaining('tok', findRichText: true), findsNothing);
      expect(find.textContaining('上下文', findRichText: true), findsNothing);
    });

    testWidgets('含估算的 token 在常驻条上同样带 ≈（与运行条同一套规则）', (tester) async {
      await pumpBar(
        tester,
        AgentTask(
          id: 'b4',
          goal: '部署 Nginx',
          status: AgentStatus.completed,
          tokenTotal: 1300,
          hasEstimatedTokens: true,
          elapsedSeconds: 10,
        ),
      );

      expect(
          find.textContaining('≈1.3k tok', findRichText: true), findsOneWidget);
      expect(find.textContaining('tok/s', findRichText: true), findsNothing);
    });
  });
}
