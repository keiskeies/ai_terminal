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
  final _xtermKey = GlobalKey<xterm.TerminalViewState>();

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
        _xtermKey.currentState?.requestKeyboard();
      }
    });
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.terminal != null && widget.terminal != oldWidget.terminal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // unfocus 后重新 requestFocus，触发 xterm CustomTextEdit 的
          // _onFocusChange listener，确保 TextInput 连接正确建立。
          // 仅 requestFocus 在 listener 已添加但焦点未变化时不触发回调。
          _focusNode.unfocus();
          _focusNode.requestFocus();
          // 主动调用 requestKeyboard() 确保 TextInput 连接建立
          _xtermKey.currentState?.requestKeyboard();
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

    // 使用 xterm 默认的 CustomTextEdit 路径（hardwareKeyboardOnly=false）。
    //
    // hardwareKeyboardOnly=true 走 CustomKeyboardListener，依赖
    // KeyEvent.character 获取字符。但 Windows 上 KeyDownEvent.character
    // 可能为 null（WM_KEYDOWN 不含字符信息，字符在 WM_CHAR 中），
    // 导致普通字母键无法输入。
    //
    // 默认路径通过 TextInput.attach → WM_CHAR 获取字符，
    // 不依赖 KeyEvent.character。通过 requestKeyboard() 确保
    // TextInput 连接正确建立。
    return xterm.TerminalView(
      key: _xtermKey,
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
