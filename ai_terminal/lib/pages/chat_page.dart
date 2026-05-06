import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
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
          title: const Text('AI 助手'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.terminal, size: 64, color: cPrimary),
                const SizedBox(height: 24),
                Text(
                  'AI 助手需要在终端中使用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: cTextMain),
                ),
                const SizedBox(height: 12),
                Text(
                  '请先连接服务器，进入终端页面后点击右下角的 AI 按钮',
                  style: TextStyle(color: cTextSub),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回服务器列表'),
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
        title: const Text('AI 助手'),
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
              const PopupMenuItem(value: 'clear', child: Text('清空会话')),
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
                                color: cCard,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: cBorder),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6)],
                              ),
                              child: Icon(Icons.keyboard_arrow_down, size: 20, color: cTextSub),
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
              color: cDanger.withOpacity(0.2),
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
              color: cCard,
              border: Border(top: BorderSide(color: cBorder)),
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
                        onChanged: (value) => setState(() => _canSend = value.trim().isNotEmpty),
                        decoration: const InputDecoration(
                          hintText: '输入指令或问题...',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    IconButton(
                      icon: chatState.isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.send, color: _canSend ? cPrimary : cTextSub),
                      onPressed: _canSend && !chatState.isLoading ? _sendMessage : null,
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.smart_toy, size: 64, color: cTextSub),
          const SizedBox(height: 16),
          Text(
            '有什么可以帮你的？',
            style: TextStyle(color: cTextSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            '例如：安装 Docker、查看内存使用',
            style: TextStyle(color: cTextSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  void _copyMessage(String content) {
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }
}
