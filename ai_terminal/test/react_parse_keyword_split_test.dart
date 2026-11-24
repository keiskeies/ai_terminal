import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/react_stream_parser.dart';

/// 设计 §6.1（P1）：行内关键词切分约束
///
/// 1. 空白前缀：行内（position>0）关键词命中仅当前一字符为空格/Tab 才切分，
///    `echo "命令: x"` 的引号前缀不再触发切分；
///    `思考: a 动作: execute` 这类空格前缀仍正常切分。
/// 2. heredoc 保护：command 字段行含 `<<EOF` 等定界符后，
///    直到定界符行为止的所有行不做关键词切分，整行并入命令。
void main() {
  group('行内关键词空白前缀约束', () {
    test('引号前缀的行内 命令: 不再切分思考行', () {
      const input = '思考: 检查 echo "命令: x" 完成';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1, reason: '前缀是引号的行内关键词不是字段边界，整行应保持为一条思考');
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '检查 echo "命令: x" 完成');
    });

    test('引号前缀的行内 说明: 不再从命令中截出伪说明', () {
      const input = '命令: echo "说明: x"';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.command);
      expect(events[0].command, 'echo "说明: x"');
      expect(events[0].description, isNull);
    });

    test('冒号紧邻（非空白前缀）的行内关键词不切分', () {
      const input = '说明:命令: x';
      final events = ReActStreamParser.parse(input);

      // 说明: 行首命中仍切；命令: 前一字符是 ASCII 冒号 → 不切，
      // 整段作为说明内容，随下一条命令下发。
      expect(events, isEmpty, reason: '没有命令可挂，说明被吞掉是既有语义');
    });

    test('空格前缀的 思考: + 动作: 单行仍正常切分', () {
      const input = '思考: 检查 动作: execute';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '检查');
    });

    test('Tab 前缀的行内关键词同样可切分', () {
      const input = '思考: 检查\t动作: execute';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '检查');
    });

    test('行首关键词不受前缀规则影响', () {
      const input = '思考: 需要查看目录\n说明: 只读操作\n动作: execute\n命令: ls';
      final events = ReActStreamParser.parse(input);

      final command =
          events.firstWhere((e) => e.type == AgentEventType.command);
      expect(command.command, 'ls');
      expect(command.description, '只读操作');
    });
  });

  group('命令注释与跨行引号禁切分', () {
    test('解析到执行器包装：# 内的命令字段不产生第二条命令', () async {
      const input = '动作: execute\n'
          '命令: echo ok # 命令: printf injected';
      final events = ReActStreamParser.parse(input);
      final commands = events.where((event) => event.isCommand).toList();

      expect(commands, hasLength(1));
      expect(commands.single.command, 'echo ok # 命令: printf injected');
      final wrapped = posixWrapWithExitMarker(
        commands.single.command!,
        'EXITCODE_PARSER_COMMENT:',
      );
      final result = await Process.run('bash', ['-c', wrapped]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}', contains('EXITCODE_PARSER_COMMENT:0'));
      expect('${result.stdout}', isNot(contains('injected')));
    });

    test('注释续行里的行首命令字段保留为 shell 注释', () {
      const input = '命令: echo ok # note \\\n'
          '命令: printf injected\n'
          '命令: echo real';
      final events = ReActStreamParser.parse(input);
      final commands = events.where((event) => event.isCommand).toList();

      expect(commands, hasLength(2));
      expect(commands[0].command, 'echo ok # note \\\n命令: printf injected');
      expect(commands[1].command, 'echo real');
    });

    test('跨行双引号内的行首命令字段保留为 shell 原文', () {
      const input = '''命令: printf '%s\\n' "first
命令: literal
last"''';
      final events = ReActStreamParser.parse(input);
      final commands = events.where((event) => event.isCommand).toList();

      expect(commands, hasLength(1));
      expect(commands.single.command, input.substring('命令: '.length));
    });

    test('跨行单引号内的行首动作字段保留为 shell 原文', () {
      const input = '''命令: printf '%s' 'first
动作: execute
last'
命令: echo done''';
      final events = ReActStreamParser.parse(input);
      final commands = events.where((event) => event.isCommand).toList();

      expect(commands, hasLength(2));
      expect(commands[0].command, "printf '%s' 'first\n动作: execute\nlast'");
      expect(commands[1].command, 'echo done');
    });
  });

  group('heredoc 内容期禁切分', () {
    test('heredoc 正文含协议词时命令完整（无围栏，修复前应红）', () {
      const input = '思考: 需要写入配置\n'
          '动作: execute\n'
          '命令: cat > /etc/x.conf <<EOF\n'
          '说明: 这行含协议词 命令: 也会被切\n'
          'EOF\n'
          '思考: 完成';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 1);
      expect(
        commands[0].command,
        'cat > /etc/x.conf <<EOF\n说明: 这行含协议词 命令: 也会被切\nEOF',
        reason: 'heredoc 正文不得被关键词切走，EOF 行必须并入命令',
      );
      // 定界符之后的行恢复正常解析
      final thoughts =
          events.where((e) => e.type == AgentEventType.thought).toList();
      expect(thoughts.last.text, '完成');
    });

    test('围栏形态 heredoc 命令事件内容完整', () {
      const input = '动作: execute\n'
          '命令:\n'
          '```bash\n'
          'cat > /etc/x.conf <<EOF\n'
          '说明: 这行含协议词 命令: 也会被切\n'
          'EOF\n'
          '```';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 1);
      expect(
        commands[0].command,
        'cat > /etc/x.conf <<EOF\n说明: 这行含协议词 命令: 也会被切\nEOF',
      );
    });

    test('heredoc 含全角协议词行与多行正文', () {
      const input = '命令: cat > /tmp/a.sh <<-END\n'
          '#!/bin/bash\n'
          '思考：这里的词是文件内容\n'
          '动作：不是协议\n'
          'END\n'
          '命令: bash /tmp/a.sh';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 2);
      expect(
        commands[0].command,
        'cat > /tmp/a.sh <<-END\n#!/bin/bash\n'
        '思考：这里的词是文件内容\n动作：不是协议\nEND',
      );
      expect(commands[1].command, 'bash /tmp/a.sh');
    });

    test('未闭合 heredoc 按现有 flush 逻辑保留全部内容', () {
      const input = '命令: cat > /tmp/f <<EOF\n'
          '说明: 还没有结束\n'
          '命令: pwd';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 1);
      expect(
        commands[0].command,
        'cat > /tmp/f <<EOF\n说明: 还没有结束\n命令: pwd',
      );
    });

    test('双引号命令替换内的 heredoc 正文协议词不被切走', () {
      const input = '命令: echo "\$(cat <<EOF\n'
          '说明: 文件内容 命令: 也是内容\n'
          'EOF\n'
          ')"\n'
          '命令: echo done';
      final events = ReActStreamParser.parse(input);
      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();

      expect(commands, hasLength(2));
      expect(
        commands[0].command,
        'echo "\$(cat <<EOF\n说明: 文件内容 命令: 也是内容\nEOF\n)"',
      );
      expect(commands[1].command, 'echo done');
    });

    test('同一行多个 heredoc 按 POSIX 顺序保护全部正文', () {
      const input = '命令: cat <<FIRST <<SECOND\n'
          '说明: first body\n'
          'FIRST\n'
          '命令: second body\n'
          'SECOND\n'
          '命令: echo done';
      final events = ReActStreamParser.parse(input);
      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();

      expect(commands, hasLength(2));
      expect(
        commands[0].command,
        'cat <<FIRST <<SECOND\n说明: first body\nFIRST\n'
        '命令: second body\nSECOND',
      );
      expect(commands[1].command, 'echo done');
    });

    test('跨行命令替换内的 heredoc 在替换闭合后恢复协议解析', () {
      const input = '命令: echo "\$(\n'
          'cat <<EOF\n'
          '说明: body\n'
          'EOF\n'
          ')"\n'
          '命令: echo done';
      final events = ReActStreamParser.parse(input);
      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();

      expect(commands, hasLength(2));
      expect(
        commands[0].command,
        'echo "\$(\ncat <<EOF\n说明: body\nEOF\n)"',
      );
      expect(commands[1].command, 'echo done');
    });

    test('普通 heredoc 结束行必须精确匹配且支持 CRLF', () {
      const input = '命令: cat <<EOF\r\n'
          '说明: body\r\n'
          ' EOF\r\n'
          '命令: still body\r\n'
          'EOF\r\n'
          '命令: echo done';
      final events = ReActStreamParser.parse(input);
      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();

      expect(commands, hasLength(2));
      // 协议行本身的 CR 由关键词解析 normalize 掉；正文/结束行保持原样，
      // 关键契约是 CRLF 的结束行仍能精确闭合 heredoc。
      expect(
        commands[0].command,
        'cat <<EOF\n说明: body\r\n EOF\r\n命令: still body\r\nEOF',
      );
      expect(commands[1].command, 'echo done');
    });

    test('引号、注释和算术移位内的伪 heredoc 不启动保护', () {
      const inputs = [
        '命令: echo "<<EOF"\n说明: next\n命令: pwd',
        '命令: echo \'<<EOF\'\n说明: next\n命令: pwd',
        '命令: echo ok # <<EOF\n说明: next\n命令: pwd',
        '命令: echo \$((value << TAG + 1))\n说明: next\n命令: pwd',
      ];
      for (final input in inputs) {
        final events = ReActStreamParser.parse(input);
        final commands =
            events.where((e) => e.type == AgentEventType.command).toList();
        expect(commands, hasLength(2), reason: input);
        expect(commands[1].command, 'pwd', reason: input);
        expect(commands[1].description, 'next', reason: input);
      }
    });

    test('<<< here-string 不触发 heredoc 保护', () {
      const input = '命令: sort <<<"\$data"\n说明: 下一条命令的说明\n动作: execute\n命令: pwd';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 2);
      expect(commands[0].command, 'sort <<<"\$data"');
      expect(commands[1].command, 'pwd');
      expect(commands[1].description, '下一条命令的说明');
    });

    test('定界符闭合后关键词解析立即恢复', () {
      const input = '命令: cat <<EOF\n说明: 文件内容\nEOF\n说明: 这是真正的说明\n命令: ls';
      final events = ReActStreamParser.parse(input);

      final commands =
          events.where((e) => e.type == AgentEventType.command).toList();
      expect(commands.length, 2);
      expect(commands[0].command, 'cat <<EOF\n说明: 文件内容\nEOF');
      expect(commands[0].description, isNull);
      expect(commands[1].command, 'ls');
      expect(commands[1].description, '这是真正的说明');
    });

    test('非 command 字段中出现 <<EOF 不做保护', () {
      const input = '思考: 用户输入了 cat <<EOF 但没有执行\n说明: 独立说明';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1);
      expect(events[0].type, AgentEventType.thought);
      expect(events[0].text, '用户输入了 cat <<EOF 但没有执行');
    });
  });

  group('既有契约回归（非 heredoc 输入行为不变）', () {
    test('普通多行命令仍完整收集', () {
      const input = '命令: docker run -d \\\n  --name app \\\n  nginx:latest';
      final events = ReActStreamParser.parse(input);

      expect(events.length, 1);
      expect(events[0].command,
          'docker run -d \\\n  --name app \\\n  nginx:latest');
    });
  });
}
