import 'package:flutter/material.dart';
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

    // 将 _focusNode 直接传给 xterm.TerminalView，使其内部的 onKeyEvent
    // 和 IME 连接都注册在同一个 FocusNode 上。
    // 若用外层 Focus 包裹且不传 focusNode，xterm 会自建一个 child FocusNode，
    // 键盘事件从 primary focus 向上传播，不会向下到达 child，导致输入全部丢失
    // （Windows 上首次未点击终端直接敲键盘即无反应；macOS/Linux 因点击触发
    // requestKeyboard 而掩盖了此问题）。
    return xterm.TerminalView(
      widget.terminal!,
      focusNode: _focusNode,
      autofocus: true,
      textStyle: xterm.TerminalStyle(
        fontSize: widget.fontSize,
        fontFamily: 'JetBrainsMono, Menlo, Monaco, Courier New, monospace',
      ),
      theme: _theme,
    );
  }
}
