import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/agent_engine.dart';

/// Agent 日志查看器对话框
class AgentLogDialog extends StatefulWidget {
  const AgentLogDialog({super.key});

  @override
  State<AgentLogDialog> createState() => _AgentLogDialogState();
}

class _AgentLogDialogState extends State<AgentLogDialog> {
  List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadLogs();
    // 监听滚动：用户手动上滚时禁用自动滚动，滚到底部时恢复
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final distanceFromBottom = _scrollController.position.maxScrollExtent - _scrollController.offset;
      if (distanceFromBottom > 120 && _autoScroll) {
        _autoScroll = false;
        setState(() {});
      }
      if (distanceFromBottom <= 40 && !_autoScroll) {
        _autoScroll = true;
        setState(() {});
      }
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) { timer.cancel(); return; }
      // 仅当日志数量变化时才 setState，避免无谓重建
      final newLogs = agentLogger.getLogs();
      if (newLogs.length != _logs.length) {
        setState(() {
          _logs = newLogs.isEmpty ? ['暂无日志...'] : newLogs;
        });
        // 下一帧再滚动，给 scrollController listener 时间检测用户是否手动上滚过
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_autoScroll && _scrollController.hasClients) {
            _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: animNormal, curve: Curves.easeOut);
          }
        });
      }
    });
  }

  void _loadLogs() {
    _logs = agentLogger.getLogs();
    if (_logs.isEmpty) _logs = ['暂无日志...'];
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Dialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.75,
        height: MediaQuery.of(context).size.height * 0.65,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text('Agent 日志', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                const Spacer(),
                // 复制全部按钮
                IconButton(
                  tooltip: '复制全部日志',
                  icon: Icon(Icons.copy_all, color: tc.textSub, size: 16),
                  onPressed: () async {
                    final ctx = context;
                    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text('已复制 ${_logs.length} 条日志', style: const TextStyle(fontSize: 13)),
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
            Divider(color: tc.border, height: 16),
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: tc.bg,
                      borderRadius: BorderRadius.circular(rSmall),
                    ),
                    // SelectionArea 包裹整个 ListView，实现跨行自由选择复制
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          Color color = tc.textSub;
                          if (log.contains('[ERROR]')) {
                            color = cDanger;
                          } else if (log.contains('[WARN]')) {
                            color = cWarning;
                          } else if (log.contains('[DEBUG]')) {
                            color = tc.textMuted;
                          } else if (log.contains('[INFO]')) {
                            color = cSuccess;
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 0.5),
                            child: Text(log, style: TextStyle(fontFamily: 'monospace', fontSize: fMicro, color: color)),
                          );
                        },
                      ),
                    ),
                  ),
                  // 回到底部按钮
                  if (!_autoScroll)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: () {
                          _autoScroll = true;
                          if (_scrollController.hasClients) {
                            _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: animNormal, curve: Curves.easeOut);
                          }
                        },
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: tc.cardElevated,
                            borderRadius: BorderRadius.circular(rFull),
                            border: Border.all(color: tc.border),
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)],
                          ),
                          child: Icon(Icons.keyboard_arrow_down, size: 18, color: tc.textSub),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('共 ${_logs.length} 条', style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
          ],
        ),
      ),
    );
  }
}
