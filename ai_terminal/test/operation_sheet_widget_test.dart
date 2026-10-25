import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';
import 'package:ai_terminal/widgets/operation_sheet.dart';
import 'package:ai_terminal/widgets/plan_panel.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Builder(
          builder: (context) => Theme(
            data: ThemeData.dark(),
            child: child,
          ),
        ),
      ),
    ),
  );
}

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
      expect(
          find.text('web-01 · 4m12s · 第 9 步 · 9 条命令 · 1 失败 · 2 项变更'),
          findsOneWidget);
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
      expect(find.textContaining('10 项 · 1 完成 · 1 进行中 · 8 待处理'),
          findsOneWidget);
      expect(find.text('步骤 1'), findsNothing);

      await tester.tap(find.text('执行清单'));
      await tester.pump();

      expect(find.text('步骤 1'), findsOneWidget);
      expect(find.text('步骤 10'), findsOneWidget);
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

  group('CollapsibleEventStream', () {
    List<AgentEvent> makeEvents() {
      final events = <AgentEvent>[];
      for (var i = 0; i < 6; i++) {
        final command = AgentEvent.command('echo $i', id: 'cmd-$i');
        events.add(command);
        events.add(AgentEvent.result(
          commandId: command.id,
          success: true,
          command: 'echo $i',
          output: 'ok',
        ));
      }
      return events;
    }

    testWidgets('running stream folds older events and expands on demand',
        (tester) async {
      final events = makeEvents();
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => CollapsibleEventStream(
          events: events,
          tc: ThemeColors.of(context),
          isRunning: true,
          maxVisible: 4,
          builder: (visible) => Text('VISIBLE:${visible.length}'),
        ),
      )));

      expect(find.textContaining('已折叠'), findsOneWidget);
      expect(find.text('VISIBLE:4'), findsOneWidget);

      await tester.tap(find.text('完整过程'));
      await tester.pump();

      expect(find.text('VISIBLE:12'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('finished legacy stream is not folded', (tester) async {
      final events = makeEvents();
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => CollapsibleEventStream(
          events: events,
          tc: ThemeColors.of(context),
          isRunning: false,
          maxVisible: 4,
          builder: (visible) => Text('VISIBLE:${visible.length}'),
        ),
      )));

      expect(find.text('VISIBLE:12'), findsOneWidget);
      expect(find.textContaining('已折叠'), findsNothing);
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
      expect(find.text('已运行'), findsOneWidget);
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
      expect(find.textContaining('检查环境'), findsOneWidget);
      expect(find.textContaining('第 3 步'), findsOneWidget);
      expect(find.textContaining('计划 1/3'), findsOneWidget);

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

      expect(find.textContaining('已暂停'), findsOneWidget);
      await tester.tap(find.byTooltip('恢复'));
      expect(resumed, isTrue);
    });
  });
}
