import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/app_toast.dart';
import '../core/ui_text.dart';

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
      title: title,
    ),
  );
}

class OutputViewerSheet extends StatefulWidget {
  final String text;
  final ThemeColors tc;

  /// 标题为 null 时在 build 里取当前语言文案。
  ///
  /// 不写成 `this.title = '原始输出'`：默认参数是编译期常量，切到英文后仍会
  /// 显示中文——`const` 表同理，凡是跟着语言走的文案都不能待在 const 默认值里。
  final String? title;

  const OutputViewerSheet({
    super.key,
    required this.text,
    required this.tc,
    this.title,
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
    final display = filtered.trim().isEmpty
        ? UiText.t('没有匹配内容', 'No matching line')
        : filtered;
    final title = widget.title ?? UiText.t('原始输出', 'Raw output');

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
                        title,
                        style: TextStyle(
                          color: tc.textMain,
                          fontSize: fSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      UiText.count(widget.text.length, '字符', 'chars'),
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                    const SizedBox(width: 4),
                    _iconButton(
                      icon: Icons.copy,
                      tooltip: UiText.t('复制全部', 'Copy all'),
                      color: tc.textSub,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.text));
                        clearTopToast();
                        showTopSnackBar(
                          context,
                          SnackBar(
                            content: Text(UiText.t('已复制', 'Copied'),
                                style: const TextStyle(fontSize: fSmall)),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.all(16),
                          ),
                        );
                      },
                    ),
                    _iconButton(
                      icon: Icons.close,
                      tooltip: UiText.t('关闭', 'Close'),
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
                    hintText: UiText.t('搜索输出…', 'Search output…'),
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
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                        fontFamilyFallback: kMonoFontFallback,
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
