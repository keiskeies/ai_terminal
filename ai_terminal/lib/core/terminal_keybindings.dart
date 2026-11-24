import 'dart:convert';

import 'package:flutter/services.dart';

// 终端快捷键自定义（P2「快捷键自定义」）。
///
// 只开放 **app 自己拦截** 的那几个动作（粘贴/搜索/命令历史/字号缩放）。
// 其余按键一律是 shell 语义（Ctrl+A 行首、Ctrl+C 中断、Ctrl+D EOF、
/// Ctrl+H 退格…）或 xterm 内置表（Ctrl+Shift+C 复制），不开放重绑定 ——
// 把它们抢过来只会让 shell 少键，而那类键用户其实并不想改。
///
// 修饰键用字面值（ctrl/meta/shift/alt），不做「Ctrl 在 mac 上就是 ⌘」这种
// 语义糖：默认表里把两个平台的习惯各写一条（`ctrl+shift+f` 与 `meta+f`），
// 谁按了哪个键就是哪个修饰，读取路径不必再分平台。
/// 可重绑定的动作
enum TerminalKeyAction {
  paste('paste', '粘贴（多行需确认）', 'Paste (multi-line confirmed)'),
  search('search', '终端内搜索', 'Search in terminal'),
  commandHistory('commandHistory', '命令历史', 'Command history'),
  zoomIn('zoomIn', '放大字号', 'Increase font size'),
  zoomOut('zoomOut', '缩小字号', 'Decrease font size'),
  zoomReset('zoomReset', '重置字号', 'Reset font size'),
  splitVertical('splitVertical', '左右分屏', 'Split left/right'),
  splitHorizontal('splitHorizontal', '上下分屏', 'Split top/bottom'),
  closePane('closePane', '关闭当前分屏', 'Close this pane'),
  focusNextPane('focusNextPane', '焦点到下一个分屏', 'Focus next pane'),
  focusPrevPane('focusPrevPane', '焦点到上一个分屏', 'Focus previous pane');

  const TerminalKeyAction(this.id, this.labelZh, this.labelEn);

  final String id;
  final String labelZh;
  final String labelEn;

  String label({required bool isZh}) => isZh ? labelZh : labelEn;

  static TerminalKeyAction? byId(String id) {
    for (final action in values) {
      if (action.id == id) return action;
    }
    return null;
  }
}

/// 一条快捷键：主键 + 修饰键组合。
///
/// 主键用可序列化的名字（`keyF`/`numpadAdd`/`arrowUp`）而不是 `LogicalKeyboardKey`
/// 的整型 id —— 设置要落盘、要跨版本读回来，裸 id 一改就是静默失效。
class KeyBinding {
  const KeyBinding({
    required this.keyName,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final String keyName;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  bool get hasModifier => ctrl || shift || alt || meta;

  /// `ctrl+shift+f` —— 顺序固定，便于比较与去重
  String get serialized {
    final parts = <String>[
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (meta) 'meta',
      keyName,
    ];
    return parts.join('+');
  }

  /// 展示文案：mac 用苹果那套字形，其余平台写全名
  String label({required bool isMac}) {
    final key = keyLabel(keyName);
    if (!isMac) {
      return [
        if (ctrl) 'Ctrl',
        if (alt) 'Alt',
        if (shift) 'Shift',
        if (meta) 'Win',
        key,
      ].join('+');
    }
    return [
      if (ctrl) '⌃',
      if (alt) '⌥',
      if (shift) '⇧',
      if (meta) '⌘',
      key,
    ].join();
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBinding && other.serialized == serialized;

  @override
  int get hashCode => serialized.hashCode;

  @override
  String toString() => serialized;
}

/// 主键表：名字 → 逻辑键，以及展示用的短标签。
///
/// 只列「加了修饰键之后 shell 不会用到」的键。表里没有的键视为不可绑定，
/// 这样录制对话框遇到媒体键、音量键之类的怪键能直接拒绝，而不是存进去
/// 之后发现永远匹配不上。
class BindableKey {
  const BindableKey(this.name, this.label, this.keyId);

  final String name;
  final String label;
  final int keyId;
}

final List<BindableKey> kBindableKeys = [
  for (var i = 0; i < 26; i++)
    BindableKey(
      'key${String.fromCharCode(65 + i)}',
      String.fromCharCode(65 + i),
      _letters[i].keyId,
    ),
  for (var i = 0; i < 10; i++) BindableKey('digit$i', '$i', _digits[i].keyId),
  for (var i = 0; i < 10; i++)
    BindableKey('numpad$i', 'Num $i', _numpadDigits[i].keyId),
  for (var i = 1; i <= 12; i++)
    BindableKey('f$i', 'F$i', _functionKeys[i - 1].keyId),
  BindableKey('numpadAdd', 'Num +', LogicalKeyboardKey.numpadAdd.keyId),
  BindableKey(
      'numpadSubtract', 'Num -', LogicalKeyboardKey.numpadSubtract.keyId),
  BindableKey('equal', '=', LogicalKeyboardKey.equal.keyId),
  BindableKey('add', '+', LogicalKeyboardKey.add.keyId),
  BindableKey('minus', '-', LogicalKeyboardKey.minus.keyId),
  BindableKey('bracketLeft', '[', LogicalKeyboardKey.bracketLeft.keyId),
  BindableKey('bracketRight', ']', LogicalKeyboardKey.bracketRight.keyId),
  BindableKey('semicolon', ';', LogicalKeyboardKey.semicolon.keyId),
  BindableKey('comma', ',', LogicalKeyboardKey.comma.keyId),
  BindableKey('period', '.', LogicalKeyboardKey.period.keyId),
  BindableKey('slash', '/', LogicalKeyboardKey.slash.keyId),
  BindableKey('backslash', r'\', LogicalKeyboardKey.backslash.keyId),
  BindableKey('quote', "'", LogicalKeyboardKey.quote.keyId),
  BindableKey('backquote', '`', LogicalKeyboardKey.backquote.keyId),
  BindableKey('insert', 'Insert', LogicalKeyboardKey.insert.keyId),
  BindableKey('home', 'Home', LogicalKeyboardKey.home.keyId),
  BindableKey('end', 'End', LogicalKeyboardKey.end.keyId),
  BindableKey('pageUp', 'PgUp', LogicalKeyboardKey.pageUp.keyId),
  BindableKey('pageDown', 'PgDn', LogicalKeyboardKey.pageDown.keyId),
  BindableKey('arrowUp', '↑', LogicalKeyboardKey.arrowUp.keyId),
  BindableKey('arrowDown', '↓', LogicalKeyboardKey.arrowDown.keyId),
  BindableKey('arrowLeft', '←', LogicalKeyboardKey.arrowLeft.keyId),
  BindableKey('arrowRight', '→', LogicalKeyboardKey.arrowRight.keyId),
];

final Map<String, BindableKey> _keysByName = {
  for (final k in kBindableKeys) k.name: k,
};

final Map<int, BindableKey> _keysByKeyId = {
  for (final k in kBindableKeys) k.keyId: k,
};

const List<LogicalKeyboardKey> _letters = [
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyF,
  LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.keyH,
  LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyN,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyP,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyS,
  LogicalKeyboardKey.keyT,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyY,
  LogicalKeyboardKey.keyZ,
];

const List<LogicalKeyboardKey> _digits = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

const List<LogicalKeyboardKey> _numpadDigits = [
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

const List<LogicalKeyboardKey> _functionKeys = [
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
];

String keyLabel(String keyName) => _keysByName[keyName]?.label ?? keyName;

/// 主键名字 → 逻辑键 id；表里没有返回 null
int? bindableKeyId(String keyName) => _keysByName[keyName]?.keyId;

/// 按下的逻辑键 → 可绑定键名；表外（媒体键、纯修饰键）返回 null
String? bindableKeyName(LogicalKeyboardKey key) {
  final found = _keysByKeyId[key.keyId];
  return found?.name;
}

/// 从设置里读出来的一条快捷键串；解析不了返回 null（不抛）
KeyBinding? parseKeyBinding(String raw) {
  final parts =
      raw.trim().toLowerCase().split('+').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final keyName = parts.last;
  // 名字在表里要能对上：字母表存的是 keyA 这种大写形式，输入允许 `ctrl+f`
  final key = _keysByName[keyName] ?? _keysByName[_canonicalKeyName(keyName)];
  if (key == null) return null;
  final mods = parts.take(parts.length - 1).toSet();
  if (mods.length != parts.length - 1) return null; // 重复修饰键
  return KeyBinding(
    keyName: key.name,
    ctrl: mods.contains('ctrl'),
    shift: mods.contains('shift'),
    alt: mods.contains('alt'),
    meta: mods.contains('meta'),
  );
}

/// `f` → `keyF`、`1` → `digit1`、`arrowup` → `arrowUp`
String _canonicalKeyName(String input) {
  if (input.length == 1) {
    final cu = input.codeUnitAt(0);
    if (cu >= 97 && cu <= 122) return 'key${input.toUpperCase()}';
    if (cu >= 48 && cu <= 57) return 'digit$input';
    return input;
  }
  for (final k in kBindableKeys) {
    if (k.name.toLowerCase() == input) return k.name;
  }
  return input;
}

/// 重绑一道新快捷键的结论
enum BindingVerdict {
  /// 可以直接用
  ok,

  /// 这个键不在可绑定表里（媒体键、音量键之类）
  unsupportedKey,

  /// 没有修饰键：裸键会劫持打字
  needsModifier,

  /// Ctrl+字母：26 个在 readline/shell 里各有语义（Ctrl+C 中断、Ctrl+D EOF、
  /// Ctrl+H 退格、Ctrl+S/Q 流量控制…）。不硬禁 —— 粘贴本来就绑 Ctrl+V，
  /// 但要用文字提醒用户这会吃掉 shell 的那个键。
  shadowShellControlKey,

  /// 和「复制选中」（Ctrl+Shift+C，xterm 内置表）撞了
  copyConflict,

  /// mac 系统级快捷键（⌘W 关窗口 / ⌘Q 退出 / ⌘H 隐藏…），抢不到也抢不得
  systemReserved;

  bool get isBlocking => this != ok && this != shadowShellControlKey;
}

/// 一条快捷键能不能绑。
///
/// 目的不是限制自由，而是让用户在按下确认之前看见「这个键在 shell 里本来
/// 有用」，抢完之后不至于以为终端坏了。
BindingVerdict validateKeyBinding(KeyBinding binding, {required bool isMac}) {
  if (!_keysByName.containsKey(binding.keyName)) {
    return BindingVerdict.unsupportedKey;
  }
  if (!binding.hasModifier) return BindingVerdict.needsModifier;
  // 只有裸 ⌘+键才是系统级；⌘⇧H、⌘⌥W 这类加了修饰的不在系统表里
  if (isMac &&
      binding.meta &&
      !binding.ctrl &&
      !binding.shift &&
      !binding.alt &&
      _macSystemKeys.contains(binding.keyName)) {
    return BindingVerdict.systemReserved;
  }
  // 复制走 Ctrl+Shift+C（xterm 内置表），抢了会让「复制选中」失效
  if (binding.keyName == 'keyC' &&
      binding.ctrl &&
      binding.shift &&
      !binding.meta) {
    return BindingVerdict.copyConflict;
  }
  // Ctrl+字母 = 控制字符，但带上 Alt 就不是了（xterm 的 Alt 发 ESC 前缀，
  // shell 收不到控制字节），所以 Alt 组合不打扰用户
  if (binding.ctrl &&
      !binding.meta &&
      !binding.alt &&
      _letterNames.contains(binding.keyName)) {
    return BindingVerdict.shadowShellControlKey;
  }
  return BindingVerdict.ok;
}

String bindingVerdictLabel(BindingVerdict verdict, {required bool isZh}) {
  switch (verdict) {
    case BindingVerdict.ok:
      return '';
    case BindingVerdict.unsupportedKey:
      return isZh ? '这个键不支持绑定' : 'This key cannot be bound';
    case BindingVerdict.needsModifier:
      return isZh
          ? '至少要有 Ctrl、⌘ 或 Alt 中的一个修饰键'
          : 'Add at least one of Ctrl, ⌘ or Alt';
    case BindingVerdict.shadowShellControlKey:
      return isZh
          ? '注意：这个组合在 shell 里另有用途（中断、EOF、退格、流量控制等），绑定后终端里就用不了了'
          : 'Heads up: the shell uses this combo for something (interrupt, EOF, backspace, flow control…). Binding it takes that away.';
    case BindingVerdict.copyConflict:
      return isZh
          ? 'Ctrl+Shift+C 是「复制选中」，换一个'
          : 'Ctrl+Shift+C is "copy selection". Pick another.';
    case BindingVerdict.systemReserved:
      return isZh
          ? '这是 macOS 系统快捷键（关窗口、退出、隐藏等），无法绑定'
          : 'This is a macOS system shortcut (close window, quit, hide) and cannot be bound';
  }
}

/// mac 上按 ⌘ 会先被系统/窗口管理吃掉的那几个键。
/// 不含 digit0 —— ⌘0 是「重置字号」的既有默认值，报它等于自己打自己。
const Set<String> _macSystemKeys = {
  'keyW',
  'keyQ',
  'keyH',
  'keyM',
  'keyTab',
};

final Set<String> _letterNames = {
  for (var i = 0; i < 26; i++) 'key${String.fromCharCode(65 + i)}',
};

/// 默认快捷键。每个动作可以有多条（各平台的习惯 + 数字小键盘别名），
/// 逐条列出比在读取路径里分平台更省事，也不会漏掉某个平台的既有习惯。
final Map<TerminalKeyAction, List<KeyBinding>> kDefaultTerminalKeybindings = {
  TerminalKeyAction.paste: _bindings([
    'ctrl+v',
    'meta+v',
  ]),
  TerminalKeyAction.search: _bindings([
    'ctrl+shift+f',
    // mac 的系统惯例是 ⌘F（Terminal.app / iTerm2 都这样），不带 Shift
    'meta+f',
  ]),
  TerminalKeyAction.commandHistory: _bindings([
    // Ctrl+H 是 readline 的退格、⌘H 是隐藏窗口，所以历史必须带 Shift 才抢
    'ctrl+shift+h',
    'meta+shift+h',
  ]),
  // Ctrl++ 在不同布局上会报成 equal / add / numpadAdd，且按住 Shift 的
  // 那两种都要收 —— 旧实现是「不看 Shift 只看逻辑键」，默认表必须等价。
  TerminalKeyAction.zoomIn: _bindings([
    'ctrl+equal',
    'ctrl+shift+equal',
    'ctrl+add',
    'ctrl+shift+add',
    'ctrl+numpadAdd',
    'meta+equal',
    'meta+shift+equal',
    'meta+add',
    'meta+shift+add',
    'meta+numpadAdd',
  ]),
  TerminalKeyAction.zoomOut: _bindings([
    'ctrl+minus',
    'ctrl+numpadSubtract',
    'meta+minus',
    'meta+numpadSubtract',
  ]),
  TerminalKeyAction.zoomReset: _bindings([
    'ctrl+digit0',
    'ctrl+numpad0',
    'meta+digit0',
    'meta+numpad0',
  ]),
  // 分屏沿用 iTerm2 的 ⌘D / ⌘⇧D 肌肉记忆。Ctrl 侧一律 ctrl+shift+字母：
  // ctrl+alt 在 Windows 上就是 AltGr（会劫持 `@`、`€` 这些输入），不能用。
  TerminalKeyAction.splitVertical: _bindings([
    'ctrl+shift+d',
    'meta+d',
  ]),
  TerminalKeyAction.splitHorizontal: _bindings([
    'ctrl+shift+s',
    'meta+shift+d',
  ]),
  // ⌘W 是「关窗口」，抢过来等于让用户丢窗口，分屏关闭只能加一层 Shift
  TerminalKeyAction.closePane: _bindings([
    'ctrl+shift+w',
    'meta+shift+w',
  ]),
  TerminalKeyAction.focusNextPane: _bindings([
    'ctrl+shift+period',
    'meta+bracketRight',
  ]),
  TerminalKeyAction.focusPrevPane: _bindings([
    'ctrl+shift+comma',
    'meta+bracketLeft',
  ]),
};

List<KeyBinding> _bindings(List<String> raw) {
  final out = <KeyBinding>[];
  for (final s in raw) {
    final binding = parseKeyBinding(s);
    if (binding != null) out.add(binding);
  }
  return out;
}

/// 设置里读出来的原始值 → 覆盖表。形状不对、动作 id 未知、组合串解析不了
/// 一律丢掉（旧版本或手改过的设置不能让 UI 崩）。
Map<String, List<String>> normalizeOverrides(Object? raw) {
  Map<dynamic, dynamic>? map;
  if (raw is Map) {
    map = raw;
  } else if (raw is String) {
    // SettingsDao 读不回 JSON 时会给原始字符串
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) map = decoded;
    } on FormatException {
      return const {};
    }
  }
  if (map == null) return const {};
  final out = <String, List<String>>{};
  map.forEach((key, value) {
    final action = TerminalKeyAction.byId(key.toString());
    if (action == null || value is! List) return;
    final combos = <String>[];
    for (final item in value) {
      final binding = parseKeyBinding(item.toString());
      if (binding != null && !combos.contains(binding.serialized)) {
        combos.add(binding.serialized);
      }
    }
    out[action.id] = combos;
  });
  return out;
}

/// 覆盖表增删改（纯函数，UI 只负责调用，规则都在这一处可测）。
///
/// [combos] 为该动作的完整新组合列表；等于默认表时把覆盖整条删掉 —— 否则
/// 设置里会永久留一条「和默认一样」的覆盖，以后改默认值就永远跟不上。
Map<String, List<String>> setActionBindings(
  Map<String, List<String>> overrides,
  TerminalKeyAction action,
  List<String> combos,
) {
  final next = <String, List<String>>{
    for (final entry in overrides.entries) entry.key: List.of(entry.value),
  };
  final defaults =
      kDefaultTerminalKeybindings[action]!.map((b) => b.serialized).toSet();
  // 注意不能用 `combos.toSet() == defaults`：Dart 的 Set 没重载 ==，
  // 那是同一性比较，两个内容相同的集合永远不相等。
  final actual = combos.toSet();
  if (actual.length == defaults.length && defaults.containsAll(actual)) {
    next.remove(action.id);
  } else {
    next[action.id] = List.of(combos);
  }
  return next;
}

/// 某个动作当前生效的组合串（覆盖优先，否则默认）
List<String> effectiveBindingStrings(
  Map<String, List<String>> overrides,
  TerminalKeyAction action,
) {
  final overridden = overrides[action.id];
  if (overridden != null) return List.of(overridden);
  return kDefaultTerminalKeybindings[action]!.map((b) => b.serialized).toList();
}

/// 加一条组合（[replace] 非空时原位替换它，否则追加）
Map<String, List<String>> addBinding(
  Map<String, List<String>> overrides,
  TerminalKeyAction action,
  KeyBinding binding, {
  KeyBinding? replace,
}) {
  final kept = effectiveBindingStrings(overrides, action)
      .where((s) => replace == null || parseKeyBinding(s) != replace)
      .toList();
  return setActionBindings(overrides, action, [...kept, binding.serialized]);
}

Map<String, List<String>> removeBinding(
  Map<String, List<String>> overrides,
  TerminalKeyAction action,
  KeyBinding binding,
) =>
    setActionBindings(
      overrides,
      action,
      effectiveBindingStrings(overrides, action)
          .where((s) => parseKeyBinding(s) != binding)
          .toList(),
    );

Map<String, List<String>> resetAction(
  Map<String, List<String>> overrides,
  TerminalKeyAction action,
) =>
    setActionBindings(
      overrides,
      action,
      kDefaultTerminalKeybindings[action]!.map((b) => b.serialized).toList(),
    );

/// 设置项 `terminalKeybindings` 的存储形状：`{动作 id: [快捷键串…]}`，
/// 只存用户改过的动作；某个动作出现即为「完全覆盖默认」，空数组表示解绑。
class TerminalKeymap {
  TerminalKeymap._(this._actions);

  final Map<TerminalKeyAction, List<KeyBinding>> _actions;

  static TerminalKeymap? _defaults;

  /// 默认映射。每次按键都要读，所以只建一次。
  static TerminalKeymap get defaults =>
      _defaults ??= TerminalKeymap.fromSettings(null);

  static TerminalKeymap fromSettings(Object? raw) {
    final result = <TerminalKeyAction, List<KeyBinding>>{
      for (final entry in kDefaultTerminalKeybindings.entries)
        entry.key: entry.value,
    };
    if (raw is Map) {
      raw.forEach((key, value) {
        final action = TerminalKeyAction.byId(key.toString());
        if (action == null) return;
        if (value is! List) return;
        result[action] = [
          for (final item in value)
            if (parseKeyBinding(item.toString()) != null)
              parseKeyBinding(item.toString())!,
        ];
      });
    }
    return TerminalKeymap._(result);
  }

  List<KeyBinding> bindingsFor(TerminalKeyAction action) =>
      _actions[action] ?? const [];

  /// 这个按键组合落在哪个动作上；没有则 null。
  ///
  /// 只在 `ctrl/meta/alt` 之一按下时匹配 —— 裸键永远不匹配，否则一条写坏的
  /// 设置就能把普通打字劫持掉。
  TerminalKeyAction? actionFor({
    required int keyId,
    required bool ctrl,
    required bool shift,
    required bool alt,
    required bool meta,
  }) {
    if (!ctrl && !alt && !meta) return null;
    final key = _keysByKeyId[keyId];
    if (key == null) return null;
    for (final action in TerminalKeyAction.values) {
      for (final binding in _actions[action] ?? const <KeyBinding>[]) {
        if (binding.keyName != key.name) continue;
        if (binding.ctrl != ctrl ||
            binding.shift != shift ||
            binding.alt != alt ||
            binding.meta != meta) {
          continue;
        }
        return action;
      }
    }
    return null;
  }
}
