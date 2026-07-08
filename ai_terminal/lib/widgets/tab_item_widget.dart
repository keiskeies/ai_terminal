import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../providers/terminal_provider.dart' as tp;

/// 独立的 Tab 项 widget，hover 状态自管理，不触发父页面 rebuild
class TabItemWidget extends StatefulWidget {
  final tp.TerminalTab tab;
  final bool isActive;
  final ThemeColors tc;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const TabItemWidget({
    super.key,
    required this.tab,
    required this.isActive,
    required this.tc,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<TabItemWidget> createState() => _TabItemWidgetState();
}

class _TabItemWidgetState extends State<TabItemWidget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final isActive = widget.isActive;
    final tc = widget.tc;

    Color bgColor;
    if (isActive) {
      bgColor = tc.cardElevated;
    } else if (_isHovered) {
      bgColor = tc.surface;
    } else {
      bgColor = Colors.transparent;
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: animFast,
          height: 34,
          constraints: const BoxConstraints(maxWidth: 160, minWidth: 72),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(rSmall),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 标签内容
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: tab.isConnected ? cSuccess : cDanger,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      tab.title,
                      style: TextStyle(
                        color: isActive ? tc.textMain : tc.textSub,
                        fontSize: fSmall,
                        fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  // 关闭按钮：hover / active 时显示
                  AnimatedOpacity(
                    duration: animFast,
                    opacity: (_isHovered || isActive) ? 1.0 : 0.0,
                    child: GestureDetector(
                      onTap: widget.onClose,
                      child: Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsets.only(left: 4),
                        decoration: BoxDecoration(
                          color: _isHovered ? tc.border.withValues(alpha: 0.5) : Colors.transparent,
                          borderRadius: BorderRadius.circular(rXSmall),
                        ),
                        child: Icon(
                          Icons.close,
                          size: 10,
                          color: isActive ? tc.textSub : tc.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // 激活态底部指示线
              if (isActive)
                Positioned(
                  bottom: 0,
                  left: 8,
                  right: 8,
                  child: Container(
                    height: 2,
                    color: cPrimary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
