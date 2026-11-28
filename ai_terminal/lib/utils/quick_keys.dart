/// 底部快捷按键栏的按键定义与修饰键转换。
///
/// 这些逻辑与 widget 无关，单独放在这里便于单测：按键顺序、粘滞修饰键如何把
/// 一个普通字符编码成 Ctrl/Alt 组合字节，都不需要起 Flutter 树就能验证。
library;

/// 一个快捷键。`sequence` 是按下后直接写入 PTY 的字节序列。
///
/// 修饰键（Ctrl/Shift/Alt）没有固定字节，`sequence` 留空，由页面按粘滞状态
/// 在下一个输入字符上计算。
class QuickKey {
  final String label;
  final String sequence;

  /// 修饰键标记：非空表示这是粘滞修饰键（'ctrl' / 'shift' / 'alt'）。
  final String? modifier;

  /// 是否需要更宽的点击区。方向键使用频率最高，单独加宽。
  final bool wide;

  const QuickKey(this.label, this.sequence,
      {this.modifier, this.wide = false});

  bool get isModifier => modifier == 'ctrl' || modifier == 'shift' || modifier == 'alt';
}

/// 底部栏的键位，按「常用优先」排列。
///
/// 顺序取舍：ESC/Tab/方向键/Home/End 是交互式程序与 shell 行编辑最高频的；
/// 修饰键紧随其后，方便紧接着敲一个普通字符。
/// 高频 Ctrl 组合（⌃C/⌃D/⌃Z/⌃L）与 readline 键放后面，需要横向滑动才看到。
///
/// 这里没有 Ins：往 PTY 写 ESC[2~ 只是把 shell 的编辑模式切成覆盖式，
/// 复制/粘贴要的是应用层读选区/写剪贴板，字节序列到不了那一层（真机验证）。
/// 触摸长按终端会弹出复制/粘贴菜单，见 TerminalView。
const List<QuickKey> kQuickKeys = [
  QuickKey('ESC', '\x1b'),
  QuickKey('Tab', '\t'),
  QuickKey('↑', '\x1b[A', wide: true),
  QuickKey('↓', '\x1b[B', wide: true),
  QuickKey('←', '\x1b[D', wide: true),
  QuickKey('→', '\x1b[C', wide: true),
  QuickKey('Home', '\x1b[H'),
  QuickKey('End', '\x1b[F'),
  QuickKey('Ctrl', '', modifier: 'ctrl'),
  QuickKey('Shift', '', modifier: 'shift'),
  QuickKey('Alt', '', modifier: 'alt'),
  QuickKey('⌃C', '\x03'),
  QuickKey('⌃D', '\x04'),
  QuickKey('⌃Z', '\x1a'),
  QuickKey('⌃L', '\x0c'),
  QuickKey('⌃A', '\x01'),
  QuickKey('⌃E', '\x05'),
  QuickKey('⌃U', '\x15'),
  QuickKey('⌃K', '\x0b'),
  QuickKey('⌃W', '\x17'),
  QuickKey('⌃R', '\x12'),
  QuickKey('PgUp', '\x1b[5~'),
  QuickKey('PgDn', '\x1b[6~'),
];

/// 粘滞修饰键的开关状态。页面持有，点一次切换，下一个输入字符消费一次。
class StickyModifiers {
  final bool ctrl;
  final bool shift;
  final bool alt;

  const StickyModifiers({this.ctrl = false, this.shift = false, this.alt = false});

  static const none = StickyModifiers();

  bool get any => ctrl || shift || alt;

  /// 切换某个修饰键。传入非修饰键名时原样返回。
  StickyModifiers toggle(String modifier) {
    switch (modifier) {
      case 'ctrl':
        return StickyModifiers(ctrl: !ctrl, shift: shift, alt: alt);
      case 'shift':
        return StickyModifiers(ctrl: ctrl, shift: !shift, alt: alt);
      case 'alt':
        return StickyModifiers(ctrl: ctrl, shift: shift, alt: !alt);
      default:
        return this;
    }
  }
}

/// 把一个可打印字符按粘滞修饰键编码成 PTY 应收到的字节。
///
/// 只处理单字符输入（软键盘上敲的一个可见字符）；多字符（粘贴、IME 一次上屏
/// 多字）一律原样返回，避免把整段文本按 Ctrl 编码。
///
/// 编码规则与终端惯例一致：
/// - Ctrl + 字母/符号：取 `code & 0x1f`（Ctrl+A = 0x01 … Ctrl+Z = 0x1a，
///   Ctrl+[ = ESC 等），仅对 ASCII 0x40..0x7f 区间有意义；
/// - Alt + 字符：前缀 ESC（0x1b），即 “meta 前缀”；
/// - Shift + 字符：大多数字符的 shift 形态由软键盘直接给出（已是 'A' 而非 'a'），
///   这里只在仍是小写字母时补成大写；其他字符不强行改；
/// - 多个修饰键按 Alt 前缀 + 主体（Ctrl/Shift）顺序叠加。
///
/// 返回 null 表示「没有可用的转换」，调用方应按普通输入发送原字符。
String? encodeWithModifiers(String input, StickyModifiers mods) {
  if (input.isEmpty || !mods.any) return null;
  // 只处理单个可见字符：粘贴/多字上屏不参与修饰编码。
  final runes = input.runes.toList();
  if (runes.length != 1) return null;
  final code = runes.first;
  if (code < 0x20) return null; // 控制字符本身不叠加

  var body = String.fromCharCode(code);

  if (mods.ctrl) {
    final upper = body.toUpperCase();
    final c = upper.codeUnitAt(0);
    if (c >= 0x40 && c <= 0x7f) {
      body = String.fromCharCode(c & 0x1f);
    } else if (c == 0x3f) {
      // Ctrl+? = 0x7f（DEL），shell 里等同退格。
      body = String.fromCharCode(0x7f);
    } else {
      // 非 ASCII/不可控字符：Ctrl 无意义，放弃编码，交给调用方原样发送。
      return null;
    }
  } else if (mods.shift) {
    // 只在仍为小写字母时补大写；其余字符假定软键盘已给出 shift 形态。
    final rune = body.runes.first;
    if (rune >= 0x61 && rune <= 0x7a) {
      body = String.fromCharCode(rune - 0x20);
    }
  }

  if (mods.alt) {
    body = '\x1b$body';
  }
  return body;
}