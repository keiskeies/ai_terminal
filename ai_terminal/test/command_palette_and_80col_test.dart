import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/pages/terminal_page.dart';
import 'package:ai_terminal/widgets/command_palette.dart';

/// 命令面板检索 + 80 列保护这两条纯逻辑的契约测试。
void main() {
  CommandPaletteEntry e(String label, {String group = '', List<String> kw = const []}) =>
      CommandPaletteEntry(label: label, group: group, keywords: kw, onRun: () {});

  group('rankPaletteEntries', () {
    final entries = [
      e('web 生产机', group: '主机', kw: ['10.0.0.8']),
      e('查看磁盘', group: '快捷命令'),
      e('设置', group: '页面', kw: ['settings']),
      e('专注模式', group: '操作'),
    ];

    test('空前缀按原序返回全部', () {
      expect(rankPaletteEntries(entries, '').length, entries.length);
    });

    test('前缀命中排在子串命中之前', () {
      final r = rankPaletteEntries(entries, '设');
      expect(r.first.entry.label, '设置');
    });

    test('别名关键字可命中', () {
      final r = rankPaletteEntries(entries, 'settings');
      expect(r.map((m) => m.entry.label), contains('设置'));
    });

    test('无匹配返回空', () {
      expect(rankPaletteEntries(entries, 'zzzzqqq'), isEmpty);
    });

    test('同分组只有首条标记 showGroup', () {
      final two = [e('a', group: 'G'), e('b', group: 'G')];
      final r = rankPaletteEntries(two, '');
      expect(r[0].showGroup, isTrue);
      expect(r[1].showGroup, isFalse);
    });
  });

  group('aiPanelSizeFor 80 列保护', () {
    // 14px 字号：minTerm ≈ 14*0.62*80+24 = 713.6
    test('宽窗口下比例正常生效', () {
      final s = aiPanelSizeFor(
        totalExtent: 2000,
        ratio: 0.4,
        enforce80Cols: true,
        fontSize: 14,
        minRatio: 0.15,
        maxRatio: 0.7,
      );
      expect(s, closeTo(800, 0.01));
    });

    test('窄窗口下面板封顶，终端剩余不低于 80 列宽', () {
      const total = 1000.0;
      final s = aiPanelSizeFor(
        totalExtent: total,
        ratio: 0.7,
        enforce80Cols: true,
        fontSize: 14,
        minRatio: 0.15,
        maxRatio: 0.7,
      );
      expect(total - s, greaterThanOrEqualTo(minTerminalWidthForFontSize(14) - 0.01));
      expect(s, lessThan(total * 0.7));
    });

    test('窗口放不下 80 列 + 最小面板时优先给终端', () {
      const total = 700.0; // < 80 列所需 713.6
      final s = aiPanelSizeFor(
        totalExtent: total,
        ratio: 0.7,
        enforce80Cols: true,
        fontSize: 14,
        minRatio: 0.15,
        maxRatio: 0.7,
      );
      expect(s, closeTo(total * 0.15, 0.01));
    });

    test('纵向（bottom 布局）不做 80 列约束', () {
      final s = aiPanelSizeFor(
        totalExtent: 1000,
        ratio: 0.7,
        enforce80Cols: false,
        fontSize: 14,
        minRatio: 0.15,
        maxRatio: 0.7,
      );
      expect(s, closeTo(700, 0.01));
    });
  });
}
