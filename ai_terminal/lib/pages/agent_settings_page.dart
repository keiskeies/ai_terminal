import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/ai_model_config.dart';
import '../services/daos.dart';
import '../core/prompts.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../providers/agent_provider.dart';
import '../services/local_file_policy.dart';
import '../utils/agent_ui_text.dart';
import '../utils/local_file_ops.dart';
import '../core/app_toast.dart';

/// P1-5: Agent 设置页面
/// 整合最大执行步骤数、内置提示词、自定义提示词
class AgentSettingsPage extends ConsumerStatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  ConsumerState<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends ConsumerState<AgentSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));
    final aiTimeoutSeconds =
        ref.watch(agentProvider.select((s) => s.aiTimeoutSeconds));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSettingTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(pStandard),
            children: [
              // 最大执行步骤数
              _buildSectionTitle(l10n.agentSettingAutoExecSection),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(l10n.agentSettingMaxStepsLabel,
                              style: TextStyle(
                                  color: ThemeColors.of(context).textMain)),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: cPrimary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(rSmall),
                            ),
                            child: Text(
                              maxSteps == 0
                                  ? l10n.commonUnlimited
                                  : '$maxSteps',
                              style: const TextStyle(
                                color: cPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.agentSettingMaxStepsDesc,
                        style: TextStyle(
                            color: ThemeColors.of(context).textSub,
                            fontSize: fSmall),
                      ),
                      const SizedBox(height: 12),
                      Slider(
                        value: maxSteps.clamp(0, 100).toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label:
                            maxSteps == 0 ? l10n.commonUnlimited : '$maxSteps',
                        onChanged: (value) {
                          ref
                              .read(agentProvider.notifier)
                              .setMaxSteps(value.toInt());
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(l10n.commonUnlimited,
                              style: TextStyle(
                                  color: ThemeColors.of(context).textMuted,
                                  fontSize: fMicro)),
                          Text(l10n.agentSettingHundredSteps,
                              style: TextStyle(
                                  color: ThemeColors.of(context).textMuted,
                                  fontSize: fMicro)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // AI 响应超时
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(l10n.agentSettingAiTimeoutLabel,
                              style: TextStyle(color: tc.textMain)),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: cPrimary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(rSmall),
                            ),
                            child: Text(
                              '${aiTimeoutSeconds}s',
                              style: const TextStyle(
                                color: cPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.agentSettingAiTimeoutDesc,
                        style: TextStyle(color: tc.textSub, fontSize: fSmall),
                      ),
                      const SizedBox(height: 12),
                      Slider(
                        value: aiTimeoutSeconds
                            .clamp(kMinAiResponseTimeoutSeconds,
                                kMaxAiResponseTimeoutSeconds)
                            .toDouble(),
                        min: kMinAiResponseTimeoutSeconds.toDouble(),
                        max: kMaxAiResponseTimeoutSeconds.toDouble(),
                        divisions: (kMaxAiResponseTimeoutSeconds -
                                kMinAiResponseTimeoutSeconds) ~/
                            30,
                        label: '${aiTimeoutSeconds}s',
                        onChanged: (value) {
                          ref
                              .read(agentProvider.notifier)
                              .setAiTimeoutSeconds(value.round());
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${kMinAiResponseTimeoutSeconds}s',
                              style: TextStyle(
                                  color: tc.textMuted, fontSize: fMicro)),
                          Text('${kMaxAiResponseTimeoutSeconds}s',
                              style: TextStyle(
                                  color: tc.textMuted, fontSize: fMicro)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 提示词设置
              _buildSectionTitle(l10n.agentSettingPromptSection),

              // 内置系统提示词（折叠面板）
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ExpansionTile(
                  leading:
                      const Icon(Icons.description_outlined, color: cWarning),
                  title: Text(l10n.agentSettingBuiltInPrompt),
                  subtitle: Text(l10n.agentSettingBuiltInPromptSubtitle,
                      style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(pStandard),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.agentSettingBuiltInPromptDesc,
                            style:
                                TextStyle(color: tc.textSub, fontSize: fSmall),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.agentSettingPromptWarning,
                            style: const TextStyle(
                                color: cWarning, fontSize: fMicro),
                          ),
                          const SizedBox(height: 12),
                          _BuiltInPromptEditor(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 自定义提示词（折叠面板）
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ExpansionTile(
                  leading: Icon(Icons.edit_note_rounded, color: tc.agentGreen),
                  title: Text(l10n.agentSettingExtraPrompt),
                  subtitle: Text(l10n.agentSettingExtraPromptSubtitle,
                      style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(pStandard),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.agentSettingExtraPromptDesc,
                            style:
                                TextStyle(color: tc.textSub, fontSize: fSmall),
                          ),
                          const SizedBox(height: 12),
                          _CustomPromptEditor(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 本地文件访问授权
              _buildSectionTitle(AgentUiText.of(context).localFileSection),
              const LocalFileAccessSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: fTitle,
          fontWeight: FontWeight.w600,
          color: cPrimary,
        ),
      ),
    );
  }
}

/// 内置提示词编辑器
class _BuiltInPromptEditor extends StatefulWidget {
  @override
  State<_BuiltInPromptEditor> createState() => _BuiltInPromptEditorState();
}

class _BuiltInPromptEditorState extends State<_BuiltInPromptEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: getSystemPrompt());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    return Column(
      children: [
        TextField(
          controller: _controller,
          maxLines: 8,
          minLines: 4,
          style: TextStyle(
            color: ThemeColors.of(context).textMain,
            fontSize: fSmall,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: kMonoFontFallback,
          ),
          decoration: InputDecoration(
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: ThemeColors.of(context).border)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() => _controller.text = defaultSystemPrompt);
              },
              icon: const Icon(Icons.restore, color: cWarning, size: 18),
              label: Text(l10n.commonResetDefault,
                  style: const TextStyle(color: cWarning)),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                saveSystemPrompt(_controller.text.trim());
                showTopSnackBar(
                  context,
                  SnackBar(
                    content: Text(l10n.agentSettingBuiltInSaved),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: Text(l10n.save),
              style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 自定义提示词编辑器
class _CustomPromptEditor extends StatefulWidget {
  @override
  State<_CustomPromptEditor> createState() => _CustomPromptEditorState();
}

class _CustomPromptEditorState extends State<_CustomPromptEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    String? savedPrompt;
    try {
      savedPrompt = SettingsDao.getCached('customSystemPrompt') as String?;
    } catch (_) {}
    _controller = TextEditingController(text: savedPrompt ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    return Column(
      children: [
        TextField(
          controller: _controller,
          maxLines: 6,
          minLines: 3,
          style: TextStyle(
            color: ThemeColors.of(context).textMain,
            fontSize: fBody,
          ),
          decoration: InputDecoration(
            hintText: l10n.agentSettingCustomPromptHint,
            hintStyle: TextStyle(
                color: ThemeColors.of(context).textMuted, fontSize: fSmall),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: ThemeColors.of(context).border)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                try {
                  SettingsDao.set(
                      'customSystemPrompt', _controller.text.trim());
                } catch (_) {}
                showTopSnackBar(
                  context,
                  SnackBar(
                    content: Text(l10n.agentSettingExtraPromptSaved),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: Text(l10n.save),
              style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 本地文件访问授权区
///
/// Agent 可以用 local_file_* 工具读写运行 App 的这台机器。默认关闭且白名单为空：
/// 没授权之前一个文件都读不到，报错信息会把用户指到这个页面。
/// 白名单是"能进哪些门"，敏感路径黑名单（~/.ssh、.env 等）是"进了门也不能碰什么"，
/// 后者优先级更高且不可被这里的配置放开。
class LocalFileAccessSection extends StatefulWidget {
  const LocalFileAccessSection();

  @override
  State<LocalFileAccessSection> createState() => LocalFileAccessSectionState();
}

class LocalFileAccessSectionState extends State<LocalFileAccessSection> {
  late LocalFilePolicy _policy;
  bool _loading = true;
  TrashUsage _trash = const TrashUsage(entries: [], bytes: 0);
  int _trashRecords = 0;
  bool _trashBusy = false;

  @override
  void initState() {
    super.initState();
    _policy = LocalFilePolicy.load();
    _loading = false;
    _loadTrash();
  }

  Future<void> _loadTrash() async {
    // 回收条目从台账反查，而不是扫授权目录：删除时把位置写进了 localRestoreFrom，
    // 扫目录要在整棵授权树里找 .ai_terminal_trash，大仓库上代价高且会碰黑名单路径。
    final restorePaths = ChangeRecordsDao.cachedAll
        .map((r) => r.localRestoreFrom ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final entries = trashEntriesFromRestorePaths(
      restorePaths,
      trashDirName: LocalFilePolicy.trashDirName,
    );
    final usage = await measureTrashEntries(entries);
    if (!mounted) return;
    setState(() {
      _trash = usage;
      _trashRecords = countPathsUnderEntries(restorePaths, usage.entries);
    });
  }

  Future<void> _clearTrash() async {
    final ui = AgentUiText.of(context);
    final tc = ThemeColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ui.localFileTrashClear),
        content: Text(
          ui.localFileTrashClearBody(
              _trash.count, formatByteSize(_trash.bytes), _trashRecords),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ui.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                Text(ui.localFileTrashClear, style: TextStyle(color: tc.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // overlay 先取：后面有 await，跨异步用 context 会踩到已销毁的 element
    final overlay = Overlay.of(context, rootOverlay: true);
    setState(() => _trashBusy = true);
    final result = await clearTrashEntries(
      _trash.entries,
      trashDirName: LocalFilePolicy.trashDirName,
    );
    if (!mounted) return;
    setState(() => _trashBusy = false);
    await _loadTrash();

    final messages = <String>[
      ui.localFileTrashCleared(
          result.removed, formatByteSize(result.bytesFreed)),
    ];
    // 拒绝/失败必须说出来：静默少删等于让用户以为已经清干净了
    if (result.refused.isNotEmpty) messages.add(ui.localFileTrashClearRefused);
    if (result.failed.isNotEmpty) {
      messages.add(ui.localFileTrashClearFailed(result.failed.length));
    }
    showTopSnackBarInOverlay(
        overlay,
        SnackBar(
          content: Text(messages.join(' · ')),
          backgroundColor: result.isClean ? null : tc.warn,
          behavior: SnackBarBehavior.floating,
        ));
  }

  Future<void> _save(LocalFilePolicy next) async {
    await next.save();
    if (!mounted) return;
    setState(() => _policy = next);
  }

  Future<void> _addDirectory() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: AgentUiText.of(context).localFilePickTitle,
    );
    if (picked == null || picked.isEmpty) return;
    if (_policy.allowedDirs.contains(picked)) return;
    await _save(_policy.copyWith(
      allowedDirs: [..._policy.allowedDirs, picked],
    ));
  }

  Future<void> _remove(String dir) async {
    await _save(_policy.copyWith(
      allowedDirs: _policy.allowedDirs.where((d) => d != dir).toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final ui = AgentUiText.of(context);
    if (_loading) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(pStandard),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(ui.localFileEnable,
                      style: TextStyle(color: tc.textMain)),
                ),
                Switch(
                  value: _policy.enabled,
                  onChanged: (v) => _save(_policy.copyWith(enabled: v)),
                ),
              ],
            ),
            Text(
              ui.localFileEnableDesc,
              style: TextStyle(color: tc.textSub, fontSize: fSmall),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(ui.localFileDirs,
                      style: TextStyle(
                          color: tc.textMain, fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: _addDirectory,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text(ui.localFileAddDir),
                ),
              ],
            ),
            if (_policy.allowedDirs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  ui.localFileNoDirs,
                  style: TextStyle(color: tc.textMuted, fontSize: fSmall),
                ),
              ),
            for (final dir in _policy.allowedDirs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    Icon(Icons.folder_outlined, size: 16, color: tc.textSub),
                title: Text(dir,
                    style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                trailing: IconButton(
                  icon: Icon(Icons.close, size: 16, color: tc.textMuted),
                  tooltip: ui.localFileRemoveDir,
                  onPressed: () => _remove(dir),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _trash.isEmpty
                        ? ui.localFileTrashEmpty
                        : ui.localFileTrashLabel(
                            _trash.count, formatByteSize(_trash.bytes)),
                    style: TextStyle(color: tc.textSub, fontSize: fSmall),
                  ),
                ),
                if (_trash.isNotEmpty)
                  _trashBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton.icon(
                          onPressed: _clearTrash,
                          icon: Icon(Icons.delete_sweep_outlined,
                              size: 16, color: tc.textMuted),
                          label: Text(ui.localFileTrashClear,
                              style: const TextStyle(fontSize: fSmall)),
                        ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              ui.localFileBlacklistHint,
              style: const TextStyle(color: cWarning, fontSize: fMicro),
            ),
          ],
        ),
      ),
    );
  }
}
