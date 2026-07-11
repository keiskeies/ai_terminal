import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/react_stream_parser.dart';
import 'package:ai_terminal/models/agent_event.dart';

void main() {
  group('ReActStreamParser - 标准 ReAct 格式解析', () {
    test('解析思考 + 动作 + 命令', () {
      const response = '思考: 我需要查看当前目录\n动作: execute\n命令: ls -la';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 2);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '我需要查看当前目录');
      expect(events[1].type, AgentEventType.command);
      expect(events[1].command, 'ls -la');
    });

    test('解析仅思考（无命令）', () {
      const response = '思考: 这是一个纯思考内容';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '这是一个纯思考内容');
    });

    test('解析仅命令', () {
      const response = '命令: docker ps -a';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'docker ps -a');
    });

    test('全角冒号关键字也能解析', () {
      const response = '思考：需要检查进程\n命令：ps aux';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 2);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '需要检查进程');
      expect(events[1].type, AgentEventType.command);
      expect(events[1].command, 'ps aux');
    });

    test('非 ReAct 格式文本解析为 text 事件', () {
      const response = '这是一段普通文本说明';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.text);
      expect(events[0].text, '这是一段普通文本说明');
    });
  });

  group('ReActStreamParser - XML tool_call 格式转换', () {
    test('带 --- 分隔符的 XML tool_call', () {
      const response = '---\n<function=terminal>\n<parameter=command>ls -la</parameter>\n</function>\n---';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'ls -la');
    });

    test('不带 --- 分隔符的 XML tool_call', () {
      const response = '<function=terminal>\n<parameter=command>uptime</parameter>\n</function>';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'uptime');
    });

    test('execute 函数名也能识别', () {
      const response = '<function=execute>\n<parameter=command>whoami</parameter>\n</function>';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'whoami');
    });

    test('run_command 函数名也能识别', () {
      const response = '<function=run_command>\n<parameter=command>pwd</parameter>\n</function>';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'pwd');
    });

    test('非 terminal 类函数不解析为命令', () {
      const response = '<function=search>\n<parameter=command>find something</parameter>\n</function>';
      final events = ReActStreamParser.parse(response);

      // 非 terminal/execute/run_command 的函数，命令内容作为普通文本返回
      expect(events.length, 1);
      expect(events[0].type, AgentEventType.text);
    });
  });

  group('ReActStreamParser - 代码块命令提取', () {
    test('从代码块提取单行命令', () {
      const response = '```\nls -la\n```';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'ls -la');
    });

    test('从代码块提取多行命令', () {
      const response = '```\necho hello\necho world\n```';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'echo hello\necho world');
    });

    test('代码块带语言标识也能提取', () {
      const response = '```bash\nsystemctl status nginx\n```';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'systemctl status nginx');
    });

    test('未闭合代码块仍能提取内容', () {
      const response = '```\necho unclosed';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'echo unclosed');
    });
  });

  group('ReActStreamParser - heredoc 多行命令', () {
    test('heredoc 命令完整保留', () {
      const response =
          '命令: cat > /tmp/test.conf <<EOF\nserver:\n  port: 8080\n  host: localhost\nEOF';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(
        events[0].command,
        'cat > /tmp/test.conf <<EOF\nserver:\n  port: 8080\n  host: localhost\nEOF',
      );
    });

    test('思考 + heredoc 命令', () {
      const response =
          '思考: 需要写入配置文件\n命令: cat <<EOF\nline1\nline2\nEOF';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 2);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '需要写入配置文件');
      expect(events[1].type, AgentEventType.command);
      expect(events[1].command, 'cat <<EOF\nline1\nline2\nEOF');
    });
  });

  group('ReActStreamParser - ask 动作选项解析', () {
    test('解析管道分隔的选项', () {
      const response = '选项: 选项A|选项B|选项C';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.ask);
      expect(events[0].options, ['选项A', '选项B', '选项C']);
    });

    test('解析两个选项', () {
      const response = '选项: 是|否';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.ask);
      expect(events[0].options, ['是', '否']);
    });

    test('选项前后空格被去除', () {
      const response = '选项:  选项A | 选项B ';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.ask);
      expect(events[0].options, ['选项A', '选项B']);
    });

    test('思考 + 选项', () {
      const response = '思考: 请用户选择\n选项: 继续|取消';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 2);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '请用户选择');
      expect(events[1].type, AgentEventType.ask);
      expect(events[1].options, ['继续', '取消']);
    });
  });

  group('ReActStreamParser - _stableId 唯一性', () {
    test('不同内容生成不同 ID', () {
      final events1 = ReActStreamParser.parse('思考: 内容A');
      final events2 = ReActStreamParser.parse('思考: 内容B');

      expect(events1.length, 1);
      expect(events2.length, 1);
      expect(events1[0].id, isNot(equals(events2[0].id)));
    });

    test('相同内容生成相同 ID（幂等）', () {
      final events1 = ReActStreamParser.parse('思考: 相同内容');
      final events2 = ReActStreamParser.parse('思考: 相同内容');

      expect(events1.length, 1);
      expect(events2.length, 1);
      expect(events1[0].id, equals(events2[0].id));
    });

    test('相同内容不同类型生成不同 ID', () {
      final events1 = ReActStreamParser.parse('思考: 相同文本');
      final events2 = ReActStreamParser.parse('命令: 相同文本');

      expect(events1.length, 1);
      expect(events2.length, 1);
      expect(events1[0].type, AgentEventType.thought);
      expect(events2[0].type, AgentEventType.command);
      expect(events1[0].id, isNot(equals(events2[0].id)));
    });

    test('不同命令生成不同 ID', () {
      final events1 = ReActStreamParser.parse('命令: ls');
      final events2 = ReActStreamParser.parse('命令: ls -la');

      expect(events1[0].id, isNot(equals(events2[0].id)));
    });

    test('相同命令生成相同 ID', () {
      final events1 = ReActStreamParser.parse('命令: ls -la');
      final events2 = ReActStreamParser.parse('命令: ls -la');

      expect(events1[0].id, equals(events2[0].id));
    });

    test('ID 以 evt_ 前缀开头', () {
      final events = ReActStreamParser.parse('思考: 测试');
      expect(events[0].id, startsWith('evt_'));
    });

    test('不同选项列表生成不同 ID', () {
      final events1 = ReActStreamParser.parse('选项: A|B');
      final events2 = ReActStreamParser.parse('选项: A|B|C');

      expect(events1[0].id, isNot(equals(events2[0].id)));
    });

    test('相同选项列表生成相同 ID', () {
      final events1 = ReActStreamParser.parse('选项: A|B|C');
      final events2 = ReActStreamParser.parse('选项: A|B|C');

      expect(events1[0].id, equals(events2[0].id));
    });
  });

  group('ReActStreamParser - 混合格式', () {
    test('思考 + 命令 + 选项', () {
      const response = '思考: 需要确认操作\n命令: rm file.txt\n选项: 确认|取消';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 3);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '需要确认操作');
      expect(events[1].type, AgentEventType.command);
      expect(events[1].command, 'rm file.txt');
      expect(events[2].type, AgentEventType.ask);
      expect(events[2].options, ['确认', '取消']);
    });

    test('文本 + 代码块', () {
      const response = '以下是命令：\n```\necho hello\n```';
      final events = ReActStreamParser.parse(response);

      expect(events.length, 2);
      expect(events[0].type, AgentEventType.text);
      expect(events[1].type, AgentEventType.command);
      expect(events[1].command, 'echo hello');
    });
  });
}
