import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../providers/agent_provider.dart';
import '../services/conversation_service.dart';
import '../models/conversation.dart';

/// 会话历史对话框
class SessionHistoryDialog extends ConsumerStatefulWidget {
  const SessionHistoryDialog({super.key});

  @override
  ConsumerState<SessionHistoryDialog> createState() => _SessionHistoryDialogState();
}

class _SessionHistoryDialogState extends ConsumerState<SessionHistoryDialog> {
  List<Conversation> _sessions = [];
  String? _activeId;
  final ConversationService _convService = ConversationService();

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  void _loadSessions() {
    final agentState = ref.read(agentProvider);
    final hostId = agentState.hostId ?? 'local';
    setState(() {
      _sessions = _convService.listSessions(hostId);
      _activeId = agentState.conversationId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Dialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.55,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text('会话历史', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                const Spacer(),
                // 新建会话按钮
                TextButton.icon(
                  onPressed: () async {
                    final ctx = context;
                    await ref.read(agentProvider.notifier).newSession();
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                  },
                  icon: const Icon(Icons.add, size: 14, color: cPrimary),
                  label: const Text('新建', style: TextStyle(fontSize: fSmall, color: cPrimary)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: tc.textSub, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            const Divider(color: cBorder, height: 16),
            Expanded(
              child: _sessions.isEmpty
                  ? Center(child: Text('暂无会话', style: TextStyle(color: tc.textMuted, fontSize: fBody)))
                  : ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        final conv = _sessions[index];
                        final isActive = conv.id == _activeId;
                        return _buildSessionTile(conv, isActive, tc);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(Conversation conv, bool isActive, ThemeColors tc) {
    final msgCount = conv.messages.length;
    final hasSummary = conv.summary != null && conv.summary!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isActive ? cPrimary.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(
          color: isActive ? cPrimary.withValues(alpha: 0.3) : tc.border.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(rSmall),
        onTap: () async {
          await ref.read(agentProvider.notifier).switchSession(conv.id);
          _loadSessions();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isActive)
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: const BoxDecoration(
                              color: cPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            conv.title,
                            style: TextStyle(
                              color: isActive ? cPrimary : tc.textMain,
                              fontSize: fBody,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '${conv.updatedAt.month}/${conv.updatedAt.day} ${conv.updatedAt.hour.toString().padLeft(2, '0')}:${conv.updatedAt.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$msgCount 条消息',
                          style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                        ),
                        if (hasSummary) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: cAgentGreen.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(rXSmall),
                            ),
                            child: const Text(
                              '已压缩',
                              style: TextStyle(color: cAgentGreen, fontSize: fMicro),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // 重命名按钮
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 14, color: tc.textSub),
                onPressed: () => _showRenameDialog(conv),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '重命名',
              ),
              // 删除按钮
              IconButton(
                icon: Icon(Icons.delete_outline, size: 14, color: tc.textSub),
                onPressed: () => _confirmDelete(conv),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '删除',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRenameDialog(Conversation conv) {
    final controller = TextEditingController(text: conv.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('重命名会话', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody),
          decoration: InputDecoration(
            hintText: '输入会话名称',
            hintStyle: TextStyle(color: ThemeColors.of(context).textMuted),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
          ),
          ElevatedButton(
            onPressed: () async {
              final title = controller.text.trim();
              if (title.isNotEmpty) {
                await _convService.rename(conv.id, title);
                _loadSessions();
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: const Text('保存', style: TextStyle(fontSize: fBody)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Conversation conv) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('删除会话？', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Text('会话「${conv.title}」的所有消息和日志将被永久删除，无法恢复。',
            style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fSmall)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
          ),
          ElevatedButton(
            onPressed: () async {
              await ref.read(agentProvider.notifier).deleteSession(conv.id);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _loadSessions();
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger, foregroundColor: Colors.white),
            child: const Text('删除', style: TextStyle(fontSize: fBody)),
          ),
        ],
      ),
    );
  }
}
