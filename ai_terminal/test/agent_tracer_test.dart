import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_tracer.dart';

void main() {
  setUp(() {
    AgentTracer.instance.setDisabled(true); // 测试环境禁用文件写入
    AgentTracer.instance.reset();
  });

  group('AgentTracer', () {
    test('startTask 创建 metrics 记录', () {
      AgentTracer.instance.startTask('task-1', 'test goal', hostId: 'host-a');
      final metrics = AgentTracer.instance.getMetrics('task-1');
      expect(metrics, isNotNull);
      expect(metrics!.goal, 'test goal');
      expect(metrics.status, 'running');
      expect(metrics.startTime, isNotNull);
    });

    test('endTask 设置 status 和 endTime', () {
      AgentTracer.instance.startTask('task-2', 'goal');
      AgentTracer.instance.endTask('task-2', status: 'completed', summary: 'done');
      final metrics = AgentTracer.instance.getMetrics('task-2');
      expect(metrics, isNotNull);
      expect(metrics!.status, 'completed');
      expect(metrics.endTime, isNotNull);
    });

    test('aiCallStart 递增 aiCallCount', () {
      AgentTracer.instance.startTask('task-3', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-3',
        type: TraceEventType.aiCallStart,
        payload: {'attempt': 1, 'retry': false, 'fallback': false},
      ));
      expect(AgentTracer.instance.getMetrics('task-3')!.aiCallCount, 1);

      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-3',
        type: TraceEventType.aiCallStart,
        payload: {'attempt': 2, 'retry': true, 'fallback': false},
      ));
      expect(AgentTracer.instance.getMetrics('task-3')!.aiCallCount, 2);
    });

    test('aiCallEnd 累加 token usage', () {
      AgentTracer.instance.startTask('task-4', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-4',
        type: TraceEventType.aiCallEnd,
        payload: {
          'attempt': 1,
          'retry': false,
          'fallback': false,
          'prompt_tokens': 100,
          'completion_tokens': 50,
        },
      ));
      final metrics = AgentTracer.instance.getMetrics('task-4')!;
      expect(metrics.tokenUsagePrompt, 100);
      expect(metrics.tokenUsageCompletion, 50);
    });

    test('aiCallEnd retry=true 累加 retryCount', () {
      AgentTracer.instance.startTask('task-5', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-5',
        type: TraceEventType.aiCallEnd,
        payload: {'retry': true, 'fallback': false, 'prompt_tokens': 0, 'completion_tokens': 0},
      ));
      expect(AgentTracer.instance.getMetrics('task-5')!.retryCount, 1);
    });

    test('aiCallEnd fallback=true 累加 fallbackModelUsed', () {
      AgentTracer.instance.startTask('task-6', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-6',
        type: TraceEventType.aiCallEnd,
        payload: {'retry': false, 'fallback': true, 'prompt_tokens': 0, 'completion_tokens': 0},
      ));
      expect(AgentTracer.instance.getMetrics('task-6')!.fallbackModelUsed, 1);
    });

    test('commandStart 递增 commandCount', () {
      AgentTracer.instance.startTask('task-7', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-7',
        type: TraceEventType.commandStart,
        payload: {'command': 'ls'},
      ));
      expect(AgentTracer.instance.getMetrics('task-7')!.commandCount, 1);
    });

    test('commandEnd success=true 累加 commandSuccessCount', () {
      AgentTracer.instance.startTask('task-8', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-8',
        type: TraceEventType.commandEnd,
        payload: {'success': true, 'reason': 'completed'},
      ));
      expect(AgentTracer.instance.getMetrics('task-8')!.commandSuccessCount, 1);
      expect(AgentTracer.instance.getMetrics('task-8')!.commandFailureCount, 0);
    });

    test('commandEnd success=false 累加 commandFailureCount', () {
      AgentTracer.instance.startTask('task-9', 'goal');
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: 'task-9',
        type: TraceEventType.commandEnd,
        payload: {'success': false, 'reason': 'safety_blocked'},
      ));
      expect(AgentTracer.instance.getMetrics('task-9')!.commandFailureCount, 1);
    });

    test('reset 清理所有 metrics', () {
      AgentTracer.instance.startTask('task-10', 'goal');
      AgentTracer.instance.reset();
      expect(AgentTracer.instance.getMetrics('task-10'), isNull);
    });

    test('未知 taskId 的 emit 不抛异常', () {
      // 不应抛出，metrics 为 null 时静默跳过
      expect(() {
        AgentTracer.instance.emitSync(TraceEvent(
          taskId: 'unknown',
          type: TraceEventType.aiCallEnd,
          payload: {},
        ));
      }, returnsNormally);
    });

    test('TaskMetrics.toJson 包含完整字段', () {
      AgentTracer.instance.startTask('task-11', 'goal');
      final metrics = AgentTracer.instance.getMetrics('task-11')!;
      final json = metrics.toJson();
      expect(json['task_id'], 'task-11');
      expect(json['goal'], 'goal');
      expect(json['status'], 'running');
      expect(json.containsKey('start_time'), isTrue);
      expect(json.containsKey('duration_seconds'), isTrue);
      expect(json.containsKey('token_usage_total'), isTrue);
    });
  });
}
