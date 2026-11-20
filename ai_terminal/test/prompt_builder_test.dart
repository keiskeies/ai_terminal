import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/plan_step.dart';
import 'package:ai_terminal/services/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PromptBuilder 纯文本叶子', () {
    test('sudo 识别：匹配命令词不匹配 sudoers 等单词', () {
      expect(PromptBuilder.isSudoCommand('sudo rm -rf /tmp/x'), isTrue);
      expect(PromptBuilder.isSudoCommand('ls | sudo cat x'), isTrue);
      expect(PromptBuilder.isSudoCommand('sudoers 配置'), isFalse);
      expect(PromptBuilder.isSudoCommand('cat /etc/sudoers'), isFalse);
      expect(PromptBuilder.isSudoCommand('echo sudo'), isTrue);
    });

    test('计划状态标记映射完整', () {
      expect(PromptBuilder.planStatusGlyph(PlanStepStatus.completed), 'x');
      expect(PromptBuilder.planStatusGlyph(PlanStepStatus.inProgress), '>');
      expect(PromptBuilder.planStatusGlyph(PlanStepStatus.failed), '!');
      expect(PromptBuilder.planStatusGlyph(PlanStepStatus.skipped), '-');
      expect(PromptBuilder.planStatusGlyph(PlanStepStatus.pending), ' ');
    });

    test('计划进度块含起止标记、各步骤与 finish 指令', () {
      final block = PromptBuilder.buildPlanProgressBlock([
        const PlanStep(title: '检查环境', status: PlanStepStatus.completed),
        const PlanStep(title: '部署服务', status: PlanStepStatus.inProgress),
        const PlanStep(title: '回滚预案', status: PlanStepStatus.skipped),
      ]);

      expect(block, contains(PromptBuilder.planProgressStartMarker));
      expect(block, contains(PromptBuilder.planProgressEndMarker));
      expect(block, contains('- [x] 检查环境'));
      expect(block, contains('- [>] 部署服务'));
      expect(block, contains('- [-] 回滚预案'));
      expect(block, contains('finish 前不得遗留待处理/进行中项'));
    });

    test('空计划仍产出标记段与指令', () {
      final block = PromptBuilder.buildPlanProgressBlock([]);

      expect(block, contains(PromptBuilder.planProgressStartMarker));
      expect(block, contains(PromptBuilder.planProgressEndMarker));
    });

    test('权限档位段落随档位切换且含档位标题', () {
      final readOnly =
          PromptBuilder.permissionModePrompt(AgentPermissionMode.readOnly);
      final ask = PromptBuilder.permissionModePrompt(AgentPermissionMode.ask);
      final auto = PromptBuilder.permissionModePrompt(AgentPermissionMode.auto);
      final fullAuto =
          PromptBuilder.permissionModePrompt(AgentPermissionMode.fullAuto);

      expect(readOnly, contains('【执行权限：只读】'));
      expect(ask, contains('【执行权限：询问】'));
      expect(auto, contains('【执行权限：自动】'));
      expect(fullAuto, contains('【执行权限：全自动】'));
      expect(readOnly, contains('系统直接拒绝'));
      expect(fullAuto, contains('不再询问用户'));
    });

    test('执行位置段落（未连接执行器）含本机说明', () {
      final text = PromptBuilder.executionLocationPrompt(null);

      expect(text, contains('【执行位置】'));
      expect(text, contains('当前未连接执行器'));
    });
  });
}
