import 'package:flutter/material.dart';

// ===== 主色（旧蓝系已退场：全部别名到石墨青 token，见 cBrand 系列）=====
const Color cPrimary = cBrand;
const Color cPrimaryHover = cBrandHover;
const Color cPrimaryActive = cBrandPressed;
const Color cPrimaryBg = cBrandBg;

// 兼容旧名
const Color cPrimaryLight = cBrandHover;
const Color cPrimaryDark = cBrandPressed;
const Color cInfo = cPrimary;
const Color cKleinBlue = cPrimary;
const Color cKleinBlueLight = cPrimaryLight;
const Color cKleinBlueDark = cPrimaryDark;

// ===== 语义色（旧语义色退场，统一指向石墨青状态色）=====
const Color cSuccess = cStatusOk;
const Color cSuccessBg = cStatusOkBg;
const Color cWarning = cStatusWarn;
const Color cWarningBg = cStatusWarnBg;
const Color cDanger = cStatusError;
const Color cDangerBg = cStatusErrorBg;

// 兼容旧名
const Color cLimeGreen = cSuccess;
const Color cLimeGreenLight = Color(0xFF8FE7B4);
const Color cLimeGreenDark = cStatusOk;
const Color cChineseRed = cDanger;
const Color cChineseRedLight = Color(0xFFFF9AA2);
const Color cChineseRedDark = cStatusError;
const Color cHermesOrange = cWarning;
const Color cHermesOrangeLight = Color(0xFFF2C276);
const Color cHermesOrangeDark = cStatusWarn;
// 紫色不再承担语义，只保留给标签分类（tagColors）。
const Color cViolet = Color(0xFF8B5CF6);
const Color cVioletLight = Color(0xFFA78BFA);
const Color cVioletDark = Color(0xFF7C3AED);

// 终端兼容
const Color cTerminalGreen = cSuccess;
const Color cAgentGreenLight = cLimeGreenLight;


// ===== 颜色系统 (深色 · 石墨青) =====
// 中性石墨底：层级靠 surface 阶梯 + 发丝线，不靠大面积色块。
// 阶梯规则（G 通道）：终端/代码 7 → 窗口 12 → 内联输出 16 → 卡片 22 → 面板 32 → 控件 44，
// 相邻至少差 4、跨层差 10；代码层永远比它的容器暗一档。
// 卡片保持原亮度：回答正文都坐在卡片上，提亮卡片等于压低小字号的对比度。
const Color cBg = Color(0xFF090C0C);
const Color cCard = Color(0xFF131616);
const Color cCardElevated = Color(0xFF1C2020);
const Color cSurface = Color(0xFF292C2C);
// 数据卡片（执行清单、结论、变更行）：比面板亮一档并带一点青，只靠亮度差在
// 深色里不够看，色相偏一点才会一眼分得开。AI 回答去掉外层气泡后，这些卡片从
// "气泡内嵌块"变成"面板上的独立卡片"，这层阶梯仍需保留：压暗会同时损失 11px
// 小字对比度，并破坏 theme_surface_ladder_test 的 0.012 亮度差契约。
const Color cCardData = Color(0xFF202A28);
// 发丝线：默认 12% 白，交互/焦点 22%，内部分隔 7%。
const Color cBorder = Color(0x1FFFFFFF);
const Color cBorderHover = Color(0x38FFFFFF);
const Color cHairline = Color(0x12FFFFFF);

// 文字
const Color cTextMain = Color(0xFFF1F3F1);
const Color cTextBody = Color(0xFFB8BEBA);
const Color cTextSub = Color(0xFF858D88);
// 面板提亮后，最弱一档的灰字在面板上要重新够到 4:1，否则小字号先糊掉
const Color cTextMuted = Color(0xFF7A827C);

// 终端
const Color cTerminalBg = Color(0xFF040707);
const Color cTerminalOutput = Color(0xFF0D1010);

// ===== 品牌强调色（深色）=====
// 青色只用于交互、进行中状态与链接；金色只用于第二数据色（耗时/统计）。
const Color cBrand = Color(0xFF45C8C3);
const Color cBrandHover = Color(0xFF6ADDD8);
const Color cBrandPressed = Color(0xFF2FA9A5);
const Color cBrandBg = Color(0x1A45C8C3);
const Color cGold = Color(0xFFE0AF63);
const Color cGoldBg = Color(0x1AE0AF63);

// 深色语义状态：比旧版更柔和，警告偏橙以区分金色。
const Color cStatusOk = Color(0xFF6FD39A);
const Color cStatusOkBg = Color(0x1A6FD39A);
const Color cStatusWarn = Color(0xFFF09A5C);
const Color cStatusWarnBg = Color(0x1AF09A5C);
const Color cStatusError = Color(0xFFF07C86);
const Color cStatusErrorBg = Color(0x1AF07C86);

// Agent 色 = 成功绿
const Color cAgentGreen = cSuccess;

// ===== 颜色系统 (浅色 · 石墨青) =====
// 浅色底同样用中性石墨阶，青色改为深青以保证白底小字号可读。
// 浅色到顶就是纯白，所以阶梯往下拉：面板最亮 → 卡片 → 代码层再暗一档；
// 旧值 cTerminalBgLight 与 cCardElevatedLight 同为纯白，代码块只能靠边框显形。
// 控件底只比旧值暗 4 点：再暗就会压掉胶囊里小字号的对比度。
const Color cBgLight = Color(0xFFEEF1EE);
const Color cCardLight = Color(0xFFFAFBFA);
const Color cCardElevatedLight = Color(0xFFFFFFFF);
const Color cSurfaceLight = Color(0xFFE4E9E4);
// 浅色到不了"更白"，数据卡片反过来往下一档，靠凹陷感区分；再暗小字号就不过 4.5:1
const Color cCardDataLight = Color(0xFFF0F4F0);
// 浅色发丝线：默认 14% 黑，交互 23% 黑，内部分隔 7% 黑。
const Color cBorderLightTheme = Color(0x24000000);
const Color cBorderLightHover = Color(0x3A000000);
const Color cHairlineLight = Color(0x12000000);
const Color cTextMainLight = Color(0xFF171B19);
const Color cTextBodyLight = Color(0xFF4B534E);
// 小字号达标线（WCAG 4.5:1）按最暗的浅色底（控件底 #E4E9E4）反推：
// 旧值 sub/muted 在控件底上只有 4.1 / 2.6，整档灰字压暗到刚好全表面过线。
const Color cTextSubLight = Color(0xFF5A635D);
const Color cTextMutedLight = Color(0xFF606963);
const Color cTerminalBgLight = Color(0xFFF2F4F2);
const Color cTerminalOutputLight = Color(0xFFE8EBE8);
const Color cTerminalGreenLight = Color(0xFF177343);
const Color cAgentGreenLightMode = Color(0xFF177343);

// 浅色品牌青：深青在全部浅色表面上 ≥4.9:1，filled button 白字仍达标。
const Color cBrandLight = Color(0xFF0A6E69);
const Color cBrandLightHover = Color(0xFF096B67);
const Color cBrandLightPressed = Color(0xFF075955);
const Color cBrandLightBg = Color(0x140B7A75);
// 浅色数据金色 / 语义状态色。
const Color cGoldLight = Color(0xFF8A5D0A);
const Color cGoldBgLight = Color(0x148A5D0A);
const Color cStatusOkLight = Color(0xFF177343);
const Color cStatusOkBgLight = Color(0x141B7F4B);
const Color cStatusWarnLight = Color(0xFF99540A);
const Color cStatusWarnBgLight = Color(0x14A65B00);
const Color cStatusErrorLight = Color(0xFFB42318);
const Color cStatusErrorBgLight = Color(0x14B42318);

// ===== 圆角系统 =====
// 原先 4/6/8/12 的阶梯在 11px 小字与细边框的深色界面上显得偏尖：边框越细，
// 小半径的转角越接近直角。整体上调一档（+1~2px），让卡片、输入框、按钮的
// 转角更圆润，同时保持四档之间的层级差不变。
const double rXSmall = 5.0;
const double rSmall = 8.0;
const double rMedium = 10.0;
const double rLarge = 14.0;
const double rXLarge = 18.0;
const double rFull = 999.0;
const double rCard = rMedium;
const double rButton = rSmall;
const double rInput = rSmall;
const double rBubble = rMedium;
/// 浮层（菜单、命令面板）。设计稿给的是 12，阶梯里没有这一步。
const double rFloat = 12.0;

// ===== 间距系统 =====
const double pXSmall = 4.0;
const double pSmall = 8.0;
/// 卡片级模块之间（结果卡 / 执行清单 / 正文 / 过程折叠）。
/// 12 在 13px 正文的回答里会读成"两块东西断开了"，10 才是一段话的呼吸。
const double pModule = 10.0;
const double pCompact = 12.0;
const double pStandard = 16.0;
const double pLarge = 20.0;
const double pXLarge = 24.0;

const double hAppBar = 48.0;
const double hTabBar = 36.0;

// ===== 阴影系统 =====
// 极简：统一的中性阴影，没有彩色阴影
const List<BoxShadow> shadowSm = [
  BoxShadow(
    color: Color(0x26000000),
    blurRadius: 4,
    spreadRadius: 0,
    offset: Offset(0, 1),
  ),
];

const List<BoxShadow> shadowMd = [
  BoxShadow(
    color: Color(0x33000000),
    blurRadius: 8,
    spreadRadius: 0,
    offset: Offset(0, 2),
  ),
];

const List<BoxShadow> shadowLg = [
  BoxShadow(
    color: Color(0x40000000),
    blurRadius: 16,
    spreadRadius: 0,
    offset: Offset(0, 4),
  ),
];

const List<BoxShadow> shadowXl = [
  BoxShadow(
    color: Color(0x59000000),
    blurRadius: 24,
    spreadRadius: 0,
    offset: Offset(0, 8),
  ),
];

// 兼容旧名
const List<BoxShadow> shadowSmallDark = shadowSm;
const List<BoxShadow> shadowMediumDark = shadowMd;
const List<BoxShadow> shadowLargeDark = shadowLg;
const List<BoxShadow> shadowXLDark = shadowXl;
const List<BoxShadow> shadowSmallLight = shadowSm;
const List<BoxShadow> shadowMediumLight = shadowMd;
const List<BoxShadow> shadowLargeLight = shadowLg;
const List<BoxShadow> shadowXLLight = shadowXl;

// ===== 字体 =====
const String kFontFamily = 'MiSans';
const List<String> kMonoFontFallback = <String>[kFontFamily];

const double fHero = 28.0;
const double fDisplay = 24.0;
const double fTitle = 16.0;
const double fBody = 13.0;
const double fSmall = 12.0;
const double fMono = 13.0;
const double fMicro = 11.0;
// Agent 正文（Markdown 回答主体）专用字号：比过程证据再小一档，
// 避免大段正文反过来压过命令/结果这些真正要读的内容。
const double fAgentBody = 10.0;
/// 最小文字：徽标、调色板标签。低于 10 在 Windows 上会糊。
const double fMini = 10.0;
/// 二级标题（Markdown h2 等），介于 fBody 与 fTitle 之间。
const double fSubtitle = 14.0;

// ===== 动画 =====
const Duration animFast = Duration(milliseconds: 120);
const Duration animNormal = Duration(milliseconds: 200);
const Duration animSlow = Duration(milliseconds: 320);

// ===== 标签颜色选项 =====
// 紫色仅在这里作为分类色存在，不再承担语义。
const List<Color> tagColors = [
  cStatusError,
  cStatusWarn,
  cGold,
  cStatusOk,
  cBrand,
  cViolet,
];
