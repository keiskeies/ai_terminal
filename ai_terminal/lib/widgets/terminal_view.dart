import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' as xterm;
import '../core/theme_colors.dart';

class TerminalView extends StatefulWidget {
  final xterm.Terminal? terminal;
  final ValueChanged<String>? onSend;
  final double fontSize;
  final String colorScheme;

  const TerminalView({
    super.key,
    this.terminal,
    this.onSend,
    this.fontSize = 13,
    this.colorScheme = 'Monokai',
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final FocusNode _focusNode = FocusNode();

  // 配色方案
  static const _colorSchemes = {
    'Monokai': xterm.TerminalTheme(
      cursor: Color(0xFFF8F8F0),
      selection: Color(0xFF49483E),
      foreground: Color(0xFFF8F8F2),
      background: Color(0xFF0C0C0C),
      black: Color(0xFF272822),
      red: Color(0xFFF92672),
      green: Color(0xFFA6E22E),
      yellow: Color(0xFFF4BF75),
      blue: Color(0xFF66D9EF),
      magenta: Color(0xFFAE81FF),
      cyan: Color(0xFFA1EFE4),
      white: Color(0xFFF8F8F2),
      brightBlack: Color(0xFF75715E),
      brightRed: Color(0xFFF92672),
      brightGreen: Color(0xFFA6E22E),
      brightYellow: Color(0xFFF4BF75),
      brightBlue: Color(0xFF66D9EF),
      brightMagenta: Color(0xFFAE81FF),
      brightCyan: Color(0xFFA1EFE4),
      brightWhite: Color(0xFFF8F8F2),
      searchHitBackground: Color(0xFF49483E),
      searchHitBackgroundCurrent: Color(0xFF665957),
      searchHitForeground: Color(0xFFF8F8F2),
    ),
    'Dracula': xterm.TerminalTheme(
      cursor: Color(0xFFF8F8F2),
      selection: Color(0xFF44475A),
      foreground: Color(0xFFF8F8F2),
      background: Color(0xFF282A36),
      black: Color(0xFF21222C),
      red: Color(0xFFFF5555),
      green: Color(0xFF50FA7B),
      yellow: Color(0xFFF1FA8C),
      blue: Color(0xFFBD93F9),
      magenta: Color(0xFFFF79C6),
      cyan: Color(0xFF8BE9FD),
      white: Color(0xFFF8F8F2),
      brightBlack: Color(0xFF6272A4),
      brightRed: Color(0xFFFF5555),
      brightGreen: Color(0xFF50FA7B),
      brightYellow: Color(0xFFF1FA8C),
      brightBlue: Color(0xFFBD93F9),
      brightMagenta: Color(0xFFFF79C6),
      brightCyan: Color(0xFF8BE9FD),
      brightWhite: Color(0xFFF8F8F2),
      searchHitBackground: Color(0xFF44475A),
      searchHitBackgroundCurrent: Color(0xFF6272A4),
      searchHitForeground: Color(0xFFF8F8F2),
    ),
    'Solarized': xterm.TerminalTheme(
      cursor: Color(0xFF93A1A1),
      selection: Color(0xFF073642),
      foreground: Color(0xFF839496),
      background: Color(0xFF002B36),
      black: Color(0xFF073642),
      red: Color(0xFFDC322F),
      green: Color(0xFF859900),
      yellow: Color(0xFFB58900),
      blue: Color(0xFF268BD2),
      magenta: Color(0xFFD33682),
      cyan: Color(0xFF2AA198),
      white: Color(0xFFEEE8D5),
      brightBlack: Color(0xFF002B36),
      brightRed: Color(0xFFCB4B16),
      brightGreen: Color(0xFF586E75),
      brightYellow: Color(0xFF657B83),
      brightBlue: Color(0xFF839496),
      brightMagenta: Color(0xFF6C71C4),
      brightCyan: Color(0xFF93A1A1),
      brightWhite: Color(0xFFFDF6E3),
      searchHitBackground: Color(0xFF073642),
      searchHitBackgroundCurrent: Color(0xFF0A4050),
      searchHitForeground: Color(0xFF839496),
    ),
    'Nord': xterm.TerminalTheme(
      cursor: Color(0xFFD8DEE9),
      selection: Color(0xFF434C5E),
      foreground: Color(0xFFD8DEE9),
      background: Color(0xFF2E3440),
      black: Color(0xFF3B4252),
      red: Color(0xFFBF616A),
      green: Color(0xFFA3BE8C),
      yellow: Color(0xFFEBCB8B),
      blue: Color(0xFF81A1C1),
      magenta: Color(0xFFB48EAD),
      cyan: Color(0xFF88C0D0),
      white: Color(0xFFE5E9F0),
      brightBlack: Color(0xFF4C566A),
      brightRed: Color(0xFFBF616A),
      brightGreen: Color(0xFFA3BE8C),
      brightYellow: Color(0xFFEBCB8B),
      brightBlue: Color(0xFF81A1C1),
      brightMagenta: Color(0xFFB48EAD),
      brightCyan: Color(0xFF8FBCBB),
      brightWhite: Color(0xFFECEFF4),
      searchHitBackground: Color(0xFF434C5E),
      searchHitBackgroundCurrent: Color(0xFF4C566A),
      searchHitForeground: Color(0xFFD8DEE9),
    ),
  };

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

    final theme = _colorSchemes[widget.colorScheme] ?? _colorSchemes['Monokai']!;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      child: xterm.TerminalView(
        widget.terminal!,
        textStyle: xterm.TerminalStyle(
          fontSize: widget.fontSize,
          fontFamily: 'JetBrainsMono, Menlo, Monaco, Courier New, monospace',
        ),
        theme: theme,
      ),
    );
  }
}
