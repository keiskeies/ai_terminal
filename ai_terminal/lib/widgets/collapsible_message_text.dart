import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../utils/agent_ui_text.dart';

/// 消息正文的收起/展开：默认最多两行。
///
/// 目标续跑那类用户消息动辄十几行，整段铺开会把这一轮的 Agent 输出挤出屏幕。
/// 两行以内不出现切换控件，避免每条消息都挂一个没用的「展开」。
class CollapsibleMessageText extends StatefulWidget {
  const CollapsibleMessageText({
    super.key,
    required this.text,
    required this.style,
    this.collapsedLines = 2,
  });

  final String text;
  final TextStyle style;
  final int collapsedLines;

  @override
  State<CollapsibleMessageText> createState() => _CollapsibleMessageTextState();
}

class _CollapsibleMessageTextState extends State<CollapsibleMessageText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final ui = AgentUiText.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: widget.collapsedLines,
        textDirection: Directionality.of(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      if (!overflows && !_expanded) {
        return Text(widget.text, style: widget.style);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            style: widget.style,
            maxLines: _expanded ? null : widget.collapsedLines,
            overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _expanded ? ui.collapse : ui.expandText,
                    style: TextStyle(fontSize: fMicro, color: tc.textSub),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: tc.textSub,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }
}
