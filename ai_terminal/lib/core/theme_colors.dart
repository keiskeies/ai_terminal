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
  // 通用 token：保留供其它需要"比面板亮一档"的容器使用；AI 回答卡片已统一
  // 改用下面的 agentCardFill，不再用它做填充。
  Color get dataCard => isLight ? cCardDataLight : cCardData;
  /// AI 回答里的卡片（执行清单、结论、证据、命令、事件、思考块）：与 demo 一致，
  /// 不填背景色，只靠 1px 边框 + 间距分层。去掉外层气泡后，原先比面板亮一档的
  /// dataCard 会让每张卡变成"浮起来的独立色块"；透明填充让内容直接坐在面板上，
  /// 视觉权重回到文字与状态标记。深浅主题同为透明，边框由 tc.border 自动适配。
  Color get agentCardFill => Colors.transparent;

  /// AI 内容卡片的统一边框线（命令行 / 正文 / 结果卡 / 执行清单 / 过程行）。
  ///
  /// 这几张卡在同一条回答里上下相邻，边框粗细/深浅只要有一处不同，看上去就像
  /// 来自两套版式。统一走这个 token，颜色随主题自动适配。
  Color get agentCardBorder => border;

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

  /// 实心品牌色/语义色（按钮、开关、实心标签）上的前景色。
  /// 深色主题的品牌青/状态色是亮色，前景取近黑；浅色主题是深色，前景取白。
  Color get onAccent => isLight ? Colors.white : cBg;
  Color get gold => isLight ? cGoldLight : cGold;
  Color get goldBg => isLight ? cGoldBgLight : cGoldBg;
  Color get ok => isLight ? cStatusOkLight : cStatusOk;
  Color get okBg => isLight ? cStatusOkBgLight : cStatusOkBg;
  Color get warn => isLight ? cStatusWarnLight : cStatusWarn;
  Color get warnBg => isLight ? cStatusWarnBgLight : cStatusWarnBg;
  Color get error => isLight ? cStatusErrorLight : cStatusError;
  Color get errorBg => isLight ? cStatusErrorBgLight : cStatusErrorBg;

  // 用户消息是"引用块"：与 demo 一致的近底色 + 极淡顶部染色 + 1px 细边框，
  // 不用整块高饱和青绿。AI 回答不再套气泡，这里也不再承担两个气泡对等堆叠的
  // 对比职责，视觉权重落在边框与角色标签上。
  // 深色直接取 demo 的 #0E1D1A / #1E3A34；浅色按同样的明度关系反推：白底上
  // 无法"再提亮"，所以卡片比面板(cCardLight)略沉一档、边框再沉一档带青，
  // 既避开原来 #E1F2F0 整块亮青在浅色主题里的刺眼感，也保持"独立引用区"语义。
  Color get userBubble =>
      isLight ? const Color(0xFFF1F8F6) : const Color(0xFF0E1D1A);
  Color get userBubbleBorder =>
      isLight ? const Color(0xFFC9DFD9) : const Color(0xFF1E3A34);
  /// demo 的 `.ucard` 有一层 180° 极淡渐变（顶部 4.5% 品牌青 → 60% 处透明）。
  /// 折进 BoxDecoration.gradient 的两段实色：深色顶部略亮带青，浅色顶部提亮到
  /// 近白，都是"顶部一层高光"，深浅语义一致。与 color 互斥，调用处只给 gradient。
  LinearGradient get userBubbleGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.6],
        colors: isLight
            ? [const Color(0xFFFAFDFC), userBubble]
            : [const Color(0xFF102620), userBubble],
      );
}
