import 'package:flutter/material.dart';

// ===== 主色 =====
const Color cPrimary = Color(0xFF3B82F6);
const Color cPrimaryHover = Color(0xFF2563EB);
const Color cPrimaryActive = Color(0xFF1D4ED8);
const Color cPrimaryBg = Color(0x1A3B82F6);

// 兼容旧名
const Color cPrimaryLight = Color(0xFF60A5FA);
const Color cPrimaryDark = Color(0xFF1D4ED8);
const Color cInfo = cPrimary;
const Color cKleinBlue = cPrimary;
const Color cKleinBlueLight = cPrimaryLight;
const Color cKleinBlueDark = cPrimaryDark;

// ===== 语义色 =====
const Color cSuccess = Color(0xFF10B981);
const Color cSuccessBg = Color(0x1A10B981);
const Color cWarning = Color(0xFFF59E0B);
const Color cWarningBg = Color(0x1AF59E0B);
const Color cDanger = Color(0xFFEF4444);
const Color cDangerBg = Color(0x1AEF4444);

// 兼容旧名
const Color cLimeGreen = cSuccess;
const Color cLimeGreenLight = Color(0xFF34D399);
const Color cLimeGreenDark = Color(0xFF059669);
const Color cChineseRed = cDanger;
const Color cChineseRedLight = Color(0xFFF87171);
const Color cChineseRedDark = Color(0xFFDC2626);
const Color cHermesOrange = cWarning;
const Color cHermesOrangeLight = Color(0xFFFBBF24);
const Color cHermesOrangeDark = Color(0xFFD97706);
const Color cViolet = Color(0xFF8B5CF6);
const Color cVioletLight = Color(0xFFA78BFA);
const Color cVioletDark = Color(0xFF7C3AED);

// 终端兼容
const Color cTerminalGreen = cSuccess;
const Color cAgentGreenLight = cLimeGreenLight;


// ===== 颜色系统 (深色 · 石墨青) =====
// 中性石墨底：层级靠 surface 阶梯 + 发丝线，不靠大面积色块。
const Color cBg = Color(0xFF0B0D0D);
const Color cCard = Color(0xFF111414);
const Color cCardElevated = Color(0xFF171B1B);
const Color cSurface = Color(0xFF1E2323);
// 发丝线：默认 12% 白，交互/焦点 22%，内部分隔 7%。
const Color cBorder = Color(0x1FFFFFFF);
const Color cBorderHover = Color(0x38FFFFFF);
const Color cHairline = Color(0x12FFFFFF);

// 文字
const Color cTextMain = Color(0xFFF1F3F1);
const Color cTextBody = Color(0xFFB8BEBA);
const Color cTextSub = Color(0xFF858D88);
const Color cTextMuted = Color(0xFF6F7671);

// 终端
const Color cTerminalBg = Color(0xFF080A0A);
const Color cTerminalOutput = Color(0xFF0E1111);

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
const Color cBgLight = Color(0xFFF3F5F3);
const Color cCardLight = Color(0xFFFBFCFB);
const Color cCardElevatedLight = Color(0xFFFFFFFF);
const Color cSurfaceLight = Color(0xFFE7ECE8);
// 浅色发丝线：默认 14% 黑，交互 23% 黑，内部分隔 7% 黑。
const Color cBorderLightTheme = Color(0x24000000);
const Color cBorderLightHover = Color(0x3A000000);
const Color cHairlineLight = Color(0x12000000);
const Color cTextMainLight = Color(0xFF171B19);
const Color cTextBodyLight = Color(0xFF4B534E);
const Color cTextSubLight = Color(0xFF68716B);
const Color cTextMutedLight = Color(0xFF8A938D);
const Color cTerminalBgLight = Color(0xFFFFFFFF);
const Color cTerminalOutputLight = Color(0xFFFBFCFB);
const Color cTerminalGreenLight = Color(0xFF1B7F4B);
const Color cAgentGreenLightMode = Color(0xFF1B7F4B);

// 浅色品牌青：深青在白底上约 5:1，filled button 白字约 5.2:1。
const Color cBrandLight = Color(0xFF0B7A75);
const Color cBrandLightHover = Color(0xFF096B67);
const Color cBrandLightPressed = Color(0xFF075955);
const Color cBrandLightBg = Color(0x140B7A75);
// 浅色数据金色 / 语义状态色。
const Color cGoldLight = Color(0xFF8A5D0A);
const Color cGoldBgLight = Color(0x148A5D0A);
const Color cStatusOkLight = Color(0xFF1B7F4B);
const Color cStatusOkBgLight = Color(0x141B7F4B);
const Color cStatusWarnLight = Color(0xFFA65B00);
const Color cStatusWarnBgLight = Color(0x14A65B00);
const Color cStatusErrorLight = Color(0xFFB42318);
const Color cStatusErrorBgLight = Color(0x14B42318);

// ===== 圆角系统 =====
const double rXSmall = 4.0;
const double rSmall = 6.0;
const double rMedium = 8.0;
const double rLarge = 12.0;
const double rXLarge = 16.0;
const double rFull = 999.0;
const double rCard = rMedium;
const double rButton = rSmall;
const double rInput = rSmall;
const double rBubble = rMedium;

// ===== 间距系统 =====
const double pXSmall = 4.0;
const double pSmall = 8.0;
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
const double fHero = 28.0;
const double fDisplay = 24.0;
const double fTitle = 16.0;
const double fBody = 13.0;
const double fSmall = 12.0;
const double fMono = 13.0;
const double fMicro = 11.0;

// ===== 动画 =====
const Duration animFast = Duration(milliseconds: 120);
const Duration animNormal = Duration(milliseconds: 200);
const Duration animSlow = Duration(milliseconds: 320);

// ===== 标签颜色选项 =====
const List<Color> tagColors = [
  cDanger,
  cWarning,
  Color(0xFFEAB308),
  cSuccess,
  cPrimary,
  Color(0xFF8B5CF6),
];
