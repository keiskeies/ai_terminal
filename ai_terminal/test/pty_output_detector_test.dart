import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/pty_output_detector.dart';

void main() {
  group('PtyOutputDetector.detect', () {
    test('用户原案例：&; 语法错误立即识别', () {
      // 用户原始命令末尾 `&;` 是 bash 非法语法
      // wrappedCommand 拼接后：nohup ... &; echo "EXITCODE_1:$?"
      // bash 解析阶段就报错，marker 永远不出现
      // 真实输出：先命令回显，再 bash 错误，再下个 prompt
      final buffer =
          'nohup java ... > /dev/null 2>&1 &; echo "EXITCODE_1:\$?"\r\n'
          '-bash: syntax error near unexpected token `;\'\r\n'
          '\$ ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.syntaxError);
      expect(diag.reason, contains('syntax error'));
    });

    test('引号未闭合 → PS2 提示符', () {
      // echo "abc 后 bash 进入 PS2 等待更多输入
      final buffer = 'echo "abc\r\n> ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 800,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.syntaxError);
      expect(diag.reason, contains('PS2'));
    });

    test('dquote PS2 提示符', () {
      final buffer = 'echo "abc\r\ndquote> ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 800,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.syntaxError);
    });

    test('sudo 密码提示', () {
      final buffer = '[sudo] password for root: ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('ssh yes/no 确认提示', () {
      final buffer = 'Are you sure you want to continue connecting (yes/no)? ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('marker 已出现 → 不检测（正常完成）', () {
      final buffer = 'EXITCODE_1:0';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 1000,
        isWindows: false,
      );
      expect(diag, isNull);
    });

    test('命令回显阶段（< 150ms）→ 不检测，避免误报', () {
      // 命令刚发出，回显还没稳定，不该检测
      final buffer = 'nohup java ... &; echo "EXITCODE_1:\$?"';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 50,
        isWindows: false,
      );
      expect(diag, isNull);
    });

    test('误报规避：cat 日志里含 "bash:" 字样但不是 syntax error', () {
      // 日志里只有 "bash: foo: command not found"，不含 syntax error
      // 不应该被识别为语法错误
      final buffer = '''
bash: foo: command not found
EXITCODE_1:127
''';
      // marker 未出现的窗口内（但日志本身合法）不应误报
      final diag = PtyOutputDetector.detect(
        buffer: 'bash: foo: command not found\n',  // 不含 marker
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNull, reason: 'command not found 不是 syntax error，不该误报');
    });

    test('误报规避：cat 日志里含 "syntax error" 字样但没有 bash: 前缀', () {
      // 日志本身记录了某次 syntax error，但不应该让本次命令被误判
      final buffer = 'log: some previous syntax error in python code\n';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNull, reason: '没有 bash:/sh: 前缀不该误判为 shell 语法错误');
    });

    test('误报规避：普通输出包含 "> " 但不是 PS2 提示符', () {
      // 例如 `echo "hello > world"` 输出
      // 要求 PS2 检测在 > 500ms 后才触发，且要求新行行首
      final buffer = 'hello > world\n';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 800,
        isWindows: false,
      );
      expect(diag, isNull, reason: '行内 > 不该误判为 PS2');
    });

    test('Windows 跳过 POSIX shell 检测', () {
      final buffer = '-bash: syntax error near unexpected token\n';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: true,
      );
      expect(diag, isNull, reason: 'Windows 下不做 POSIX shell 语法错误检测');
    });

    test('多种 shell：zsh 语法错误也识别', () {
      // 注意：zsh 用 "parse error" 不是 "syntax error"，按当前实现不应识别
      // 但若 zsh 报 "syntax error" 应识别
      final buffer = 'zsh: syntax error: unexpected token\n';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.syntaxError);
    });

    test('未闭合括号进入 PS2（cmdsubst>）', () {
      final buffer = 'echo \$(date\r\ncmdsubst> ';
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 800,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.syntaxError);
    });
  });
}
