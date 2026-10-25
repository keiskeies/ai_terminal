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
  Color get hairline => isLight ? cHairlineLight : cHairline;

  // 文字
  Color get textMain => isLight ? cTextMainLight : cTextMain;
  Color get textBody => isLight ? cTextBodyLight : cTextBody;
  Color get textSub => isLight ? cTextSubLight : cTextSub;
  Color get textMuted => isLight ? cTextMutedLight : cTextMuted;

  // 终端
  Color get terminalBg => isLight ? cTerminalBgLight : cTerminalBg;
  Color get terminalOutput => isLight ? cTerminalOutputLight : cTerminalOutput;
  Color get terminalGreen => isLight ? cTerminalGreenLight : cTerminalGreen;

  // Agent
  Color get agentGreen => isLight ? cAgentGreenLightMode : cStatusOk;
  Color get agentGreenLight => isLight ? cAgentGreenLightMode : cStatusOk;

  // 石墨青品牌/语义色（浅色主题继续使用现有蓝色主色，避免白底青字对比度不足）
  Color get brand => isLight ? cBrandLight : cBrand;
  Color get brandHover => isLight ? cBrandLightHover : cBrandHover;
  Color get brandPressed => isLight ? cBrandLightPressed : cBrandPressed;
  Color get brandBg => isLight ? cBrandLightBg : cBrandBg;
  Color get gold => isLight ? cGoldLight : cGold;
  Color get goldBg => isLight ? cGoldBgLight : cGoldBg;
  Color get ok => isLight ? cStatusOkLight : cStatusOk;
  Color get okBg => isLight ? cStatusOkBgLight : cStatusOkBg;
  Color get warn => isLight ? cStatusWarnLight : cStatusWarn;
  Color get warnBg => isLight ? cStatusWarnBgLight : cStatusWarnBg;
  Color get error => isLight ? cStatusErrorLight : cStatusError;
  Color get errorBg => isLight ? cStatusErrorBgLight : cStatusErrorBg;

  // 对话气泡：用户消息用品牌青淡染，和 AI 的中性石墨气泡明确区分。
  Color get userBubble =>
      isLight ? const Color(0xFFE1F2F0) : const Color(0xFF12302E);
  Color get userBubbleBorder =>
      isLight ? const Color(0x590B7A75) : const Color(0x6645C8C3);
}
