import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';

/// 标签颜色选择：v3 色板 + 选中态外圈环（色环 + 深色对勾），首位提供「无颜色」。
class ColorPickerRow extends StatelessWidget {
  final String? selectedColor;
  final ValueChanged<String?> onColorSelected;

  const ColorPickerRow({
    super.key,
    this.selectedColor,
    required this.onColorSelected,
  });

  Color? get _selectedColor {
    if (selectedColor == null) return null;
    return Color(int.parse(selectedColor!.replaceFirst('#', '0xFF')));
  }

  String _colorToHex(Color color) {
    return '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          selected: selectedColor == null,
          onTap: () => onColorSelected(null),
          ringColor: tc.textSub,
          tooltip: UiText.t('无颜色', 'No color'),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: tc.surface,
              shape: BoxShape.circle,
              border: Border.all(color: tc.border),
            ),
            child: Icon(Icons.block, size: 12, color: tc.textMuted),
          ),
        ),
        for (final color in tagColors)
          _Swatch(
            selected: _selectedColor == color,
            onTap: () => onColorSelected(_colorToHex(color)),
            ringColor: color,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: _selectedColor == color
                  ? const Icon(Icons.check_rounded, size: 13, color: cBg)
                  : null,
            ),
          ),
      ],
    );
  }
}

class _Swatch extends StatefulWidget {
  const _Swatch({
    required this.selected,
    required this.onTap,
    required this.ringColor,
    required this.child,
    this.tooltip,
  });

  final bool selected;
  final VoidCallback onTap;
  final Color ringColor;
  final Widget child;
  final String? tooltip;

  @override
  State<_Swatch> createState() => _SwatchState();
}

class _SwatchState extends State<_Swatch> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final ring = widget.selected
        ? widget.ringColor
        : (_hovering ? tc.borderHover : Colors.transparent);
    Widget swatch = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: animFast,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 2),
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
    if (widget.tooltip != null) {
      swatch = Tooltip(message: widget.tooltip!, child: swatch);
    }
    return swatch;
  }
}