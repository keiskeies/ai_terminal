import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../models/chat_session.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isStreaming;
  final VoidCallback? onLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: EdgeInsets.only(
          bottom: 12,
          left: isUser ? 48 : 0,
          right: isUser ? 0 : 48,
        ),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // 头像和名称
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smart_toy, size: 14, color: cPrimary),
                    const SizedBox(width: 4),
                    Text(
                      'AI 助手',
                      style: TextStyle(fontSize: fSmall, color: cTextSub),
                    ),
                  ],
                ),
              ),

            // 消息内容
            GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isUser ? cPrimary : cCard,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(12),
                    topRight: const Radius.circular(12),
                    bottomLeft: Radius.circular(isUser ? 12 : 0),
                    bottomRight: Radius.circular(isUser ? 0 : 12),
                  ),
                ),
                child: isUser
                    ? Text(
                        message.content,
                        style: const TextStyle(color: Colors.white, fontSize: fBody),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarkdownBody(
                            data: message.content,
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(color: cTextMain, fontSize: fBody),
                              code: TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: fMono,
                                color: cTerminalGreen,
                                backgroundColor: const Color(0xFF2D2D2D),
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: const Color(0xFF1E1E1E),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              blockquote: TextStyle(color: cTextSub),
                              blockquoteDecoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(color: cBorder, width: 3),
                                ),
                              ),
                              h1: TextStyle(color: cTextMain, fontSize: 18, fontWeight: FontWeight.bold),
                              h2: TextStyle(color: cTextMain, fontSize: 16, fontWeight: FontWeight.bold),
                              h3: TextStyle(color: cTextMain, fontSize: 14, fontWeight: FontWeight.bold),
                              listBullet: TextStyle(color: cTextMain),
                              strong: const TextStyle(color: cTextMain, fontWeight: FontWeight.bold),
                              em: TextStyle(color: cTextMain, fontStyle: FontStyle.italic),
                              a: TextStyle(color: cPrimary),
                              tableHead: TextStyle(color: cTextMain, fontWeight: FontWeight.bold),
                              tableBody: TextStyle(color: cTextMain),
                              tableBorder: TableBorder.all(color: cBorder),
                            ),
                          ),
                          // 流式光标指示器
                          if (isStreaming)
                            Container(
                              width: 8,
                              height: 16,
                              margin: const EdgeInsets.only(top: 4),
                              decoration: BoxDecoration(
                                color: cPrimary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
              ),
            ),

            // 时间戳
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Text(
                _formatTime(message.timestamp),
                style: TextStyle(fontSize: 10, color: cTextSub),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
