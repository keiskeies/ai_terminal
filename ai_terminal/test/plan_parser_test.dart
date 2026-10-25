import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/utils/react_stream_parser.dart';

void main() {
  group('ReActStreamParser plan', () {
    test('parses all status markers and ends at the action line', () {
      const response = '''思考: 先检查再安装
计划:
- [x] 检查系统
- [>] 安装 Nginx
- [ ] 验证服务
- [!] 检查端口
- [-] 备份旧配置
动作: execute
命令: echo hi''';

      final events = ReActStreamParser.parse(response);
      final planEvent = events.where((e) => e.isPlan).single;
      final steps = planEvent.planSteps!;

      expect(steps, hasLength(5));
      expect(steps[0].title, '检查系统');
      expect(steps[0].status, PlanStepStatus.completed);
      expect(steps[1].status, PlanStepStatus.inProgress);
      expect(steps[2].status, PlanStepStatus.pending);
      expect(steps[3].status, PlanStepStatus.failed);
      expect(steps[4].status, PlanStepStatus.skipped);

      final command = events.where((e) => e.isCommand).single;
      expect(command.command, 'echo hi');
    });

    test('supports Chinese status markers', () {
      const response = '''思考: 计划演示
计划:
- 【已完成】检查系统
- 【进行中】安装 Nginx
- 【待处理】验证服务
动作: finish''';

      final events = ReActStreamParser.parse(response);
      final steps = events.where((e) => e.isPlan).single.planSteps!;
      expect(steps[0].status, PlanStepStatus.completed);
      expect(steps[1].status, PlanStepStatus.inProgress);
      expect(steps[2].status, PlanStepStatus.pending);
    });

    test('ignores prose inside the plan block', () {
      const response = '''思考: 计划演示
计划:
这里是说明文字，不是步骤
- [x] 真正的步骤
动作: finish''';

      final events = ReActStreamParser.parse(response);
      final steps = events.where((e) => e.isPlan).single.planSteps!;
      expect(steps, hasLength(1));
      expect(steps.single.title, '真正的步骤');
    });

    test('no plan event when there are no list markers', () {
      const response = '''思考: 先检查
动作: execute
命令: ls''';

      final events = ReActStreamParser.parse(response);
      expect(events.where((e) => e.isPlan), isEmpty);
      expect(events.where((e) => e.isCommand).single.command, 'ls');
    });

    test('empty plan block is ignored', () {
      const response = '''思考: 先检查
计划:
动作: execute
命令: ls''';

      final events = ReActStreamParser.parse(response);
      expect(events.where((e) => e.isPlan), isEmpty);
    });

    test('numeric list markers are accepted', () {
      const response = '''思考: 计划演示
计划:
1. [x] 第一步
2. [ ] 第二步
动作: finish''';

      final events = ReActStreamParser.parse(response);
      final steps = events.where((e) => e.isPlan).single.planSteps!;
      expect(steps.map((e) => e.title), ['第一步', '第二步']);
      expect(steps[0].status, PlanStepStatus.completed);
      expect(steps[1].status, PlanStepStatus.pending);
    });
  });
}
