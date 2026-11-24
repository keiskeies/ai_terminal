import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/command_snippet.dart';
import '../models/runbook.dart';
import 'inline_form.dart';

const _uuid = Uuid();

/// 抽屉里的编辑表单外壳：字段区自己滚，底部固定「取消 / 保存」。
///
/// 和设置组里的 [InlineSheet] 是同一套视觉，但**返回交给抽屉顶栏**（←），
/// 所以这里不再画第二个返回按钮，也不会出现「卡片里套卡片」。
class DrawerFormBody extends StatelessWidget {
  const DrawerFormBody({
    super.key,
    required this.children,
    required this.onCancel,
    required this.onSave,
    this.saveLabel,
    this.error,
    this.busy = false,
  });

  final List<Widget> children;
  final VoidCallback onCancel;
  final VoidCallback onSave;
  final String? saveLabel;
  final String? error;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            children: [
              for (final (i, w) in children.indexed) ...[
                if (i > 0) const SizedBox(height: 14),
                w,
              ],
              if (error != null && error!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(error!,
                    style: TextStyle(
                        fontSize: fSmall, color: tc.error, height: 1.4)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Spacer(),
            InlineButton(label: UiText.t('取消', 'Cancel'), onTap: onCancel),
            const SizedBox(width: 8),
            InlineButton(
              label: saveLabel ?? UiText.t('保存', 'Save'),
              primary: true,
              busy: busy,
              onTap: onSave,
            ),
          ],
        ),
      ],
    );
  }
}

/// 快捷命令：名称 / 命令（可含 {{变量}}）/ 说明。
class SnippetEditorForm extends StatefulWidget {
  const SnippetEditorForm({
    super.key,
    this.initial,
    required this.onCancel,
    required this.onSaved,
  });

  final CommandSnippet? initial;
  final VoidCallback onCancel;
  final Future<void> Function(CommandSnippet snippet) onSaved;

  @override
  State<SnippetEditorForm> createState() => _SnippetEditorFormState();
}

class _SnippetEditorFormState extends State<SnippetEditorForm> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _command =
      TextEditingController(text: widget.initial?.command ?? '');
  late final _description =
      TextEditingController(text: widget.initial?.description ?? '');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final command = _command.text.trim();
    if (name.isEmpty || command.isEmpty) {
      setState(() => _error = UiText.t(
          name.isEmpty ? '起个名字，列表里才认得出。' : '命令不能为空。',
          name.isEmpty
              ? 'Name it so the list stays readable.'
              : 'Command is required.'));
      return;
    }
    final description = _description.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    final old = widget.initial;
    await widget.onSaved(CommandSnippet.create(
      id: old?.id ?? _uuid.v4(),
      name: name,
      command: command,
      description: description.isEmpty ? null : description,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return DrawerFormBody(
      onCancel: widget.onCancel,
      onSave: _save,
      error: _error,
      busy: _saving,
      children: [
        InlineField(label: UiText.t('名称', 'Name'), controller: _name),
        InlineField(
          label: UiText.t('命令', 'Command'),
          controller: _command,
          mono: true,
          maxLines: 5,
          hint: 'docker exec -it {{container}} /bin/bash',
        ),
        InlineField(
          label: UiText.t('说明', 'Description'),
          controller: _description,
          maxLines: 2,
        ),
      ],
    );
  }
}

/// 运维工作流：图标 / 名称 / 类型 / 分类 / 说明 / 内容。
/// 内置模板只读，跟整页编辑器一致。
class RunbookEditorForm extends StatefulWidget {
  const RunbookEditorForm({
    super.key,
    this.initial,
    required this.onCancel,
    required this.onSaved,
  });

  final Runbook? initial;
  final VoidCallback onCancel;
  final Future<void> Function(Runbook runbook) onSaved;

  @override
  State<RunbookEditorForm> createState() => _RunbookEditorFormState();
}

class _RunbookEditorFormState extends State<RunbookEditorForm> {
  static const _icons = <String>[
    '🩺',
    '🛡️',
    '💾',
    '🌐',
    '⚙️',
    '🔐',
    '🚀',
    '📦',
    '🔧',
    '📋',
    '🔥',
    '⚠️',
    '✅',
    '🔍',
    '📈',
  ];

  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _description =
      TextEditingController(text: widget.initial?.description ?? '');
  late final _content =
      TextEditingController(text: widget.initial?.content ?? '');
  late RunbookType _type = widget.initial?.type ?? RunbookType.agent;
  late RunbookCategory _category =
      widget.initial?.category ?? RunbookCategory.custom;
  late String _icon =
      widget.initial?.icon.isEmpty == false ? widget.initial!.icon : '📋';
  String? _error;
  bool _saving = false;

  bool get _isBuiltin => widget.initial?.isBuiltin ?? false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _content.dispose();
    super.dispose();
  }

  String _categoryLabel(RunbookCategory c) => switch (c) {
        RunbookCategory.inspection => UiText.t('巡检', 'Inspection'),
        RunbookCategory.security => UiText.t('安全', 'Security'),
        RunbookCategory.deployment => UiText.t('部署', 'Deployment'),
        RunbookCategory.troubleshooting => UiText.t('故障排查', 'Troubleshooting'),
        RunbookCategory.maintenance => UiText.t('日常维护', 'Maintenance'),
        RunbookCategory.custom => UiText.t('自定义', 'Custom'),
      };

  Future<void> _save() async {
    if (_isBuiltin) return;
    final name = _name.text.trim();
    final content = _content.text.trim();
    if (name.isEmpty || content.isEmpty) {
      setState(() => _error = UiText.t(
          name.isEmpty ? '起个名字，列表里才认得出。' : '内容不能为空。',
          name.isEmpty ? 'Name is required.' : 'Content is required.'));
      return;
    }
    final description = _description.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    final old = widget.initial;
    await widget.onSaved(Runbook.create(
      id: old?.id ?? _uuid.v4(),
      name: name,
      icon: _icon,
      type: _type,
      category: _category,
      content: content,
      description: description.isEmpty ? null : description,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return DrawerFormBody(
      onCancel: widget.onCancel,
      onSave: _isBuiltin ? () {} : _save,
      saveLabel:
          _isBuiltin ? UiText.t('内置模板只读', 'Built-in is read-only') : null,
      error: _error,
      busy: _saving,
      children: [
        Text(UiText.t('图标', 'Icon'),
            style: TextStyle(fontSize: fMicro, color: tc.textSub)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in _icons)
              GestureDetector(
                onTap: _isBuiltin ? null : () => setState(() => _icon = e),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e == _icon ? tc.brandBg : tc.surface,
                    borderRadius: BorderRadius.circular(rSmall),
                    border:
                        Border.all(color: e == _icon ? tc.brand : tc.border),
                  ),
                  child: Text(e, style: const TextStyle(fontSize: 15)),
                ),
              ),
          ],
        ),
        InlineField(
          label: UiText.t('名称', 'Name'),
          controller: _name,
          onChanged: _isBuiltin ? null : (_) {},
        ),
        InlineSelect<RunbookType>(
          label: UiText.t('类型', 'Type'),
          value: _type,
          items: [
            (
              RunbookType.agent,
              UiText.t('AI 执行（自然语言步骤）', 'AI (natural-language steps)')
            ),
            (RunbookType.command, UiText.t('直接执行（shell 命令）', 'Shell commands')),
          ],
          onChanged: (v) => setState(() => _type = v),
        ),
        InlineSelect<RunbookCategory>(
          label: UiText.t('分类', 'Category'),
          value: _category,
          items: [
            for (final c in RunbookCategory.values) (c, _categoryLabel(c)),
          ],
          onChanged: (v) => setState(() => _category = v),
        ),
        InlineField(
          label: UiText.t('说明', 'Description'),
          controller: _description,
          maxLines: 2,
        ),
        InlineField(
          label: _type == RunbookType.agent
              ? UiText.t('步骤（写给 AI）', 'Steps (for the AI)')
              : UiText.t('命令', 'Commands'),
          controller: _content,
          mono: true,
          maxLines: 10,
          hint:
              UiText.t('可用 {{host}}、{{user}} 等变量。', 'Use {{host}}, {{user}}…'),
        ),
      ],
    );
  }
}
