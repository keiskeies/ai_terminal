import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../core/constants.dart';
import '../core/terminal_themes.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../providers/app_providers.dart';
import '../services/daos.dart';

/// 终端配色 + 字号的即时调整区（顶栏浮层和设置 · 外观共用同一份）。
///
/// 设计取舍（这是它存在的理由）：
/// 配色是**即时即用**的东西 —— 用户不知道自己想要哪套，只能挨个切过去看。
/// 所以①入口摆在终端顶栏上（一次点击，不用进设置）；②必须有一块**真的按
/// 当前配色渲染的终端输出预览**。只列八个配色名字、旁边点几个 8px 色块，
/// 等于让用户靠想象力做决定 —— 那是把「选配色」变成了「背名字」。
///
/// 浮层一变，背后的终端同步变，这才叫看到效果。
class TerminalAppearancePanel extends ConsumerWidget {
  const TerminalAppearancePanel({
    super.key,
    required this.onMore,
    this.width = 372,
  });

  /// 打开「设置 · 外观」（主题深浅 / 回滚行数 / 会话日志 / 快捷键）。
  /// 那些是一件事配一次、配完不再动的，不该挂在终端顶栏上。
  final VoidCallback onMore;

  final double width;

  /// 4 列、间距 8：卡片宽由浮层宽度反推（这里不能用 LayoutBuilder，
  /// 见 [TerminalPaletteGrid] 的说明）。
  static const double _pad = 12;
  static const double _gap = 8;
  static const int _cols = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tc = ThemeColors.of(context);
    final isLight = tc.isLight;
    final paletteId = ref.watch(
        settingsProvider.select((s) => s['terminalPalette'] as String?));
    final fontSize =
        (ref.watch(settingsProvider.select(
                    (s) => s['terminalFontSize'] as num?)) ??
                13)
            .toDouble();
    final theme = resolveTerminalTheme(
        paletteId: paletteId, isLight: isLight);

    Future<void> save(String key, dynamic value) async {
      await SettingsDao.set(key, value);
      ref.read(settingsProvider.notifier).setSetting(key, value);
    }

    // 步进时现场从 provider 读当前值，不闭包捕获 build 时的 fontSize：
    // 连点两下「+」如果两下落在同一帧，捕获的旧值会让第二下白点。
    Future<void> stepFont(int delta) async {
      final cur =
          (ref.read(settingsProvider)['terminalFontSize'] as num?)?.toInt() ?? 13;
      final next = (cur + delta).clamp(8, 24);
      if (next != cur) await save('terminalFontSize', next);
    }

    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.all(_pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TerminalPalettePreview(theme: theme, fontSize: fontSize),
            const SizedBox(height: 12),
            TerminalPaletteGrid(
              paletteId: paletteId,
              isLight: isLight,
              spacing: _gap,
              chipWidth: (width - _pad * 2 - _gap * (_cols - 1)) / _cols,
              onSelect: (id) => save('terminalPalette', id),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: tc.hairline),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(UiText.t('字号', 'Font size'),
                    style: TextStyle(fontSize: fSmall, color: tc.textSub)),
                const Spacer(),
                _StepButton(
                  icon: Icons.remove,
                  onTap: fontSize <= 8 ? null : () => stepFont(-1),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    '${fontSize.toInt()} px',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: fSmall,
                      color: tc.textMain,
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: kMonoFontFallback,
                    ),
                  ),
                ),
                _StepButton(
                  icon: Icons.add,
                  onTap: fontSize >= 24 ? null : () => stepFont(1),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onMore,
                child: Text(UiText.t('外观设置', 'More appearance'),
                    style: TextStyle(fontSize: fSmall, color: tc.brand)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按给定配色真实渲染的一小段终端输出。
///
/// 刻意用真命令输出（git status）而不是「示例文字」：用户判断配色好坏，看的就是
/// 这些颜色（modify 的红、新增的绿、提示符的青、光标块）在同一屏里会不会互相压住。
class TerminalPalettePreview extends StatelessWidget {
  const TerminalPalettePreview({
    super.key,
    required this.theme,
    required this.fontSize,
  });

  final xterm.TerminalTheme theme;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final line = fontSize * 1.5;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: theme.brightBlack.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _line(line, [
            _span('~/app ', theme.cyan),
            _span('\$ ', theme.foreground),
            _span('git status', theme.foreground),
          ]),
          _line(line, [
            _span('On branch ', theme.foreground),
            _span('main', theme.green),
          ]),
          _line(line, [
            _span('  modified:   ', theme.foreground),
            _span('lib/app.dart', theme.red),
          ]),
          _line(line, [
            _span('  new file:   ', theme.foreground),
            _span('docs/README.md', theme.green),
          ]),
          _line(line, [
            _span('\$ ', theme.foreground),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                width: fontSize * 0.55,
                height: fontSize * 1.05,
                color: theme.cursor,
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _line(double height, List<InlineSpan> spans) {
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(children: spans),
          maxLines: 1,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.2,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: kMonoFontFallback,
          ),
        ),
      ),
    );
  }

  TextSpan _span(String text, Color color) =>
      TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize));
}

/// 配色选择器：每套配色画成**一小块真终端**（自己的底色 + 红绿黄蓝四条 + 名字），
/// 而不是「白底上一行文字 + 几个色点」。
///
/// 色点在 8px 大小下只能看出色相，看不出背景与前景的搭配，而搭配恰恰是选配色时
/// 唯一要判断的东西。
///
/// 卡片宽度由调用方给定：这个组件会出现在 MenuAnchor 的浮层里，而浮层用
/// [IntrinsicWidth] 量宽度 —— LayoutBuilder 拿不到内在尺寸，会直接抛
/// 「LayoutBuilder does not support returning intrinsic dimensions」。
class TerminalPaletteGrid extends StatelessWidget {
  const TerminalPaletteGrid({
    super.key,
    required this.paletteId,
    required this.isLight,
    required this.onSelect,
    required this.chipWidth,
    this.spacing = 8,
    this.chipHeight = 54,
  });

  final String? paletteId;
  final bool isLight;
  final ValueChanged<String> onSelect;
  final double chipWidth;
  final double spacing;
  final double chipHeight;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final p in kTerminalPalettes)
          _PaletteChip(
            palette: p,
            label: p.label(isZh: UiText.zh),
            isLight: isLight,
            width: chipWidth,
            height: chipHeight,
            selected: p.id == (paletteId ?? kDefaultTerminalPalette),
            // 亮色模式下这套配色只有暗色版本 —— 选了会回落成默认亮色，
            // 直接在卡片上标出来，比选完再解释一句强。
            fallback: isLight && p.light == null,
            onTap: () => onSelect(p.id),
          ),
      ],
    );
  }
}

class _PaletteChip extends StatelessWidget {
  const _PaletteChip({
    required this.palette,
    required this.label,
    required this.isLight,
    required this.width,
    required this.height,
    required this.selected,
    required this.fallback,
    required this.onTap,
  });

  final TerminalPalette palette;
  final String label;
  final bool isLight;
  final double width;
  final double height;
  final bool selected;
  final bool fallback;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final theme = isLight
        ? (palette.light ?? kTerminalPalettes.first.light!)
        : palette.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: animFast,
        width: width,
        height: height,
        padding: const EdgeInsets.fromLTRB(7, 6, 7, 5),
        decoration: BoxDecoration(
          color: theme.background,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(
            color: selected ? tc.brand : tc.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 红 / 绿 / 黄 / 蓝：终端里最常出现的一组对比
            Row(
              children: [
                for (final c in [theme.red, theme.green, theme.yellow, theme.blue])
                  Container(
                    width: 9,
                    height: 3,
                    margin: const EdgeInsets.only(right: 2, top: 1),
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
              ],
            ),
            Text(
              label,
              // 名字允许折两行：「Catppuccin Mocha」在 81px 宽里一行放不下，
              // 截成「Catppuccin …」等于没给名字。
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                height: 1.15,
                color: theme.foreground,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (fallback)
              Text(
                UiText.t('仅暗色', 'Dark only'),
                maxLines: 1,
                style:
                    TextStyle(fontSize: 8, height: 1.1, color: theme.brightBlack),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: onTap == null ? tc.hairline : tc.border),
        ),
        child:
            Icon(icon, size: 14, color: onTap == null ? tc.textMuted : tc.textSub),
      ),
    );
  }
}
