import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_bubble.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String? hostId;

  const ChatPage({super.key, this.hostId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _canSend = false;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    // 监听滚动：用户手动上滚时禁用自动滚动
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
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final content = _inputController.text.trim();
    if (content.isEmpty) return;

    _autoScroll = true; // 用户发送消息时恢复自动滚动
    ref.read(chatProvider.notifier).sendMessage(
      content,
      hostId: widget.hostId,
    );
    _inputController.clear();
    setState(() => _canSend = false);
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _scrollToBottomManual() {
    _autoScroll = true;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final chatState = ref.watch(chatProvider);

    ref.listen(chatProvider, (_, state) {
      if (state.currentAssistantMessage != null || state.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });

    // 没有 hostId 时显示提示
    if (widget.hostId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.commonAIAssistant),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.terminal, size: 64, color: cPrimary),
                const SizedBox(height: 24),
                Text(
                  l10n.chatNeedTerminal,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: tc.textMain),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.chatConnectServerHint,
                  style: TextStyle(color: tc.textSub),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.arrow_back),
                  label: Text(l10n.chatBackToServerList),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cPrimary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.commonAIAssistant),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings/ai'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') {
                ref.read(chatProvider.notifier).clearSession();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'clear', child: Text(l10n.chatClearSession)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: chatState.messages.isEmpty && chatState.currentAssistantMessage == null
                ? _buildEmptyState()
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(pStandard),
                        itemCount: chatState.messages.length + (chatState.currentAssistantMessage != null ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (chatState.currentAssistantMessage != null &&
                              index == chatState.messages.length) {
                            // 正在输入的 AI 消息
                            return MessageBubble(
                              message: ChatMessage.create(
                                role: 'assistant',
                                content: chatState.currentAssistantMessage!,
                              ),
                              isStreaming: true,
                            );
                          }

                          final message = chatState.messages[index];
                          return MessageBubble(
                            message: message,
                            onLongPress: () => _copyMessage(message.content),
                          );
                        },
                      ),
                      // 回到底部按钮
                      if (!_autoScroll)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: GestureDetector(
                            onTap: _scrollToBottomManual,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: tc.card,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: tc.border),
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6)],
                              ),
                              child: Icon(Icons.keyboard_arrow_down, size: 20, color: tc.textSub),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),

          // 错误提示
          if (chatState.error != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: cDanger.withValues(alpha: 0.2),
              child: Row(
                children: [
                  const Icon(Icons.error, color: cDanger, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chatState.error!,
                      style: const TextStyle(color: cDanger, fontSize: fSmall),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => ref.read(chatProvider.notifier).cancelLoading(),
                  ),
                ],
              ),
            ),

          // 输入区
          Container(
            decoration: BoxDecoration(
              color: tc.card,
              border: Border(top: BorderSide(color: tc.border)),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        maxLines: 5,
                        minLines: 1,
                        onChanged: (value) {
                          final canSend = value.trim().isNotEmpty;
                          if (canSend != _canSend) {
                            setState(() => _canSend = canSend);
                          }
                        },
                        decoration: InputDecoration(
                          hintText: l10n.chatInputHint,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    _SendButton(
                      isLoading: chatState.isLoading,
                      canSend: _canSend,
                      onPressed: _sendMessage,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.smart_toy, size: 64, color: tc.textSub),
          const SizedBox(height: 16),
          Text(
            l10n.chatEmptyTitle,
            style: TextStyle(color: tc.textSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.chatEmptyHint,
            style: TextStyle(color: tc.textSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  void _copyMessage(String content) {
    final l10n = AppLocalizations.of(context)!;
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.commonCopiedToClipboard)),
    );
  }
}

/// 独立的发送按钮组件，避免输入时 rebuild 整页
class _SendButton extends StatelessWidget {
  final bool isLoading;
  final bool canSend;
  final VoidCallback onPressed;

  const _SendButton({
    required this.isLoading,
    required this.canSend,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return IconButton(
      icon: isLoading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.send, color: canSend ? cPrimary : tc.textSub),
      onPressed: canSend && !isLoading ? onPressed : null,
    );
  }
}
