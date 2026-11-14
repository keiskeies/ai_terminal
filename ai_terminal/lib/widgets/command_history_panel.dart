import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/command_history_entry.dart';
import '../services/daos.dart';

/// 终端命令历史面板（P2）。
///
/// 只做三件事：搜、填进命令行、直接执行。命令来自 `CommandTracker` 从屏幕上
/// 抓的回显行，所以列表里天然没有密码（密码输入没有回显，见该文件注释）。
class CommandHistoryPanel extends StatefulWidget {
  const CommandHistoryPanel({super.key, required this.onInsert});

  /// 把命令写回当前 tab 的终端。[run] 为真时带回车直接执行，否则只填到命令行。
  final void Function(String command, {required bool run}) onInsert;

  @override
  State<CommandHistoryPanel> createState() => _CommandHistoryPanelState();
}

class _CommandHistoryPanelState extends State<CommandHistoryPanel> {
  final TextEditingController _query = TextEditingController();
  List<CommandHistoryEntry> _items = const [];

  @override
  void initState() {
    super.initState();
    _items = CommandHistoryDao.search('');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() => _items = CommandHistoryDao.search(_query.text));
  }

  Future<void> _delete(CommandHistoryEntry entry) async {
    await CommandHistoryDao.delete(entry.id);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tc = ThemeColors.of(ctx);
        return AlertDialog(
          backgroundColor: tc.cardElevated,
          content: Text(UiText.t('清空全部命令历史？', 'Clear all command history?'),
              style: TextStyle(color: tc.textMain, fontSize: fBody)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(UiText.t('取消', 'Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: tc.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(UiText.t('清空', 'Clear')),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    await CommandHistoryDao.clearAll();
    if (!mounted) return;
    _refresh();
  }

  void _insert(CommandHistoryEntry entry, {required bool run}) {
    widget.onInsert(entry.command, run: run);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Dialog(
      backgroundColor: tc.cardElevated,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 520),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(pStandard, pStandard, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.history, color: tc.brand, size: 18),
                  const SizedBox(width: 8),
                  Text(UiText.t('命令历史', 'Command history'),
                      style: TextStyle(
                          color: tc.textMain,
                          fontSize: fBody,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    tooltip: UiText.t('清空历史', 'Clear history'),
                    iconSize: 16,
                    onPressed: _items.isEmpty ? null : _clearAll,
                    icon: Icon(Icons.delete_sweep_outlined, color: tc.textSub),
                  ),
                  IconButton(
                    tooltip: UiText.t('关闭 (Esc)', 'Close (Esc)'),
                    iconSize: 16,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: tc.textSub),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(pStandard, pSmall, pStandard, pSmall),
              child: TextField(
                controller: _query,
                autofocus: true,
                style: TextStyle(fontSize: fSmall, color: tc.textMain),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: UiText.t('搜索历史命令', 'Search history'),
                  hintStyle: TextStyle(fontSize: fSmall, color: tc.textMuted),
                  prefixIcon: Icon(Icons.search, size: 16, color: tc.textSub),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          iconSize: 14,
                          icon: Icon(Icons.clear, size: 14, color: tc.textSub),
                          onPressed: () {
                            _query.clear();
                            _refresh();
                          },
                        ),
                  filled: true,
                  fillColor: tc.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(rSmall),
                    borderSide: BorderSide(color: tc.border),
                  ),
                ),
                onChanged: (_) => _refresh(),
                onSubmitted: _items.isEmpty
                    ? null
                    : (_) => _insert(_items.first, run: true),
              ),
            ),
            if (_items.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    UiText.t('暂无历史命令', 'No history yet'),
                    style: TextStyle(fontSize: fSmall, color: tc.textMuted),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) => _tile(context, _items[i], tc),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(pStandard, pSmall, pStandard, pSmall),
              child: Row(
                children: [
                  Text(
                    UiText.t('回车执行首条结果 · Enter 填入 · 单击复制',
                        'Enter runs the top match · click a row to fill · tap to copy'),
                    style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(
      BuildContext context, CommandHistoryEntry entry, ThemeColors tc) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: () => _insert(entry, run: false),
      title: Text(
        entry.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontFamilyFallback: kMonoFontFallback,
          fontSize: fSmall,
          color: tc.textMain,
        ),
      ),
      subtitle: Text(
        '${entry.useCount}× · ${_ago(entry.usedAt)}',
        style: TextStyle(fontSize: fMicro, color: tc.textMuted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: UiText.t('复制', 'Copy'),
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: entry.command));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(UiText.t('已复制', 'Copied'),
                    style: const TextStyle(fontSize: fSmall)),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.all(16),
              ));
            },
            icon: Icon(Icons.copy_outlined, color: tc.textSub),
          ),
          IconButton(
            tooltip: UiText.t('执行', 'Run'),
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            onPressed: () => _insert(entry, run: true),
            icon: Icon(Icons.play_arrow_rounded, color: tc.brand),
          ),
          IconButton(
            tooltip: UiText.t('删除', 'Delete'),
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            onPressed: () => _delete(entry),
            icon: Icon(Icons.close, color: tc.textMuted),
          ),
        ],
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return UiText.t('刚刚', 'just now');
    if (d.inHours < 1) return UiText.t('${d.inMinutes} 分钟前', '${d.inMinutes}m ago');
    if (d.inDays < 1) return UiText.t('${d.inHours} 小时前', '${d.inHours}h ago');
    return UiText.t('${d.inDays} 天前', '${d.inDays}d ago');
  }
}
