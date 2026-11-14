/// OSC 133 命令块跟踪。
///
/// 支持语义提示的 shell（iTerm2 的 shell integration、WezTerm、 Waves、
/// starship 的 `--print-prompt-continuation` 之类）会在提示符前后打
/// `ESC ] 133 ; A BEL` 这一类序列。xterm 4.0.0 不认识 133，但会把不认识的
/// OSC 原样转交给 `Terminal.onPrivateOSC`（parser 里唯一的一条通路），
/// 所以不必 fork 就能拿到事件。
///
/// 位置一律记成 `CellAnchor` 而不是行号：回滚区裁剪、折行重排都会让行号漂移，
/// 而锚点保证相对位置不变；被裁掉的锚点自动 detach，那一块就作废 —— 宁可不给
/// 「解释本块」，也不要把相邻两次命令的输出拼在一起喂给 AI。
///
/// 没装 shell integration 的会话一个块也不会有（不会有 A 事件）。所有入口在
/// 块列表为空时都安静返回 null / 空串，调用方据此隐藏菜单项，绝不报错。
library;

import 'package:xterm/xterm.dart' as xterm;

import 'terminal_text_actions.dart' show stripPromptPrefix;

/// OSC 133 的四种标记。语义按 iTerm2/wezterm 的约定：
/// A = 提示符开始，B = 提示符结束（命令即将输入），
/// C = 命令开始执行（输出即将到达），D = 命令结束（可带退出码）。
enum BlockMarker { promptStart, promptEnd, commandStart, commandFinished }

BlockMarker? parseOsc133(String code, List<String> args) {
  if (code != '133' || args.isEmpty) return null;
  switch (args.first) {
    case 'A':
      return BlockMarker.promptStart;
    case 'B':
      return BlockMarker.promptEnd;
    case 'C':
      return BlockMarker.commandStart;
    case 'D':
      return BlockMarker.commandFinished;
    default:
      return null;
  }
}

/// 从 D 的参数里取退出码（`133;D;0`）。非数字（有的实现塞 `;` 附加数据）返回 null。
int? parseOsc133ExitCode(String code, List<String> args) {
  if (code != '133' || args.isEmpty || args.first != 'D') return null;
  if (args.length < 2) return null;
  return int.tryParse(args[1]);
}

/// 一个命令块：锚点 + 退出码。锚点可能 detach（回滚裁剪 / 切到 alt buffer），
/// 此时 [startLine] 返回 null，这块视作不可用。
class TerminalBlock {
  TerminalBlock(this._prompt);

  final xterm.CellAnchor _prompt;
  xterm.CellAnchor? command;
  xterm.CellAnchor? output;
  xterm.CellAnchor? end;
  int? exitCode;

  /// shell 若在 A 的参数里带了 `cmd=`（Wave 的做法），这里能拿到原文
  String? promptData;

  bool get isAttached => _prompt.attached;

  int? get startLine => _prompt.attached ? _prompt.y : null;

  /// 命令文本所在行（B 存在时是 B 的行，否则退回提示符行）
  int? get commandLine =>
      command?.attached == true ? command!.y : startLine;

  /// 输出首行（C 存在时是 C 的行；没有 C 就紧跟命令行）
  int? outputFirstLine(int bufferHeight) {
    if (output?.attached == true) return output!.y;
    final line = commandLine;
    if (line == null) return null;
    return line + 1 <= bufferHeight - 1 ? line + 1 : null;
  }

  void dispose() {
    _prompt.dispose();
    command?.dispose();
    output?.dispose();
    end?.dispose();
  }
}

/// 逐事件维护某台终端的命令块列表。
///
/// 事件来自 `Terminal.onPrivateOSC`，在 `write()` 解析线程内同步触发，
/// 此刻光标正停在 shell 打标记的位置，直接按光标造锚点即可。
class TerminalBlockTracker {
  TerminalBlockTracker({required this.terminal});

  final xterm.Terminal terminal;

  final List<TerminalBlock> _blocks = [];
  TerminalBlock? _open;

  /// 上限：回滚区可以有几万行，锚点不能无界增长（R8）。
  static const int maxBlocks = 400;

  List<TerminalBlock> get blocks => List.unmodifiable(_blocks);

  int get length => _blocks.length;

  bool get isEmpty => _blocks.isEmpty;

  /// 喂给 `Terminal.onPrivateOSC`
  void onPrivateOsc(String code, List<String> args) {
    final marker = parseOsc133(code, args);
    if (marker == null) return;
    switch (marker) {
      case BlockMarker.promptStart:
        // shell 没发 D 就开下一块（比如命令被 ^C 掐断）：上一块就此收尾
        final anchor = _anchor();
        if (anchor == null) {
          // 光标位置拿不到（回滚边界）：这一块直接放弃，不留半截块
          _open = null;
          break;
        }
        final block = TerminalBlock(anchor);
        _open = block;
        // A 的参数形如 ['A', 'cmd=ls']，只认 key=value，别把裸串当命令
        for (final part in args.skip(1)) {
          final eq = part.indexOf('=');
          if (eq > 0 && block.promptData == null) {
            block.promptData = part.substring(eq + 1);
          }
        }
        _blocks.add(block);
        _trim();
      case BlockMarker.promptEnd:
        final open = _open;
        if (open != null && open.command == null) {
          open.command = _anchor();
        }
      case BlockMarker.commandStart:
        final open = _open;
        if (open != null && open.output == null) {
          open.output = _anchor();
        }
      case BlockMarker.commandFinished:
        final open = _open;
        if (open != null && open.end == null) {
          open.end = _anchor();
          open.exitCode = parseOsc133ExitCode(code, args);
        }
        _open = null;
    }
  }

  /// 本回调在 `Terminal.write()` 的解析循环里同步执行。xterm 4.0.0 的循环缓冲
  /// 在回滚回卷时本身就会越界（页面侧为此写了恢复逻辑），此刻再抛异常等于把
  /// 整段输出写坏。取不到锚点就放弃这块 —— 命令块只是便利功能。
  xterm.CellAnchor? _anchor() {
    try {
      final buffer = terminal.buffer;
      final height = buffer.height;
      if (height == 0) return null;
      final y = buffer.absoluteCursorY;
      if (y < 0 || y >= height) return null;
      return buffer.createAnchor(buffer.cursorX, y);
    } catch (_) {
      return null;
    }
  }

  /// 先扔锚点已脱离的（被回滚裁掉），再按上限掐旧的。
  void _trim() {
    _blocks.removeWhere((b) {
      if (b.isAttached) return false;
      b.dispose();
      return true;
    });
    while (_blocks.length > maxBlocks) {
      _blocks.removeAt(0).dispose();
    }
  }

  /// 清屏/重连后调用：旧锚点全部作废
  void reset() {
    for (final b in _blocks) {
      b.dispose();
    }
    _blocks.clear();
    _open = null;
  }

  void dispose() => reset();
}

/// 块的首行；锚点已脱离（回滚裁掉）返回 null。
int? blockStartLine(List<TerminalBlock> blocks, int index) {
  if (index < 0 || index >= blocks.length) return null;
  return blocks[index].startLine;
}

/// 某一块覆盖的 buffer 行区间 [start, end]（含端点）。
/// 终点优先取 D 锚点；没有 D 就到下一块的提示符前一行；都没有就到缓冲末尾。
({int start, int end})? blockLineRange(
  List<TerminalBlock> blocks,
  int index,
  int bufferHeight,
) {
  if (index < 0 || index >= blocks.length) return null;
  final block = blocks[index];
  final start = block.startLine;
  if (start == null) return null;
  var end = bufferHeight - 1;
  final endLine = block.end?.attached == true ? block.end!.y : null;
  if (endLine != null) {
    end = endLine;
  }
  for (var i = index + 1; i < blocks.length; i++) {
    final next = blocks[i].startLine;
    if (next == null) continue;
    if (next - 1 < end) end = next - 1;
    break;
  }
  if (end < start) end = start;
  if (end > bufferHeight - 1) end = bufferHeight - 1;
  return (start: start, end: end);
}

/// 光标/右键所在行命中哪一块。落在两块之间（比如最开头）返回 null。
int? blockIndexAtLine(List<TerminalBlock> blocks, int line, int bufferHeight) {
  for (var i = 0; i < blocks.length; i++) {
    final range = blockLineRange(blocks, i, bufferHeight);
    if (range == null) continue;
    if (line >= range.start && line <= range.end) return i;
  }
  return null;
}

/// 从 [line] 往后/往前跳到下一块 / 上一块。[forward] 为 false 时往回。
/// 返回 null 表示没有可跳的目标（调用方据此禁用菜单项）。
int? blockIndexNearLine(
  List<TerminalBlock> blocks,
  int line, {
  required bool forward,
  int bufferHeight = 1 << 30,
}) {
  if (forward) {
    for (var i = 0; i < blocks.length; i++) {
      final range = blockLineRange(blocks, i, bufferHeight);
      if (range != null && range.start > line) return i;
    }
  } else {
    for (var i = blocks.length - 1; i >= 0; i--) {
      final range = blockLineRange(blocks, i, bufferHeight);
      if (range != null && range.start < line) return i;
    }
  }
  return null;
}

/// 读某一块覆盖的 buffer 行区间内文本的取行器。越界读返回空串：
/// 块与读取之间缓冲可能又被裁剪，行号会失效。
String Function(int line) blockLineReader(xterm.Terminal terminal) {
  String read(int i) {
    final height = terminal.buffer.height;
    if (i < 0 || i >= height) return '';
    return terminal.buffer.lines[i].getText();
  }

  return read;
}

/// 取块内文本：命令行 + 输出。行尾填充空格与 NUL 一律裁掉。
/// 全空（只有一条提示符）返回空串，调用方据此隐藏菜单项。
String blockTextOf(
  List<TerminalBlock> blocks,
  int index,
  int bufferHeight,
  String Function(int line) lineAt,
) {
  final range = blockLineRange(blocks, index, bufferHeight);
  if (range == null) return '';
  final lines = <String>[];
  for (var i = range.start; i <= range.end; i++) {
    final text = stripTrailing(_line(lineAt, i));
    // 输出里连续的空行不带进 AI 上下文，白占 token
    if (text.isEmpty && (lines.isEmpty || lines.last.isEmpty)) continue;
    lines.add(text);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

String _line(String Function(int line) lineAt, int i) {
  try {
    return lineAt(i);
  } catch (_) {
    // 调用方读的是实时 buffer，块与读取之间可能被裁剪，行号会越界
    return '';
  }
}

String stripTrailing(String text) {
  var end = text.length;
  while (end > 0) {
    final cp = text.codeUnitAt(end - 1);
    if (cp == 0x20 || cp == 0) {
      end--;
    } else {
      break;
    }
  }
  return end == text.length ? text : text.substring(0, end);
}

/// 块里的命令（提示符已剥掉）。优先用 shell 在 A 参数里给的 `cmd=`，
/// 否则从屏幕行剥提示符。
///
/// 和 CommandTracker 同一道闸门：**必须真的剥掉了一段前缀**才算命令。
/// 没剥掉说明这行根本不是「提示符 + 命令」（可能是裸输出），
/// 宁可得 null 让菜单少一项，也不要把输出行当命令喂给 AI。
String? blockCommandOf(TerminalBlock block, String Function(int line) lineAt) {
  final inline = block.promptData?.trim();
  if (inline != null && inline.isNotEmpty) return inline;
  final line = block.commandLine;
  if (line == null) return null;
  final raw = _line(lineAt, line).trim();
  if (raw.isEmpty) return null;
  final stripped = stripPromptPrefix(raw).trim();
  if (stripped.isEmpty || stripped.length == raw.length) return null;
  return stripped;
}

/// 喂给 AI 的块文本：必须有上限（R8），但报错总在末尾、命令在开头，
/// 所以留头 + 留尾，中间掐掉并标注省略了多少行。
String clipBlockForAgent(String text, {int maxChars = 6000}) {
  if (text.length <= maxChars) return text;
  final lines = text.split('\n');
  final headBudget = (maxChars * 0.25).floor();
  final head = <String>[];
  var used = 0;
  for (final line in lines) {
    if (used + line.length + 1 > headBudget) break;
    head.add(line);
    used += line.length + 1;
  }
  final headCount = head.length;
  final tail = <String>[];
  var tailUsed = 0;
  for (var i = lines.length - 1; i >= headCount; i--) {
    if (tailUsed + lines[i].length + 1 > maxChars - used) break;
    tail.insert(0, lines[i]);
    tailUsed += lines[i].length + 1;
  }
  final skipped = lines.length - headCount - tail.length;
  return [...head, '… 省略 $skipped 行 …', ...tail].join('\n');
}
