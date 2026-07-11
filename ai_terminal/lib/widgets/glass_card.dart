import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 主按钮：填充背景 + 文字白，用于主要操作
class PrimaryButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final double fontSize;
  final bool isLoading;
  final bool isDisabled;

  const PrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.height = 32,
    this.fontSize = fSmall,
    this.isLoading = false,
    this.isDisabled = false,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  Color get _bgColor {
    if (widget.isDisabled || widget.isLoading) return cPrimary.withValues(alpha: 0.5);
    if (_isPressed) return cPrimaryActive;
    if (_isHovered) return cPrimaryHover;
    return cPrimary;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.isDisabled || widget.isLoading || widget.onPressed == null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      cursor: disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _isPressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: disabled ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: animFast,
          height: widget.height,
          padding: EdgeInsets.symmetric(horizontal: widget.icon != null ? 12 : 16),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(rButton),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.isLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withValues(alpha: 0.8)),
                  ),
                )
              else ...[
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.text,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w500,
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

/// 次按钮：边框 + 透明背景，用于次要操作
class SecondaryButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final double fontSize;
  final bool isLoading;
  final bool isDisabled;

  const SecondaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.height = 32,
    this.fontSize = fSmall,
    this.isLoading = false,
    this.isDisabled = false,
  });

  @override
  State<SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<SecondaryButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  Color get _textColor {
    final tc = ThemeColors.of(context);
    if (widget.isDisabled || widget.isLoading) return tc.textMuted;
    return tc.textMain;
  }

  Color get _borderColor {
    final tc = ThemeColors.of(context);
    if (widget.isDisabled || widget.isLoading) return tc.border;
    if (_isHovered) return tc.borderHover;
    return tc.border;
  }

  Color get _bgColor {
    final tc = ThemeColors.of(context);
    if (_isPressed) return tc.surface;
    if (_isHovered) return tc.cardElevated;
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.isDisabled || widget.isLoading || widget.onPressed == null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      cursor: disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _isPressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: disabled ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: animFast,
          height: widget.height,
          padding: EdgeInsets.symmetric(horizontal: widget.icon != null ? 12 : 16),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(rButton),
            border: Border.all(color: _borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.isLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(ThemeColors.of(context).textSub),
                  ),
                )
              else ...[
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 14, color: _textColor),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.text,
                  style: TextStyle(
                    color: _textColor,
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w500,
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

/// 文字按钮：无边框，用于最次操作
class TextButtonX extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double fontSize;
  final Color? color;
  final bool isDisabled;

  const TextButtonX({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.fontSize = fSmall,
    this.color,
    this.isDisabled = false,
  });

  @override
  State<TextButtonX> createState() => _TextButtonXState();
}

class _TextButtonXState extends State<TextButtonX> {
  bool _isHovered = false;

  Color get _textColor {
    final tc = ThemeColors.of(context);
    if (widget.isDisabled) return tc.textMuted;
    return widget.color ?? tc.textSub;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.isDisabled || widget.onPressed == null;
    final tc = ThemeColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: disabled ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: animFast,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _isHovered && !disabled ? tc.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: _textColor),
                const SizedBox(width: 4),
              ],
              Text(
                widget.text,
                style: TextStyle(
                  color: _textColor,
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 简约卡片容器：深色底 + 细边框 + 微妙阴影
class CardX extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color? color;
  final Color? borderColor;
  final List<BoxShadow>? shadows;

  const CardX({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.color,
    this.borderColor,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.all(pStandard),
      decoration: BoxDecoration(
        color: color ?? tc.card,
        borderRadius: borderRadius ?? BorderRadius.circular(rCard),
        border: Border.all(color: borderColor ?? tc.border, width: 1),
        boxShadow: shadows ?? shadowSm,
      ),
      child: child,
    );
  }
}

/// 浮层容器：用于 tooltip / 弹出层，带阴影
class Popover extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? maxHeight;
  final EdgeInsetsGeometry? padding;

  const Popover({
    super.key,
    required this.child,
    this.width,
    this.maxHeight,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      width: width,
      constraints: maxHeight != null ? BoxConstraints(maxHeight: maxHeight!) : null,
      decoration: BoxDecoration(
        color: tc.cardElevated,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border, width: 1),
        boxShadow: shadowLg,
      ),
      padding: padding ?? const EdgeInsets.all(6),
      child: child,
    );
  }
}

/// 图标按钮：圆形/方形图标按钮
class IconButtonX extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final String? tooltip;
  final bool isDisabled;

  const IconButtonX({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 28,
    this.iconSize = 16,
    this.color,
    this.tooltip,
    this.isDisabled = false,
  });

  @override
  State<IconButtonX> createState() => _IconButtonXState();
}

class _IconButtonXState extends State<IconButtonX> {
  bool _isHovered = false;

  Color get _iconColor {
    final tc = ThemeColors.of(context);
    if (widget.isDisabled) return tc.textMuted;
    return widget.color ?? tc.textSub;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.isDisabled || widget.onPressed == null;
    final tc = ThemeColors.of(context);
    final btn = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: disabled ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: animFast,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: _isHovered && !disabled ? tc.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: Icon(widget.icon, size: widget.iconSize, color: _iconColor),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
