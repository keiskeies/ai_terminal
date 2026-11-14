import 'package:xterm/xterm.dart' as xterm;

/// 一次搜索命中：buffer 行号 + cell 列区间 [start, end)。
/// 列号可直接交给 buffer.lines[line].createAnchor 做高亮。
class TerminalSearchMatch {
  final int line;
  final int start;
  final int end;

  const TerminalSearchMatch({
    required this.line,
    required this.start,
    required this.end,
  });
}

/// 纯文本命中：行号 + 字符串下标区间 [start, end)。
class TextMatch {
  final int line;
  final int start;
  final int end;

  const TextMatch({required this.line, required this.start, required this.end});
}

/// 逐行字面量搜索（query 里的正则元字符按字面处理），默认忽略大小写。
/// 用 RegExp 做大小写折叠而不是 toLowerCase：后者对个别 Unicode 字符
/// （如 İ）会改变串长度，导致命中下标漂移。
List<TextMatch> findTextMatches(
  List<String> lines,
  String query, {
  bool caseSensitive = false,
}) {
  if (query.isEmpty) return const [];
  final pattern = RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
  final results = <TextMatch>[];
  for (var i = 0; i < lines.length; i++) {
    for (final m in pattern.allMatches(lines[i])) {
      results.add(TextMatch(line: i, start: m.start, end: m.end));
    }
  }
  return results;
}

/// 提取 buffer 行的文本与每个字符对应的 cell 列号。
/// 宽字符（CJK）占两个 cell，第二个 cell 码点为 0，getText 会跳过它，
/// 所以字符串下标和 cell 列号必须逐个映射，不能直接当下标用。
({String text, List<int> columns}) lineTextWithColumns(xterm.BufferLine line) {
  final text = StringBuffer();
  final columns = <int>[];
  for (var i = 0; i < line.length; i++) {
    final cp = line.getCodePoint(i);
    if (cp == 0) continue;
    text.writeCharCode(cp);
    columns.add(i);
  }
  return (text: text.toString(), columns: columns);
}

/// 搜索整个 buffer（含回滚区）。命中换算成 cell 列区间。
/// [maxMatches] 封顶：回滚区可达数万行，高亮对象不能无界增长。
List<TerminalSearchMatch> searchTerminalBuffer(
  xterm.Buffer buffer,
  String query, {
  bool caseSensitive = false,
  int maxMatches = 5000,
}) {
  if (query.isEmpty) return const [];
  final lines = <String>[];
  final columnMaps = <List<int>>[];
  for (var i = 0; i < buffer.height; i++) {
    final extracted = lineTextWithColumns(buffer.lines[i]);
    lines.add(extracted.text);
    columnMaps.add(extracted.columns);
  }
  final matches = findTextMatches(lines, query, caseSensitive: caseSensitive);
  final results = <TerminalSearchMatch>[];
  for (final m in matches) {
    if (results.length >= maxMatches) break;
    final columns = columnMaps[m.line];
    final line = buffer.lines[m.line];
    final lastCell = columns[m.end - 1];
    results.add(TerminalSearchMatch(
      line: m.line,
      start: columns[m.start],
      end: lastCell + line.getWidth(lastCell),
    ));
  }
  return results;
}