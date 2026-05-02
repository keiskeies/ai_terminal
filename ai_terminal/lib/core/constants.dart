import 'package:flutter/material.dart';

// ===== 颜色系统 (深色) =====
// 背景
const Color cBg = Color(0xFF0B0D11);           // 页面背景
const Color cCard = Color(0xFF12151C);         // 卡片/组件背景
const Color cCardElevated = Color(0xFF1A1E28); // 浮层/弹窗背景
const Color cSurface = Color(0xFF1F2430);      // 表面（hover/active）

// 边框
const Color cBorder = Color(0xFF252A36);       // 边框/分割线
const Color cBorderHover = Color(0xFF2E3446);  // 亮边框（hover）

// 文字
const Color cTextMain = Color(0xFFE2E8F0);     // 主文字
const Color cTextSub = Color(0xFF64748B);      // 次文字
const Color cTextMuted = Color(0xFF475569);    // 更弱的文字

// 主题色 - 优雅的蓝紫
const Color cPrimary = Color(0xFF6366F1);      // 主色（Indigo）
const Color cPrimaryLight = Color(0xFF818CF8); // 浅主色
const Color cPrimaryDark = Color(0xFF4F46E5);  // 深主色

// 语义色
const Color cSuccess = Color(0xFF22C55E);      // 成功/在线
const Color cDanger = Color(0xFFEF4444);       // 危险/离线
const Color cWarning = Color(0xFFF59E0B);      // 警告
const Color cInfo = Color(0xFF3B82F6);         // 信息

// 终端
const Color cTerminalBg = Color(0xFF080A0F);
const Color cTerminalGreen = Color(0xFF4ADE80);

// Agent 色
const Color cAgentGreen = Color(0xFF10B981);
const Color cAgentGreenLight = Color(0xFF34D399);

// ===== 颜色系统 (浅色) =====
const Color cBgLight = Color(0xFFF8FAFC);
const Color cCardLight = Color(0xFFFFFFFF);
const Color cCardElevatedLight = Color(0xFFFFFFFF);
const Color cSurfaceLight = Color(0xFFF1F5F9);
const Color cBorderLightTheme = Color(0xFFE2E8F0);
const Color cBorderLightHover = Color(0xFFCBD5E1);
const Color cTextMainLight = Color(0xFF1E293B);
const Color cTextSubLight = Color(0xFF64748B);
const Color cTextMutedLight = Color(0xFF94A3B8);
const Color cTerminalBgLight = Color(0xFFF1F5F9);
const Color cTerminalGreenLight = Color(0xFF16A34A);
const Color cAgentGreenLightMode = Color(0xFF059669);

// 渐变色
const LinearGradient primaryGradient = LinearGradient(
  colors: [cPrimary, Color(0xFF8B5CF6)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient agentGradient = LinearGradient(
  colors: [cAgentGreen, Color(0xFF059669)],
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
const double rFull = 999.0;  // 胶囊

// 兼容旧名称
const double rCard = rLarge;
const double rButton = rMedium;
const double rInput = rMedium;
const double rBubble = rXLarge;
const double pStandard = 16.0;
const double pCompact = 12.0;
const double hAppBar = 52.0;
const double hTabBar = 38.0;

// ===== 阴影系统 =====
List<BoxShadow> shadowSmall({bool isLight = false}) => [
  BoxShadow(
    color: (isLight ? Colors.black : Colors.black).withOpacity(isLight ? 0.06 : 0.2),
    blurRadius: 4,
    offset: const Offset(0, 1),
  ),
];

List<BoxShadow> shadowMedium({bool isLight = false}) => [
  BoxShadow(
    color: (isLight ? Colors.black : Colors.black).withOpacity(isLight ? 0.08 : 0.3),
    blurRadius: 12,
    offset: const Offset(0, 4),
  ),
];

List<BoxShadow> shadowLarge({bool isLight = false}) => [
  BoxShadow(
    color: (isLight ? Colors.black : Colors.black).withOpacity(isLight ? 0.1 : 0.4),
    blurRadius: 24,
    offset: const Offset(0, 8),
  ),
];

List<BoxShadow> get shadowGlow => [
  BoxShadow(
    color: cPrimary.withOpacity(0.15),
    blurRadius: 16,
    spreadRadius: 0,
  ),
];

List<BoxShadow> get shadowAgentGlow => [
  BoxShadow(
    color: cAgentGreen.withOpacity(0.15),
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
  Color(0xFFEF4444),
  Color(0xFFF59E0B),
  Color(0xFFEAB308),
  Color(0xFF22C55E),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
];
