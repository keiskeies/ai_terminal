import 'package:flutter/material.dart';
import 'constants.dart';

/// 主题感知颜色工具 - 根据当前主题自动返回深色/浅色模式对应的颜色
/// 使用方式：ThemeColors.of(context).bg
class ThemeColors {
  final bool isLight;

  ThemeColors._(this.isLight);

  factory ThemeColors.of(BuildContext context) {
    return ThemeColors._(Theme.of(context).brightness == Brightness.light);
  }

  // 背景
  Color get bg => isLight ? cBgLight : cBg;
  Color get card => isLight ? cCardLight : cCard;
  Color get cardElevated => isLight ? cCardElevatedLight : cCardElevated;
  Color get surface => isLight ? cSurfaceLight : cSurface;

  // 边框
  Color get border => isLight ? cBorderLightTheme : cBorder;
  Color get borderHover => isLight ? cBorderLightHover : cBorderHover;

  // 文字
  Color get textMain => isLight ? cTextMainLight : cTextMain;
  Color get textSub => isLight ? cTextSubLight : cTextSub;
  Color get textMuted => isLight ? cTextMutedLight : cTextMuted;

  // 终端
  Color get terminalBg => isLight ? cTerminalBgLight : cTerminalBg;
  Color get terminalGreen => isLight ? cTerminalGreenLight : cTerminalGreen;

  // Agent
  Color get agentGreen => isLight ? cAgentGreenLightMode : cAgentGreen;
  Color get agentGreenLight => isLight ? cAgentGreenLightMode : cAgentGreenLight;
}
