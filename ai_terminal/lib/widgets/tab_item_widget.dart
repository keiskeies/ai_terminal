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
      // 设计稿 .tab[aria-pressed=true]：卡片底（#131616），不是更亮的面板色。
      bgColor = tc.card;
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
          height: 32,
          constraints: const BoxConstraints(maxWidth: 160, minWidth: 72),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.only(left: 10, right: 4),
          // 设计稿 tab：选中态用「卡片底 + 发丝描边」表达，不再叠品牌色下划线——
          // 顶栏里下划线会和标签文字底边打架，描边与顶栏其他控件同一套语言。
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: isActive ? tc.border : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      // 连接中给琥珀色，别让用户把"还在建连"读成"已掉线"
                      color: switch (tab.status) {
                        tp.TabStatus.connected => tc.ok,
                        tp.TabStatus.connecting || tp.TabStatus.reconnecting => tc.warn,
                        _ => tc.error,
                      },
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
        ),
      ),
    );
  }
}
