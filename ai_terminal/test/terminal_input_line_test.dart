import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/utils/terminal_input_line.dart';

/// 造一个指定宽度、写完内容的终端。
xterm.Terminal terminalWith(String data, {int cols = 80, int rows = 10}) {
  final terminal = xterm.Terminal(maxLines: 200);
  terminal.resize(cols, rows);
  terminal.write(data);
  return terminal;
}

void main() {
  group('currentInputLineOf', () {
    test('提示符 + 命令原样读出', () {
      final t = terminalWith(r'user@web1:~$ ls -l');
      expect(currentInputLineOf(t), r'user@web1:~$ ls -l');
    });

    test('上一行输出不混进来', () {
      final t = terminalWith('total 12\ndrwxr-xr-x 2 u g\r\nuser@web1:~\$ ');
      expect(currentInputLineOf(t), r'user@web1:~$');
    });

    test('折行的长命令拼回一行，且不留 CR / LF', () {
      final cmd = 'echo ${'a' * 90}';
      final t = terminalWith('root@host:/x\$ $cmd', cols: 80);
      final line = currentInputLineOf(t);
      expect(line, 'root@host:/x\$ $cmd');
      expect(line.contains('\r'), isFalse);
      expect(line.contains('\n'), isFalse);
    });

    test('不折行的新行不往前并', () {
      // 没有尾部换行：光标停在 second 这一行，前面的 first line 不算
      final t = terminalWith('first line\r\nsecond');
      expect(currentInputLineOf(t), 'second');
      // 尾部换行后光标落到新的空行 → 输入行为空，不把上一行拖进来
      expect(currentInputLineOf(terminalWith('first line\r\nsecond\r\n')), '');
    });

    test('整屏宽的纯文本折行后拼回原样', () {
      final t = terminalWith('a' * 80, cols: 20);
      final line = currentInputLineOf(t);
      expect(line.length, 80);
      expect(line.contains('\r'), isFalse);
    });

    test('空 buffer 读空串', () {
      expect(currentInputLineOf(terminalWith('')), isEmpty);
    });

    test('宽字符折行也拼得回来', () {
      // 20 列 = 10 个汉字；写 30 个会折成多行
      final text = '中' * 30;
      final t = terminalWith(text, cols: 20);
      expect(currentInputLineOf(t), text);
    });
  });

  group('trimTrailingControl', () {
    test('裁掉行尾空白、CR 与 NUL 填充', () {
      final nul = String.fromCharCode(0);
      expect(trimTrailingControl('ls -l   '), 'ls -l');
      expect(trimTrailingControl('ls -l$nul$nul$nul'), 'ls -l');
      expect(trimTrailingControl('ls -l\r'), 'ls -l');
    });

    test('无尾部空白时内容不变', () {
      expect(trimTrailingControl('ls -l'), 'ls -l');
      expect(trimTrailingControl(''), '');
    });
  });

  group('firstLineOfInput', () {
    xterm.BufferLine wrapped() => xterm.BufferLine(4, isWrapped: true);

    test('回溯有上限，不会被异常 buffer 吞掉整段回滚区', () {
      const total = 200;
      final all = List.generate(total, (_) => wrapped());
      expect(firstLineOfInput(total - 1, (i) => all[i]), total - 1 - 64);
    });

    test('未折行时就是光标行本身', () {
      final lines = [xterm.BufferLine(4), xterm.BufferLine(4)];
      expect(firstLineOfInput(1, (i) => lines[i]), 1);
    });
  });
}
