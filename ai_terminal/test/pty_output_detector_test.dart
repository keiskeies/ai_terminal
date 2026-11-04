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

  group('sudo 密码提示语言中立识别', () {
    // sudo 只翻译 "password for %u"，`[sudo]` 前缀各语言保留。
    // 历史上这里匹配英文整句，中文服务器（用户实机 i78750k）永远命中不了。
    for (final prompt in [
      '[sudo] password for cjm: ',
      '[sudo] cjm 的密码：',
      '[sudo] Passwort für cjm: ',
      '[sudo] cjm さんのパスワード: ',
      '[sudo] contraseña para cjm: ',
    ]) {
      test('"$prompt" 识别为 sudo 提示', () {
        expect(PtyOutputDetector.waitsForSudoPassword(prompt), isTrue);
      });
    }

    test('提示已被后续输出顶掉 → 不再算等待密码', () {
      final buffer = 'sudo apt update\r\n'
          '[sudo] cjm 的密码：\r\n'
          '获取:1 http://deb.debian.org stable InRelease [150 kB]\r\n';
      expect(PtyOutputDetector.waitsForSudoPassword(buffer), isFalse);
    });

    test('日志里出现的 [sudo] 行不当成等待密码', () {
      final buffer = "grep '\\[sudo\\]' /var/log/auth.log\r\n"
          'Nov  3 10:11:12 host sudo: cjm : 3 incorrect password attempts\r\n\$ ';
      expect(PtyOutputDetector.waitsForSudoPassword(buffer), isFalse);
    });

    test('未配置密码时中文提示仍报 interactivePrompt', () {
      final diag = PtyOutputDetector.detect(
        buffer: '[sudo] cjm 的密码：',
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('已配置密码时不中断命令，交给调用方应答', () {
      final diag = PtyOutputDetector.detect(
        buffer: '[sudo] cjm 的密码：',
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        sudoPromptWillBeAnswered: true,
      );
      expect(diag, isNull);
    });

    test('已配置 sudo 密码也不能把密码喂给其它程序的提示', () {
      // ssh/macOS 的 Password: 与 sudo 无关，误注入等于把特权密码泄露给别的进程
      final diag = PtyOutputDetector.detect(
        buffer: 'ssh deploy@10.0.0.5\r\nPassword: ',
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        sudoPromptWillBeAnswered: true,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });
  });

  group('SudoPromptResponder', () {
    test('同一段提示分多个 chunk 到达只应答一次', () {
      final r = SudoPromptResponder();
      expect(r.shouldAnswer('[sudo] cjm 的密码'), isFalse); // 冒号还没到
      expect(r.shouldAnswer('[sudo] cjm 的密码：'), isTrue);
      expect(r.shouldAnswer('[sudo] cjm 的密码： '), isFalse); // 尾随空格是同一提示
      expect(r.shouldAnswer('[sudo] cjm 的密码：  '), isFalse);
    });

    test('sudo 重试产生的新提示可以再应答一次', () {
      final r = SudoPromptResponder();
      expect(r.shouldAnswer('[sudo] cjm 的密码：'), isTrue);
      expect(r.shouldAnswer('[sudo] cjm 的密码：'), isFalse);
      // 答错后 sudo 打印重试并再次把提示打到尾部
      final retry = '[sudo] cjm 的密码：\r\n对不起，请重试。\r\n[sudo] cjm 的密码：';
      expect(r.shouldAnswer(retry), isTrue);
    });

    test('命令链里第二条 sudo 的提示同样能应答', () {
      final r = SudoPromptResponder();
      expect(r.shouldAnswer('[sudo] cjm 的密码：'), isTrue);
      expect(
        r.shouldAnswer('[sudo] cjm 的密码：\r\nOK\r\n[sudo] cjm 的密码：'),
        isTrue,
      );
    });
  });

  group('分页器等待检测', () {
    test('用户原案例：journalctl 停在 less 的 (END)', () {
      const buffer = 'IDX BOOT ID                          FIRST ENTRY\r\n'
          ' -1 ba6d79bc62864baba1fa29d7d29b88ea Wed 2026-11-04 00:27:18 CST\r\n'
          '  0 156cc5d90dde403f9e674bd2bcd53dfd Wed 2026-11-04 00:55:07 CST\r\n'
          'lines 1-3/3 (END)';
      expect(PtyOutputDetector.waitsForPager(buffer), isTrue);
    });

    test('ANSI 包裹的 (END) 状态行', () {
      const buffer = 'output\r\n\x1B[7m(END)\x1B[27m\x1B[K';
      expect(PtyOutputDetector.waitsForPager(buffer), isTrue);
    });

    test('more 的 --More-- 状态行（含退格重绘）', () {
      expect(
        PtyOutputDetector.waitsForPager('line\r\n--More--(23%)\x08\x08\x08'),
        isTrue,
      );
      expect(PtyOutputDetector.waitsForPager('line\r\n--More--'), isTrue);
    });

    test('less -M 的 lines x-y/z 状态行', () {
      expect(
        PtyOutputDetector.waitsForPager('...\r\nlines 1-24/100'),
        isTrue,
      );
    });

    test('正文中间的 (END) 不算分页器', () {
      const buffer = '(END)\r\nIDX BOOT ID\r\n  0 156cc5d90dde403f9e674bd2bcd53dfd';
      expect(PtyOutputDetector.waitsForPager(buffer), isFalse);
    });

    test('状态行已滚出尾部窗口 → 不误判', () {
      final buffer = '(END)${'x' * 3000}';
      expect(PtyOutputDetector.waitsForPager(buffer), isFalse);
    });

    test('普通命令输出不误判', () {
      expect(PtyOutputDetector.waitsForPager('total 0\r\ndrwxr-xr-x 2 root root'), isFalse);
      expect(PtyOutputDetector.waitsForPager(''), isFalse);
    });
  });
}
