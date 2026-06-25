import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';

/// P2-9: 统一空状态组件
/// 支持自定义插画、动画、引导文案和 CTA
class EmptyStateWidget extends StatelessWidget {
  final Widget? illustration;
  final IconData? icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryAction;

  const EmptyStateWidget({
    super.key,
    this.illustration,
    this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(pStandard * 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 插画或图标
            if (illustration != null)
              illustration!
            else if (icon != null)
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: cPrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(rLarge),
                ),
                child: Icon(icon, size: 32, color: cPrimary),
              ),
            const SizedBox(height: 24),
            // 标题
            Text(
              title,
              style: TextStyle(
                fontSize: fTitle,
                fontWeight: FontWeight.w600,
                color: tc.textMain,
              ),
              textAlign: TextAlign.center,
            ),
            // 副标题
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: fBody,
                  color: tc.textSub,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            // 主按钮
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
            // 次要按钮
            if (secondaryLabel != null && onSecondaryAction != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onSecondaryAction,
                child: Text(secondaryLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 脉冲动画容器（用于空状态装饰）
class PulsingContainer extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const PulsingContainer({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
  });

  @override
  State<PulsingContainer> createState() => _PulsingContainerState();
}

class _PulsingContainerState extends State<PulsingContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.5 + 0.5 * _controller.value,
          child: widget.child,
        );
      },
    );
  }
}
