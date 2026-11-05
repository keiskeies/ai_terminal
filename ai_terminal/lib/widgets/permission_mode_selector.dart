import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_permission_mode.dart';
import '../utils/agent_ui_text.dart';

/// 输入框旁的执行权限胶囊：只读 / 询问 / 自动 / 全自动。
///
/// 向上弹出菜单，当前档位带勾选。颜色只用于图标、文字与细边框，
/// 不整块铺色（石墨青视觉规范）。
class PermissionModeSelector extends StatefulWidget {
  final AgentPermissionMode mode;
  final ValueChanged<AgentPermissionMode> onChanged;
  final ThemeColors tc;

  /// 窄屏只显示图标，避免挤压输入框底部的模型胶囊
  final bool compact;

  const PermissionModeSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    required this.tc,
    this.compact = false,
  });

  @override
  State<PermissionModeSelector> createState() => _PermissionModeSelectorState();
}

class _PermissionModeSelectorState extends State<PermissionModeSelector> {
  final _controller = MenuController();

  Color _color(AgentPermissionMode mode) {
    switch (mode) {
      case AgentPermissionMode.readOnly:
        return widget.tc.textSub;
      case AgentPermissionMode.ask:
        return widget.tc.brand;
      case AgentPermissionMode.auto:
        return widget.tc.warn;
      case AgentPermissionMode.fullAuto:
        return widget.tc.error;
    }
  }

  IconData _icon(AgentPermissionMode mode) {
    switch (mode) {
      case AgentPermissionMode.readOnly:
        return Icons.lock_outline;
      case AgentPermissionMode.ask:
        return Icons.shield_outlined;
      case AgentPermissionMode.auto:
        return Icons.bolt_outlined;
      case AgentPermissionMode.fullAuto:
        return Icons.warning_amber_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final tc = widget.tc;
    final color = _color(widget.mode);

    return MenuAnchor(
      controller: _controller,
      alignmentOffset: const Offset(0, -8),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tc.cardElevated),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(10),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMedium),
            side: BorderSide(color: tc.border),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: 286,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Text(
                  ui.permissionModeTitle,
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final mode in AgentPermissionMode.values)
                _PermissionModeItem(
                  mode: mode,
                  selected: mode == widget.mode,
                  color: _color(mode),
                  icon: _icon(mode),
                  tc: tc,
                  ui: ui,
                  onTap: () {
                    _controller.close();
                    if (mode != widget.mode) widget.onChanged(mode);
                  },
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: ui.zh
              ? '${ui.permissionModeTitle}：${ui.permissionModeDescription(widget.mode)}'
              : '${ui.permissionModeTitle}: ${ui.permissionModeDescription(widget.mode)}',
          child: InkWell(
            borderRadius: BorderRadius.circular(rFull),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Container(
              height: 24,
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? 6 : 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(rFull),
                border: Border.all(color: color.withValues(alpha: 0.45)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon(widget.mode), size: 12, color: color),
                  if (!widget.compact) ...[
                    const SizedBox(width: 4),
                    Text(
                      ui.permissionModeLabel(widget.mode),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: fMicro,
                        color: color,
                        height: 1.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(Icons.unfold_more, size: 11, color: color),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PermissionModeItem extends StatefulWidget {
  final AgentPermissionMode mode;
  final bool selected;
  final Color color;
  final IconData icon;
  final ThemeColors tc;
  final AgentUiText ui;
  final VoidCallback onTap;

  const _PermissionModeItem({
    required this.mode,
    required this.selected,
    required this.color,
    required this.icon,
    required this.tc,
    required this.ui,
    required this.onTap,
  });

  @override
  State<_PermissionModeItem> createState() => _PermissionModeItemState();
}

class _PermissionModeItemState extends State<_PermissionModeItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: _hovered
              ? widget.color.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(rXSmall),
                ),
                child: Icon(widget.icon, size: 14, color: widget.color),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.ui.permissionModeLabel(widget.mode),
                      style: TextStyle(
                        color:
                            widget.selected ? widget.color : tc.textMain,
                        fontSize: fSmall,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.ui.permissionModeDescription(widget.mode),
                      style: TextStyle(
                        color: tc.textSub,
                        fontSize: fMicro,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (widget.selected)
                Icon(Icons.check, size: 15, color: widget.color)
              else
                const SizedBox(width: 15),
            ],
          ),
        ),
      ),
    );
  }
}
