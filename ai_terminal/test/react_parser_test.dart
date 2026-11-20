import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/services/react_parser.dart';

/// ReActParser 特征化测试 —— 从 agent_engine.dart 抽出解析层后锁定其行为。
///
/// 这些用例覆盖 [ReActParser.parseReActResponse] 的动作分流与 fallback、
/// 回答块/操作单解析、围栏防误切与有界截断。它们与引擎实例状态无关，
/// 是后续继续拆分 engine 时的安全网（报告 §7「拆分前补齐特征化测试」）。
void main() {
  group('ReActParser.parseReActResponse 动作分流', () {
    test('显式 execute：提取命令并定型为 execute', () {
      const response = '思考: 检查磁盘占用\n动作: execute\n命令: df -h';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.execute);
      expect(step.command, contains('df -h'));
      expect(step.rawResponse, response);
    });

    test('显式 finish：带回答块时提取 answer', () {
      const response = '动作: finish\n回答: 已经帮你装好了 Docker';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.finish);
      expect(step.answer, contains('Docker'));
    });

    test('显式 ask：提取选项列表', () {
      const response = '思考: 选哪种方案?\n动作: ask\n选项: 是|否';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.ask);
      expect(step.options, isNotNull);
      expect(step.options, containsAll(['是', '否']));
    });

    test('显式 tool：提取工具名与参数', () {
      const response = '动作: tool\n工具: sftp_upload\n参数:\n  local: /tmp/a\n  remote: /var/www';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.tool);
      expect(step.toolName, 'sftp_upload');
      expect(step.toolArgs, isNotNull);
      expect(step.toolArgs!['local'], '/tmp/a');
    });

    test('空响应：action 为 null（视为仍在思考，不结束任务）', () {
      final step = ReActParser.parseReActResponse('   \n  ');

      expect(step.action, isNull);
      expect(step.thought, '');
    });

    test('无动作行但有命令：默认按 execute 处理', () {
      const response = '思考: 直接查一下\n命令: uptime';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.execute);
      expect(step.command, contains('uptime'));
    });

    test('无动作行 + isTaskComplete 命中：fallback 为 finish', () {
      // isTaskComplete 只在短行的行首/行尾命中完成关键词
      const response = '任务完成';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, ActionType.finish);
    });

    test('只有思考无命令：action 为 null（交给重试，不结束任务）', () {
      const response = '思考: 我需要先查一下文档再决定';
      final step = ReActParser.parseReActResponse(response);

      expect(step.action, isNull);
      expect(step.thought, isNotEmpty);
    });

    test('复用传入的 parsedEvents：正文无命令时仍取到事件里的命令', () {
      // 流结束路径缓存了解析结果；即便 content 里没有可再解析的命令行，
      // 传入的 parsedEvents 仍应提供命令（证明复用的是事件，不是重新解析文本）。
      final events = [AgentEvent.command('from_cached_events')];
      final step = ReActParser.parseReActResponse('动作: execute',
          parsedEvents: events);

      expect(step.action, ActionType.execute);
      expect(step.command, 'from_cached_events');
    });
  });

  group('ReActParser.parseAnswerBlock 回答正文解析', () {
    test('回答: 行内文本 + 后续正文', () {
      final lines = '回答: 结果如下\n第二行正文'.split('\n');
      final answer = ReActParser.parseAnswerBlock(lines);

      expect(answer, isNotNull);
      expect(answer, contains('结果如下'));
      expect(answer, contains('第二行正文'));
    });

    test('围栏内的协议关键词行不触发提前截断', () {
      final lines = '回答: 示例\n```\n动作: execute\n命令: echo hi\n```\n结尾'.split('\n');
      final answer = ReActParser.parseAnswerBlock(lines);

      expect(answer, isNotNull);
      expect(answer, contains('动作: execute'));
      expect(answer, contains('结尾'));
    });

    test('超长回答被有界截断（R8）', () {
      final longText = 'x' * 13000;
      final lines = '回答: $longText'.split('\n');
      final answer = ReActParser.parseAnswerBlock(lines);

      expect(answer, isNotNull);
      expect(answer!.length, lessThan(longText.length));
      expect(answer, contains('截断'));
    });

    test('无回答行时返回 null', () {
      expect(ReActParser.parseAnswerBlock('思考: 无回答'.split('\n')), isNull);
    });
  });

  group('ReActParser.parseReportSections 操作单四段', () {
    test('解析结论/现状/变更/建议四段', () {
      final lines = '回答: 摘要\n结论: 安装成功\n现状: 服务运行中\n变更: 新增 nginx\n建议: 无'.split('\n');
      final sections = ReActParser.parseReportSections(lines);

      expect(sections, isNotNull);
      expect(sections, contains('结论: 安装成功'));
      expect(sections, contains('现状: 服务运行中'));
    });

    test('无回答行时返回 null', () {
      expect(
        ReActParser.parseReportSections('思考: 没写回答'.split('\n')),
        isNull,
      );
    });
  });
}
