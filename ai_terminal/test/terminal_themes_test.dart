import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/terminal_themes.dart';

void main() {
  group('terminalPaletteById', () {
    test('已知 id 命中对应配色', () {
      expect(terminalPaletteById('dracula').id, 'dracula');
      expect(terminalPaletteById('solarized').id, 'solarized');
    });

    test('null 与未知 id 回落到默认，不抛异常', () {
      expect(terminalPaletteById(null).id, kDefaultTerminalPalette);
      expect(terminalPaletteById('not-a-palette').id, kDefaultTerminalPalette);
      expect(terminalPaletteById('').id, kDefaultTerminalPalette);
    });
  });

  group('resolveTerminalTheme', () {
    test('暗色模式取配色自己的暗色主题', () {
      expect(
        resolveTerminalTheme(paletteId: 'dracula', isLight: false).background,
        terminalPaletteById('dracula').dark.background,
      );
    });

    test('亮色模式取亮色变体', () {
      expect(
        resolveTerminalTheme(paletteId: 'solarized', isLight: true).background,
        terminalPaletteById('solarized').light!.background,
      );
    });

    test('只有暗色版本的配色在亮色模式回落到内置亮色', () {
      final fallback = resolveTerminalTheme(
        paletteId: 'one-dark',
        isLight: true,
      );
      expect(terminalPaletteById('one-dark').light, isNull);
      expect(
        fallback.background,
        terminalPaletteById(kDefaultTerminalPalette).light!.background,
      );
      // 回落必须是亮底，否则亮色模式下选 One Dark 会得到深色背景
      final luminance = fallback.background.computeLuminance();
      expect(luminance, greaterThan(0.5));
    });

    test('默认配色的暗色主题与改动前一致（防止误改品牌色）', () {
      final dark = terminalPaletteById(kDefaultTerminalPalette).dark;
      expect(dark.background.toARGB32(), 0xFF040707);
      expect(dark.cursor.toARGB32(), 0xFF45C8C3);
    });
  });

  group('配色完整性', () {
    test('每个配色都有亮色可读的背景/前景对比', () {
      for (final palette in kTerminalPalettes) {
        final light = palette.light;
        if (light == null) continue;
        final contrast = _contrast(
          light.background.computeLuminance(),
          light.foreground.computeLuminance(),
        );
        expect(contrast, greaterThan(3.0), reason: '${palette.id} 亮色前景与背景对比过低');
      }
    });

    test('暗色配色的前景在其背景上可读', () {
      for (final palette in kTerminalPalettes) {
        final dark = palette.dark;
        final contrast = _contrast(
          dark.background.computeLuminance(),
          dark.foreground.computeLuminance(),
        );
        expect(contrast, greaterThan(4.0), reason: '${palette.id} 暗色前景与背景对比过低');
      }
    });

    test('搜索高亮色不与背景同色（否则搜到的命中看不见）', () {
      for (final palette in kTerminalPalettes) {
        final themes = [
          palette.dark,
          if (palette.light != null) palette.light!
        ];
        for (final theme in themes) {
          expect(theme.searchHitBackground, isNot(theme.background),
              reason: '${palette.id} 搜索命中底色与终端底色相同');
        }
      }
    });
  });

  group('paletteSwatches', () {
    test('返回 8 个基础 ANSI 色且顺序为黑红绿黄蓝紫青白', () {
      final palette = terminalPaletteById('dracula');
      final swatches = paletteSwatches(palette, isLight: false);
      expect(swatches, [
        palette.dark.black,
        palette.dark.red,
        palette.dark.green,
        palette.dark.yellow,
        palette.dark.blue,
        palette.dark.magenta,
        palette.dark.cyan,
        palette.dark.white,
      ]);
    });

    test('亮色模式取亮色变体的色板', () {
      final palette = terminalPaletteById('solarized');
      expect(paletteSwatches(palette, isLight: true), [
        palette.light!.black,
        palette.light!.red,
        palette.light!.green,
        palette.light!.yellow,
        palette.light!.blue,
        palette.light!.magenta,
        palette.light!.cyan,
        palette.light!.white,
      ]);
    });

    test('无亮色变体的配色在亮色模式下用内置亮色色板', () {
      expect(
        paletteSwatches(terminalPaletteById('gruvbox'), isLight: true),
        paletteSwatches(terminalPaletteById(kDefaultTerminalPalette),
            isLight: true),
      );
    });
  });
}

/// WCAG 对比度
double _contrast(double a, double b) {
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}
