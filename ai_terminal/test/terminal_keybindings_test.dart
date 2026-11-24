import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/terminal_keybindings.dart';

/// 断言里写人读的快捷键串，比较时换成 KeyBinding（相等按 serialized 判）
Set<KeyBinding> _b(Iterable<String> raw) =>
    {for (final s in raw) parseKeyBinding(s)!};

void main() {
  group('parseKeyBinding', () {
    test('字母要写全名，也接受裸字母', () {
      expect(parseKeyBinding('ctrl+keyF')!.keyName, 'keyF');
      expect(parseKeyBinding('ctrl+f')!.keyName, 'keyF');
      expect(parseKeyBinding('CTRL+SHIFT+F'), isNotNull);
    });

    test('修饰键按位置解析，顺序不影响结果', () {
      final a = parseKeyBinding('ctrl+shift+f')!;
      final b = parseKeyBinding('shift+ctrl+f')!;
      expect(a.ctrl, isTrue);
      expect(a.shift, isTrue);
      expect(a.alt, isFalse);
      expect(a.meta, isFalse);
      expect(a, b);
    });

    test('无修饰键的组合照样能解析（校验才拦）', () {
      expect(parseKeyBinding('f')!.hasModifier, isFalse);
    });

    test('未知键、空串、重复修饰键解析为 null', () {
      expect(parseKeyBinding('ctrl+volumeUp'), isNull);
      expect(parseKeyBinding(''), isNull);
      expect(parseKeyBinding('ctrl+ctrl+f'), isNull);
      expect(parseKeyBinding('ctrl+'), isNull);
    });

    test('数字与数字小键盘分开', () {
      expect(parseKeyBinding('ctrl+0')!.keyName, 'digit0');
      expect(parseKeyBinding('ctrl+numpad0')!.keyName, 'numpad0');
    });

    test('往返序列化稳定', () {
      for (final raw in [
        'ctrl+shift+f',
        'meta+shift+h',
        'ctrl+numpadSubtract',
        'alt+f12',
      ]) {
        final binding = parseKeyBinding(raw)!;
        expect(parseKeyBinding(binding.serialized), binding);
      }
    });
  });

  group('默认快捷键', () {
    test('每个动作都有默认值', () {
      for (final action in TerminalKeyAction.values) {
        expect(kDefaultTerminalKeybindings[action], isNotEmpty,
            reason: '$action 没有默认快捷键');
      }
    });

    test('既有习惯一个都不能丢（回归基线）', () {
      final map = TerminalKeymap.fromSettings(null);
      Set<KeyBinding> bindings(TerminalKeyAction a) =>
          map.bindingsFor(a).toSet();
      expect(bindings(TerminalKeyAction.paste),
          containsAll(_b(<String>{'ctrl+v', 'meta+v'})));
      expect(bindings(TerminalKeyAction.search),
          containsAll(_b(<String>{'ctrl+shift+f', 'meta+f'})));
      expect(bindings(TerminalKeyAction.commandHistory),
          containsAll(_b(<String>{'ctrl+shift+h', 'meta+shift+h'})));
      expect(
          bindings(TerminalKeyAction.zoomIn),
          containsAll(_b(<String>{
            'ctrl+equal',
            'ctrl+add',
            'ctrl+numpadAdd',
            'meta+equal',
            'meta+add',
            'meta+numpadAdd'
          })));
      expect(
          bindings(TerminalKeyAction.zoomOut),
          containsAll(_b(<String>{
            'ctrl+minus',
            'ctrl+numpadSubtract',
            'meta+minus',
            'meta+numpadSubtract'
          })));
      expect(bindings(TerminalKeyAction.zoomReset),
          containsAll(_b(<String>{'ctrl+digit0', 'ctrl+numpad0'})));
    });

    test('默认表里没有任何一条会抢裸键', () {
      for (final entry in kDefaultTerminalKeybindings.entries) {
        for (final b in entry.value) {
          expect(b.hasModifier, isTrue,
              reason: '${entry.key.id} 的 ${b.serialized} 是裸键');
        }
      }
    });

    test('同一个组合不会被两个默认动作同时占用', () {
      final seen = <String, TerminalKeyAction>{};
      for (final entry in kDefaultTerminalKeybindings.entries) {
        for (final b in entry.value) {
          final owner = seen[b.serialized];
          expect(owner, isNull,
              reason: '${b.serialized} 同时属于 ${owner?.id} 和 ${entry.key.id}');
          seen[b.serialized] = entry.key;
        }
      }
    });
  });

  group('TerminalKeymap.fromSettings', () {
    test('null / 非法形状一律回落到默认', () {
      for (final raw in [null, 42, 'x', <String, Object?>{}, 'not-a-map']) {
        final map = TerminalKeymap.fromSettings(raw);
        expect(map.bindingsFor(TerminalKeyAction.search),
            kDefaultTerminalKeybindings[TerminalKeyAction.search]);
      }
    });

    test('覆盖某个动作不影响其它动作', () {
      final map = TerminalKeymap.fromSettings({
        'search': ['ctrl+alt+keyF'],
      });
      expect(map.bindingsFor(TerminalKeyAction.search).single.serialized,
          'ctrl+alt+keyF');
      expect(map.bindingsFor(TerminalKeyAction.commandHistory),
          kDefaultTerminalKeybindings[TerminalKeyAction.commandHistory]);
    });

    test('空数组 = 解绑', () {
      final map = TerminalKeymap.fromSettings({
        'search': <Object?>[],
      });
      expect(map.bindingsFor(TerminalKeyAction.search), isEmpty);
      expect(
        map.actionFor(
          keyId: LogicalKeyboardKey.keyF.keyId,
          ctrl: true,
          shift: true,
          alt: false,
          meta: false,
        ),
        isNull,
      );
    });

    test('未知动作 id 与坏值被忽略，不会污染其它动作', () {
      final map = TerminalKeymap.fromSettings({
        'no-such-action': ['ctrl+alt+j'],
        'search': 'not-a-list',
        'zoomIn': [123, 'ctrl+alt+keyK', 'garbage++'],
      });
      expect(map.bindingsFor(TerminalKeyAction.search),
          kDefaultTerminalKeybindings[TerminalKeyAction.search]);
      expect(
        map.bindingsFor(TerminalKeyAction.zoomIn).map((b) => b.serialized),
        ['ctrl+alt+keyK'],
      );
    });
  });

  group('TerminalKeymap.actionFor', () {
    final map = TerminalKeymap.fromSettings(null);

    TerminalKeyAction? hit(LogicalKeyboardKey key,
            {bool ctrl = false,
            bool shift = false,
            bool alt = false,
            bool meta = false}) =>
        map.actionFor(
            keyId: key.keyId, ctrl: ctrl, shift: shift, alt: alt, meta: meta);

    test('命中默认组合', () {
      expect(hit(LogicalKeyboardKey.keyF, ctrl: true, shift: true),
          TerminalKeyAction.search);
      expect(
          hit(LogicalKeyboardKey.keyF, meta: true), TerminalKeyAction.search);
      expect(hit(LogicalKeyboardKey.keyV, ctrl: true), TerminalKeyAction.paste);
      expect(
          hit(LogicalKeyboardKey.equal, ctrl: true), TerminalKeyAction.zoomIn);
      expect(hit(LogicalKeyboardKey.numpadAdd, ctrl: true),
          TerminalKeyAction.zoomIn);
      expect(
          hit(LogicalKeyboardKey.minus, meta: true), TerminalKeyAction.zoomOut);
      expect(hit(LogicalKeyboardKey.digit0, ctrl: true),
          TerminalKeyAction.zoomReset);
    });

    test('裸键与只按 Shift 永不劫持打字', () {
      expect(hit(LogicalKeyboardKey.keyF), isNull);
      expect(hit(LogicalKeyboardKey.keyF, shift: true), isNull);
      // 单独 Shift 是很多应用的「反向 Tab」，不能变成搜索
      expect(hit(LogicalKeyboardKey.tab, shift: true), isNull);
    });

    test('修饰键必须逐个对上：多一个少一个都不算', () {
      expect(hit(LogicalKeyboardKey.keyF, ctrl: true), isNull);
      expect(hit(LogicalKeyboardKey.keyF, ctrl: true, shift: true, alt: true),
          isNull);
      expect(hit(LogicalKeyboardKey.keyH, ctrl: true), isNull);
      expect(hit(LogicalKeyboardKey.keyH, ctrl: true, shift: true),
          TerminalKeyAction.commandHistory);
    });

    test('shell 控制键没有被任何默认绑定抢走', () {
      // Ctrl+字母里只有这几个是默认绑定的（V 粘贴、F 搜索、H 历史需 Shift）
      for (final key in [
        LogicalKeyboardKey.keyA, // readline 行首
        LogicalKeyboardKey.keyC, // 中断信号
        LogicalKeyboardKey.keyD, // EOF
        LogicalKeyboardKey.keyE, // readline 行尾
        LogicalKeyboardKey.keyH, // 退格
        LogicalKeyboardKey.keyK, // readline 删到行尾
        LogicalKeyboardKey.keyL, // 清屏
        LogicalKeyboardKey.keyR, // readline 反向搜索
        LogicalKeyboardKey.keyU, // readline 删到行首
        LogicalKeyboardKey.keyZ, // 挂起
      ]) {
        expect(hit(key, ctrl: true), isNull,
            reason: 'Ctrl+${key.keyLabel} 被抢了');
      }
    });

    test('自定义后旧组合立即失效（覆盖而非追加）', () {
      final custom = TerminalKeymap.fromSettings({
        'search': ['ctrl+alt+keyF'],
      });
      expect(
        custom.actionFor(
            keyId: LogicalKeyboardKey.keyF.keyId,
            ctrl: true,
            shift: true,
            alt: false,
            meta: false),
        isNull,
      );
      expect(
        custom.actionFor(
            keyId: LogicalKeyboardKey.keyF.keyId,
            ctrl: true,
            shift: false,
            alt: true,
            meta: false),
        TerminalKeyAction.search,
      );
    });

    test('表外的键不参与匹配', () {
      expect(hit(LogicalKeyboardKey.f13, ctrl: true, alt: true), isNull);
    });
  });

  group('validateKeyBinding', () {
    KeyBinding b(String raw) => parseKeyBinding(raw)!;

    test('裸键被拒', () {
      expect(validateKeyBinding(b('f'), isMac: false),
          BindingVerdict.needsModifier);
      expect(validateKeyBinding(b('f'), isMac: false).isBlocking, isTrue);
    });

    test('表外的键被拒', () {
      expect(
        validateKeyBinding(
          const KeyBinding(keyName: 'volumeUp', ctrl: true),
          isMac: false,
        ),
        BindingVerdict.unsupportedKey,
      );
    });

    test('Ctrl+字母只提示不拦（粘贴本来就绑 Ctrl+V）', () {
      final verdict = validateKeyBinding(b('ctrl+j'), isMac: false);
      expect(verdict, BindingVerdict.shadowShellControlKey);
      expect(verdict.isBlocking, isFalse);
      // Ctrl+Shift+字母 在 xterm 里发出的还是同一个控制字节，照样提示；
      // Ctrl+Alt+字母 发的是 ESC 前缀，不是控制字节，就不打扰
      expect(validateKeyBinding(b('ctrl+shift+j'), isMac: false),
          BindingVerdict.shadowShellControlKey);
      expect(
          validateKeyBinding(b('ctrl+alt+j'), isMac: false), BindingVerdict.ok);
    });

    test('Ctrl+Shift+C（复制）与裸 ⌘W 之类系统键被硬拦', () {
      expect(validateKeyBinding(b('ctrl+shift+c'), isMac: false),
          BindingVerdict.copyConflict);
      expect(BindingVerdict.copyConflict.isBlocking, isTrue);
      for (final raw in ['meta+w', 'meta+q', 'meta+h', 'meta+m']) {
        expect(validateKeyBinding(b(raw), isMac: true),
            BindingVerdict.systemReserved);
      }
      // 同样这些在非 mac 上不是系统键
      expect(validateKeyBinding(b('meta+w'), isMac: false), BindingVerdict.ok);
      // 加了 Shift 就不是系统键（⌘⇧H 是命令历史的默认值）
      expect(validateKeyBinding(b('meta+shift+h'), isMac: true),
          BindingVerdict.ok);
    });

    test('每一条默认快捷键都能通过自己的校验', () {
      for (final isMac in [false, true]) {
        for (final entry in kDefaultTerminalKeybindings.entries) {
          for (final binding in entry.value) {
            final verdict = validateKeyBinding(binding, isMac: isMac);
            expect(verdict.isBlocking, isFalse,
                reason:
                    '${entry.key.id} 的默认值 ${binding.serialized} 在 isMac=$isMac 下被判为 ${verdict.name}');
          }
        }
      }
    });
  });

  group('展示', () {
    test('mac 用字形、其余用全名', () {
      final binding = parseKeyBinding('ctrl+shift+f')!;
      expect(binding.label(isMac: true), '⌃⇧F');
      expect(parseKeyBinding('meta+f')!.label(isMac: true), '⌘F');
      expect(binding.label(isMac: false), 'Ctrl+Shift+F');
      expect(parseKeyBinding('meta+f')!.label(isMac: false), 'Win+F');
    });

    test('动作有中英文标签，且 id 稳定（设置存的是 id）', () {
      for (final action in TerminalKeyAction.values) {
        expect(action.label(isZh: true), isNotEmpty);
        expect(action.label(isZh: false), isNotEmpty);
        expect(TerminalKeyAction.byId(action.id), action);
      }
      expect(TerminalKeyAction.byId('nope'), isNull);
    });

    test('拒绝理由都有双语文案（ok 之外）', () {
      for (final verdict in BindingVerdict.values) {
        if (verdict == BindingVerdict.ok) continue;
        expect(bindingVerdictLabel(verdict, isZh: true), isNotEmpty);
        expect(bindingVerdictLabel(verdict, isZh: false), isNotEmpty);
      }
    });
  });

  group('覆盖表增删改（设置页只调这几个函数）', () {
    const search = TerminalKeyAction.search;

    test('normalizeOverrides 容忍字符串 JSON、坏值与重复组合', () {
      expect(normalizeOverrides('{"search":["ctrl+alt+g","ctrl+alt+g"]}'), {
        'search': ['ctrl+alt+keyG']
      });
      expect(normalizeOverrides('not json'), isEmpty);
      expect(
          normalizeOverrides({
            'nope': ['ctrl+alt+j']
          }),
          isEmpty);
      expect(normalizeOverrides({'search': 'not-a-list'}), isEmpty);
      expect(
          normalizeOverrides({
            'search': ['garbage', 'ctrl+alt+g']
          }).values.single,
          ['ctrl+alt+keyG']);
    });

    test('在默认表上加一条：默认那几条都留着', () {
      final next = addBinding(const {}, search, parseKeyBinding('ctrl+alt+g')!);
      final effective = effectiveBindingStrings(next, search);
      expect(effective, contains('ctrl+alt+keyG'));
      expect(
          effective,
          containsAll(
              kDefaultTerminalKeybindings[search]!.map((b) => b.serialized)));
    });

    test('原位替换一条不动其它组合', () {
      final old = parseKeyBinding('ctrl+shift+f')!;
      final next = addBinding(const {}, search, parseKeyBinding('ctrl+alt+g')!,
          replace: old);
      final effective = effectiveBindingStrings(next, search);
      expect(effective, isNot(contains(old.serialized)));
      // mac 的 ⌘F 是另一条默认，不该被牵连
      expect(effective,
          contains(kDefaultTerminalKeybindings[search]!.last.serialized));
    });

    test('删到与默认一致时把覆盖整条撤掉（不留无意义覆盖）', () {
      final added =
          addBinding(const {}, search, parseKeyBinding('ctrl+alt+g')!);
      final back = removeBinding(added, search, parseKeyBinding('ctrl+alt+g')!);
      expect(back.containsKey('search'), isFalse);
      expect(effectiveBindingStrings(back, search),
          kDefaultTerminalKeybindings[search]!.map((b) => b.serialized));
    });

    test('清空一个动作 = 空数组覆盖，而不是删掉覆盖项', () {
      var overrides = const <String, List<String>>{};
      for (final b in TerminalKeymap.defaults.bindingsFor(search)) {
        overrides = removeBinding(overrides, search, b);
      }
      expect(overrides['search'], isEmpty);
      expect(
          TerminalKeymap.fromSettings(overrides).bindingsFor(search), isEmpty);
    });

    test('恢复默认清掉覆盖', () {
      final added =
          addBinding(const {}, search, parseKeyBinding('ctrl+alt+g')!);
      expect(resetAction(added, search), isEmpty);
    });

    test('改一个动作不碰别人的覆盖', () {
      final history = addBinding(const {}, TerminalKeyAction.commandHistory,
          parseKeyBinding('alt+f9')!);
      final withSearch =
          addBinding(history, search, parseKeyBinding('alt+f8')!);
      expect(withSearch.keys.toSet(), {'commandHistory', 'search'});
      expect(withSearch['commandHistory'], history['commandHistory']);
    });

    test('写入函数不改入参（UI 直接拿返回值 setState）', () {
      const original = {
        'search': ['ctrl+alt+keyG']
      };
      removeBinding(original, search, parseKeyBinding('ctrl+alt+g')!);
      addBinding(original, search, parseKeyBinding('alt+f7')!);
      expect(original, {
        'search': ['ctrl+alt+keyG']
      });
    });
  });

  group('可绑定键表', () {
    test('名字唯一且都能被解析回来', () {
      final names = kBindableKeys.map((k) => k.name).toList();
      expect(names.toSet().length, names.length);
      for (final k in kBindableKeys) {
        expect(bindableKeyId(k.name), k.keyId);
        expect(keyLabel(k.name), k.label);
      }
    });

    test('字母 26 个、数字 10 个、功能键 12 个', () {
      expect(kBindableKeys.where((k) => k.name.startsWith('key')).length, 26);
      expect(kBindableKeys.where((k) => k.name.startsWith('digit')).length, 10);
      expect(
          kBindableKeys.where((k) => k.name.startsWith('numpad')).length, 12);
      expect(
          kBindableKeys.where((k) => RegExp(r'^f\d+$').hasMatch(k.name)).length,
          12);
    });
  });
}
