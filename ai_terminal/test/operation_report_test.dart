import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/utils/react_stream_parser.dart';

void main() {
  group('OperationReport', () {
    test('JSON round-trip preserves all fields', () {
      const report = OperationReport(
        operationId: 'op-1',
        taskId: 'task-1',
        goal: '部署 Nginx',
        hostId: 'web-01',
        elapsedSeconds: 252,
        stepIndex: 9,
        commandSuccessCount: 8,
        commandFailureCount: 1,
        conclusion: 'Nginx 已安装并运行。',
        details: '结论: ...\n现状: ...',
        stateBadges: [
          OperationBadge(text: '服务运行中', level: 'success'),
        ],
        changeRecordIds: ['chg-1'],
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
        ],
        plan: [
          PlanStep(title: '检查系统', status: PlanStepStatus.completed),
          PlanStep(title: '安装 Nginx', status: PlanStepStatus.inProgress),
          PlanStep(title: '验证服务'),
        ],
        nextActions: ['配置 HTTPS'],
        verified: true,
        aiGenerated: true,
        finishState: 'success',
      );

      final restored = OperationReport.fromJson(report.toJson());

      expect(restored.operationId, 'op-1');
      expect(restored.taskId, 'task-1');
      expect(restored.goal, '部署 Nginx');
      expect(restored.hostId, 'web-01');
      expect(restored.elapsedSeconds, 252);
      expect(restored.stepIndex, 9);
      expect(restored.commandSuccessCount, 8);
      expect(restored.commandFailureCount, 1);
      expect(restored.conclusion, 'Nginx 已安装并运行。');
      expect(restored.details, contains('现状'));
      expect(restored.stateBadges, hasLength(1));
      expect(restored.stateBadges.single.text, '服务运行中');
      expect(restored.stateBadges.single.level, 'success');
      expect(restored.changeRecordIds, ['chg-1']);
      expect(restored.changes, hasLength(1));
      expect(restored.changes.single.command, 'apt install nginx');
      expect(restored.changes.single.canRollback, isTrue);
      expect(restored.changes.single.rollbackCommand, 'apt remove nginx');
      expect(restored.changes.single.additions, 3);
      expect(restored.changes.single.deletions, 1);
      expect(restored.changes.single.hasDiff, isTrue);
      expect(restored.plan, hasLength(3));
      expect(restored.plan[0].title, '检查系统');
      expect(restored.plan[0].status, PlanStepStatus.completed);
      expect(restored.plan[1].status, PlanStepStatus.inProgress);
      expect(restored.plan[2].status, PlanStepStatus.pending);
      expect(restored.nextActions, ['配置 HTTPS']);
      expect(restored.verified, isTrue);
      expect(restored.aiGenerated, isTrue);
      expect(restored.finishState, 'success');
      expect(restored.commandCount, 9);
    });

    test('fromJson tolerates missing/old fields', () {
      final restored = OperationReport.fromJson(const {});
      expect(restored.operationId, '');
      expect(restored.conclusion, '');
      expect(restored.elapsedSeconds, 0);
      expect(restored.finishState, 'success');
      expect(restored.changeRecordIds, isEmpty);
    });

    test('extractConclusion reads 结论 section from four-section summary', () {
      const raw = '''结论: Nginx 已安装并运行，网站可以访问
现状: systemctl is-active 显示 active
变更: 安装了 nginx
建议: 可以配置 HTTPS''';

      expect(OperationReport.extractConclusion(raw),
          'Nginx 已安装并运行，网站可以访问');
    });

    test('extractConclusion handles inline sections on one line', () {
      const raw = '结论: 系统正常。现状: active 变更: 无 建议: 无';
      expect(OperationReport.extractConclusion(raw), '系统正常。');
    });

    test('extractConclusion handles a label on its own line', () {
      const raw = '''## 结论
Nginx 已安装并运行
## 现状
active''';
      expect(OperationReport.extractConclusion(raw), 'Nginx 已安装并运行');
    });

    test('extractConclusion falls back to first paragraph', () {
      const raw = '''先检查了系统版本。

然后执行了安装。''';
      expect(OperationReport.extractConclusion(raw), '先检查了系统版本。');
    });

    test('extractConclusion returns fallback for empty input', () {
      expect(OperationReport.extractConclusion(null, fallback: '已结束'), '已结束');
      expect(OperationReport.extractConclusion('   ', fallback: '已结束'), '已结束');
    });

    test('extractNextActions reads 建议 items and filters 无', () {
      const raw = '''结论: 完成
建议:
- 配置 HTTPS
1. 开放 80 端口
无''';
      expect(OperationReport.extractNextActions(raw),
          ['配置 HTTPS', '开放 80 端口']);
    });

    test('extractDetails omits content equal to conclusion', () {
      expect(OperationReport.extractDetails('完成', conclusion: '完成'), isNull);
      expect(OperationReport.extractDetails('结论: 完成\n现状: active'),
          contains('现状'));
    });
  });

  group('Agent model metadata', () {
    test('AgentTask carries operationId and stepIndex', () {
      final task = AgentTask(id: 't1', operationId: 'op1', goal: 'g');
      final updated = task.copyWith(stepIndex: 3, elapsedSeconds: 12);
      expect(updated.operationId, 'op1');
      expect(updated.stepIndex, 3);
      expect(updated.elapsedSeconds, 12);
    });

    test('AgentResult carries failureKind', () {
      final result = AgentResult.fromCommand(
        command: 'ls',
        stdout: '',
        stderr: 'permission denied',
        exitCode: 1,
        duration: const Duration(milliseconds: 20),
        failureKind: 'permissionDenied',
      );
      expect(result.success, isFalse);
      expect(result.failureKind, 'permissionDenied');
    });
  });

  group('ReAct finish summary pipeline', () {
    test('four-section finish thought survives parsing and becomes conclusion',
        () {
      const response = '''思考: 结论: Nginx 已安装并运行
现状: 443 端口监听中
变更: 安装了 nginx
建议: 配置 HTTPS
动作: finish''';

      final events = ReActStreamParser.parse(response);
      final thoughts =
          events.where((e) => e.isThought).map((e) => e.text ?? '').toList();
      expect(thoughts, isNotEmpty);
      final thought = thoughts.last;
      expect(thought, contains('现状'));
      expect(OperationReport.extractConclusion(thought), 'Nginx 已安装并运行');
    });
  });

  group('report event', () {
    test('AgentEvent.report is recognized and keeps payload', () {
      const report = OperationReport(
        operationId: 'op',
        goal: 'g',
        elapsedSeconds: 1,
        stepIndex: 1,
        commandSuccessCount: 1,
        commandFailureCount: 0,
        conclusion: 'done',
        finishState: 'success',
      );
      final event = AgentEvent.report(report, hostId: 'web-01');
      expect(event.isReport, isTrue);
      expect(event.operationReport?.operationId, 'op');
      expect(event.hostId, 'web-01');
    });
  });
}
