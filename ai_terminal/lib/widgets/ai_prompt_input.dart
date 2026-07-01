import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';

/// AI 输入框，支持斜杠命令建议
///
/// 键盘约定（与主流 AI 对话平台一致）：
/// - Enter / NumpadEnter：发送（若斜杠命令浮层打开则选中高亮命令）
/// - Shift + Enter：换行
/// - ↑ / ↓ / Tab / Esc：斜杠浮层导航
class AIPromptInput extends StatefulWidget {
  final bool enabled;
  final bool isRunning;
  final String hintText;
  final String initialText;
  final Function(String) onSend;
  final VoidCallback? onStop;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChanged;
  final Color accentColor;
  /// 斜杠命令回调：返回 true 表示命令已被处理（不再走 onSend）
  final bool Function(String command)? onSlashCommand;

  const AIPromptInput({
    super.key,
    required this.enabled,
    this.isRunning = false,
    required this.hintText,
    this.initialText = '',
    required this.onSend,
    this.onStop,
    this.onChanged,
    this.onFocusChanged,
    required this.accentColor,
    this.onSlashCommand,
  });

  @override
  State<AIPromptInput> createState() => _AIPromptInputState();
}

/// 斜杠命令定义
class SlashCommand {
  final String command;
  final String description;
  const SlashCommand(this.command, this.description);
}

const List<SlashCommand> kSlashCommands = [
  SlashCommand('/new', '新建会话'),
  SlashCommand('/compact', '压缩记忆（总结早期对话）'),
];

class _AIPromptInputState extends State<AIPromptInput> {
  late TextEditingController _controller;
  final _focusNode = FocusNode();
  String _lastInitialText = '';
  bool _isFocused = false;
  OverlayEntry? _slashOverlay;
  List<SlashCommand> _filteredCommands = [];
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _lastInitialText = widget.initialText;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      final focused = _focusNode.hasFocus;
      if (focused != _isFocused) {
        setState(() => _isFocused = focused);
        widget.onFocusChanged?.call(focused);
      }
      if (!focused) {
        _hideSlashOverlay();
      }
    });
  }

  void _onTextChanged() {
    widget.onChanged?.call(_controller.text);
    _detectSlashCommand();
  }

  /// 检测输入框中的斜杠命令前缀，显示建议
  void _detectSlashCommand() {
    final text = _controller.text;
    // 仅当文本以 / 开头且不含空格时显示建议
    if (text.startsWith('/') && !text.contains(' ')) {
      final prefix = text.toLowerCase();
      final filtered = kSlashCommands
          .where((c) => c.command.toLowerCase().startsWith(prefix))
          .toList();
      if (filtered.isNotEmpty) {
        _filteredCommands = filtered;
        _highlightedIndex = _highlightedIndex.clamp(0, filtered.length - 1);
        _showSlashOverlay();
        return;
      }
    }
    _hideSlashOverlay();
  }

  void _showSlashOverlay() {
    if (_slashOverlay == null) {
      _slashOverlay = OverlayEntry(builder: _buildSlashOverlay);
      Overlay.of(context).insert(_slashOverlay!);
    } else {
      _slashOverlay!.markNeedsBuild();
    }
  }

  void _hideSlashOverlay() {
    _slashOverlay?.remove();
    _slashOverlay = null;
  }

  Widget _buildSlashOverlay(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return const SizedBox.shrink();
    final size = renderBox.size;
    final tc = ThemeColors.of(context);
    return Positioned(
      bottom: size.height + 4,
      left: 0,
      width: size.width,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: tc.cardElevated,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < _filteredCommands.length; i++)
                InkWell(
                  onTap: () => _selectSlashCommand(_filteredCommands[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    color: i == _highlightedIndex ? widget.accentColor.withValues(alpha: 0.15) : Colors.transparent,
                    child: Row(
                      children: [
                        Text(
                          _filteredCommands[i].command,
                          style: TextStyle(
                            color: i == _highlightedIndex ? widget.accentColor : tc.textMain,
                            fontSize: fSmall,
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _filteredCommands[i].description,
                            style: TextStyle(color: tc.textSub, fontSize: fMicro),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectSlashCommand(SlashCommand cmd) {
    _controller.text = cmd.command;
    _controller.selection = TextSelection.collapsed(offset: cmd.command.length);
    _hideSlashOverlay();
  }

  /// 键盘事件：Enter 发送、Shift+Enter 换行、斜杠浮层导航
  /// 返回 KeyEventResult.handled 表示消费事件（阻止 TextField 默认行为，如换行）；
  /// 返回 KeyEventResult.ignored 表示放行，让 TextField 走默认处理（如 Shift+Enter 换行）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // 斜杠命令浮层导航（仅浮层打开时）
    final slashActive = _slashOverlay != null && _filteredCommands.isNotEmpty;
    if (slashActive) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _highlightedIndex = (_highlightedIndex + 1) % _filteredCommands.length;
        });
        _slashOverlay!.markNeedsBuild();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _highlightedIndex = (_highlightedIndex - 1 + _filteredCommands.length) % _filteredCommands.length;
        });
        _slashOverlay!.markNeedsBuild();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        _selectSlashCommand(_filteredCommands[_highlightedIndex]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _hideSlashOverlay();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
        // 浮层打开时 Enter 选中高亮命令（不发送）
        final cmd = _filteredCommands[_highlightedIndex];
        _controller.clear();
        _hideSlashOverlay();
        _executeSlashCommand(cmd);
        return KeyEventResult.handled;
      }
    }

    // Enter / NumpadEnter：发送（Shift+Enter 走默认换行）
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (!shift) {
        // 无 Shift：发送。无论是否发送成功都消费事件，
        // 避免空输入按 Enter 也产生换行。
        _send();
        return KeyEventResult.handled;
      }
      // 有 Shift：换行，放行让 TextField 走默认行为
    }

    return KeyEventResult.ignored;
  }

  void _executeSlashCommand(SlashCommand cmd) {
    final handled = widget.onSlashCommand?.call(cmd.command) ?? false;
    if (handled) return;
    // 默认行为：作为普通文本发送
    widget.onSend(cmd.command);
  }

  @override
  void didUpdateWidget(covariant AIPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialText != _lastInitialText && widget.initialText != _controller.text) {
      _controller.text = widget.initialText;
      _lastInitialText = widget.initialText;
    }
  }

  @override
  void dispose() {
    _hideSlashOverlay();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    // 运行中不发送（按终止按钮才能中断）
    if (widget.isRunning) return;
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    // 若是斜杠命令，优先走 onSlashCommand
    if (text.startsWith('/') && widget.onSlashCommand != null) {
      final handled = widget.onSlashCommand!(text);
      if (handled) {
        _controller.clear();
        return;
      }
    }
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final borderColor = _isFocused
        ? widget.accentColor.withValues(alpha: 0.7)
        : tc.border.withValues(alpha: 0.5);
    final disabledBorderColor = tc.border.withValues(alpha: 0.3);

    // 运行中：发送按钮变为终止按钮（外圆内方）
    final running = widget.isRunning;

    // 使用 Focus(onKeyEvent:) 而非 KeyboardListener：
    // KeyboardListener 的 onKeyEvent 返回 void，无法消费事件，Enter 会继续传播到
    // TextField 触发换行。Focus 的 onKeyEvent 返回 KeyEventResult，
    // 返回 handled 可消费事件，阻止 TextField 默认行为。
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: TextField(
        controller: _controller,
        enabled: widget.enabled,
        minLines: 1,
        maxLines: 5,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        style: TextStyle(color: tc.textMain, fontSize: fBody, height: 1.5),
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: TextStyle(color: tc.textMuted, fontSize: fBody),
          filled: true,
          fillColor: tc.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: widget.accentColor, width: 1.5),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: disabledBorderColor),
          ),
          contentPadding: const EdgeInsets.fromLTRB(14, 12, 48, 12),
          isDense: false,
          suffixIcon: Padding(
            padding: const EdgeInsets.all(4),
            child: GestureDetector(
              onTap: running
                  ? widget.onStop
                  : (widget.enabled ? _send : null),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  // 运行中：外圆红色背景；空闲：accent 色
                  color: running
                      ? cDanger.withValues(alpha: 0.9)
                      : (widget.enabled ? widget.accentColor : cTextMuted),
                  borderRadius: BorderRadius.circular(rSmall),
                ),
                child: running
                    ? // 外圆内方：外层圆形容器 + 内层白色方块
                      Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.arrow_upward_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
              ),
            ),
          ),
        ),
        onSubmitted: (_) {},
      ),
    );
  }
}
