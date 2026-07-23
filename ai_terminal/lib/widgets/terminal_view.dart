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

    // 桌面平台使用 hardwareKeyboardOnly：直接从硬件键盘事件的 character
    // 获取输入，绕过 TextInput.attach / IME 路径。
    //
    // xterm 默认走 CustomTextEdit → TextInput.attach 建立 IME 连接，但：
    // 1. Windows 上 IME 框架会过度介入，拦截普通字符导致无法输入
    // 2. _focusNode.requestFocus() 在 CustomTextEdit listener 添加前执行时，
    //    _onFocusChange 不触发，TextInput 连接永不建立
    //
    // hardwareKeyboardOnly 路径走 CustomKeyboardListener，直接从
    // KeyEvent.character 提取字符，不依赖 IME。
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    return xterm.TerminalView(
      widget.terminal!,
      focusNode: _focusNode,
      autofocus: true,
      hardwareKeyboardOnly: isDesktop,
      // CustomKeyboardListener._onKeyEvent 对所有事件类型（含 KeyUpEvent）
      // 都尝试 onInsert，而 _handleKeyEvent 对 KeyUpEvent 返回 ignored，
      // 导致字符重复。这里拦截 KeyUpEvent 阻止重复插入。
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      },
      textStyle: xterm.TerminalStyle(
        fontSize: widget.fontSize,
        fontFamily: 'JetBrainsMono, Menlo, Monaco, Courier New, monospace',
      ),
      theme: _theme,
    );
  }
}
