import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart' as xterm;

/// 终端配色预设（P2「主题自定义」的配色部分）。
///
/// 只做预设不做自由取色：终端配色真正难的是 16 色 ANSI + 前景/背景/光标/选区
/// 之间的对比度平衡，让用户逐个调的结果通常是不能看。预设来自业界通用方案，
/// 暗色与亮色分别设计。
///
/// 亮色变体可以缺省（`light == null`）——那些本来就是暗色方案的配色
/// （One Dark / Dracula / Gruvbox）没有可靠的亮色版本，缺省即回落到内置亮色，
/// 比硬造一套低对比度的假亮色好。
class TerminalPalette {
  const TerminalPalette({
    required this.id,
    required this.labelZh,
    required this.labelEn,
    required this.dark,
    this.light,
  });

  final String id;
  final String labelZh;
  final String labelEn;

  final xterm.TerminalTheme dark;

  /// 亮色变体；为 null 表示此配色只有暗色版本
  final xterm.TerminalTheme? light;

  String label({required bool isZh}) => isZh ? labelZh : labelEn;
}

/// 内置默认配色（应用品牌青色系），同时是未知/未设置 id 的回落值。
const String kDefaultTerminalPalette = 'default';

const _appDark = xterm.TerminalTheme(
  cursor: Color(0xFF45C8C3),
  selection: Color(0x4D45C8C3),
  foreground: Color(0xFFE6ECE8),
  background: Color(0xFF040707),
  black: Color(0xFF1A1D1C),
  red: Color(0xFFF07C86),
  green: Color(0xFF6FD39A),
  yellow: Color(0xFFF09A5C),
  blue: Color(0xFF6AA9FF),
  magenta: Color(0xFFD98AD9),
  cyan: Color(0xFF45C8C3),
  white: Color(0xFFE6ECE8),
  brightBlack: Color(0xFF6F7671),
  brightRed: Color(0xFFFF9AA2),
  brightGreen: Color(0xFF8FE7B4),
  brightYellow: Color(0xFFF2C276),
  brightBlue: Color(0xFF8CC0FF),
  brightMagenta: Color(0xFFE9A8E9),
  brightCyan: Color(0xFF6ADDD8),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF1A2423),
  searchHitBackgroundCurrent: Color(0xFF243331),
  searchHitForeground: Color(0xFFF1F3F1),
);

const _appLight = xterm.TerminalTheme(
  cursor: Color(0xFF0B7A75),
  selection: Color(0x330B7A75),
  foreground: Color(0xFF1A1F1D),
  background: Color(0xFFE8EBE8),
  black: Color(0xFF2A2F2C),
  red: Color(0xFFB42318),
  green: Color(0xFF1B7F4B),
  yellow: Color(0xFF8A5D0A),
  blue: Color(0xFF1F5FA8),
  magenta: Color(0xFF8A3A8A),
  cyan: Color(0xFF0B7A75),
  white: Color(0xFF6F7872),
  brightBlack: Color(0xFF8A938D),
  brightRed: Color(0xFFD14343),
  brightGreen: Color(0xFF2E9B63),
  brightYellow: Color(0xFFA66F00),
  brightBlue: Color(0xFF2E7BC4),
  brightMagenta: Color(0xFFA94FA9),
  brightCyan: Color(0xFF159792),
  brightWhite: Color(0xFF171B19),
  searchHitBackground: Color(0xFFDFF3F1),
  searchHitBackgroundCurrent: Color(0xFFC9EAE7),
  searchHitForeground: Color(0xFF171B19),
);

const _oneDark = xterm.TerminalTheme(
  cursor: Color(0xFFABB2BF),
  selection: Color(0x4D528BFF),
  foreground: Color(0xFFABB2BF),
  background: Color(0xFF282C34),
  black: Color(0xFF3F4451),
  red: Color(0xFFE06C75),
  green: Color(0xFF98C379),
  yellow: Color(0xFFE5C07B),
  blue: Color(0xFF61AFEF),
  magenta: Color(0xFFC678DD),
  cyan: Color(0xFF56B6C2),
  white: Color(0xFFABB2BF),
  brightBlack: Color(0xFF5C6370),
  brightRed: Color(0xFFFF8C94),
  brightGreen: Color(0xFFB5E08C),
  brightYellow: Color(0xFFF0D599),
  brightBlue: Color(0xFF8CC7FF),
  brightMagenta: Color(0xFFDE9CF0),
  brightCyan: Color(0xFF7ED4DE),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF3A4049),
  searchHitBackgroundCurrent: Color(0xFF464E59),
  searchHitForeground: Color(0xFFEEF1F5),
);

const _dracula = xterm.TerminalTheme(
  cursor: Color(0xFFF8F8F2),
  selection: Color(0x4D62728D),
  foreground: Color(0xFFF8F8F2),
  background: Color(0xFF282A36),
  black: Color(0xFF21222C),
  red: Color(0xFFFF555F),
  green: Color(0xFF50FA7B),
  yellow: Color(0xFFF1FA8C),
  blue: Color(0xFFBD93F9),
  magenta: Color(0xFFFF79C6),
  cyan: Color(0xFF8BE9FD),
  white: Color(0xFFF8F8F2),
  brightBlack: Color(0xFF6272A4),
  brightRed: Color(0xFFFF6E6E),
  brightGreen: Color(0xFF69FF94),
  brightYellow: Color(0xFFFFF1A3),
  brightBlue: Color(0xFFD6ACFF),
  brightMagenta: Color(0xFFFFA8D6),
  brightCyan: Color(0xFFA4FFFF),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF44475A),
  searchHitBackgroundCurrent: Color(0xFF4F5368),
  searchHitForeground: Color(0xFFF8F8F2),
);

const _solarizedDark = xterm.TerminalTheme(
  cursor: Color(0xFF93A1A1),
  selection: Color(0x4D586E78),
  foreground: Color(0xFF93A1A1),
  background: Color(0xFF002B36),
  black: Color(0xFF073642),
  red: Color(0xFFDC322F),
  green: Color(0xFF859900),
  yellow: Color(0xFFB58900),
  blue: Color(0xFF268BD2),
  magenta: Color(0xFFD33682),
  cyan: Color(0xFF2AA198),
  white: Color(0xFFEEE8D5),
  brightBlack: Color(0xFF586E75),
  brightRed: Color(0xFFCB4B16),
  brightGreen: Color(0xFF586E75),
  brightYellow: Color(0xFF657B83),
  brightBlue: Color(0xFF839496),
  brightMagenta: Color(0xFF6C71C4),
  brightCyan: Color(0xFF93A1A1),
  brightWhite: Color(0xFFFDF6E3),
  searchHitBackground: Color(0xFF074654),
  searchHitBackgroundCurrent: Color(0xFF0A5566),
  searchHitForeground: Color(0xFFEEE8D5),
);

const _solarizedLight = xterm.TerminalTheme(
  cursor: Color(0xFF586E75),
  selection: Color(0x3393A1A1),
  foreground: Color(0xFF657B83),
  background: Color(0xFFFDF6E3),
  black: Color(0xFF073642),
  red: Color(0xFFDC322F),
  green: Color(0xFF859900),
  yellow: Color(0xFFB58900),
  blue: Color(0xFF268BD2),
  magenta: Color(0xFFD33682),
  cyan: Color(0xFF2AA198),
  white: Color(0xFFEEE8D5),
  brightBlack: Color(0xFF93A1A1),
  brightRed: Color(0xFFCB4B16),
  brightGreen: Color(0xFF586E75),
  brightYellow: Color(0xFF657B83),
  brightBlue: Color(0xFF839496),
  brightMagenta: Color(0xFF6C71C4),
  brightCyan: Color(0xFF93A1A1),
  brightWhite: Color(0xFFFDF6E3),
  searchHitBackground: Color(0xFFEEE0B7),
  searchHitBackgroundCurrent: Color(0xFFE5D6A9),
  searchHitForeground: Color(0xFF073642),
);

const _gruvbox = xterm.TerminalTheme(
  cursor: Color(0xFFEBDBB2),
  selection: Color(0x4D665C43),
  foreground: Color(0xFFEBDBB2),
  background: Color(0xFF282828),
  black: Color(0xFF3C3836),
  red: Color(0xFFFB4934),
  green: Color(0xFFB8BB26),
  yellow: Color(0xFFFABD2F),
  blue: Color(0xFF83A598),
  magenta: Color(0xFFD3869B),
  cyan: Color(0xFF8EC07C),
  white: Color(0xFFEBDBB2),
  brightBlack: Color(0xFF928374),
  brightRed: Color(0xFFF07178),
  brightGreen: Color(0xFFCABB24),
  brightYellow: Color(0xFFFCE195),
  brightBlue: Color(0xFF8ECAE0),
  brightMagenta: Color(0xFFE8A9BF),
  brightCyan: Color(0xFFA9D6A0),
  brightWhite: Color(0xFFFBF4C5),
  searchHitBackground: Color(0xFF3C3836),
  searchHitBackgroundCurrent: Color(0xFF504945),
  searchHitForeground: Color(0xFFFDF9E4),
);

/// 可选配色（按设置页展示顺序）。
const List<TerminalPalette> kTerminalPalettes = [
  TerminalPalette(
    id: kDefaultTerminalPalette,
    labelZh: '默认（青）',
    labelEn: 'Default (teal)',
    dark: _appDark,
    light: _appLight,
  ),
  TerminalPalette(
    id: 'one-dark',
    labelZh: 'One Dark',
    labelEn: 'One Dark',
    dark: _oneDark,
  ),
  TerminalPalette(
    id: 'dracula',
    labelZh: 'Dracula',
    labelEn: 'Dracula',
    dark: _dracula,
  ),
  TerminalPalette(
    id: 'solarized',
    labelZh: 'Solarized',
    labelEn: 'Solarized',
    dark: _solarizedDark,
    light: _solarizedLight,
  ),
  TerminalPalette(
    id: 'gruvbox',
    labelZh: 'Gruvbox',
    labelEn: 'Gruvbox',
    dark: _gruvbox,
  ),
];

/// 按 id 取配色；未设置或未知 id 回落到默认，绝不抛异常
/// （设置项可能被旧版本写成任意值，配色拿不到不能把终端搞崩）。
TerminalPalette terminalPaletteById(String? id) {
  for (final p in kTerminalPalettes) {
    if (p.id == id) return p;
  }
  return kTerminalPalettes.first;
}

/// 解析实际生效的主题：亮色模式下若该配色没有亮色变体，回落到内置亮色。
xterm.TerminalTheme resolveTerminalTheme({
  required String? paletteId,
  required bool isLight,
}) {
  final palette = terminalPaletteById(paletteId);
  if (!isLight) return palette.dark;
  return palette.light ?? kTerminalPalettes.first.light!;
}

/// 配色卡片上的色板预览：8 个基础 ANSI 色。纯函数便于单测。
List<Color> paletteSwatches(TerminalPalette palette, {required bool isLight}) {
  final theme = isLight ? (palette.light ?? _appLight) : palette.dark;
  return [
    theme.black,
    theme.red,
    theme.green,
    theme.yellow,
    theme.blue,
    theme.magenta,
    theme.cyan,
    theme.white,
  ];
}
