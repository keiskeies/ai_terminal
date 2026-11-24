import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/shell_syntax.dart';

void main() {
  group('ShellSyntax.unclosedReason', () {
    test('闭合命令放行', () {
      expect(ShellSyntax.unclosedReason('ls -la /tmp'), isNull);
      expect(ShellSyntax.unclosedReason('echo "hello world"'), isNull);
      expect(ShellSyntax.unclosedReason("echo 'hello world'"), isNull);
    });

    test('未闭合单双引号被拦截', () {
      expect(ShellSyntax.unclosedReason('echo "abc'), '双引号未闭合');
      expect(ShellSyntax.unclosedReason("echo 'abc"), '单引号未闭合');
      expect(ShellSyntax.unclosedReason('echo `abc'), '反引号未闭合');
    });

    test('转义引号不算未闭合', () {
      expect(ShellSyntax.unclosedReason(r'echo "a\"b"'), isNull);
      expect(ShellSyntax.unclosedReason(r'''echo 'it'\''s' '''), isNull);
    });

    test('引号内的括号不误报', () {
      expect(ShellSyntax.unclosedReason('echo "(unclosed"'), isNull);
      expect(ShellSyntax.unclosedReason("awk '{print \$1}' f.log"), isNull);
    });

    test('圆括号配对', () {
      expect(ShellSyntax.unclosedReason(r'echo $(date)'), isNull);
      expect(ShellSyntax.unclosedReason(r'echo $(date'), '圆括号未闭合');
    });

    test('嵌套 \$() 使用独立引号上下文', () {
      const nested = r'''echo "$(printf '"')"''';
      expect(ShellSyntax.unclosedReason(nested), isNull);
      const deeper = r'''echo "$(echo "$(printf '"')")"''';
      expect(ShellSyntax.unclosedReason(deeper), isNull);
      expect(
          ShellSyntax.unclosedReason(r'''echo "$(printf 'abc)"'''), '单引号未闭合');
      expect(ShellSyntax.unclosedReason(r'echo "$(echo $(date)"'), '圆括号未闭合');
    });

    test('heredoc 有结束定界符放行，缺失拦截', () {
      const ok = 'cat > /tmp/a <<EOF\nline1\nEOF';
      expect(ShellSyntax.unclosedReason(ok), isNull);
      const bad = 'cat > /tmp/a <<EOF\nline1\nline2';
      expect(ShellSyntax.unclosedReason(bad), contains('缺少结束行'));
    });

    test('heredoc body 里的引号不误报', () {
      const cmd = 'cat > /tmp/a <<\'EOF\'\necho "unclosed\nEOF';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
    });

    test('<<< here-string 与移位不误判为 heredoc', () {
      expect(ShellSyntax.unclosedReason('grep -q foo <<< "bar"'), isNull);
      expect(ShellSyntax.unclosedReason('echo \$((1<<2))'), isNull);
    });

    test('引号内/注释里的 <<TAG 不是 heredoc（回归：不得误拦截合法命令）', () {
      expect(ShellSyntax.unclosedReason('echo "<<EOF hello"'), isNull);
      expect(ShellSyntax.unclosedReason('grep "<<EOF x" file'), isNull);
      expect(ShellSyntax.unclosedReason("echo '<<EOF demo'"), isNull);
      expect(ShellSyntax.unclosedReason('# cat <<EOF\necho ok'), isNull);
      // 真正的 heredoc 仍须拦缺失定界符
      expect(ShellSyntax.unclosedReason('cat > f <<EOF\nline1'),
          contains('缺少结束行'));
    });

    test('行首注释里的引号不误报', () {
      expect(ShellSyntax.unclosedReason('# echo "comment\necho ok'), isNull);
    });

    test('普通 heredoc 结束行不允许缩进或尾随空白', () {
      expect(ShellSyntax.unclosedReason('cat <<EOF\nbody\n EOF'),
          contains('缺少结束行'));
      expect(ShellSyntax.unclosedReason('cat <<EOF\nbody\n\tEOF'),
          contains('缺少结束行'));
      expect(ShellSyntax.unclosedReason('cat <<EOF\nbody\nEOF   '),
          contains('缺少结束行'));
      expect(ShellSyntax.unclosedReason('cat <<EOF\nbody\nEOF'), isNull);
    });

    test('<<- 只允许前导 tab，空格缩进仍不是结束行', () {
      expect(ShellSyntax.unclosedReason('cat <<-EOF\nbody\n\tEOF'), isNull);
      expect(ShellSyntax.unclosedReason('cat <<-EOF\nbody\n  EOF'),
          contains('缺少结束行'));
      expect(ShellSyntax.unclosedReason('cat <<-EOF\nbody\n\tEOF  '),
          contains('缺少结束行'));
    });

    test('CRLF 的普通与 <<- 结束行可识别', () {
      expect(
          ShellSyntax.unclosedReason('cat <<EOF\r\nbody\r\nEOF\r\n'), isNull);
      expect(ShellSyntax.unclosedReason('cat <<-EOF\r\nbody\r\n\tEOF\r\n'),
          isNull);
    });

    test('同一行多个 heredoc 按顺序消费并校验每个 tag', () {
      const ok = 'cat <<FIRST <<SECOND\nfirst body\nFIRST\nsecond body\nSECOND';
      expect(ShellSyntax.unclosedReason(ok), isNull);
      expect(ShellSyntax.heredocBodyLines(ok.split('\n')), {1, 2, 3, 4});
      expect(ShellSyntax.unclosedReason('cat <<FIRST <<SECOND\nFIRST\nbody'),
          contains('SECOND'));
    });

    test('heredoc 起始识别保留跨行单双引号上下文', () {
      expect(
          ShellSyntax.unclosedReason('echo "first\nsecond" <<EOF\nbody\nEOF'),
          isNull);
      expect(
          ShellSyntax.unclosedReason("echo 'first\nsecond' <<EOF\nbody\nEOF"),
          isNull);
      // 引号内的 <<TAG 是纯文本，不能要求结束行。
      expect(ShellSyntax.unclosedReason('echo "first\n<<EOF demo"\necho ok'),
          isNull);
      expect(ShellSyntax.unclosedReason("echo 'first\n<<EOF demo'\necho ok"),
          isNull);
    });

    test('双引号内命令替换的 heredoc 正文不参与闭合检查', () {
      const cmd = 'echo "\$(cat <<EOF\nbody "unclosed\nEOF\n)"';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {1, 2});
    });

    test('双引号内嵌套命令替换的 heredoc 按顺序排除', () {
      const cmd = 'echo "\$(cat <<FIRST <<SECOND\n'
          'first "body\nFIRST\nsecond ) body\nSECOND\n)" && echo "done"';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {1, 2, 3, 4});
    });

    test('跨行命令替换中的 heredoc 可登记且闭合后恢复扫描', () {
      const cmd = 'echo "\$(\ncat <<EOF\nbody\nEOF\n)"\necho "done"';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {2, 3});
    });

    test('算术移位不识别为 heredoc，算术内命令替换仍可识别', () {
      expect(ShellSyntax.unclosedReason(r'echo $((value << TAG + 1))'), isNull);
      expect(
          ShellSyntax.unclosedReason(r'echo "$((value << TAG + 1))"'), isNull);
      expect(
          ShellSyntax.heredocBodyLines(
              r'echo $((value << TAG + 1))'.split('\n')),
          isEmpty);

      const cmd = 'echo \$(( \$(cat <<EOF\nbody\nEOF\n) + 1 ))';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {1, 2});
    });

    test('命令替换的引号字符串内伪 heredoc 不登记', () {
      const cmd = 'echo "\$(printf \'%s\' \'<<TAG demo\')"';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), isEmpty);

      const nestedDouble = 'echo "\$(printf \'%s\' "<<TAG demo")"';
      expect(ShellSyntax.unclosedReason(nestedDouble), isNull);
      expect(ShellSyntax.heredocBodyLines(nestedDouble.split('\n')), isEmpty);
    });

    test('反引号替换内真实 heredoc 被排除，引号内伪 heredoc 不登记', () {
      const real = 'echo "`cat <<EOF\nbody "unclosed\nEOF\n`"';
      expect(ShellSyntax.unclosedReason(real), isNull);
      expect(ShellSyntax.heredocBodyLines(real.split('\n')), {1, 2});

      const fake = 'echo "`printf \'%s\' \'<<EOF\'`"';
      expect(ShellSyntax.unclosedReason(fake), isNull);
      expect(ShellSyntax.heredocBodyLines(fake.split('\n')), isEmpty);
    });

    test('heredoc 起始行后续引号仍参与闭合检查', () {
      const cmd = 'cat <<EOF; echo "unclosed\nbody\nEOF';
      expect(ShellSyntax.unclosedReason(cmd), '双引号未闭合');
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {1, 2});
    });

    test('heredoc 正文中的注释/运算符不改变主命令引号状态', () {
      const cmd = 'cat <<EOF\n# "unclosed\njob &\nEOF\necho "done"';
      expect(ShellSyntax.unclosedReason(cmd), isNull);
      expect(ShellSyntax.heredocBodyLines(cmd.split('\n')), {1, 2, 3});
    });

    test('行内注释中的 heredoc 与引号不参与闭合检查', () {
      expect(ShellSyntax.unclosedReason('echo ok # cat <<EOF "demo'), isNull);
      expect(ShellSyntax.unclosedReason('cat <<EOF\nbody\nEOF # done'),
          contains('缺少结束行'));
    });

    test('Windows 命令直接放行', () {
      expect(ShellSyntax.unclosedReason('echo "abc', isWindows: true), isNull);
    });
  });

  group('ShellSyntax.scanPosixCommand 共享可靠性预检', () {
    test('反斜杠换行后的 & 仍识别为后台运算符', () {
      final scan = ShellSyntax.scanPosixCommand('echo ok \\\n&');
      expect(scan.hasBackgroundOperator, isTrue);
      expect(scan.reliabilityReason, contains('后台命令'));
    });

    test('注释续行不会把下一行误判为后台命令', () {
      final scan = ShellSyntax.scanPosixCommand('echo ok # note \\\n&');
      expect(scan.hasBackgroundOperator, isFalse);
      expect(scan.reliabilityReason, isNull);
    });

    test('heredoc 正文里的 & 不参与后台判定', () {
      final scan = ShellSyntax.scanPosixCommand('cat <<EOF\njob &\nEOF');
      expect(scan.hasBackgroundOperator, isFalse);
    });

    test('正常续行可闭合，末尾反斜杠续行被拒绝', () {
      expect(
          ShellSyntax.scanPosixCommand('echo ok \\\n  done').reliabilityReason,
          isNull);
      expect(
        ShellSyntax.scanPosixCommand('echo ok\n# note \\').reliabilityReason,
        '命令末尾反斜杠续行未闭合',
      );
    });

    test('行尾注释前需要右值的运算符在包装前拒绝', () {
      for (final command in [
        'true && # comment',
        'true || # comment',
        'printf x | # comment',
        'echo value > # comment',
        'echo value < # comment',
      ]) {
        expect(
          ShellSyntax.scanPosixCommand(command).reliabilityReason,
          contains('需要右值'),
          reason: command,
        );
      }
    });

    test('引号/转义中的运算符不会误判为悬空右值', () {
      expect(
          ShellSyntax.scanPosixCommand(r'echo "&&" # comment')
              .reliabilityReason,
          isNull);
      expect(
          ShellSyntax.scanPosixCommand(r'echo \& # comment').reliabilityReason,
          isNull);
      expect(
          ShellSyntax.scanPosixCommand('echo ok; # comment').reliabilityReason,
          isNull);
    });
  });
}
