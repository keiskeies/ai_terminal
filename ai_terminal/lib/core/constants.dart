import 'package:flutter/material.dart';

// ===== 品牌四色 =====
// 克莱因蓝 - 主色/行动：导航高亮、主按钮、链接、信息
const Color cKleinBlue = Color(0xFF3B7DFF);
const Color cKleinBlueLight = Color(0xFF5A9AFF);
const Color cKleinBlueDark = Color(0xFF2060D0);

// 莱姆绿 - 智能/成功：Agent、在线、操作成功
const Color cLimeGreen = Color(0xFF6ECC54);
const Color cLimeGreenLight = Color(0xFF8FE07A);
const Color cLimeGreenDark = Color(0xFF4DA83A);

// 中国红 - 危险/重要：错误、删除、断开、离线
const Color cChineseRed = Color(0xFFC8161D);
const Color cChineseRedLight = Color(0xFFE03040);
const Color cChineseRedDark = Color(0xFF9E1018);

// 爱马仕橙 - 警示/关注：警告、待处理、未读、执行中
const Color cHermesOrange = Color(0xFFEB5C20);
const Color cHermesOrangeLight = Color(0xFFF07840);
const Color cHermesOrangeDark = Color(0xFFC44A18);

// ===== 颜色系统 (深色) =====
// 背景
const Color cBg = Color(0xFF0A0A0F);
const Color cCard = Color(0xFF111118);
const Color cCardElevated = Color(0xFF1A1A24);
const Color cSurface = Color(0xFF22222E);

// 边框
const Color cBorder = Color(0xFF2A2A38);
const Color cBorderHover = Color(0xFF363648);

// 文字
const Color cTextMain = Color(0xFFF0F0F5);
const Color cTextSub = Color(0xFF8888A0);
const Color cTextMuted = Color(0xFF5C5C72);

// 主题色（克莱因蓝）
const Color cPrimary = cKleinBlue;
const Color cPrimaryLight = cKleinBlueLight;
const Color cPrimaryDark = cKleinBlueDark;

// 语义色（品牌四色）
const Color cSuccess = cLimeGreen;
const Color cDanger = cChineseRed;
const Color cWarning = cHermesOrange;
const Color cInfo = cKleinBlue;

// 终端
const Color cTerminalBg = Color(0xFF000000);
const Color cTerminalGreen = cLimeGreen;

// Agent 色（莱姆绿）
const Color cAgentGreen = cLimeGreen;
const Color cAgentGreenLight = cLimeGreenLight;

// ===== 颜色系统 (浅色) =====
const Color cBgLight = Color(0xFFF5F5FA);
const Color cCardLight = Color(0xFFFFFFFF);
const Color cCardElevatedLight = Color(0xFFFFFFFF);
const Color cSurfaceLight = Color(0xFFEEEEF5);
const Color cBorderLightTheme = Color(0xFFD8D8E5);
const Color cBorderLightHover = Color(0xFFC0C0D2);
const Color cTextMainLight = Color(0xFF1A1A2E);
const Color cTextSubLight = Color(0xFF6B6B85);
const Color cTextMutedLight = Color(0xFF9999AD);
const Color cTerminalBgLight = Color(0xFFF0F0F5);
const Color cTerminalGreenLight = cLimeGreenDark;
const Color cAgentGreenLightMode = cLimeGreenDark;

// 渐变色
const LinearGradient primaryGradient = LinearGradient(
  colors: [cKleinBlue, cKleinBlueLight],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient agentGradient = LinearGradient(
  colors: [cLimeGreen, cLimeGreenDark],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient surfaceGradient = LinearGradient(
  colors: [cCardElevated, cCard],
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
);

// ===== 圆角系统 =====
const double rXSmall = 4.0;
const double rSmall = 10.0;
const double rMedium = 10.0;
const double rLarge = 14.0;
const double rXLarge = 20.0;
const double rFull = 999.0;
const double rCard = rLarge;
const double rButton = rMedium;
const double rInput = rMedium;
const double rBubble = rXLarge;
const double pStandard = 16.0;
const double pCompact = 12.0;
const double hAppBar = 52.0;
const double hTabBar = 38.0;

// ===== 阴影系统 =====
const List<BoxShadow> shadowSmallDark = [
  BoxShadow(
    color: Color(0x33000000),
    blurRadius: 4,
    offset: Offset(0, 1),
  ),
];

const List<BoxShadow> shadowSmallLight = [
  BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 4,
    offset: Offset(0, 1),
  ),
];

const List<BoxShadow> shadowMediumDark = [
  BoxShadow(
    color: Color(0x4D000000),
    blurRadius: 12,
    offset: Offset(0, 4),
  ),
];

const List<BoxShadow> shadowMediumLight = [
  BoxShadow(
    color: Color(0x14000000),
    blurRadius: 12,
    offset: Offset(0, 4),
  ),
];

const List<BoxShadow> shadowLargeDark = [
  BoxShadow(
    color: Color(0x66000000),
    blurRadius: 24,
    offset: Offset(0, 8),
  ),
];

const List<BoxShadow> shadowLargeLight = [
  BoxShadow(
    color: Color(0x1A000000),
    blurRadius: 24,
    offset: Offset(0, 8),
  ),
];

List<BoxShadow> shadowSmall({bool isLight = false}) => isLight ? shadowSmallLight : shadowSmallDark;
List<BoxShadow> shadowMedium({bool isLight = false}) => isLight ? shadowMediumLight : shadowMediumDark;
List<BoxShadow> shadowLarge({bool isLight = false}) => isLight ? shadowLargeLight : shadowLargeDark;

const List<BoxShadow> shadowGlow = [
  BoxShadow(
    color: Color(0x263B7DFF),
    blurRadius: 16,
    spreadRadius: 0,
  ),
];

const List<BoxShadow> shadowAgentGlow = [
  BoxShadow(
    color: Color(0x266ECC54),
    blurRadius: 16,
    spreadRadius: 0,
  ),
];

// ===== 字体 =====
const double fTitle = 16.0;
const double fBody = 13.0;
const double fSmall = 11.0;
const double fMono = 12.0;
const double fMicro = 10.0;

// ===== 动画 =====
const Duration animFast = Duration(milliseconds: 150);
const Duration animNormal = Duration(milliseconds: 250);
const Duration animSlow = Duration(milliseconds: 400);

// ===== 标签颜色选项 =====
const List<Color> tagColors = [
  cChineseRed,
  cHermesOrange,
  Color(0xFFEAB308),
  cLimeGreen,
  cKleinBlue,
  Color(0xFF8B5CF6),
];
