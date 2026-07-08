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


// ===== 颜色系统 (深色) =====
const Color cBg = Color(0xFF0D1117);
const Color cCard = Color(0xFF161B22);
const Color cCardElevated = Color(0xFF1C2128);
const Color cSurface = Color(0xFF21262D);
const Color cBorder = Color(0xFF30363D);
const Color cBorderHover = Color(0xFF484F58);

// 文字
const Color cTextMain = Color(0xFFE6EDF3);
const Color cTextBody = Color(0xFFB1BAC4);
const Color cTextSub = Color(0xFF7D8590);
const Color cTextMuted = Color(0xFF6E7681);

// 终端
const Color cTerminalBg = Color(0xFF0A0D12);
const Color cTerminalOutput = Color(0xFF0D1117);

// Agent 色 = 成功绿
const Color cAgentGreen = cSuccess;

// ===== 颜色系统 (浅色) =====
const Color cBgLight = Color(0xFFF6F8FA);
const Color cCardLight = Color(0xFFFFFFFF);
const Color cCardElevatedLight = Color(0xFFF6F8FA);
const Color cSurfaceLight = Color(0xFFEAEFF2);
const Color cBorderLightTheme = Color(0xFFD0D7DE);
const Color cBorderLightHover = Color(0xFFAFB8C1);
const Color cTextMainLight = Color(0xFF1F2328);
const Color cTextBodyLight = Color(0xFF444D56);
const Color cTextSubLight = Color(0xFF6E7781);
const Color cTextMutedLight = Color(0xFF8C959F);
const Color cTerminalBgLight = Color(0xFFFFFFFF);
const Color cTerminalGreenLight = Color(0xFF1A7F37);
const Color cAgentGreenLightMode = Color(0xFF1A7F37);

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
