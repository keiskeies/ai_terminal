import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 终端右键菜单里需要页面能力（Agent / 片段 / SFTP / 审计）的动作。
/// 终端的纯本地动作（复制、粘贴、清屏、字号、保存）由 TerminalView 自己完成。
enum TerminalMenuIntent {
  sendToAgent,
  askError,
  saveSnippet,
  openSftp,
  openAudit,
  viewChanges,
}

class TerminalMenuItem {
  const TerminalMenuItem({
    required this.label,
    this.icon,
    this.shortcut,
    this.enabled = true,
    this.danger = false,
    this.separatorBefore = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final String? shortcut;
  final bool enabled;

  /// 危险动作（执行命令、清空缓冲）用警示色，和普通项区分开
  final bool danger;
  final bool separatorBefore;
  final VoidCallback? onTap;
}

/// 终端右键菜单：分组、键盘提示、悬停高亮，超长时内部滚动。
class TerminalContextMenu extends StatefulWidget {
  const TerminalContextMenu({
    super.key,
    required this.position,
    required this.items,
    required this.onDismiss,
    required this.tc,
  });

  final Offset position;
  final List<TerminalMenuItem> items;
  final VoidCallback onDismiss;
  final ThemeColors tc;

  @override
  State<TerminalContextMenu> createState() => _TerminalContextMenuState();
}

class _TerminalContextMenuState extends State<TerminalContextMenu> {
  final FocusNode _focusNode = FocusNode();
  String? _hovered;

  static const double _width = 224;
  static const double _itemHeight = 32;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double get _estimatedHeight {
    var height = 8.0;
    for (final item in widget.items) {
      if (item.separatorBefore) height += 9;
      height += _itemHeight;
    }
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final screen = MediaQuery.of(context).size;
    final maxHeight = screen.height * 0.7;
    final menuHeight = _estimatedHeight.clamp(0.0, maxHeight);

    double left = widget.position.dx;
    double top = widget.position.dy;
    if (left + _width > screen.width - 8) left = screen.width - _width - 8;
    if (top + menuHeight > screen.height - 8) {
      top = screen.height - menuHeight - 8;
    }
    if (left < 8) left = 8;
    if (top < 8) top = 8;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in widget.items) ...[
          if (item.separatorBefore)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Container(height: 1, color: tc.border),
            ),
          _buildItem(item, tc),
        ],
      ],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            onSecondaryTapDown: (_) => widget.onDismiss(),
            child: const SizedBox.expand(),
          ),
        ),
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
                width: _width,
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: tc.cardElevated,
                  borderRadius: BorderRadius.circular(rSmall),
                  border: Border.all(color: tc.border, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: tc.isLight ? 0.12 : 0.5),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(TerminalMenuItem item, ThemeColors tc) {
    final enabled = item.enabled && item.onTap != null;
    final color = !enabled
        ? tc.textMuted
        : item.danger
            ? tc.error
            : tc.textMain;
    final hovered = _hovered == item.label;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = item.label),
      onExit: (_) => setState(() => _hovered = null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                widget.onDismiss();
                item.onTap!();
              }
            : null,
        child: Container(
          height: _itemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: hovered && enabled
              ? tc.brand.withValues(alpha: 0.10)
              : Colors.transparent,
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 14, color: color),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fSmall, color: color),
                ),
              ),
              if (item.shortcut != null) ...[
                const SizedBox(width: 8),
                Text(
                  item.shortcut!,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: tc.textMuted,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
