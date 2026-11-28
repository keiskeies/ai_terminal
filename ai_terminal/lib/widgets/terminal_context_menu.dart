import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 终端右键菜单里需要页面能力（Agent / 片段 / SFTP / 审计）的动作。
/// 终端的纯本地动作（复制、粘贴、清屏、字号、保存）由 TerminalView 自己完成。
enum TerminalMenuIntent {
  sendToAgent,
  askError,

  /// 整块 OSC 133 命令（命令 + 输出）发给 Agent
  askBlock,
  saveSnippet,
  openSftp,
  openAudit,
  viewChanges,
  showHistory,
}

class TerminalMenuItem {
  const TerminalMenuItem({
    required this.label,
    this.icon,
    this.shortcut,
    this.enabled = true,
    this.danger = false,
    this.separatorBefore = false,
    this.touchHidden = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final String? shortcut;
  final bool enabled;

  /// 危险动作（执行命令、清空缓冲）用警示色，和普通项区分开
  final bool danger;
  final bool separatorBefore;

  /// 只在鼠标/键盘场景出现的动作：分屏没法用手指拖、字号有捏合和外观浮层、
  /// 清空回滚缓冲这种破坏性项不该出现在拇指会扫到的位置。
  final bool touchHidden;
  final VoidCallback? onTap;
}

/// 终端右键菜单：分组、键盘提示、悬停高亮，超长时内部滚动。
/// [compact] 用于触摸端（安卓/iOS）：手指点不准 32px 的行，也读不到没有
/// 鼠标悬停可依赖的快捷键列，所以行加高到 44px、去掉 shortcut。
class TerminalContextMenu extends StatefulWidget {
  const TerminalContextMenu({
    super.key,
    required this.position,
    required this.items,
    required this.onDismiss,
    required this.tc,
    this.compact = false,
  });

  final Offset position;
  final List<TerminalMenuItem> items;
  final VoidCallback onDismiss;
  final ThemeColors tc;
  final bool compact;

  @override
  State<TerminalContextMenu> createState() => _TerminalContextMenuState();
}

class _TerminalContextMenuState extends State<TerminalContextMenu> {
  final FocusNode _focusNode = FocusNode();
  String? _hovered;

  static const double _width = 224;
  static const double _itemHeight = 32;
  static const double _itemHeightTouch = 44;

  double get _rowHeight => widget.compact ? _itemHeightTouch : _itemHeight;

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
      height += _rowHeight;
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
    final compact = widget.compact;
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
          height: _rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: hovered && enabled
              ? tc.brand.withValues(alpha: 0.10)
              : Colors.transparent,
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: compact ? 18 : 14, color: color),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: compact ? fBody : fSmall, color: color),
                ),
              ),
              if (item.shortcut != null && !compact) ...[
                const SizedBox(width: 8),
                // 长 URL/路径不能把标签挤没，最多占 120px 后省略
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    item.shortcut!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fMicro,
                      color: tc.textMuted,
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: kMonoFontFallback,
                    ),
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
