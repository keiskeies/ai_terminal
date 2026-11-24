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
        chunks.add(MarkdownTableChunk.ofTable(MarkdownTableData(header, rows)));
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

/// 智能列宽表格：按内容自然宽度分配列宽，单元格永不换行。
///
/// 规则：
/// - 每列取内容不换行时的最大宽度（含单元格内边距与系统字号缩放）；
/// - 总宽不超可用宽度时不强行摊满，列宽完全跟着内容走；
/// - 总宽超限时保持内容宽度，改为横向滚动（常显滚动条），不压缩、不换行；
/// - 表头加粗、隔行底色，边框与其它 agent 卡片统一。
class SmartMarkdownTable extends StatefulWidget {
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
  State<SmartMarkdownTable> createState() => _SmartMarkdownTableState();
}

class _SmartMarkdownTableState extends State<SmartMarkdownTable> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final tc = widget.tc;
    final fontSize = widget.fontSize;
    final textScaler = MediaQuery.textScalerOf(context);

    final columnCount = math.max(
      data.header.length,
      data.rows.fold<int>(0, (max, row) => math.max(max, row.length)),
    );
    if (columnCount == 0) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;

      // 按内容测量自然宽度：maxLines=1，宽度即整行文字所需宽度（含 padding）。
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
            textScaler: textScaler,
            textDirection: TextDirection.ltr,
          )..layout();
          // +2 防止浮点取整后差 1px 又触发换行
          width = math.max(width, painter.width + 16 + 2);
          painter.dispose();
        }

        if (col < data.header.length) measure(data.header[col], true);
        for (final row in data.rows) {
          if (col < row.length) measure(row[col], false);
        }
        return width;
      });

      final total = natural.fold(0.0, (a, b) => a + b);
      // 表格最小宽度 = 满宽：内容窄于可用宽度时，把富余宽度按比例分给各列；
      // 内容超宽时保持自然列宽、横向滚动，单元格仍不换行。
      final available = maxWidth - 2; // 容器左右各 1px 边框
      final widths = List<double>.from(natural);
      final extra = available - total;
      if (extra > 0) {
        for (var col = 0; col < widths.length; col++) {
          widths[col] += extra * (natural[col] / total);
        }
        // 浮点尾差补给最后一列，保证正好铺满
        final sum = widths.fold(0.0, (a, b) => a + b);
        widths[widths.length - 1] += available - sum;
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
            maxLines: 1,
            softWrap: false,
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

      final table = Table(
        border: TableBorder(
          horizontalInside: BorderSide(color: tc.agentCardBorder, width: 1),
        ),
        columnWidths: {
          for (var col = 0; col < widths.length; col++)
            col: FixedColumnWidth(widths[col]),
        },
        children: tableRows,
      );

      // 容器左右各 1px 边框；窄表已补到满宽，宽表横向滚动
      final contentWidth = widths.fold(0.0, (a, b) => a + b) + 2;
      final containerWidth = math.min(maxWidth, contentWidth);

      Widget body;
      if (contentWidth <= maxWidth + 0.5) {
        // 内容放得下：列宽已按比例铺满整行
        body = table;
      } else {
        // 超宽：保持每列内容宽度，横向滚动查看，绝不压缩换行
        body = Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 10),
            child: table,
          ),
        );
      }

      // 用 Align 让表格贴在左侧；窄表宽度跟内容走，宽表占满可用宽度并滚动。
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: containerWidth,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: tc.agentCardBorder, width: 1),
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(rXSmall),
            child: body,
          ),
        ),
      );
    });
  }
}
