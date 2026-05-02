import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../providers/terminal_provider.dart';

class TabBarWidget extends StatelessWidget {
  final List<TerminalTab> tabs;
  final String? activeTabId;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabClosed;
  final VoidCallback? onAddTab;

  const TabBarWidget({
    super.key,
    required this.tabs,
    this.activeTabId,
    required this.onTabSelected,
    required this.onTabClosed,
    this.onAddTab,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: hTabBar,
      decoration: BoxDecoration(
        color: cBg,
        border: Border(
          bottom: BorderSide(color: cBorder.withOpacity(0.6), width: 1),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        // tabs + 末尾的"+"按钮
        itemCount: tabs.length + (onAddTab != null ? 1 : 0),
        itemBuilder: (context, index) {
          // 最后一项是"+"按钮
          if (index == tabs.length) {
            return _AddTabButton(onTap: onAddTab!);
          }
          final tab = tabs[index];
          final isActive = tab.id == activeTabId;
          return _TabItem(
            tab: tab,
            isActive: isActive,
            onSelected: () => onTabSelected(tab.id),
            onClosed: () => onTabClosed(tab.id),
          );
        },
      ),
    );
  }
}

/// "+"新增标签按钮，跟tab在同一行
class _AddTabButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddTabButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '新连接',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(left: 2, right: 2, top: 0, bottom: 0),
          decoration: BoxDecoration(
            color: cSurface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: cBorder.withOpacity(0.3)),
          ),
          child: Icon(Icons.add, size: 16, color: cTextSub),
        ),
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  final TerminalTab tab;
  final bool isActive;
  final VoidCallback onSelected;
  final VoidCallback onClosed;

  const _TabItem({
    required this.tab,
    required this.isActive,
    required this.onSelected,
    required this.onClosed,
  });

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;
    final bgColor = isActive
        ? cCard
        : _isHovered
            ? cSurface
            : Colors.transparent;

    return GestureDetector(
      onTap: widget.onSelected,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: animFast,
          curve: Curves.easeOut,
          constraints: const BoxConstraints(maxWidth: 140, minWidth: 60),
          margin: const EdgeInsets.only(right: 1),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(rMedium),
              topRight: Radius.circular(rMedium),
            ),
            border: isActive
                ? Border(
                    top: BorderSide(color: cPrimary, width: 2),
                    left: BorderSide(color: cBorder.withOpacity(0.3), width: 0.5),
                    right: BorderSide(color: cBorder.withOpacity(0.3), width: 0.5),
                  )
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 连接状态点
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: widget.tab.isConnected ? cSuccess : cDanger,
                  shape: BoxShape.circle,
                  boxShadow: widget.tab.isConnected
                      ? [BoxShadow(color: cSuccess.withOpacity(0.4), blurRadius: 4)]
                      : null,
                ),
              ),
              // 标签标题（仅名称）
              Flexible(
                child: Text(
                  widget.tab.title,
                  style: TextStyle(
                    color: isActive ? cTextMain : cTextSub,
                    fontSize: fSmall,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              // 关闭按钮 - 始终显示
              GestureDetector(
                onTap: widget.onClosed,
                child: Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(rXSmall),
                    color: _isHovered
                        ? cBorder.withOpacity(0.5)
                        : Colors.transparent,
                  ),
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: _isHovered ? cTextSub : cTextMuted,
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
