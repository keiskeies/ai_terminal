import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/agent_event.dart';

/// 询问的两态渲染
///
/// - [AgentAskCard]：**等待作答**时的完整卡片。问题 + 可点选项 + 自定义输入，
///   永远完整展示（用户必须能立刻看到并作答，折叠起来等于把问题藏了）。
/// - [AgentAskStepRow]：**已作答**后的步骤行。像命令行一样收成一行：
///   ❓ 问题摘要 + 绿色答案胶囊，点开才展开完整问题、当时的选项和用户的回答。
///   "问过什么、选了什么"必须留在步骤流里 —— 答完就消失等于过程断档。
///
/// 提问是 agent 输出过程中真实发生的一步，必须和命令/思考按发生顺序排在一起，
/// 不能在流程之外单独飘着。

/// 等待作答的询问卡：问题 + 可点选项 + 自定义回答
class AgentAskCard extends StatelessWidget {
  final AgentEvent event;
  final ThemeColors tc;

  /// 问题正文渲染（Markdown）
  final Widget Function(String text, ThemeColors tc) markdownBuilder;

  /// 选项点击回调（null 时只展示不可点）
  final void Function(String choice)? onSelectChoice;

  const AgentAskCard({
    super.key,
    required this.event,
    required this.tc,
    required this.markdownBuilder,
    this.onSelectChoice,
  });

  @override
  Widget build(BuildContext context) {
    final options = event.options ?? const [];
    final question = (event.question ?? event.text ?? '').trim();
    final title = question.isEmpty ? '请选择' : question;
    final pending = onSelectChoice != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.agentCardBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: tc.brand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.help_outline, size: 13, color: tc.brand),
              ),
              const SizedBox(width: 8),
              Expanded(
                // 问题正文可能带 Markdown（表格/加粗/列表），
                // 与普通正文共用同一套渲染，避免把表格原样显示成竖线文本。
                child: markdownBuilder(title, tc),
              ),
            ],
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options
                  .map((opt) => AgentAskOptionChip(
                        label: opt,
                        tc: tc,
                        selectable: pending,
                        onTap: onSelectChoice,
                      ))
                  .toList(),
            ),
          ],
          if (pending) ...[
            const SizedBox(height: 10),
            AgentAskCustomAnswerField(
              tc: tc,
              onSubmit: (answer) => onSelectChoice?.call(answer),
            ),
          ],
        ],
      ),
    );
  }
}

/// 选项胶囊：可点时是按钮，不可点时只是"当时的选项"留档
class AgentAskOptionChip extends StatelessWidget {
  final String label;
  final ThemeColors tc;
  final bool selectable;
  final void Function(String choice)? onTap;

  const AgentAskOptionChip({
    super.key,
    required this.label,
    required this.tc,
    required this.selectable,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selectable ? tc.brand : tc.textMuted;
    return GestureDetector(
      onTap: selectable ? () => onTap?.call(label) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(
              color: accent.withValues(alpha: selectable ? 0.3 : 0.18)),
          boxShadow: [
            BoxShadow(
              color: tc.brand.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selectable ? Icons.touch_app : Icons.radio_button_unchecked,
                size: 12, color: accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: fSmall,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已作答的询问步骤行：一行摘要 + 点开看全文
///
/// 收起态：❓ + 问题（单行省略）+ 绿色答案胶囊 + 展开箭头
/// 展开态：完整问题 + 当时的选项 + 用户的选择
class AgentAskStepRow extends StatefulWidget {
  final AgentEvent event;

  /// 用户选了什么（引擎回写到事件上；旧数据可能为 null）
  final String? chosen;

  final ThemeColors tc;

  /// 展开后的完整内容（问题 Markdown + 当时的选项）
  final Widget expanded;

  const AgentAskStepRow({
    super.key,
    required this.event,
    required this.chosen,
    required this.tc,
    required this.expanded,
  });

  @override
  State<AgentAskStepRow> createState() => _AgentAskStepRowState();
}

class _AgentAskStepRowState extends State<AgentAskStepRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final question =
        (widget.event.question ?? widget.event.text ?? '').trim();
    final title = question.isEmpty ? '请选择' : question;
    final chosen = widget.chosen;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        // 与命令行/正文/结果卡同一套框：透明填充 + 1px 边框 + rCard 圆角
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.agentCardBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.help_outline, size: 13, color: tc.brand),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.textBody, fontSize: fSmall),
                    ),
                  ),
                  if (chosen != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: tc.ok.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(rFull),
                          border: Border.all(
                              color: tc.ok.withValues(alpha: 0.35), width: 0.5),
                        ),
                        child: Text(
                          chosen,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: tc.ok,
                              fontSize: fMicro,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: tc.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tc.border, width: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  widget.expanded,
                  if (chosen != null) ...[
                    const SizedBox(height: pSmall),
                    Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 13, color: tc.ok),
                        const SizedBox(width: 6),
                        Text(
                          '你的选择：$chosen',
                          style: TextStyle(
                              color: tc.ok, fontSize: fMicro, height: 1.4),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// ask 选项之外的自由输入：按钮覆盖不到用户想法时，直接回一句话。
class AgentAskCustomAnswerField extends StatefulWidget {
  final ThemeColors tc;
  final void Function(String answer) onSubmit;

  const AgentAskCustomAnswerField({
    super.key,
    required this.tc,
    required this.onSubmit,
  });

  @override
  State<AgentAskCustomAnswerField> createState() =>
      _AgentAskCustomAnswerFieldState();
}

class _AgentAskCustomAnswerFieldState extends State<AgentAskCustomAnswerField> {
  final _controller = TextEditingController();
  bool _submitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? _]) {
    final text = _controller.text.trim();
    if (text.isEmpty || _submitted) return;
    _submitted = true;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(rSmall),
      borderSide: BorderSide(color: tc.border),
    );
    return TextField(
      controller: _controller,
      style: TextStyle(color: tc.textMain, fontSize: fSmall),
      cursorColor: tc.brand,
      textInputAction: TextInputAction.send,
      onSubmitted: (value) => _submit(value),
      decoration: InputDecoration(
        isDense: true,
        hintText: UiText.t('按钮都不合适？直接输入你的回答…',
            'None of these fit? Type your answer…'),
        hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
        filled: true,
        fillColor: tc.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rSmall),
          borderSide: BorderSide(color: tc.brand.withValues(alpha: 0.5)),
        ),
        suffixIcon: IconButton(
          tooltip: '发送自定义回答',
          icon: Icon(Icons.send, size: 16, color: tc.brand),
          onPressed: _submit,
        ),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 32),
      ),
    );
  }
}
