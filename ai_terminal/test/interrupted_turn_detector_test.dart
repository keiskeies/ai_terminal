import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/utils/interrupted_turn_detector.dart';

void main() {
  group('isInterruptedTurn', () {
    test('new-format turn without finish/report is interrupted', () {
      final command = AgentEvent.command(
        'ls',
        id: 'c1',
        hostId: 'web-01',
        toolName: 'exec_command',
      );
      final result = AgentEvent.result(
        commandId: 'c1',
        success: true,
        durationMs: 12,
      );
      expect(isInterruptedTurn([command, result]), isTrue);
      expect(lastEventHostId([command, result]), 'web-01');
    });

    test('legacy events without new metadata are not mislabeled', () {
      final command = AgentEvent.command('ls', id: 'c1');
      final result = AgentEvent.result(commandId: 'c1', success: true);
      expect(isInterruptedTurn([command, result]), isFalse);
    });

    test('finish and report are terminal', () {
      final command = AgentEvent.command(
        'ls',
        id: 'c1',
        hostId: 'web-01',
        toolName: 'exec_command',
      );
      expect(
        isInterruptedTurn([command, AgentEvent.finish(summary: 'done')]),
        isFalse,
      );
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
      expect(
        isInterruptedTurn([command, AgentEvent.report(report)]),
        isFalse,
      );
    });

    test('plan without finish is interrupted', () {
      final plan = AgentEvent.plan([
        const PlanStep(title: '检查系统', status: PlanStepStatus.completed),
      ]);
      expect(isInterruptedTurn([plan]), isTrue);
    });

    test('empty events are not interrupted', () {
      expect(isInterruptedTurn(const []), isFalse);
    });
  });
}
