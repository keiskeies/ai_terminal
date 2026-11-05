import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/agent_engine.dart';
import '../core/app_toast.dart';

/// Agent 日志查看器对话框
///
/// 日志按 `[时间] [级别] [tag] 消息` 解析后再展示：级别和 tag 可过滤，
/// 还能只看本次任务。原始环形缓冲混着启动、旧任务和框架异常，不做过滤
/// 基本没法在里面找东西。
class AgentLogDialog extends StatefulWidget {
  const AgentLogDialog({super.key});

  @override
  State<AgentLogDialog> createState() => _AgentLogDialogState();
}

class _LogEntry {
  const _LogEntry({
    required this.raw,
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final String raw;
  final String time;
  final String level;
  final String tag;
  final String message;

  /// 不是日志头（例如历史遗留的栈帧行）时，级别/tag 为空，整行原文显示
  static final RegExp _pattern = RegExp(
    r'^\[(\d{4}-\d{2}-\d{2} [\d:.]+)\]\s+\[(INFO|DEBUG|WARN|ERROR)\]\s+\[([^\]]+)\]\s?(.*)$',
    dotAll: true,
  );

  static _LogEntry parse(String line) {
    final m = _pattern.firstMatch(line);
    if (m == null) {
      return _LogEntry(raw: line, time: '', level: '', tag: '', message: line);
    }
    return _LogEntry(
      raw: line,
      time: m.group(1)!,
      level: m.group(2)!,
      tag: m.group(3)!,
      message: m.group(4)!,
    );
  }
}

class _AgentLogDialogState extends State<AgentLogDialog> {
  List<_LogEntry> _all = const [];
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  Timer? _refreshTimer;

  String? _levelFilter;
  String? _tagFilter;
  bool _currentTaskOnly = false;

  @override
  void initState() {
    super.initState();
    _loadLogs();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final distanceFromBottom = _scrollController.position.maxScrollExtent - _scrollController.offset;
      if (distanceFromBottom > 120 && _autoScroll) {
        setState(() => _autoScroll = false);
      }
      if (distanceFromBottom <= 40 && !_autoScroll) {
        setState(() => _autoScroll = true);
      }
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final newLogs = agentLogger.getLogs();
      if (newLogs.length != _all.length) {
        setState(() {
          _all = [for (final line in newLogs) _LogEntry.parse(line)];
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_autoScroll && _scrollController.hasClients) {
            _scrollController.animateTo(_scrollController.position.maxScrollExtent,
                duration: animNormal, curve: Curves.easeOut);
          }
        });
      }
    });
  }

  void _loadLogs() {
    _all = [for (final line in agentLogger.getLogs()) _LogEntry.parse(line)];
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  List<String> get _tags {
    final tags = <String>{
      for (final e in _all)
        if (e.tag.isNotEmpty) e.tag,
    }.toList()
      ..sort();
    return tags;
  }

  List<_LogEntry> get _visible {
    var list = _all;
    if (_currentTaskOnly) {
      final start = list.lastIndexWhere(
          (e) => e.tag == 'AgentEngine' && e.message.contains('=== 开始任务 ==='));
      if (start >= 0) list = list.sublist(start);
    }
    if (_levelFilter != null) {
      list = [for (final e in list) if (e.level == _levelFilter) e];
    }
    if (_tagFilter != null) {
      list = [for (final e in list) if (e.tag == _tagFilter) e];
    }
    return list;
  }

  Color _levelColor(_LogEntry e, ThemeColors tc) {
    switch (e.level) {
      case 'ERROR':
        return cDanger;
      case 'WARN':
        return cWarning;
      case 'DEBUG':
        return tc.textMuted;
      case 'INFO':
        return tc.textBody;
      default:
        return tc.textMuted;
    }
  }

  Widget _levelChip(String label, String? level, ThemeColors tc) {
    final selected = _levelFilter == level;
    return GestureDetector(
      onTap: () => setState(() => _levelFilter = level),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? tc.brand.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(
            color: selected ? tc.brand.withValues(alpha: 0.5) : tc.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fMicro,
            color: selected ? tc.brand : tc.textSub,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final visible = _visible;
    return Dialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.78,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text('Agent 日志',
                    style: TextStyle(
                        color: tc.textMain,
                        fontSize: fBody,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('共 ${_all.length} 条 · 显示 ${visible.length} 条',
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
                const Spacer(),
                IconButton(
                  tooltip: '复制当前筛选结果',
                  icon: Icon(Icons.copy_all, color: tc.textSub, size: 16),
                  onPressed: () async {
                    final ctx = context;
                    await Clipboard.setData(
                        ClipboardData(text: visible.map((e) => e.raw).join('\n')));
                    if (!ctx.mounted) return;
                    showTopSnackBar(ctx,
                      SnackBar(
                        content: Text('已复制 ${visible.length} 条日志',
                            style: const TextStyle(fontSize: 13)),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: tc.textSub, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _levelChip('全部', null, tc),
                _levelChip('INFO', 'INFO', tc),
                _levelChip('WARN', 'WARN', tc),
                _levelChip('ERROR', 'ERROR', tc),
                _levelChip('DEBUG', 'DEBUG', tc),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(rFull),
                    border: Border.all(color: tc.border, width: 0.5),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _tagFilter,
                      isDense: true,
                      dropdownColor: tc.cardElevated,
                      icon: Icon(Icons.arrow_drop_down, size: 16, color: tc.textSub),
                      style: TextStyle(fontSize: fMicro, color: tc.textSub),
                      hint: Text('全部 tag',
                          style: TextStyle(fontSize: fMicro, color: tc.textSub)),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('全部 tag')),
                        for (final tag in _tags)
                          DropdownMenuItem<String?>(
                              value: tag,
                              child: Text(tag,
                                  style: const TextStyle(fontSize: fMicro))),
                      ],
                      onChanged: (v) => setState(() => _tagFilter = v),
                    ),
                  ),
                ),
                // 只看本次任务：从最后一条「开始任务」截断，旧任务和启动日志不再混进来
                GestureDetector(
                  onTap: () => setState(() => _currentTaskOnly = !_currentTaskOnly),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _currentTaskOnly
                          ? tc.brand.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(rFull),
                      border: Border.all(
                        color: _currentTaskOnly
                            ? tc.brand.withValues(alpha: 0.5)
                            : tc.border,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _currentTaskOnly
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 13,
                          color: _currentTaskOnly ? tc.brand : tc.textSub,
                        ),
                        const SizedBox(width: 4),
                        Text('只看本次任务',
                            style: TextStyle(
                                fontSize: fMicro,
                                color: _currentTaskOnly ? tc.brand : tc.textSub)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Divider(color: tc.border, height: 16),
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: tc.bg,
                      borderRadius: BorderRadius.circular(rSmall),
                    ),
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final e = visible[index];
                          final color = _levelColor(e, tc);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text.rich(
                              TextSpan(children: [
                                if (e.time.isNotEmpty)
                                  TextSpan(
                                    text: '${e.time.substring(11)}  ',
                                    style: TextStyle(color: tc.textMuted),
                                  ),
                                if (e.tag.isNotEmpty) ...[
                                  TextSpan(
                                    text: '${e.tag}  ',
                                    style: TextStyle(
                                        color: tc.brand.withValues(alpha: 0.75)),
                                  ),
                                ],
                                TextSpan(text: e.message, style: TextStyle(color: color)),
                              ]),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontFamilyFallback: kMonoFontFallback,
                                fontSize: fMicro,
                                height: 1.45,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (!_autoScroll)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: () {
                          _autoScroll = true;
                          if (_scrollController.hasClients) {
                            _scrollController.animateTo(
                                _scrollController.position.maxScrollExtent,
                                duration: animNormal,
                                curve: Curves.easeOut);
                          }
                        },
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: tc.cardElevated,
                            borderRadius: BorderRadius.circular(rFull),
                            border: Border.all(color: tc.border),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 6)
                            ],
                          ),
                          child: Icon(Icons.keyboard_arrow_down,
                              size: 18, color: tc.textSub),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
