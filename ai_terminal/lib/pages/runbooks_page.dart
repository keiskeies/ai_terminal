import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/runbook.dart';
import '../providers/runbook_provider.dart';

const _uuid = Uuid();

// 常用 emoji 图标列表
const List<String> _kEmojiIcons = [
  '🩺', '🛡️', '💾', '🌐', '⚙️', '🔐', '🚀', '📦',
  '🔧', '📋', '🔥', '⚠️', '✅', '🔍', '📈',
];

// 分类顺序
const List<RunbookCategory> _kCategoryOrder = [
  RunbookCategory.inspection,
  RunbookCategory.security,
  RunbookCategory.deployment,
  RunbookCategory.troubleshooting,
  RunbookCategory.maintenance,
  RunbookCategory.custom,
];

// 分类默认 emoji
const Map<RunbookCategory, String> _kCategoryEmoji = {
  RunbookCategory.inspection: '🩺',
  RunbookCategory.security: '🛡️',
  RunbookCategory.deployment: '🚀',
  RunbookCategory.troubleshooting: '🔧',
  RunbookCategory.maintenance: '⚙️',
  RunbookCategory.custom: '📋',
};

String _runbookCategoryLabel(RunbookCategory cat, AppLocalizations l10n) {
  switch (cat) {
    case RunbookCategory.inspection:
      return l10n.runbookCategoryInspection;
    case RunbookCategory.security:
      return l10n.runbookCategorySecurity;
    case RunbookCategory.deployment:
      return l10n.runbookCategoryDeployment;
    case RunbookCategory.troubleshooting:
      return l10n.runbookCategoryTroubleshooting;
    case RunbookCategory.maintenance:
      return l10n.runbookCategoryMaintenance;
    case RunbookCategory.custom:
      return l10n.runbookCategoryCustom;
  }
}

/// 运维工作流管理页面
///
/// 管理可沉淀的运维操作模板，支持两种类型：
/// - agent：自然语言 prompt 交给 AI 执行
/// - command：变量替换后在终端直接执行
class RunbooksPage extends ConsumerStatefulWidget {
  /// agent 类型执行回调（将 prompt 发给 AI 执行）
  final void Function(String prompt)? onExecuteAgent;

  /// command 类型执行回调（在终端执行命令）
  final void Function(String command)? onExecuteCommand;

  const RunbooksPage({
    super.key,
    this.onExecuteAgent,
    this.onExecuteCommand,
  });

  @override
  ConsumerState<RunbooksPage> createState() => _RunbooksPageState();
}

class _RunbooksPageState extends ConsumerState<RunbooksPage> {
  String _searchQuery = '';
  // 选中的分类筛选；null 表示"全部"
  RunbookCategory? _selectedCategory;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final runbooks = ref.watch(runbooksProvider);
    final filtered = _filterRunbooks(runbooks);
    final grouped = _groupByCategory(filtered);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.runbookTitle),
        actions: [
          IconButton(
            icon: Icon(Icons.file_download_outlined, color: tc.textMain),
            tooltip: l10n.runbookImportTooltip,
            onPressed: () => _showImportDialog(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchAndFilter(),
          Expanded(
            child: filtered.isEmpty
                ? _buildEmptyState()
                : _buildGroupedList(grouped),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        backgroundColor: cPrimary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  // ===== 顶部搜索框 + 分类筛选 =====
  Widget _buildSearchAndFilter() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(pStandard, pSmall, pStandard, pSmall),
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(bottom: BorderSide(color: tc.border)),
      ),
      child: Column(
        children: [
          // 搜索框
          TextField(
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
            style: TextStyle(color: tc.textMain, fontSize: fBody),
            decoration: InputDecoration(
              isDense: true,
              hintText: l10n.runbookSearchHint,
              hintStyle: TextStyle(color: tc.textSub, fontSize: fBody),
              prefixIcon: Icon(Icons.search, color: tc.textSub, size: 18),
              filled: true,
              fillColor: tc.card,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: pCompact,
                vertical: pSmall,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(rInput),
                borderSide: BorderSide(color: tc.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(rInput),
                borderSide: const BorderSide(color: cPrimary),
              ),
            ),
          ),
          const SizedBox(height: pSmall),
          // 分类筛选
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildFilterChip(null, l10n.runbookFilterAll),
                ..._kCategoryOrder.map(
                  (cat) => _buildFilterChip(cat, _runbookCategoryLabel(cat, l10n)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(RunbookCategory? category, String label) {
    final tc = ThemeColors.of(context);
    final selected = _selectedCategory == category;
    return Padding(
      padding: const EdgeInsets.only(right: pSmall),
      child: GestureDetector(
        onTap: () => setState(() => _selectedCategory = category),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: pCompact),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? cPrimaryBg : tc.card,
            borderRadius: BorderRadius.circular(rFull),
            border: Border.all(
              color: selected ? cPrimary : tc.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? cPrimary : tc.textSub,
              fontSize: fSmall,
            ),
          ),
        ),
      ),
    );
  }

  // ===== 分组列表 =====
  Widget _buildGroupedList(Map<RunbookCategory, List<Runbook>> grouped) {
    // 按固定顺序输出各分类
    const order = [
      RunbookCategory.inspection,
      RunbookCategory.security,
      RunbookCategory.deployment,
      RunbookCategory.troubleshooting,
      RunbookCategory.maintenance,
      RunbookCategory.custom,
    ];
    final sections = <Widget>[];
    for (final cat in order) {
      final list = grouped[cat];
      if (list == null || list.isEmpty) continue;
      sections.add(_buildSectionHeader(cat, list.length));
      for (final rb in list) {
        sections.add(_buildRunbookCard(rb));
      }
    }
    return ListView(
      padding: const EdgeInsets.all(pStandard),
      children: sections,
    );
  }

  Widget _buildSectionHeader(RunbookCategory cat, int count) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: pSmall, bottom: pSmall),
      child: Row(
        children: [
          Text(
            _kCategoryEmoji[cat]!,
            style: const TextStyle(fontSize: fBody),
          ),
          const SizedBox(width: pSmall),
          Text(
            _runbookCategoryLabel(cat, l10n),
            style: TextStyle(
              color: tc.textMain,
              fontSize: fBody,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: pSmall),
          Text(
            '$count',
            style: TextStyle(color: tc.textSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  // ===== 工作流卡片 =====
  Widget _buildRunbookCard(Runbook rb) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: pSmall),
      padding: const EdgeInsets.all(pStandard),
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上半部分：图标 + 名称描述 + 类型标签
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧：emoji 图标
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tc.cardElevated,
                  shape: BoxShape.circle,
                  border: Border.all(color: tc.border),
                ),
                alignment: Alignment.center,
                child: Text(
                  rb.icon.isEmpty ? '📋' : rb.icon,
                  style: const TextStyle(fontSize: 20),
                ),
              ),
              const SizedBox(width: pCompact),
              // 中间：名称 + 描述
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            rb.name,
                            style: TextStyle(
                              color: tc.textMain,
                              fontSize: fBody,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (rb.isBuiltin) ...[
                          const SizedBox(width: pSmall),
                          _buildBuiltinTag(),
                        ],
                      ],
                    ),
                    if (rb.description != null && rb.description!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          rb.description!,
                          style: TextStyle(
                            color: tc.textSub,
                            fontSize: fSmall,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: pSmall),
              // 右侧：类型标签 + 执行次数
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildTypeTag(rb.type),
                  const SizedBox(height: 4),
                  Text(
                    l10n.runbookRunCount(rb.runCount),
                    style: TextStyle(color: tc.textSub, fontSize: fMicro),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: pCompact),
          // 底部操作行
          _buildActionRow(rb),
        ],
      ),
    );
  }

  Widget _buildBuiltinTag() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cWarningBg,
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: cWarning),
      ),
      child: Text(
        l10n.runbookBuiltinTag,
        style: const TextStyle(color: cWarning, fontSize: fMicro),
      ),
    );
  }

  Widget _buildTypeTag(RunbookType type) {
    final l10n = AppLocalizations.of(context)!;
    final isAgent = type == RunbookType.agent;
    final color = isAgent ? cPrimary : cSuccess;
    final bg = isAgent ? cPrimaryBg : cSuccessBg;
    final label = isAgent ? l10n.runbookTypeAgentTag : l10n.runbookTypeCommand;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: fMicro),
      ),
    );
  }

  // 底部操作行：执行 / 编辑 / 克隆（内置）/ 删除（自定义）
  Widget _buildActionRow(Runbook rb) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        // 执行按钮（主操作）
        ElevatedButton.icon(
          onPressed: () => _executeRunbook(rb),
          icon: const Icon(Icons.play_arrow, size: 16),
          label: Text(l10n.commonExecute),
          style: ElevatedButton.styleFrom(
            backgroundColor: cPrimary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: pCompact),
            minimumSize: const Size(0, 30),
            textStyle: const TextStyle(fontSize: fSmall),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rButton),
            ),
          ),
        ),
        const Spacer(),
        // 编辑
        _iconButton(
          icon: Icons.edit_outlined,
          tooltip: l10n.runbookEditTooltip,
          onTap: () => _showEditDialog(rb),
        ),
        // 克隆（仅内置显示）
        if (rb.isBuiltin)
          _iconButton(
            icon: Icons.copy_outlined,
            tooltip: l10n.runbookCloneTooltip,
            onTap: () => _cloneRunbook(rb),
          ),
        // 删除（仅自定义显示）
        if (!rb.isBuiltin)
          _iconButton(
            icon: Icons.delete_outline,
            tooltip: l10n.runbookDeleteTooltip,
            color: cDanger,
            onTap: () => _deleteRunbook(rb),
          ),
      ],
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    final tc = ThemeColors.of(context);
    return IconButton(
      icon: Icon(icon, size: 18, color: color ?? tc.textSub),
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
  }

  // ===== 空状态 =====
  Widget _buildEmptyState() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome_motion, size: 64, color: tc.textSub),
          const SizedBox(height: pStandard),
          Text(
            l10n.runbookEmptyTitle,
            style: TextStyle(color: tc.textSub, fontSize: fBody),
          ),
          const SizedBox(height: pSmall),
          Text(
            _searchQuery.isNotEmpty || _selectedCategory != null
                ? l10n.runbookEmptyFiltered
                : l10n.runbookEmptyHint,
            style: TextStyle(color: tc.textSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  // ===== 执行逻辑 =====
  Future<void> _executeRunbook(Runbook rb) async {
    final l10n = AppLocalizations.of(context)!;
    if (rb.type == RunbookType.agent) {
      // agent 类型：交给 AI 执行
      if (widget.onExecuteAgent != null) {
        widget.onExecuteAgent!(rb.content);
        await ref.read(runbooksProvider.notifier).incrementRunCount(rb.id);
      } else {
        _toast(l10n.runbookUseInTerminal);
      }
      return;
    }

    // command 类型：处理变量替换后执行
    final variables = rb.getAllVariables();
    final values = <String, String>{};
    if (variables.isNotEmpty) {
      final filled = await _showVariablesDialog(rb, variables);
      if (filled == null) return; // 用户取消
      values.addAll(filled);
      if (rb.hasUnfilledVariables(values)) {
        _toast(l10n.terminalUnfilledVariables);
        return;
      }
    }

    final resolved = rb.resolveContent(values);
    if (widget.onExecuteCommand != null) {
      widget.onExecuteCommand!(resolved);
      await ref.read(runbooksProvider.notifier).incrementRunCount(rb.id);
    } else {
      _toast(l10n.runbookUseInTerminal);
    }
  }

  /// 弹出变量填写对话框，返回 null 表示用户取消
  Future<Map<String, String>?> _showVariablesDialog(
    Runbook rb,
    List<String> variables,
  ) {
    final controllers = {
      for (final v in variables) v: TextEditingController(),
    };
    final l10n = AppLocalizations.of(context)!;
    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        final tc = ThemeColors.of(context);
        return AlertDialog(
        title: Text(l10n.terminalFillVariables(rb.name)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rb.description != null && rb.description!.isNotEmpty) ...[
                Text(
                  rb.description!,
                  style: TextStyle(color: tc.textSub, fontSize: fSmall),
                ),
                const SizedBox(height: pCompact),
              ],
              // 原始命令预览
              Text(l10n.terminalCommandTemplate, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(pSmall),
                decoration: BoxDecoration(
                  color: tc.terminalBg,
                  borderRadius: BorderRadius.circular(rSmall),
                  border: Border.all(color: tc.border),
                ),
                child: SelectableText(
                  rb.content,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: fMono,
                    color: tc.terminalGreen,
                  ),
                ),
              ),
              const SizedBox(height: pCompact),
              // 变量输入框
              ...variables.map(
                (v) => Padding(
                  padding: const EdgeInsets.only(bottom: pSmall),
                  child: TextField(
                    controller: controllers[v],
                    style: TextStyle(color: tc.textMain, fontSize: fBody),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '{{$v}}',
                      labelStyle: TextStyle(
                        color: tc.textSub,
                        fontSize: fSmall,
                        fontFamily: 'JetBrainsMono',
                      ),
                      filled: true,
                      fillColor: tc.cardElevated,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: pCompact,
                        vertical: pSmall,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(rInput),
                        borderSide: BorderSide(color: tc.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(rInput),
                        borderSide: const BorderSide(color: cPrimary),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(
                context,
                {for (final v in variables) v: controllers[v]!.text.trim()},
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary),
            child: Text(l10n.commonExecute),
          ),
        ],
      );
      },
    );
  }

  // ===== 克隆 =====
  Future<void> _cloneRunbook(Runbook rb) async {
    final cloned = await ref.read(runbooksProvider.notifier).cloneRunbook(rb.id);
    if (cloned != null && mounted) {
      final l10n = AppLocalizations.of(context)!;
      _toast(l10n.runbookClonedToast(cloned.name));
    }
  }

  // ===== 删除 =====
  Future<void> _deleteRunbook(Runbook rb) async {
    final l10n = AppLocalizations.of(context)!;
    if (rb.isBuiltin) {
      _toast(l10n.runbookBuiltinCannotDelete);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.runbookDeleteTitle),
        content: Text(l10n.runbookDeleteConfirm(rb.name)),
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
      await ref.read(runbooksProvider.notifier).deleteRunbook(rb.id);
      if (mounted) _toast(l10n.runbookDeletedToast);
    }
  }

  // ===== 新建/编辑对话框 =====
  void _showEditDialog([Runbook? rb]) {
    showDialog(
      context: context,
      builder: (context) => _RunbookEditDialog(
        runbook: rb,
        onSave: (newRb) async {
          final notifier = ref.read(runbooksProvider.notifier);
          if (rb != null) {
            // 编辑：保留 id 与内置属性等
            newRb.id = rb.id;
            newRb.isBuiltin = rb.isBuiltin;
            newRb.createdAt = rb.createdAt;
            newRb.runCount = rb.runCount;
            newRb.lastRunAt = rb.lastRunAt;
            await notifier.updateRunbook(newRb);
          } else {
            await notifier.addRunbook(newRb);
          }
        },
      ),
    );
  }

  // ===== 导入对话框 =====
  void _showImportDialog() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => _RunbookImportDialog(
        onImport: (jsonStr) async {
          return ref.read(runbooksProvider.notifier).importFromJson(jsonStr);
        },
        onDone: (count) {
          if (mounted) {
            _toast(l10n.runbookImportSuccess(count));
          }
        },
      ),
    );
  }

  // ===== 过滤与分组 =====
  List<Runbook> _filterRunbooks(List<Runbook> all) {
    return all.where((rb) {
      // 分类筛选
      if (_selectedCategory != null && rb.category != _selectedCategory) {
        return false;
      }
      // 搜索筛选
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return rb.name.toLowerCase().contains(q) ||
          (rb.description?.toLowerCase().contains(q) ?? false) ||
          rb.content.toLowerCase().contains(q);
    }).toList();
  }

  Map<RunbookCategory, List<Runbook>> _groupByCategory(List<Runbook> list) {
    final map = <RunbookCategory, List<Runbook>>{};
    for (final rb in list) {
      map.putIfAbsent(rb.category, () => []).add(rb);
    }
    return map;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ===== 新建/编辑对话框 =====
class _RunbookEditDialog extends StatefulWidget {
  final Runbook? runbook;
  final Future<void> Function(Runbook rb) onSave;

  const _RunbookEditDialog({this.runbook, required this.onSave});

  @override
  State<_RunbookEditDialog> createState() => _RunbookEditDialogState();
}

class _RunbookEditDialogState extends State<_RunbookEditDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _contentController = TextEditingController();
  late RunbookType _type;
  late RunbookCategory _category;
  late String _icon;

  @override
  void initState() {
    super.initState();
    final rb = widget.runbook;
    if (rb != null) {
      _nameController.text = rb.name;
      _descriptionController.text = rb.description ?? '';
      _contentController.text = rb.content;
      _type = rb.type;
      _category = rb.category;
      _icon = rb.icon.isEmpty ? '📋' : rb.icon;
    } else {
      _type = RunbookType.agent;
      _category = RunbookCategory.custom;
      _icon = '📋';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final isEdit = widget.runbook != null;
    final isBuiltin = widget.runbook?.isBuiltin ?? false;
    return AlertDialog(
      title: Text(isEdit ? l10n.runbookEditTitle : l10n.runbookNewTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名称
                TextFormField(
                  controller: _nameController,
                  enabled: !isBuiltin,
                  style: TextStyle(color: tc.textMain, fontSize: fBody),
                  decoration: _inputDecoration(l10n.runbookFieldName),
                  validator: (v) => v == null || v.trim().isEmpty ? l10n.runbookNameRequired : null,
                ),
                const SizedBox(height: pCompact),
                // 图标选择
                Text(l10n.runbookFieldIcon, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                const SizedBox(height: pSmall),
                _buildEmojiPicker(),
                const SizedBox(height: pCompact),
                // 类型选择
                Text(l10n.runbookFieldType, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                const SizedBox(height: pSmall),
                _buildTypeSelector(),
                const SizedBox(height: pCompact),
                // 分类选择
                Text(l10n.runbookFieldCategory, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                const SizedBox(height: pSmall),
                _buildCategorySelector(),
                const SizedBox(height: pCompact),
                // 描述
                TextFormField(
                  controller: _descriptionController,
                  style: TextStyle(color: tc.textMain, fontSize: fBody),
                  decoration: _inputDecoration(l10n.runbookFieldDescription),
                ),
                const SizedBox(height: pCompact),
                // 内容
                Text(
                  _type == RunbookType.agent ? l10n.runbookContentAgent : l10n.runbookContentCommand,
                  style: TextStyle(color: tc.textSub, fontSize: fSmall),
                ),
                const SizedBox(height: pSmall),
                TextFormField(
                  controller: _contentController,
                  enabled: !isBuiltin,
                  maxLines: 5,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: fMono,
                    color: tc.textMain,
                  ),
                  decoration: _inputDecoration(
                    _type == RunbookType.agent
                        ? l10n.runbookContentAgentHint('{{host}}')
                        : l10n.runbookContentCommandHint('{{host}}', '{{user}}'),
                  ).copyWith(
                    alignLabelWithHint: true,
                  ),
                  validator: (v) => v == null || v.trim().isEmpty ? l10n.runbookContentRequired : null,
                ),
                if (isBuiltin)
                  Padding(
                    padding: const EdgeInsets.only(top: pSmall),
                    child: Text(
                      l10n.runbookBuiltinNotEditable,
                      style: const TextStyle(color: cWarning, fontSize: fSmall),
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
        if (!isBuiltin)
          ElevatedButton(
            onPressed: _save,
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary),
            child: Text(isEdit ? l10n.save : l10n.runbookCreate),
          ),
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    final tc = ThemeColors.of(context);
    return InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(color: tc.textSub, fontSize: fBody),
      filled: true,
      fillColor: tc.cardElevated,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: pCompact,
        vertical: pSmall,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: tc.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: const BorderSide(color: cPrimary),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rInput),
        borderSide: BorderSide(color: tc.border),
      ),
    );
  }

  // emoji 图标选择器
  Widget _buildEmojiPicker() {
    final tc = ThemeColors.of(context);
    return Wrap(
      spacing: pSmall,
      runSpacing: pSmall,
      children: _kEmojiIcons.map((e) {
        final selected = e == _icon;
        return GestureDetector(
          onTap: () => setState(() => _icon = e),
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? cPrimaryBg : tc.cardElevated,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(
                color: selected ? cPrimary : tc.border,
              ),
            ),
            child: Text(e, style: const TextStyle(fontSize: 18)),
          ),
        );
      }).toList(),
    );
  }

  // 类型单选
  Widget _buildTypeSelector() {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        _buildTypeOption(RunbookType.agent, l10n.runbookTypeAgentOption, cPrimary, l10n.runbookTypeAgentDesc),
        const SizedBox(width: pCompact),
        _buildTypeOption(RunbookType.command, l10n.runbookTypeCommand, cSuccess, l10n.runbookTypeCommandDesc),
      ],
    );
  }

  Widget _buildTypeOption(
    RunbookType type,
    String label,
    Color color,
    String desc,
  ) {
    final tc = ThemeColors.of(context);
    final selected = _type == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _type = type),
        child: Container(
          padding: const EdgeInsets.all(pCompact),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.12) : tc.cardElevated,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: selected ? color : tc.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 16,
                    color: selected ? color : tc.textSub,
                  ),
                  const SizedBox(width: pSmall),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? color : tc.textMain,
                      fontSize: fBody,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: TextStyle(color: tc.textSub, fontSize: fMicro),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 分类下拉选择
  Widget _buildCategorySelector() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: pCompact),
      decoration: BoxDecoration(
        color: tc.cardElevated,
        borderRadius: BorderRadius.circular(rInput),
        border: Border.all(color: tc.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RunbookCategory>(
          value: _category,
          isExpanded: true,
          dropdownColor: tc.surface,
          style: TextStyle(color: tc.textMain, fontSize: fBody),
          items: _kCategoryOrder
              .map((cat) => DropdownMenuItem(
                    value: cat,
                    child: Text('${_kCategoryEmoji[cat]} ${_runbookCategoryLabel(cat, l10n)}'),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) setState(() => _category = v);
          },
        ),
      ),
    );
  }

  void _save() async {
    if (!_formKey.currentState!.validate()) return;
    final rb = Runbook.create(
      id: _uuid.v4(),
      name: _nameController.text.trim(),
      icon: _icon,
      type: _type,
      category: _category,
      content: _contentController.text.trim(),
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
    );
    await widget.onSave(rb);
    if (mounted) Navigator.pop(context);
  }
}

// ===== 导入对话框 =====
class _RunbookImportDialog extends StatefulWidget {
  /// 执行导入，返回成功导入的数量
  final Future<int> Function(String jsonStr) onImport;

  /// 导入成功后的回调（对话框已关闭）
  final void Function(int count) onDone;

  const _RunbookImportDialog({
    required this.onImport,
    required this.onDone,
  });

  @override
  State<_RunbookImportDialog> createState() => _RunbookImportDialogState();
}

class _RunbookImportDialogState extends State<_RunbookImportDialog> {
  final _controller = TextEditingController();
  String? _errorMsg;
  bool _importing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final l10n = AppLocalizations.of(context)!;
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.isNotEmpty) {
      _controller.text = data.text!;
      setState(() => _errorMsg = null);
    } else {
      setState(() => _errorMsg = l10n.runbookClipboardEmpty);
    }
  }

  Future<void> _doImport() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _errorMsg = l10n.runbookPasteJsonFirst);
      return;
    }
    setState(() {
      _importing = true;
      _errorMsg = null;
    });
    try {
      final count = await widget.onImport(text);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onDone(count);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _errorMsg = l10n.runbookJsonParseFailed(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.runbookImportTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.runbookImportHint,
              style: TextStyle(color: tc.textSub, fontSize: fSmall),
            ),
            const SizedBox(height: pSmall),
            // JSON 格式示例提示
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(pSmall),
              decoration: BoxDecoration(
                color: tc.terminalBg,
                borderRadius: BorderRadius.circular(rSmall),
                border: Border.all(color: tc.border),
              ),
              child: SelectableText(
                '[\n'
                '  {\n'
                '    "name": "磁盘巡检",\n'
                '    "icon": "🩺",\n'
                '    "type": "agent",\n'
                '    "category": "inspection",\n'
                '    "description": "检查 {{host}} 磁盘使用情况",\n'
                '    "content": "检查 {{host}} 的磁盘使用情况并给出建议"\n'
                '  }\n'
                ']',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: tc.terminalGreen,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: pCompact),
            // JSON 输入框
            TextField(
              controller: _controller,
              maxLines: 12,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: tc.textMain,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.runbookImportPasteHint,
                hintStyle: TextStyle(color: tc.textSub, fontSize: fBody),
                filled: true,
                fillColor: tc.cardElevated,
                alignLabelWithHint: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: pCompact,
                  vertical: pSmall,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(rInput),
                  borderSide: BorderSide(color: tc.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(rInput),
                  borderSide: const BorderSide(color: cPrimary),
                ),
              ),
              onChanged: (_) {
                if (_errorMsg != null) {
                  setState(() => _errorMsg = null);
                }
              },
            ),
            if (_errorMsg != null) ...[
              const SizedBox(height: pSmall),
              Text(
                _errorMsg!,
                style: const TextStyle(color: cDanger, fontSize: fSmall),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _pasteFromClipboard,
          icon: const Icon(Icons.content_paste, size: 16),
          label: Text(l10n.runbookPasteFromClipboard),
        ),
        TextButton(
          onPressed: _importing ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        ElevatedButton(
          onPressed: _importing ? null : _doImport,
          style: ElevatedButton.styleFrom(backgroundColor: cPrimary),
          child: _importing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(l10n.runbookImportButton),
        ),
      ],
    );
  }
}
