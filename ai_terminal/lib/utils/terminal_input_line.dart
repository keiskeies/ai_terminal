/// 从终端 buffer 读出「用户正在输入的那一行」。
///
/// 命令历史的数据源来自屏幕而不是按键（理由见 utils/command_tracker.dart），
/// 而屏幕读出来的行有两个坑：
///
/// 1. **换行折行**：命令比终端宽度长时 shell 会把它折成好几行，buffer 里每段
///    都是一条独立行，靠 `BufferLine.isWrapped` 串起来。只取光标行会拿到命令的
///    尾巴，所以要从光标行往回并所有 `isWrapped` 的行。
/// 2. **换行符是 CRLF**：`\r\n` 拼回去会在中间留一个 `\r`，落到终端上等于
///    回车——把历史粘贴出去时会多执行一次。段落一律裁掉行尾控制字符再拼。
library;

import 'package:xterm/xterm.dart' as xterm;

/// 取 [terminal] 当前输入行的完整文本（含折行拼接）。
/// 无光标行（buffer 未就绪）返回空串。
String currentInputLineOf(xterm.Terminal terminal) {
  final buffer = terminal.buffer;
  final lines = buffer.lines;
  if (lines.length == 0) return '';
  final cursor = buffer.absoluteCursorY.clamp(0, lines.length - 1);
  return inputLineAt(cursor, (i) => lines[i]);
}

/// 纯函数版本：给定光标行号与取行器，返回该光标行所属输入行的文本。
/// 与 xterm 的 buffer 容器解耦，便于单测直接喂构造好的行序列。
String inputLineAt(
  int cursorLine,
  xterm.BufferLine Function(int index) lineAt,
) {
  final start = firstLineOfInput(cursorLine, lineAt);
  final buf = StringBuffer();
  for (var i = start; i <= cursorLine; i++) {
    buf.write(trimTrailingControl(lineAt(i).getText()));
  }
  return buf.toString();
}

/// 往回找到本输入行的首行：`isWrapped` 为真表示这行是上一行的延续。
int firstLineOfInput(
    int cursorLine, xterm.BufferLine Function(int index) lineAt) {
  var start = cursorLine;
  // 上限防止异常 buffer（每行都标记 wrapped）把整段回滚区吞进来
  while (start > 0 && lineAt(start).isWrapped && cursorLine - start < _maxWrapLookback) {
    start--;
  }
  return start;
}

const int _maxWrapLookback = 64;

/// 裁掉行尾的空白与控制字符（NUL 填充、CR、制表等）。
String trimTrailingControl(String text) {
  var end = text.length;
  while (end > 0) {
    final cp = text.codeUnitAt(end - 1);
    if (cp == 0x20 || cp <= 0x20) {
      end--;
    } else {
      break;
    }
  }
  return end == text.length ? text : text.substring(0, end);
}
