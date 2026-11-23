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
      expect(
          ShellSyntax.unclosedReason('cat > f <<EOF\nline1'), contains('缺少结束行'));
    });

    test('行首注释里的引号不误报', () {
      expect(ShellSyntax.unclosedReason('# echo "comment\necho ok'), isNull);
    });

    test('Windows 命令直接放行', () {
      expect(
          ShellSyntax.unclosedReason('echo "abc', isWindows: true), isNull);
    });
  });
}
