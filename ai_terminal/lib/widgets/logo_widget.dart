import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// AI Terminal 品牌 LOGO 组件
///
/// 支持三种形态：
/// - [LogoType.mark] 仅图标，适用于顶部栏、空状态
/// - [LogoType.wordmark] 图标 + 文字，适用于启动页、关于页
/// - [LogoType.light] 浅色背景版本
class LogoWidget extends StatelessWidget {
  final LogoType type;
  final double? size;
  final double? iconSize;
  final Color? textColor;

  const LogoWidget({
    super.key,
    this.type = LogoType.mark,
    this.size,
    this.iconSize,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = type == LogoType.light;
    final effectiveIconSize = iconSize ?? size ?? 32.0;

    if (type == LogoType.wordmark) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/icons/logo_mark.svg',
            width: effectiveIconSize,
            height: effectiveIconSize,
          ),
          const SizedBox(width: 10),
          Text(
            'AI Terminal',
            style: TextStyle(
              color: textColor ?? Theme.of(context).colorScheme.onSurface,
              fontSize: effectiveIconSize * 0.55,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
            ),
          ),
        ],
      );
    }

    return SvgPicture.asset(
      isLight ? 'assets/icons/logo_mark_light.svg' : 'assets/icons/logo_mark.svg',
      width: effectiveIconSize,
      height: effectiveIconSize,
    );
  }
}

enum LogoType { mark, wordmark, light }
