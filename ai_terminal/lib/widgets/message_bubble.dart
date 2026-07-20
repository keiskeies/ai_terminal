import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/chat_session.dart';
import 'logo_widget.dart';

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
    final tc = ThemeColors.of(context);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        margin: EdgeInsets.only(
          bottom: 16,
          left: isUser ? 48 : 0,
          right: isUser ? 0 : 48,
        ),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // 头像和名称
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const LogoWidget(type: LogoType.mark, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'AI 助手',
                      style: TextStyle(fontSize: fSmall, color: tc.textSub, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),

            // 消息内容
            GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isUser ? cPrimary : tc.card,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(rBubble),
                    topRight: const Radius.circular(rBubble),
                    bottomLeft: Radius.circular(isUser ? rBubble : rXSmall),
                    bottomRight: Radius.circular(isUser ? rXSmall : rBubble),
                  ),
                  border: isUser
                      ? null
                      : Border.all(color: tc.border),
                ),
                child: isUser
                    ? SelectableText(
                        message.content,
                        style: const TextStyle(color: Colors.white, fontSize: fBody, height: 1.5),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarkdownBody(
                            data: message.content,
                            selectable: true,
                            // 规避 flutter_markdown 0.6.23 在 selectable=true 时无条件调用 onSelectionChanged!() 的 bug
                            onSelectionChanged: (_, __, ___) {},
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(color: tc.textBody, fontSize: fBody, height: 1.5),
                              code: TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: fMono,
                                color: tc.terminalGreen,
                                backgroundColor: tc.terminalBg,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: tc.terminalOutput,
                                borderRadius: BorderRadius.circular(rSmall),
                                border: Border.all(color: tc.border),
                              ),
                              blockquote: TextStyle(color: tc.textSub),
                              blockquoteDecoration: const BoxDecoration(
                                border: Border(
                                  left: BorderSide(color: cPrimary, width: 2),
                                ),
                              ),
                              h1: TextStyle(color: tc.textMain, fontSize: fTitle, fontWeight: FontWeight.bold),
                              h2: TextStyle(color: tc.textMain, fontSize: fBody + 2, fontWeight: FontWeight.bold),
                              h3: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600),
                              listBullet: TextStyle(color: tc.textMain),
                              strong: TextStyle(color: tc.textMain, fontWeight: FontWeight.bold),
                              em: TextStyle(color: tc.textMain, fontStyle: FontStyle.italic),
                              a: const TextStyle(color: cPrimary),
                              tableHead: TextStyle(color: tc.textMain, fontWeight: FontWeight.bold),
                              tableBody: TextStyle(color: tc.textMain),
                              tableBorder: TableBorder.all(color: tc.border),
                            ),
                          ),
                          // 流式光标指示器
                          if (isStreaming)
                            Container(
                              width: 6,
                              height: 14,
                              margin: const EdgeInsets.only(top: 6),
                              decoration: const BoxDecoration(
                                color: cPrimary,
                                borderRadius: BorderRadius.all(Radius.circular(1)),
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
                style: TextStyle(fontSize: fMicro, color: tc.textMuted),
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
