import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/quick_keys.dart';

void main() {
  group('底部快捷栏键位顺序（常用优先）', () {
    List<String> labels() => kQuickKeys.map((k) => k.label).toList();

    test('前 8 个是 ESC/Tab/方向/Home/End', () {
      expect(labels().take(8).toList(),
          ['ESC', 'Tab', '↑', '↓', '←', '→', 'Home', 'End']);
    });

    test('修饰键紧跟其后', () {
      expect(labels().sublist(8, 11), ['Ctrl', 'Shift', 'Alt']);
    });

    test('没有 Ins：ESC[2~ 只改 shell 编辑模式，复制/粘贴走长按菜单', () {
      expect(labels(), isNot(contains('Ins')));
    });

    test('常见 Ctrl 组合仍在表内（只是排到后面）', () {
      final ls = labels();
      for (final k in ['⌃C', '⌃D', '⌃Z', '⌃L', '⌃A', '⌃E', '⌃U', '⌃K', '⌃W', '⌃R']) {
        expect(ls, contains(k));
      }
    });

    test('方向键 / Home / End 有正确的 VT 序列', () {
      Map<String, String> seq = {
        for (final k in kQuickKeys) k.label: k.sequence
      };
      expect(seq['↑'], '\x1b[A');
      expect(seq['↓'], '\x1b[B');
      expect(seq['←'], '\x1b[D');
      expect(seq['→'], '\x1b[C');
      expect(seq['Home'], '\x1b[H');
      expect(seq['End'], '\x1b[F');
      expect(seq['ESC'], '\x1b');
      expect(seq['Tab'], '\t');
    });

    test('只有 Ctrl/Shift/Alt 是修饰键', () {
      final mods =
          kQuickKeys.where((k) => k.isModifier).map((k) => k.modifier).toList();
      expect(mods, ['ctrl', 'shift', 'alt']);
    });

    test('只有四个方向键标记为加宽', () {
      final wide =
          kQuickKeys.where((k) => k.wide).map((k) => k.label).toList();
      expect(wide, ['↑', '↓', '←', '→']);
    });
  });

  group('粘滞修饰键状态切换', () {
    test('toggle 只翻转目标修饰键', () {
      var s = StickyModifiers.none.toggle('ctrl');
      expect((s.ctrl, s.shift, s.alt), (true, false, false));
      s = s.toggle('alt');
      expect((s.ctrl, s.shift, s.alt), (true, false, true));
      s = s.toggle('ctrl');
      expect((s.ctrl, s.shift, s.alt), (false, false, true));
    });

    test('未知修饰键名原样返回', () {
      final s = StickyModifiers.none.toggle('hyper');
      expect(s.any, isFalse);
    });

    test('any 反映是否有任一修饰键激活', () {
      expect(StickyModifiers.none.any, isFalse);
      expect(const StickyModifiers(shift: true).any, isTrue);
    });
  });

  group('encodeWithModifiers：把普通字符编码成组合键字节', () {
    test('无修饰键返回 null（交给普通输入）', () {
      expect(encodeWithModifiers('a', StickyModifiers.none), isNull);
    });

    test('Ctrl+字母 = code & 0x1f', () {
      expect(encodeWithModifiers('a', const StickyModifiers(ctrl: true)), '\x01');
      expect(encodeWithModifiers('c', const StickyModifiers(ctrl: true)), '\x03');
      expect(encodeWithModifiers('z', const StickyModifiers(ctrl: true)), '\x1a');
      expect(encodeWithModifiers('A', const StickyModifiers(ctrl: true)), '\x01');
    });

    test('Ctrl+[ = ESC，Ctrl+] = GS', () {
      expect(encodeWithModifiers('[', const StickyModifiers(ctrl: true)), '\x1b');
      expect(encodeWithModifiers(']', const StickyModifiers(ctrl: true)), '\x1d');
    });

    test('Alt+字符加 ESC 前缀', () {
      expect(encodeWithModifiers('b', const StickyModifiers(alt: true)), '\x1bb');
    });

    test('Shift+小写字母变大写', () {
      expect(encodeWithModifiers('a', const StickyModifiers(shift: true)), 'A');
    });

    test('Ctrl+Alt 叠加：ESC 前缀 + Ctrl 主体', () {
      expect(
        encodeWithModifiers('a', const StickyModifiers(ctrl: true, alt: true)),
        '\x1b\x01',
      );
    });

    test('多字符（粘贴/IME 上屏）不参与编码', () {
      expect(encodeWithModifiers('abc', const StickyModifiers(ctrl: true)), isNull);
    });

    test('控制字符本身不叠加', () {
      expect(encodeWithModifiers('\x1b[A', const StickyModifiers(ctrl: true)),
          isNull);
    });

    test('Ctrl+非 ASCII 无法编码，返回 null', () {
      expect(encodeWithModifiers('中', const StickyModifiers(ctrl: true)), isNull);
    });
  });
}