import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/services/termination_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminationGuard 终态收口', () {
    late int generation;
    late List<String> order;
    late TerminationGuard guard;

    setUp(() {
      generation = 1;
      order = <String>[];
      guard = TerminationGuard(hostId: 'h1', generation: () => generation);
    });

    test('固定顺序 status→report→finish→flush→tracer→cleanup', () {
      final fired = guard.terminate(
        status: AgentStatus.completed,
        finishState: AgentFinishState.success,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
        flush: () => order.add('flush'),
        endTracer: () => order.add('tracer'),
        cleanup: () => order.add('cleanup'),
      );

      expect(fired, isTrue);
      expect(order, [
        'status',
        'report',
        'finish',
        'flush',
        'tracer',
        'cleanup',
      ]);
    });

    test('回调抛异常时后续终态动作仍执行并记录错误', () {
      final fired = guard.terminate(
        status: AgentStatus.failed,
        finishState: AgentFinishState.failed,
        writeStatus: (_) => order.add('status'),
        emitReport: () => throw StateError('report boom'),
        emitFinish: () => order.add('finish'),
        flush: () => order.add('flush'),
        endTracer: () => order.add('tracer'),
        cleanup: () => order.add('cleanup'),
      );

      expect(fired, isTrue);
      expect(order, [
        'status',
        'finish',
        'flush',
        'tracer',
        'cleanup',
      ]);
      expect(guard.lastErrors.single, contains('report boom'));
    });

    test('代际不符时整组动作不执行', () {
      final fired = guard.terminate(
        status: AgentStatus.cancelled,
        finishState: AgentFinishState.cancelled,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
        cleanup: () => order.add('cleanup'),
        expectedGeneration: 99, // 当前 generation=1
      );

      expect(fired, isFalse);
      expect(order, isEmpty);
    });

    test('同代际幂等：第二次收口不再执行动作', () {
      guard.terminate(
        status: AgentStatus.completed,
        finishState: AgentFinishState.success,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
      );
      order.clear();

      final second = guard.terminate(
        status: AgentStatus.failed,
        finishState: AgentFinishState.failed,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
      );

      expect(second, isFalse);
      expect(order, isEmpty);
      expect(guard.isTerminatedForCurrentGeneration, isTrue);
    });

    test('代际变化后重新开放收口', () {
      guard.terminate(
        status: AgentStatus.completed,
        finishState: AgentFinishState.success,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
      );
      generation = 2; // 新任务

      expect(guard.isTerminatedForCurrentGeneration, isFalse);
      final fired = guard.terminate(
        status: AgentStatus.failed,
        finishState: AgentFinishState.failed,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
      );
      expect(fired, isTrue);
    });

    test('flush / endTracer / cleanup 可省略', () {
      final fired = guard.terminate(
        status: AgentStatus.cancelled,
        finishState: AgentFinishState.cancelled,
        writeStatus: (_) => order.add('status'),
        emitReport: () => order.add('report'),
        emitFinish: () => order.add('finish'),
      );

      expect(fired, isTrue);
      expect(order, ['status', 'report', 'finish']);
    });

    test('writeStatus 收到传入的 status', () {
      AgentStatus? written;
      guard.terminate(
        status: AgentStatus.cancelled,
        finishState: AgentFinishState.cancelled,
        writeStatus: (s) => written = s,
        emitReport: () {},
        emitFinish: () {},
      );

      expect(written, AgentStatus.cancelled);
    });

    group('UI 态终口', () {
      test('resolveUiStatus 返回原值并记录决策', () {
        final uiGuard = TerminationGuard(hostId: null, generation: () => 0);

        expect(uiGuard.resolveUiStatus(AgentStatus.cancelled),
            AgentStatus.cancelled);
        expect(uiGuard.resolveUiStatus(AgentStatus.failed), AgentStatus.failed);
        expect(uiGuard.uiStatusCount, 2);
      });

      test('UI 终态历史有界（不超过 32 条）', () {
        final uiGuard = TerminationGuard(hostId: null, generation: () => 0);

        for (var i = 0; i < 100; i++) {
          uiGuard.resolveUiStatus(AgentStatus.cancelled);
        }

        expect(uiGuard.uiStatusCount, 32);
      });
    });
  });
}
