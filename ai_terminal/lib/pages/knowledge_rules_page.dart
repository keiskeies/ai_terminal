import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/app_toast.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../models/knowledge_rule.dart';
import '../providers/knowledge_rule_provider.dart';
import '../services/daos.dart';
import '../core/l10n_holder.dart';

const _uuid = Uuid();

/// 内部规范：用户自维护、注入给 AI 的组织约定
///
/// 与官方知识库的区别是这里以自然语言规则为主体 —— 公司习惯（走内网源、
/// 不改主配置、端口非默认）无法用结构化命令卡表达。
class KnowledgeRulesPage extends ConsumerStatefulWidget {
  const KnowledgeRulesPage({super.key});

  @override
  ConsumerState<KnowledgeRulesPage> createState() => _KnowledgeRulesPageState();
}

class _KnowledgeRulesPageState extends ConsumerState<KnowledgeRulesPage> {
  Future<void> _export() async {
    final rules = ref.read(knowledgeRulesProvider);
    if (rules.isEmpty) {
      if (!mounted) return;
      showTopSnackBar(context,
        SnackBar(
          content: Text(UiText.t('没有可导出的规范条目', 'Nothing to export')),
          backgroundColor: cWarning,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final json = ref.read(knowledgeRulesProvider.notifier).exportJson();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: UiText.t('导出内部规范', 'Export internal rules'),
      fileName: 'knowledge-rules.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    try {
      await File(path).writeAsString(json);
      if (!mounted) return;
      showTopSnackBar(context,
        SnackBar(
          content: Text(L10n.str.ut_cbd8c9bc33(rules.length, path)),
          backgroundColor: cSuccess,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context,
        SnackBar(
          content: Text(L10n.str.ut_b078e9e8b1(e)),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: UiText.t('导入内部规范', 'Import internal rules'),
    );
    final path = result?.files.single.path;
    if (path == null) return;

    try {
      final source = await File(path).readAsString();
      // 主机作用域在别的设备上无意义，本机没有对应主机则跳过该条
      final knownHostIds = HostsDao.cached.map((h) => h.id).toSet();
      final result = await ref
          .read(knowledgeRulesProvider.notifier)
          .importFromJson(source, knownHostIds: knownHostIds);
      if (!mounted) return;
      final skippedHint = result.skippedUnknownHost > 0
          ? L10n.str.ut_81d685bdc0(result.skippedUnknownHost)
          : '';
      showTopSnackBar(context,
        SnackBar(
          content: Text(L10n.str.ut_f59978a9af(result.imported, skippedHint)),
          backgroundColor: cSuccess,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context,
        SnackBar(
          content: Text(L10n.str.ut_4bda191f7f(e)),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showEditDialog([KnowledgeRule? rule]) {
    showDialog(
      context: context,
      builder: (context) => KnowledgeRuleEditDialog(
        rule: rule,
        onSave: (saved) {
          final notifier = ref.read(knowledgeRulesProvider.notifier);
          if (rule != null) {
            notifier.updateRule(saved);
          } else {
            notifier.addRule(saved);
          }
        },
      ),
    );
  }

  Future<void> _confirmDelete(KnowledgeRule rule) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UiText.t('删除规范', 'Delete rule')),
        content: Text(UiText.t(
            '确定删除「${rule.title}」？删除后 AI 不再遵循这条约定。',
            'Delete "${rule.title}"? The AI will stop following this rule.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(knowledgeRulesProvider.notifier).deleteRule(rule.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final rules = ref.watch(knowledgeRulesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(UiText.t('内部规范', 'Internal Rules')),
        actions: [
          IconButton(
            tooltip: UiText.t('导入 JSON', 'Import JSON'),
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _import,
          ),
          IconButton(
            tooltip: UiText.t('导出 JSON', 'Export JSON'),
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _export,
          ),
        ],
      ),
      body: rules.isEmpty ? _buildEmptyState() : _buildList(rules),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        backgroundColor: tc.brand,
        child: Icon(Icons.add, color: tc.isLight ? Colors.white : cBg),
      ),
    );
  }

  Widget _buildEmptyState() {
    final tc = ThemeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(pStandard * 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book_outlined, size: 56, color: tc.textSub),
            const SizedBox(height: 16),
            Text(
              UiText.t('还没有内部规范', 'No internal rules yet'),
              style: TextStyle(color: tc.textMain, fontSize: fBody),
            ),
            const SizedBox(height: 8),
            Text(
              UiText.t(
                '写下你所在环境的约定，例如「统一走内网镜像源」「nginx 只改 conf.d，不碰主配置」\n'
                '「生产 MySQL 端口 3307」，AI 执行命令时会遵循它们。',
                'Record the conventions of your environment, e.g. "always use the internal mirror", '
                '"edit nginx via conf.d only, never the main config".\nThe AI follows them when running commands.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<KnowledgeRule> rules) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(pStandard, pStandard, pStandard, 88),
      itemCount: rules.length,
      itemBuilder: (context, index) => _buildCard(rules[index]),
    );
  }

  Widget _buildCard(KnowledgeRule rule) {
    final tc = ThemeColors.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      rule.title,
                      style: TextStyle(
                        color: rule.enabled ? tc.textMain : tc.textSub,
                        fontSize: fBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Switch(
                  value: rule.enabled,
                  onChanged: (v) =>
                      ref.read(knowledgeRulesProvider.notifier).toggleEnabled(rule, v),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildBadge(
                    rule.strict
                        ? UiText.t('严格', 'Strict')
                        : UiText.t('建议', 'Suggested'),
                    rule.strict ? cWarning : cInfo,
                  ),
                  // 作用域用 gold（第二种强调色）而不是旧紫：紫 #8B5CF6
                  // 不在石墨青配色阶梯里，出现在设置系页面里格外突兀。
                  _buildBadge(_scopeText(rule), tc.gold),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8, right: 8),
              child: Text(
                rule.content,
                style: TextStyle(
                  color: rule.enabled ? tc.textBody : tc.textSub,
                  fontSize: fSmall,
                  height: 1.5,
                ),
              ),
            ),
            if (rule.commands.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 8, bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: tc.terminalBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    rule.commands.trim(),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: kMonoFontFallback,
                      fontSize: fMono,
                      color: tc.terminalGreen,
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => _showEditDialog(rule),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(UiText.t('编辑', 'Edit')),
                  ),
                  TextButton.icon(
                    onPressed: () => _confirmDelete(rule),
                    icon: const Icon(Icons.delete_outline, size: 16, color: cDanger),
                    label: Text(UiText.t('删除', 'Delete'),
                        style: const TextStyle(color: cDanger)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _scopeText(KnowledgeRule rule) {
    switch (rule.scope) {
      case KnowledgeRuleScope.global:
        return UiText.t('全局', 'Global');
      case KnowledgeRuleScope.group:
        return '${UiText.t('主机组', 'Group')} · ${rule.group ?? '-'}';
      case KnowledgeRuleScope.host:
        final name = HostsDao.getCachedById(rule.hostId ?? '')?.name;
        return '${UiText.t('主机', 'Host')} · ${name ?? rule.hostId ?? '-'}';
    }
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: fMicro)),
    );
  }
}

/// 规范编辑弹窗
class KnowledgeRuleEditDialog extends StatefulWidget {
  final KnowledgeRule? rule;
  final ValueChanged<KnowledgeRule> onSave;

  const KnowledgeRuleEditDialog(
      {super.key, this.rule, required this.onSave});

  @override
  State<KnowledgeRuleEditDialog> createState() => _KnowledgeRuleEditDialogState();
}

class _KnowledgeRuleEditDialogState extends State<KnowledgeRuleEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late final TextEditingController _commandsController;

  late KnowledgeRuleScope _scope;
  late String _group;
  late String _hostId;
  late bool _strict;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _titleController = TextEditingController(text: rule?.title ?? '');
    _contentController = TextEditingController(text: rule?.content ?? '');
    _commandsController = TextEditingController(text: rule?.commands ?? '');
    _scope = rule?.scope ?? KnowledgeRuleScope.global;
    _group = rule?.group ?? (HostsDao.cached.isNotEmpty ? HostsDao.cached.first.group : '默认');
    _hostId = rule?.hostId ?? (HostsDao.cached.isNotEmpty ? HostsDao.cached.first.id : '');
    _strict = rule?.strict ?? true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _commandsController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final rule = widget.rule ??
        (KnowledgeRule()
          ..id = _uuid.v4()
          ..enabled = true);
    rule.title = _titleController.text.trim();
    rule.content = _contentController.text.trim();
    rule.commands = _commandsController.text.trim();
    rule.scope = _scope;
    rule.group = _scope == KnowledgeRuleScope.group ? _group : null;
    rule.hostId = _scope == KnowledgeRuleScope.host ? _hostId : null;
    rule.strict = _strict;

    widget.onSave(rule);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final groups = HostsDao.cached.map((h) => h.group).toSet().toList()..sort();
    if (groups.isEmpty) groups.add('默认');
    final hosts = HostsDao.cached;

    return AlertDialog(
      backgroundColor: tc.cardElevated,
      insetPadding: const EdgeInsets.all(pStandard * 2),
      title: Text(
        widget.rule != null
            ? UiText.t('编辑规范', 'Edit rule')
            : UiText.t('新增规范', 'New rule'),
        style: TextStyle(color: tc.textMain, fontSize: fBody),
      ),
      content: SizedBox(
        // 小屏按视口 92% 缩放，大屏保持 560 上限
        width: math.min(560, MediaQuery.sizeOf(context).width * 0.92),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: UiText.t('标题', 'Title'),
                    hintText: UiText.t(
                        '例如：nginx 只改 conf.d', 'e.g. Edit nginx via conf.d only'),
                    hintStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                  ),
                  style: TextStyle(color: tc.textMain, fontSize: fBody),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? UiText.t('请填写标题', 'Title is required')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _contentController,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: UiText.t('规范内容', 'Rule'),
                    hintText: UiText.t(
                        '用自然语言写清楚约束，AI 会原样遵循。\n例如：内网统一走 mirrors.corp.internal，'
                        '不要使用公网 apt 源。',
                        'Describe the constraint in plain language.\ne.g. Always use mirrors.corp.internal; '
                        'never the public apt mirrors.'),
                    hintStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                  ),
                  style: TextStyle(color: tc.textMain, fontSize: fSmall, height: 1.5),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? UiText.t('请填写规范内容', 'Rule content is required')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _commandsController,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: UiText.t('参考命令（可选）', 'Reference commands (optional)'),
                    hintText: 'apt -o Dir::Etc::sourcelist=... update',
                    hintStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                  ),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                    fontSize: fMono,
                    color: tc.terminalGreen,
                  ),
                ),
                const SizedBox(height: 16),
                Text(UiText.t('作用域', 'Scope'),
                    style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                const SizedBox(height: 4),
                SegmentedButton<KnowledgeRuleScope>(
                  segments: [
                    ButtonSegment(
                      value: KnowledgeRuleScope.global,
                      label: Text(UiText.t('全局', 'Global')),
                    ),
                    ButtonSegment(
                      value: KnowledgeRuleScope.group,
                      label: Text(UiText.t('主机组', 'Group')),
                    ),
                    ButtonSegment(
                      value: KnowledgeRuleScope.host,
                      label: Text(UiText.t('单台主机', 'Host')),
                    ),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (s) => setState(() => _scope = s.first),
                ),
                if (_scope == KnowledgeRuleScope.group) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: groups.contains(_group) ? _group : groups.first,
                    decoration: InputDecoration(
                      labelText: UiText.t('主机组', 'Host group'),
                    ),
                    // value 保持持久化的原始组名（'默认' 写进 Hive 不能改），
                    // 只有 child 走本地化展示。
                    items: groups
                        .map((g) => DropdownMenuItem(
                            value: g, child: Text(UiText.hostGroup(g))))
                        .toList(),
                    onChanged: (v) => setState(() => _group = v ?? _group),
                  ),
                ],
                if (_scope == KnowledgeRuleScope.host) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: hosts.any((h) => h.id == _hostId) ? _hostId : null,
                    decoration: InputDecoration(
                      labelText: UiText.t('主机', 'Host'),
                    ),
                    items: hosts
                        .map((h) => DropdownMenuItem(
                              value: h.id,
                              child: Text('${h.name} · ${h.host}'),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _hostId = v ?? _hostId),
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _strict,
                  onChanged: (v) => setState(() => _strict = v),
                  title: Text(UiText.t('严格遵循', 'Strict'),
                      style: TextStyle(color: tc.textMain, fontSize: fSmall)),
                  subtitle: Text(
                    _strict
                        ? UiText.t('AI 必须原样执行，不得自行调整',
                            'The AI must follow this verbatim')
                        : UiText.t('允许 AI 在不违背约定前提下调整参数',
                            'The AI may tune parameters within this rule'),
                    style: TextStyle(color: tc.textSub, fontSize: fMicro),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        ElevatedButton(onPressed: _save, child: Text(l10n.save)),
      ],
    );
  }
}

/// 打开规范编辑器。设置页的「内部规范」分组与规范页面共用同一个表单。
Future<void> showKnowledgeRuleEditor(
  BuildContext context, {
  KnowledgeRule? rule,
  required ValueChanged<KnowledgeRule> onSave,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => KnowledgeRuleEditDialog(rule: rule, onSave: onSave),
  );
}
