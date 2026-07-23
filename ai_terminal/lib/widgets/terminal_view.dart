import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;
import '../core/theme_colors.dart';

class TerminalView extends StatefulWidget {
  final xterm.Terminal? terminal;
  final ValueChanged<String>? onSend;
  final double fontSize;

  const TerminalView({
    super.key,
    this.terminal,
    this.onSend,
    this.fontSize = 13,
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final FocusNode _focusNode = FocusNode();

  static const _theme = xterm.TerminalTheme(
    cursor: Color(0xFF6ECC54),
    selection: Color(0x803B7DFF),
    foreground: Color(0xFFF0F0F5),
    background: Color(0xFF000000),
    black: Color(0xFF1A1A24),
    red: Color(0xFFC8161D),
    green: Color(0xFF6ECC54),
    yellow: Color(0xFFEB5C20),
    blue: Color(0xFF3B7DFF),
    magenta: Color(0xFFC83080),
    cyan: Color(0xFF3DB8E8),
    white: Color(0xFFE8E8F0),
    brightBlack: Color(0xFF4A4A5A),
    brightRed: Color(0xFFE03040),
    brightGreen: Color(0xFF8FE07A),
    brightYellow: Color(0xFFF07840),
    brightBlue: Color(0xFF5A9AFF),
    brightMagenta: Color(0xFFF070C0),
    brightCyan: Color(0xFF5CD0F0),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF1A1A24),
    searchHitBackgroundCurrent: Color(0xFF2A2A38),
    searchHitForeground: Color(0xFFF0F0F5),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.terminal != null && widget.terminal != oldWidget.terminal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.unfocus();
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 键盘事件处理：
  /// - KeyUpEvent 拦截（防止 CustomKeyboardListener 重复插入字符）
  /// - character 为 null 时（Windows IME 问题）从 keyLabel fallback
  /// - 其他情况返回 ignored，让 xterm keyInput + CustomKeyboardListener 处理
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // KeyUpEvent 拦截：CustomKeyboardListener._onKeyEvent 对所有事件类型
    // 都尝试 onInsert，而 xterm _handleKeyEvent 对 KeyUpEvent 返回 ignored，
    // 导致字符被插入两次。
    if (event is KeyUpEvent) {
      return KeyEventResult.handled;
    }

    // 只处理 KeyDownEvent 和 KeyRepeatEvent
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final terminal = widget.terminal;
    if (terminal == null) {
      return KeyEventResult.ignored;
    }

    final hardware = HardwareKeyboard.instance;
    final hasCtrl = hardware.isControlPressed;
    final hasAlt = hardware.isAltPressed;
    final hasMeta = hardware.isMetaPressed;

    // 只在没有 ctrl/alt/meta 修饰键且 character 为 null 时提供 fallback。
    // 有修饰键时交给 xterm keyInput 处理（如 Ctrl+C → \x03）。
    // character 不为 null 时交给 CustomKeyboardListener 的 character 路径处理。
    if (!hasCtrl && !hasAlt && !hasMeta &&
        (event.character == null || event.character!.isEmpty)) {
      final char = _charFromKeyEvent(event, hardware.isShiftPressed);
      if (char != null && char.isNotEmpty) {
        terminal.textInput(char);
        return KeyEventResult.handled;
      }
    }

    // 返回 ignored，让 xterm 继续处理：
    // 1. _handleKeyEvent → keyInput（处理特殊键如 Enter/Tab/方向键/Ctrl+字母）
    // 2. CustomKeyboardListener 检查 character（如果不为 null）
    return KeyEventResult.ignored;
  }

  /// 当 KeyEvent.character 为 null 时（Windows IME 问题），
  /// 从 LogicalKeyboardKey.keyLabel 生成字符。
  String? _charFromKeyEvent(KeyEvent event, bool shift) {
    final key = event.logicalKey;

    // Space 键
    if (key == LogicalKeyboardKey.space) {
      return ' ';
    }

    final label = key.keyLabel;
    if (label.length != 1) {
      return null;
    }

    // 字母键：keyLabel 返回大写，根据 shift 决定大小写
    if (RegExp(r'[a-zA-Z]').hasMatch(label)) {
      return shift ? label.toUpperCase() : label.toLowerCase();
    }

    // 数字键和符号键：keyLabel 直接是字符
    // 注意：Shift+数字键的符号（如 Shift+1=!）无法通过 keyLabel 获取，
    // 但这只在 character 为 null 时作为 fallback，覆盖大多数场景。
    return label;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.terminal == null) {
      final tc = ThemeColors.of(context);
      return Container(
        color: tc.terminalBg,
        child: Center(
          child: Text('等待连接...', style: TextStyle(color: tc.textSub)),
        ),
      );
    }

    // 桌面平台使用 hardwareKeyboardOnly=true（CustomKeyboardListener 路径）。
    //
    // 为什么不用默认的 CustomTextEdit 路径：
    // CustomTextEdit 通过 TextInput.attach 建立连接，期望通过
    // updateEditingValue 回调获取字符。但 Windows 桌面的 TextInput
    // 实现不通过 updateEditingValue 发送普通键盘字符（只用于 IME）。
    // 结果：keyInput 对字母键返回 false → ignored → 传递给 TextInput →
    // TextInput 不处理 → 字符丢失。只有 keytab 中有映射的特殊键
    // （Enter/Tab/Backspace/方向键等）能正常工作。
    //
    // hardwareKeyboardOnly=true 的 CustomKeyboardListener 路径：
    // keyInput 失败后从 KeyEvent.character 插入字符。但 Windows 上
    // IME 激活时 character 可能为 null，所以通过 onKeyEvent 回调
    // 提供 fallback：从 LogicalKeyboardKey.keyLabel 生成字符。
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    return xterm.TerminalView(
      widget.terminal!,
      focusNode: _focusNode,
      autofocus: true,
      hardwareKeyboardOnly: isDesktop,
      onKeyEvent: _handleKeyEvent,
      textStyle: xterm.TerminalStyle(
        fontSize: widget.fontSize,
        fontFamily: 'JetBrainsMono, Menlo, Monaco, Courier New, monospace',
      ),
      theme: _theme,
    );
  }
}
