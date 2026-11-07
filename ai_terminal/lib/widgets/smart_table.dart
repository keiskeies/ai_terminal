import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 一张解析好的 Markdown 表格（对齐信息忽略，单元格按纯文本渲染）
class MarkdownTableData {
  final List<String> header;
  final List<List<String>> rows;

  const MarkdownTableData(this.header, this.rows);
}

/// `splitMarkdownTables` 的输出：要么是一段普通 Markdown 文本，要么是一张表格。
class MarkdownTableChunk {
  final String text;
  final MarkdownTableData? table;

  const MarkdownTableChunk.text(this.text) : table = null;
  const MarkdownTableChunk.ofTable(MarkdownTableData this.table) : text = '';
}

/// 分隔行：`| --- | --- |`、`--- | ---`、`:---:` 等
final RegExp _separatorPattern =
    RegExp(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$');

bool _isTableStart(List<String> lines, int index) {
  if (index + 1 >= lines.length) return false;
  if (!lines[index].contains('|')) return false;
  return _separatorPattern.hasMatch(lines[index + 1].trim());
}

/// 把一段 Markdown 文本按表格块拆开。
///
/// flutter_markdown 0.6.x 的 `builders` 只对行内元素生效，表格始终按
/// FlexColumnWidth 均分列宽；所以在进入 MarkdownBody 之前先把表格切出来，
/// 交给 [SmartMarkdownTable] 按内容自适应列宽。
List<MarkdownTableChunk> splitMarkdownTables(String content) {
  final chunks = <MarkdownTableChunk>[];
  final lines = content.split('\n');
  var textStart = 0;
  var i = 0;

  while (i < lines.length) {
    if (_isTableStart(lines, i)) {
      final header = _parseCells(lines[i]);
      final rows = <List<String>>[];
      var j = i + 2;
      while (j < lines.length) {
        final trimmed = lines[j].trim();
        if (trimmed.isEmpty || !trimmed.contains('|')) break;
        // 当前行是分隔行，或下一行是分隔行（说明当前行已是下一张表的表头），
        // 都说明本表到此结束，避免把下一张表吞成数据行。
        if (_separatorPattern.hasMatch(trimmed)) break;
        if (j + 1 < lines.length &&
            _separatorPattern.hasMatch(lines[j + 1].trim())) {
          break;
        }
        rows.add(_parseCells(lines[j]));
        j++;
      }
      // 表头不该是空的，否则只是普通文本里夹了一行竖线
      if (header.any((c) => c.isNotEmpty)) {
        if (textStart < i) {
          final before = lines.sublist(textStart, i).join('\n');
          if (before.trim().isNotEmpty) {
            chunks.add(MarkdownTableChunk.text(before));
          }
        }
        chunks.add(
            MarkdownTableChunk.ofTable(MarkdownTableData(header, rows)));
        i = j;
        textStart = j;
        continue;
      }
    }
    i++;
  }

  if (textStart < lines.length) {
    final rest = lines.sublist(textStart).join('\n');
    if (rest.trim().isNotEmpty) {
      chunks.add(MarkdownTableChunk.text(rest));
    }
  }
  if (chunks.isEmpty) {
    chunks.add(MarkdownTableChunk.text(content));
  }
  return chunks;
}

/// 解析一行表格单元格：去掉首尾竖线后按 `|` 切分（支持 `\|` 转义）。
List<String> _parseCells(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|') && !text.endsWith(r'\|')) {
    text = text.substring(0, text.length - 1);
  }
  const placeholder = '\u0001';
  text = text.replaceAll(r'\|', placeholder);
  return text
      .split('|')
      .map((cell) => _cleanCell(cell.replaceAll(placeholder, '|')))
      .toList();
}

/// 单元格文本清洗：去掉内联标记残留，换行压成空格（交由 Text 自动换行）。
String _cleanCell(String raw) {
  var text = raw.trim();
  if (text.length > 1 && text.startsWith('`') && text.endsWith('`')) {
    text = text.substring(1, text.length - 1);
  }
  text = text.replaceAll('**', '').replaceAll('__', '');
  return text.replaceAll(RegExp(r'\s*\n\s*'), ' ');
}

/// 智能列宽表格：按内容自然宽度分配列宽，不再均等分。
///
/// 规则：
/// - 每列取内容不换行时的最大宽度（含单元格内边距）；
/// - 总宽不超可用宽度时不强行摊满，列宽完全跟着内容走；
/// - 总宽超限时按比例压缩（保底最小列宽），单元格内自动换行；
/// - 表头加粗、隔行底色，边框与其它 agent 卡片统一。
class SmartMarkdownTable extends StatelessWidget {
  final MarkdownTableData data;
  final ThemeColors tc;
  final double fontSize;

  const SmartMarkdownTable({
    super.key,
    required this.data,
    required this.tc,
    this.fontSize = fAgentBody,
  });

  @override
  Widget build(BuildContext context) {
    final columnCount = math.max(
      data.header.length,
      data.rows.fold<int>(0, (max, row) => math.max(max, row.length)),
    );
    if (columnCount == 0) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, constraints) {
      // 容器左右各 1px 边框，先扣掉，避免固定列宽把整行顶出父级
      final available = constraints.maxWidth.isFinite
          ? math.max(1.0, constraints.maxWidth - 2)
          : 600.0;

      final natural = List<double>.generate(columnCount, (col) {
        var width = 24.0; // 空列也留一点宽度
        void measure(String text, bool bold) {
          if (text.isEmpty) return;
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                height: 1.35,
              ),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          width = math.max(width, painter.width + 16); // 左右 padding
          painter.dispose();
        }

        if (col < data.header.length) measure(data.header[col], true);
        for (final row in data.rows) {
          if (col < row.length) measure(row[col], false);
        }
        return width;
      });

      final total = natural.fold(0.0, (a, b) => a + b);
      final List<double> widths;
      if (total <= available) {
        // 内容自适应：不把剩余空间摊回各列，否则又会退化成“接近均分”
        widths = natural;
      } else {
        final minCol = math.min(36.0, available / columnCount);
        final shrinkable = math.max(0.0, available - columnCount * minCol);
        final naturalSum = math.max(1.0, total - columnCount * minCol);
        widths = [
          for (final width in natural)
            minCol + shrinkable * math.max(0.0, width - minCol) / naturalSum,
        ];
      }

      Widget cellBox(String text, int col,
          {bool bold = false, bool zebra = false}) {
        return Container(
          width: widths[col],
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: zebra ? tc.surface.withValues(alpha: 0.5) : null,
            border: Border(
              right: BorderSide(color: tc.agentCardBorder, width: 1),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.35,
              color: bold ? tc.textMain : tc.textBody,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        );
      }

      final tableRows = <TableRow>[];
      if (data.header.isNotEmpty) {
        tableRows.add(TableRow(
          decoration: BoxDecoration(color: tc.surface),
          children: [
            for (var col = 0; col < columnCount; col++)
              cellBox(col < data.header.length ? data.header[col] : '', col,
                  bold: true),
          ],
        ));
      }
      for (var row = 0; row < data.rows.length; row++) {
        tableRows.add(TableRow(
          children: [
            for (var col = 0; col < columnCount; col++)
              cellBox(
                col < data.rows[row].length ? data.rows[row][col] : '',
                col,
                zebra: row.isOdd,
              ),
          ],
        ));
      }

      // 用 Align 让表格贴在左侧、宽度跟着内容走：
      // 父级偶发 tight 约束时也不会把边框拉满整行。
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: tc.agentCardBorder, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Table(
              border: TableBorder(
                horizontalInside:
                    BorderSide(color: tc.agentCardBorder, width: 1),
              ),
              columnWidths: {
                for (var col = 0; col < widths.length; col++)
                  col: FixedColumnWidth(widths[col]),
              },
              children: tableRows,
            ),
          ),
        ),
      );
    });
  }
}
