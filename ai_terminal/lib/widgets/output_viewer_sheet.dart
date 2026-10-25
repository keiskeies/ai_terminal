import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 打开原始输出查看器（底部面板，支持搜索与复制）
Future<void> showOutputViewer(
  BuildContext context, {
  required String text,
  required ThemeColors tc,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tc.cardElevated,
    builder: (_) => OutputViewerSheet(
      text: text,
      tc: tc,
      title: title ?? '原始输出',
    ),
  );
}

class OutputViewerSheet extends StatefulWidget {
  final String text;
  final ThemeColors tc;
  final String title;

  const OutputViewerSheet({
    super.key,
    required this.text,
    required this.tc,
    this.title = '原始输出',
  });

  @override
  State<OutputViewerSheet> createState() => _OutputViewerSheetState();
}

class _OutputViewerSheetState extends State<OutputViewerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final lines = widget.text.split('\n');
    final filtered = _query.isEmpty
        ? widget.text
        : lines
            .where((line) => line.toLowerCase().contains(_query.toLowerCase()))
            .join('\n');
    final display = filtered.trim().isEmpty ? '没有匹配内容' : filtered;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
                child: Row(
                  children: [
                    Icon(Icons.subject, size: 15, color: tc.textSub),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: tc.textMain,
                          fontSize: fSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${widget.text.length} 字符',
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                    const SizedBox(width: 4),
                    _iconButton(
                      icon: Icons.copy,
                      tooltip: '复制全部',
                      color: tc.textSub,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.text));
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制',
                                style: TextStyle(fontSize: fSmall)),
                            duration: Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                            margin: EdgeInsets.all(16),
                          ),
                        );
                      },
                    ),
                    _iconButton(
                      icon: Icons.close,
                      tooltip: '关闭',
                      color: tc.textSub,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  style: TextStyle(color: tc.textMain, fontSize: fSmall),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索输出…',
                    hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
                    prefixIcon:
                        Icon(Icons.search, size: 16, color: tc.textMuted),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear,
                                size: 15, color: tc.textMuted),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                    filled: true,
                    fillColor: tc.terminalBg,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(rXSmall),
                      borderSide: BorderSide(color: tc.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(rXSmall),
                      borderSide: BorderSide(color: tc.border),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tc.terminalBg,
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(color: tc.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      display,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: fMono,
                        color: tc.textBody,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 17, color: color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
