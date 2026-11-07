import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../utils/live_thought_text.dart';

/// 模型原生推理块（reasoning_content / reasoning）。
///
/// 只有部分网关返回该字段；这不是 ReAct 的「思考:」，而是模型自己的推理流。
/// 限高避免长推理把正文挤走，任务结束即从状态里清掉。
class ModelReasoningBlock extends StatelessWidget {
  const ModelReasoningBlock({
    super.key,
    required this.text,
    required this.tc,
  });

  final String text;
  final ThemeColors tc;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: tc.dataCard,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology_outlined, size: 13, color: tc.textSub),
              const SizedBox(width: 4),
              Text(UiText.t('模型思考', 'Model thinking'),
                  style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              primary: false,
              child: Text(
                text,
                style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式过程中的当前步「思考中」块。
///
/// ReAct 原文里混着 思考/动作/命令/选项 等协议行，展示前先剥掉协议，
/// 只把正在生成的思考正文逐字显示出来；步骤结束由结构化事件接管。
class LiveThoughtBlock extends StatelessWidget {
  const LiveThoughtBlock({
    super.key,
    required this.rawText,
    required this.tc,
  });

  final String rawText;
  final ThemeColors tc;

  @override
  Widget build(BuildContext context) {
    final text = extractLiveThought(rawText);
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 静态图标而不是 CircularProgressIndicator：流式可能持续几十秒，
              // 常驻 spinner 会以满帧率持续调度重绘，把整机的 GPU 占用拉高
              Icon(Icons.psychology_outlined, size: 11, color: tc.brand),
              const SizedBox(width: 5),
              Text(UiText.t('思考中', 'Thinking'), style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            text,
            style: TextStyle(color: tc.textMain, fontSize: fBody, height: 1.5),
          ),
        ],
      ),
    );
  }
}
