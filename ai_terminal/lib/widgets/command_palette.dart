import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 命令面板条目。
///
/// 面板本身不知道终端/主机/页面的概念：调用方把每种能力翻译成一个条目并
/// 带上 [onRun]，面板只负责检索与键盘导航。这样新增入口不用改面板。
class CommandPaletteEntry {
  const CommandPaletteEntry({
    required this.label,
    required this.onRun,
    this.subtitle,
    this.icon = Icons.terminal,
    this.group = '',
    this.keywords = const [],
  });

  final String label;
  final String? subtitle;
  final IconData icon;

  /// 分组标题（主机 / 快捷命令 / 页面 / 操作）。空串表示不分组。
  final String group;

  /// 额外检索词：别名、英文写法等，命中后仍能匹配到条目。
  final List<String> keywords;

  /// 选中后执行（面板已关闭）。
  final VoidCallback onRun;
}

/// Ctrl+K 命令面板：把「主机 / 命令 / 页面 / 操作」收进一个零占位的浮层入口。
///
/// 检索用「子串 + 子序列」两级打分，够快也够直观；不用模糊库是为了不把
/// 一个几百条目的列表拖进依赖。
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.entries, this.placeholder});

  final List<CommandPaletteEntry> entries;
  final String? placeholder;

  /// 打开面板；返回时条目已执行。
  static Future<void> show(
    BuildContext context, {
    required List<CommandPaletteEntry> entries,
    String? placeholder,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => CommandPalette(entries: entries, placeholder: placeholder),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  // 方向/回车/Esc 必须挂在输入框自己的 focusNode 上：TextField 内部的
  // text-editing Actions 会先吃掉方向键（光标移动），祖先 Focus 的
  // onKeyEvent 根本轮不到。节点自身的 onKeyEvent 在那些 Actions 之前。
  final FocusNode _fieldNode = FocusNode();
  List<PaletteMatch> _results = [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _fieldNode.onKeyEvent = _onKey;
    _requery('');
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldNode.dispose();
    super.dispose();
  }

  void _requery(String query) {
    setState(() {
      _results = rankPaletteEntries(widget.entries, query);
      _selected = 0;
    });
  }

  void _runSelected() => _run(_selected);

  void _run(int index) {
    if (_results.isEmpty) return;
    final entry = _results[index.clamp(0, _results.length - 1)].entry;
    Navigator.of(context).pop();
    entry.onRun();
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      final n = _results.length;
      _selected = (_selected + delta) % n;
      if (_selected < 0) _selected += n;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _move(event is KeyDownEvent &&
              HardwareKeyboard.instance.isShiftPressed
          ? -1
          : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _runSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final size = MediaQuery.of(context).size;
    final maxH = size.height * 0.6;

    // 设计稿 .palette：距顶 56px（贴在顶栏下沿，不是屏幕正中）、宽
    // min(520, 92%)、r12、1px 强描边 + 大投影。之前用 Center + 560 固定宽
    // + 无边框 Material，窗口越宽越像“飘在中间的一张纸”。
    return LayoutBuilder(
      builder: (context, c) {
        final width = math.min(520.0, c.maxWidth * 0.92);
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 56),
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  // 设计稿 .palette：1px 强描边（.18 白）+ 大投影。普通 border
                  // 在深底上几乎看不见，设计稿特意用了更亮的描边。
                  border: Border.all(color: tc.borderHover, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Material(
                  color: tc.cardElevated,
                  borderRadius: BorderRadius.circular(12),
                  // 1px 强描边压在 Material 外侧：Material 自带 clip 会把
                  // Border 的圆角裁齐，放进 DecoratedBox 才有完整一圈。
                  clipBehavior: Clip.antiAlias,
                  child: Focus(
                    // 按键只在这里拦方向/回车/Esc；焦点归输入框本身（autofocus），
                    // 之前把 autofocus 挂在外层 Focus 上会让输入框永远拿不到焦点，
                    // 打字全部落空。祖先节点仍在按键冒泡链上，方向键照常处理。
                    onKeyEvent: _onKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Row(
                            children: [
                              Icon(Icons.search_rounded,
                                  size: 15, color: tc.textSub),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _fieldNode,
                                  autofocus: true,
                                  style: TextStyle(
                                      color: tc.textMain, fontSize: fBody),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: widget.placeholder ??
                                        '搜索主机 / 命令 / 页面 / 操作…',
                                    hintStyle: TextStyle(
                                        color: tc.textMuted, fontSize: fBody),
                                  ),
                                  onChanged: _requery,
                                ),
                              ),
                              _kbd(tc, 'Esc'),
                            ],
                          ),
                        ),
                        Divider(color: tc.hairline, height: 1),
                        if (_results.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: Text('没有匹配项',
                                  style: TextStyle(
                                      fontSize: fSmall, color: tc.textMuted)),
                            ),
                          )
                        else
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: maxH - 92),
                            child: ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.all(6),
                              itemCount: _results.length,
                              itemBuilder: (context, index) {
                                final s = _results[index];
                                return _PaletteRow(
                                  entry: s.entry,
                                  selected: index == _selected,
                                  showGroup: s.showGroup,
                                  hoverIndex: index,
                                  onHover: (i) {
                                    if (i != _selected) {
                                      setState(() => _selected = i);
                                    }
                                  },
                                  onTap: () => _run(index),
                                );
                              },
                            ),
                          ),
                        // 快捷键提示（设计稿 .pal-foot）
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: tc.hairline)),
                          ),
                          child: Row(
                            children: [
                              _footHint(tc, '↑↓', '选择'),
                              const SizedBox(width: 12),
                              _footHint(tc, 'Enter', '执行'),
                              const SizedBox(width: 12),
                              _footHint(tc, 'Esc', '关闭'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class PaletteMatch {
  PaletteMatch(this.entry, this.score);

  final CommandPaletteEntry entry;
  final int score;
  bool showGroup = false;
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.entry,
    required this.selected,
    required this.showGroup,
    required this.hoverIndex,
    required this.onHover,
    required this.onTap,
  });

  final CommandPaletteEntry entry;
  final bool selected;
  final bool showGroup;
  final int hoverIndex;
  final ValueChanged<int> onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showGroup)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Text(entry.group,
                style: TextStyle(
                  fontSize: fMicro,
                  color: tc.brand,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                )),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: MouseRegion(
            onEnter: (_) => onHover(hoverIndex),
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                // 设计稿 .pal-item[aria-selected]：圆角行 + 品牌底 + 左侧 2px
                // 品牌内嵌条。铺满行的直角高亮会把分组标题也罩进去。
                // min-height 38 = .pal-item{min-height:38px}。
                constraints: const BoxConstraints(minHeight: 38),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? tc.brandBg : null,
                  borderRadius: BorderRadius.circular(rSmall),
                  border: selected
                      ? Border(left: BorderSide(color: tc.brand, width: 2))
                      : null,
                ),
                child: Row(
                  children: [
                    // 类型徽章（.pal-type）：两字组名缩写，扫一眼知道命中的是什么
                    if (entry.group.isNotEmpty) ...[
                      Container(
                        constraints: const BoxConstraints(minWidth: 32),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: tc.border),
                        ),
                        child: Text(_typeBadge(entry.group),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: fMicro, color: tc.textSub)),
                      ),
                      const SizedBox(width: 9),
                    ],
                    Icon(entry.icon, size: 15, color: tc.textSub),
                    const SizedBox(width: 9),
                    // .pal-name 是 flex:none（自然宽度、不拉伸），.pal-sub 才
                    // flex:1 吃掉剩余空间靠左排。之前把 subtitle 右对齐，读起来
                    // 像两列没对齐的表格，和设计稿的「名字+副标题」节奏不一致。
                    Flexible(
                      child: Text(entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: fBody,
                            color: tc.textMain,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          )),
                    ),
                    if (entry.subtitle != null) ...[
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(entry.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontFamilyFallback: kMonoFontFallback,
                                fontSize: fMicro,
                                color: tc.textMuted)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 组名 → 徽章缩写：徽章只有 ~32px 宽，长组名取前两字。
String _typeBadge(String group) {
  const map = {
    '操作': '操作',
    '页面': '页面',
    '主机': '主机',
    '快捷命令': '命令',
    '工作流': '工作',
    'Actions': 'ACT',
    'Pages': 'PG',
    'Snippets': 'CMD',
    'Runbooks': 'RUN',
  };
  final s = map[group] ?? group;
  return s.length <= 2 ? s : s.substring(0, 2);
}

Widget _footHint(ThemeColors tc, String key, String label) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _kbd(tc, key),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
    ],
  );
}

Widget _kbd(ThemeColors tc, String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: tc.surface,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: tc.border),
    ),
    child: Text(text,
        style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
  );
}

/// 检索打分：完整子串 > 词首前缀 > 子序列；分数相同保持原顺序。
///
/// 纯函数，便于单测覆盖「别名命中」「无匹配」与分组标记。
List<PaletteMatch> rankPaletteEntries(
    List<CommandPaletteEntry> entries, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  final scored = <PaletteMatch>[];
  for (final e in entries) {
    if (query.isEmpty) {
      scored.add(PaletteMatch(e, 0));
      continue;
    }
    final label = e.label.toLowerCase();
    final subtitle = (e.subtitle ?? '').toLowerCase();
    int? best;
    if (label.startsWith(query)) {
      best = 100;
    } else if (label.contains(query)) {
      best = 70;
    } else if (subtitle.contains(query)) {
      best = 50;
    } else if (e.keywords.any((k) => k.toLowerCase().contains(query))) {
      best = 45;
    } else if (_isSubsequence(query, label)) {
      best = 20;
    }
    if (best != null) scored.add(PaletteMatch(e, best));
  }
  if (query.isEmpty) {
    // 无输入时按分组原序展示，只给每个分组的第一条打组标题
    _markGroups(scored);
    return scored;
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  _markGroups(scored);
  return scored;
}

void _markGroups(List<PaletteMatch> scored) {
  String? prev;
  for (final s in scored) {
    s.showGroup = s.entry.group.isNotEmpty && s.entry.group != prev;
    prev = s.entry.group.isEmpty ? prev : s.entry.group;
  }
}

bool _isSubsequence(String needle, String haystack) {
  if (needle.isEmpty) return true;
  if (needle.length > haystack.length) return false;
  var i = 0;
  for (var j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack[j] == needle[i]) i++;
  }
  return i == needle.length;
}
