import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show kSecondaryButton;
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
  // TerminalController 用于管理终端选区，右键复制时读取选中文本
  final xterm.TerminalController _controller = xterm.TerminalController();
  final GlobalKey _terminalContainerKey = GlobalKey();

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
    _controller.dispose();
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

  /// 右键弹出自定义上下文菜单（复制 / 粘贴）
  void _showContextMenu(Offset globalPosition) {
    final terminal = widget.terminal;
    if (terminal == null) return;

    final tc = ThemeColors.of(context);
    final selection = _controller.selection;
    final hasSelection = selection != null &&
        terminal.buffer.getText(selection).trim().isNotEmpty;

    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _TerminalContextMenu(
        position: globalPosition,
        hasSelection: hasSelection,
        themeColors: tc,
        onCopy: hasSelection
            ? () {
                final text = terminal.buffer.getText(selection);
                Clipboard.setData(ClipboardData(text: text));
                _controller.clearSelection();
                entry.remove();
              }
            : null,
        onPaste: () {
          Clipboard.getData('text/plain').then((data) {
            if (data?.text != null && data!.text!.isNotEmpty) {
              terminal.paste(data.text!);
            }
          });
          entry.remove();
        },
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
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

    // 用 Listener 在外层直接监听原始指针事件，不依赖 xterm 内部的
    // 手势处理器。Listener 不参与手势竞技，不会干扰 xterm 的左键选区
    // 和键盘焦点，但能在手势竞技之前接收到所有指针事件。
    //
    // 事件分发顺序：Listener → xterm.TerminalView 内部手势 → xterm.TerminalView
    // 所以右侧也能收到。
    return Listener(
      onPointerDown: (event) {
        // onPointerDown 会收到所有鼠标按钮按下+触摸。
        // kSecondaryButton = 2，对应右键（Mac 双指点击 / Windows 右键）
        if (event.buttons == kSecondaryButton) {
          // event.position 是相对 Listener 的局部坐标，转换为全局坐标
          final renderBox =
              _terminalContainerKey.currentContext?.findRenderObject();
          if (renderBox is RenderBox) {
            _showContextMenu(renderBox.localToGlobal(event.position));
          }
        }
      },
      child: Container(
        key: _terminalContainerKey,
        child: xterm.TerminalView(
        widget.terminal!,
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        hardwareKeyboardOnly: isDesktop,
        onKeyEvent: _handleKeyEvent,
        textStyle: xterm.TerminalStyle(
          fontSize: widget.fontSize,
          fontFamily: 'JetBrainsMono, Menlo, Monaco, Courier New, monospace',
        ),
        theme: _theme,
      ),
      ),
    );
  }
}

/// 终端右键上下文菜单
/// 跟随鼠标光标位置弹出，支持明暗主题，点击外部或 ESC 关闭
class _TerminalContextMenu extends StatefulWidget {
  final Offset position;
  final bool hasSelection;
  final ThemeColors themeColors;
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;
  final VoidCallback onDismiss;

  const _TerminalContextMenu({
    required this.position,
    required this.hasSelection,
    required this.themeColors,
    required this.onCopy,
    required this.onPaste,
    required this.onDismiss,
  });

  @override
  State<_TerminalContextMenu> createState() => _TerminalContextMenuState();
}

class _TerminalContextMenuState extends State<_TerminalContextMenu> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.themeColors;
    final size = MediaQuery.of(context).size;

    // 菜单尺寸预估
    const menuWidth = 168.0;
    const menuHeight = 88.0;
    const menuItemHeight = 36.0;

    // 计算菜单位置，避免超出屏幕边界
    double left = widget.position.dx;
    double top = widget.position.dy;
    if (left + menuWidth > size.width - 8) {
      left = size.width - menuWidth - 8;
    }
    if (top + menuHeight > size.height - 8) {
      top = size.height - menuHeight - 8;
    }
    if (left < 8) left = 8;
    if (top < 8) top = 8;

    return Stack(
      children: [
        // 透明遮罩，点击关闭菜单
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            onSecondaryTapDown: (_) => widget.onDismiss(),
            child: const SizedBox.expand(),
          ),
        ),
        // 菜单主体
        Positioned(
          left: left,
          top: top,
          child: Focus(
            focusNode: _focusNode,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                widget.onDismiss();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: menuWidth,
                decoration: BoxDecoration(
                  color: tc.cardElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tc.border, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: tc.isLight
                          ? Colors.black.withValues(alpha: 0.12)
                          : Colors.black.withValues(alpha: 0.5),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMenuItem(
                      icon: Icons.copy_rounded,
                      label: '复制',
                      shortcut: '⌘C',
                      enabled: widget.onCopy != null,
                      onTap: widget.onCopy,
                      tc: tc,
                      isFirst: true,
                      menuItemHeight: menuItemHeight,
                    ),
                    Container(height: 1, color: tc.border),
                    _buildMenuItem(
                      icon: Icons.paste_rounded,
                      label: '粘贴',
                      shortcut: '⌘V',
                      enabled: true,
                      onTap: widget.onPaste,
                      tc: tc,
                      isLast: true,
                      menuItemHeight: menuItemHeight,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required String shortcut,
    required bool enabled,
    required VoidCallback? onTap,
    required ThemeColors tc,
    required double menuItemHeight,
    bool isFirst = false,
    bool isLast = false,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(isFirst ? 8 : 0),
        bottom: Radius.circular(isLast ? 8 : 0),
      ),
      child: Container(
        height: menuItemHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: enabled ? tc.textMain : tc.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: enabled ? tc.textMain : tc.textMuted,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            Text(
              shortcut,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? tc.textSub : tc.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
