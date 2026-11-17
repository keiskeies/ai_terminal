import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/knowledge_rule.dart';
import '../services/daos.dart';
import 'inline_form.dart';

/// 内部规范编辑器（抽屉内联版）。
///
/// 规范是自然语言约定，字段就三项（标题/内容/参考命令）加作用域。
/// 以前是一个 560 宽的 AlertDialog，比设置里任何一行都大；现在跟着抽屉走。
class RuleEditorForm extends StatefulWidget {
  const RuleEditorForm({
    super.key,
    this.rule,
    required this.onSave,
    required this.onCancel,
  });

  final KnowledgeRule? rule;
  final ValueChanged<KnowledgeRule> onSave;
  final VoidCallback onCancel;

  @override
  State<RuleEditorForm> createState() => _RuleEditorFormState();
}

class _RuleEditorFormState extends State<RuleEditorForm> {
  static const _uuid = Uuid();

  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _commands;
  late KnowledgeRuleScope _scope;
  late String _group;
  late String _hostId;
  late bool _strict;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _title = TextEditingController(text: rule?.title ?? '');
    _content = TextEditingController(text: rule?.content ?? '');
    _commands = TextEditingController(text: rule?.commands ?? '');
    _scope = rule?.scope ?? KnowledgeRuleScope.global;
    _group = rule?.group ??
        (HostsDao.cached.isNotEmpty ? HostsDao.cached.first.group : '默认');
    _hostId = rule?.hostId ??
        (HostsDao.cached.isNotEmpty ? HostsDao.cached.first.id : '');
    _strict = rule?.strict ?? true;
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _commands.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      setState(() =>
          _error = UiText.t('请填写标题', 'Title is required'));
      return;
    }
    if (_content.text.trim().isEmpty) {
      setState(() => _error =
          UiText.t('请填写规范内容', 'Rule content is required'));
      return;
    }
    final rule = widget.rule ??
        (KnowledgeRule()
          ..id = _uuid.v4()
          ..enabled = true);
    rule.title = _title.text.trim();
    rule.content = _content.text.trim();
    rule.commands = _commands.text.trim();
    rule.scope = _scope;
    rule.group = _scope == KnowledgeRuleScope.group ? _group : null;
    rule.hostId = _scope == KnowledgeRuleScope.host ? _hostId : null;
    rule.strict = _strict;
    widget.onSave(rule);
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final groups = HostsDao.cached.map((h) => h.group).toSet().toList()..sort();
    if (groups.isEmpty) groups.add('默认');
    final hosts = HostsDao.cached;
    return InlineSheet(
      title: widget.rule != null
          ? UiText.t('编辑规范', 'Edit rule')
          : UiText.t('新增规范', 'New rule'),
      onBack: widget.onCancel,
      error: _error,
      actions: [
        InlineButton(
            label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
            label: UiText.t('保存', 'Save'), primary: true, onTap: _save),
      ],
      children: [
        InlineField(
          label: UiText.t('标题', 'Title'),
          controller: _title,
          hint: UiText.t('例如：nginx 只改 conf.d', 'e.g. nginx via conf.d only'),
        ),
        const SizedBox(height: 10),
        InlineField(
          label: UiText.t('规范内容', 'Rule'),
          controller: _content,
          maxLines: 6,
          hint: UiText.t(
              '用自然语言写清楚约束，AI 会原样遵循。',
              'Describe the constraint in plain language.'),
        ),
        const SizedBox(height: 10),
        InlineField(
          label: UiText.t('参考命令（可选）', 'Reference commands (optional)'),
          controller: _commands,
          mono: true,
          maxLines: 3,
          hint: 'apt -o Dir::Etc::sourcelist=... update',
        ),
        const SizedBox(height: 10),
        InlineSelect<KnowledgeRuleScope>(
          label: UiText.t('作用域', 'Scope'),
          value: _scope,
          items: [
            (KnowledgeRuleScope.global, UiText.t('全局', 'Global')),
            (KnowledgeRuleScope.group, UiText.t('主机组', 'Group')),
            (KnowledgeRuleScope.host, UiText.t('单台主机', 'Host')),
          ],
          onChanged: (v) => setState(() => _scope = v),
        ),
        if (_scope == KnowledgeRuleScope.group) ...[
          const SizedBox(height: 10),
          InlineSelect<String>(
            label: UiText.t('主机组', 'Host group'),
            value: groups.contains(_group) ? _group : groups.first,
            items: [
              for (final g in groups) (g, UiText.hostGroup(g)),
            ],
            onChanged: (v) => setState(() => _group = v),
          ),
        ],
        if (_scope == KnowledgeRuleScope.host) ...[
          const SizedBox(height: 10),
          if (hosts.isEmpty)
            Text(
              UiText.t('还没有主机，无法限定到单台。', 'No hosts yet.'),
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            )
          else
            InlineSelect<String>(
              label: UiText.t('主机', 'Host'),
              value: hosts.any((h) => h.id == _hostId)
                  ? _hostId
                  : hosts.first.id,
              items: [
                for (final h in hosts) (h.id, '${h.name} · ${h.host}'),
              ],
              onChanged: (v) => setState(() => _hostId = v),
            ),
        ],
        const SizedBox(height: 8),
        InlineSwitchRow(
          label: UiText.t('严格遵循', 'Strict'),
          subtitle: _strict
              ? UiText.t('AI 必须原样执行，不得自行调整',
                  'The AI must follow this verbatim')
              : UiText.t('允许 AI 在不违背约定前提下调整参数',
                  'The AI may tune parameters within this rule'),
          value: _strict,
          onChanged: (v) => setState(() => _strict = v),
        ),
      ],
    );
  }
}
