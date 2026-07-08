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
  /// 是否处于多机编排模式
  final bool isOrchestratorMode;
  /// 切换编排模式回调
  final VoidCallback? onToggleOrchestrator;

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
    this.isOrchestratorMode = false,
    this.onToggleOrchestrator,
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
      bottom: size.height + 6,
      left: 0,
      width: size.width,
      child: Container(
        decoration: BoxDecoration(
          color: cCardElevated,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: cBorder, width: 1),
          boxShadow: shadowLg,
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < _filteredCommands.length; i++)
              _SlashCommandItem(
                command: _filteredCommands[i],
                isHighlighted: i == _highlightedIndex,
                accentColor: widget.accentColor,
                tc: tc,
                onTap: () => _selectSlashCommand(_filteredCommands[i]),
              ),
          ],
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
    final running = widget.isRunning;
    final accent = widget.accentColor;

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
          fillColor: cCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: const BorderSide(color: cBorder, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: const BorderSide(color: cBorder, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: accent, width: 1),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: cBorder.withValues(alpha: 0.5)),
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 10, 46, 10),
          isDense: true,
          suffixIcon: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onToggleOrchestrator != null)
                  _buildOrchestratorButton(),
                _buildSendButton(running),
              ],
            ),
          ),
        ),
        onSubmitted: (_) {},
      ),
    );
  }

  Widget _buildOrchestratorButton() {
    final isOrch = widget.isOrchestratorMode;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onToggleOrchestrator,
        child: AnimatedContainer(
          duration: animFast,
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: isOrch ? cWarning : cSurface,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: Tooltip(
            message: isOrch ? '退出编排模式' : '进入多机编排模式',
            child: Icon(
              Icons.hub_outlined,
              color: isOrch ? Colors.white : cTextMuted,
              size: 15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSendButton(bool running) {
    final canSend = widget.enabled && !running;
    final bgColor = running
        ? cDanger
        : canSend
            ? cPrimary
            : cTextMuted.withValues(alpha: 0.5);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: running
            ? widget.onStop
            : (canSend ? _send : null),
        child: AnimatedContainer(
          duration: animFast,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: running
              ? Center(
                  child: Container(
                    width: 9,
                    height: 9,
                    color: Colors.white,
                  ),
                )
              : const Icon(
                  Icons.arrow_upward_rounded,
                  color: Colors.white,
                  size: 15,
                ),
        ),
      ),
    );
  }
}

class _SlashCommandItem extends StatefulWidget {
  final SlashCommand command;
  final bool isHighlighted;
  final Color accentColor;
  final ThemeColors tc;
  final VoidCallback onTap;

  const _SlashCommandItem({
    required this.command,
    required this.isHighlighted,
    required this.accentColor,
    required this.tc,
    required this.onTap,
  });

  @override
  State<_SlashCommandItem> createState() => _SlashCommandItemState();
}

class _SlashCommandItemState extends State<_SlashCommandItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isHighlighted || _isHovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: animFast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: active
              ? widget.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          child: Row(
            children: [
              Text(
                widget.command.command,
                style: TextStyle(
                  color: active ? widget.accentColor : widget.tc.textMain,
                  fontSize: fSmall,
                  fontFamily: 'JetBrainsMono',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.command.description,
                  style: TextStyle(
                    color: widget.tc.textSub,
                    fontSize: fMicro,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
