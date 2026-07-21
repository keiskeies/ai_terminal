import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/constants.dart';
import '../services/daos.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../providers/agent_provider.dart';
import '../providers/app_providers.dart';
import '../services/knowledge_service.dart';
import '../services/crash_reporter.dart';
import '../services/health_check_service.dart';

/// P1-5: 设置页信息架构重组
/// 按用户任务场景分组：连接管理、AI 与智能、外观与体验、关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只监听需要的 maxSteps，避免 agent 其他状态变化触发 rebuild
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(pStandard),
            children: [
              // ===== 连接管理 =====
              _buildSectionTitle(context, l10n.settingsConnection),
              _buildGroupCard(
                context,
                items: [
                  _SettingItem(
                    icon: Icons.dns,
                    iconColor: cPrimary,
                    title: l10n.settingsHosts,
                    subtitle: l10n.settingsHostsDesc,
                    onTap: () => context.push('/hosts'),
                  ),
                  _SettingItem(
                    icon: Icons.code,
                    iconColor: cPrimary,
                    title: l10n.settingsSnippets,
                    subtitle: l10n.settingsSnippetsDesc,
                    onTap: () => context.push('/snippets'),
                  ),
                  _SettingItem(
                    icon: Icons.play_circle_outline,
                    iconColor: cSuccess,
                    title: l10n.settingsRunbooks,
                    subtitle: l10n.settingsRunbooksDesc,
                    onTap: () => context.push('/runbooks'),
                  ),
                  _SettingItem(
                    icon: Icons.history_edu,
                    iconColor: cViolet,
                    title: l10n.settingsChangeRecords,
                    subtitle: l10n.settingsChangeRecordsDesc,
                    onTap: () => context.push('/change-records'),
                  ),
                  _SettingItem(
                    icon: Icons.shield,
                    iconColor: cWarning,
                    title: l10n.settingsAuditLog,
                    subtitle: l10n.settingsAuditLogDesc,
                    onTap: () => context.push('/audit-log'),
                  ),
                  _SettingItem(
                    icon: Icons.lock_clock,
                    iconColor: cDanger,
                    title: l10n.settingsChangeWindow,
                    subtitle: l10n.settingsChangeWindowDesc,
                    onTap: () => context.push('/change-window'),
                  ),
                  _SettingItem(
                    icon: Icons.notifications_active,
                    iconColor: cWarning,
                    title: l10n.settingsNotification,
                    subtitle: l10n.settingsNotificationDesc,
                    onTap: () => context.push('/settings/notification'),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ===== AI 与智能 =====
              _buildSectionTitle(context, l10n.settingsAI),
              _buildGroupCard(
                context,
                items: [
                  _SettingItem(
                    icon: Icons.smart_toy,
                    iconColor: cPrimary,
                    title: l10n.settingsAIModel,
                    subtitle: l10n.settingsAIModelDesc,
                    onTap: () => context.push('/settings/ai'),
                  ),
                  _SettingItem(
                    icon: Icons.auto_mode_rounded,
                    iconColor: tc.agentGreen,
                    title: l10n.settingsAgent,
                    subtitle: l10n.settingsAgentDesc(maxSteps),
                    onTap: () => context.push('/settings/agent'),
                  ),
                  _SettingItem(
                    icon: Icons.travel_explore_rounded,
                    iconColor: cInfo,
                    title: '联网搜索',
                    subtitle: 'AI 知识不足时主动搜索网络（web_search / fetch_url）',
                    onTap: () => context.push('/settings/web_search'),
                  ),
                  _SettingItem(
                    icon: Icons.menu_book_rounded,
                    iconColor: cInfo,
                    title: l10n.settingsKnowledge,
                    subtitle: l10n.settingsKnowledgeDesc,
                    onTap: () => _updateKnowledgeBase(context),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ===== 外观与体验 =====
              _buildSectionTitle(context, l10n.settingsAppearance),
              _buildGroupCard(
                context,
                items: [
                  _SettingItem(
                    icon: Icons.palette,
                    iconColor: cPrimary,
                    title: l10n.settingsAppearanceSettings,
                    subtitle: l10n.settingsAppearanceSettingsDesc,
                    onTap: () => context.push('/settings/appearance'),
                  ),
                  _SettingItem(
                    icon: Icons.language,
                    iconColor: cPrimary,
                    title: l10n.settingsLanguage,
                    subtitle: _getLanguageName(
                      SettingsDao.getCached('locale', defaultValue: 'system') as String,
                      l10n,
                    ),
                    onTap: () => _showLanguageDialog(context, ref),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ===== 关于 =====
              _buildSectionTitle(context, l10n.settingsAbout),
              _buildGroupCard(
                context,
                items: [
                  _SettingItem(
                    icon: Icons.info,
                    iconColor: cPrimary,
                    title: l10n.settingsAboutApp,
                    subtitle: l10n.settingsVersion,
                    trailing: TextButton(
                      onPressed: () => _checkForUpdate(context),
                      child: Text(l10n.settingsCheckUpdate),
                    ),
                    onTap: () {},
                  ),
                  _SettingItem(
                    icon: Icons.security,
                    iconColor: tc.textSub,
                    title: l10n.settingsSecurity,
                    subtitle: l10n.settingsSecurityDesc,
                    onTap: () => context.push('/settings/security'),
                  ),
                  _SettingItem(
                    icon: Icons.bug_report_outlined,
                    iconColor: cWarning,
                    title: '诊断',
                    subtitle: _diagnosticsSubtitle(),
                    onTap: () => _showDiagnosticsDialog(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分组标题
  Widget _buildSectionTitle(BuildContext context, String title) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: fTitle,
          fontWeight: FontWeight.w600,
          color: tc.textMain,
        ),
      ),
    );
  }

  /// 分组卡片：包含多个设置项
  /// 窄屏单列 + 分隔线；宽屏 2 列 Wrap 布局
  Widget _buildGroupCard(BuildContext context, {required List<_SettingItem> items}) {
    final tc = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 720;
          if (!isWide) {
            // 窄屏：单列 + 分隔线
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(items.length * 2 - 1, (index) {
                if (index.isOdd) {
                  return Divider(
                    height: 1,
                    indent: 60,
                    color: tc.border.withValues(alpha: 0.6),
                  );
                }
                return _buildSettingItem(context, items[index ~/ 2]);
              }),
            );
          }
          // 宽屏：2 列布局，每个条目独立卡片样式
          const spacing = 12.0;
          final itemWidth = (constraints.maxWidth - spacing * 3) / 2;
          return Padding(
            padding: const EdgeInsets.all(spacing),
            child: Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: items.map((item) => SizedBox(
                width: itemWidth,
                child: _buildSettingItem(context, item, isStandalone: true),
              )).toList(),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSettingItem(BuildContext context, _SettingItem item, {bool isStandalone = false}) {
    final tc = ThemeColors.of(context);
    return Material(
      color: isStandalone ? tc.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      clipBehavior: isStandalone ? Clip.antiAlias : Clip.none,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: isStandalone
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(rCard),
                  border: Border.all(color: tc.border.withValues(alpha: 0.5)),
                )
              : null,
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: item.iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(rSmall),
                ),
                child: Icon(item.icon, color: item.iconColor, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w500),
                    ),
                    if (item.subtitle != null)
                      Text(
                        item.subtitle!,
                        style: TextStyle(color: tc.textSub, fontSize: fSmall),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                  ],
                ),
              ),
              item.trailing ?? Icon(Icons.chevron_right, color: tc.textSub, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final info = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      // 简单实现：显示当前版本信息
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.settingsVersion}: ${info.version}'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// P2-8: 诊断入口副标题 — 显示崩溃次数或正常状态
  String _diagnosticsSubtitle() {
    final count = crashReporter.sessionCrashCount;
    if (count > 0) {
      return '本次会话崩溃 $count 次';
    }
    final lastTime = crashReporter.lastCrashTime;
    if (lastTime != null) {
      return '上次崩溃: ${_formatTime(lastTime)}';
    }
    return '查看崩溃日志与健康状态';
  }

  String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// P2-8: 诊断对话框 — 展示版本/SSH池/磁盘/崩溃日志
  Future<void> _showDiagnosticsDialog(BuildContext context) async {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    PackageInfo? info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (_) {}
    // 触发一次手动健康检查
    final snap = await healthCheckService.checkNow();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Row(
          children: [
            Icon(Icons.bug_report_outlined, color: cWarning, size: 22),
            const SizedBox(width: 8),
            Text('诊断', style: TextStyle(color: tc.textMain, fontSize: fTitle)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _diagRow(tc, '应用版本', '${info?.version ?? "unknown"}+${info?.buildNumber ?? "0"}'),
                _diagRow(tc, '本次会话崩溃', '${crashReporter.sessionCrashCount} 次'),
                _diagRow(tc, '上次崩溃时间',
                    crashReporter.lastCrashTime != null
                        ? _formatTime(crashReporter.lastCrashTime!)
                        : '无'),
                if (crashReporter.lastCrashSummary != null)
                  _diagRow(tc, '上次崩溃摘要', crashReporter.lastCrashSummary!),
                const Divider(height: 24),
                Text('健康检查', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _diagRow(tc, 'SSH 池连接', '${snap.sshTotalConnections} 个 (ref=${snap.sshTotalRefCount})'),
                _diagRow(tc, '已死连接', snap.sshDeadConnections > 0
                    ? '${snap.sshDeadConnections} 个 (需关注)'
                    : '0'),
                _diagRow(tc, '磁盘可写', snap.diskWritable ? '是' : '否 (致命问题!)'),
                _diagRow(tc, '检查时间', _formatTime(snap.timestamp)),
                const Divider(height: 24),
                Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制崩溃日志'),
                      onPressed: () async {
                        final content = await crashReporter.readLog();
                        if (!ctx.mounted) return;
                        if (content.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: const Text('崩溃日志为空'),
                            behavior: SnackBarBehavior.floating,
                          ));
                          return;
                        }
                        await Clipboard.setData(ClipboardData(text: content));
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text('已复制 ${content.length} 字符'),
                          backgroundColor: cSuccess,
                          behavior: SnackBarBehavior.floating,
                        ));
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('清除'),
                      onPressed: () async {
                        await crashReporter.clearLog();
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: const Text('已清除崩溃日志'),
                          backgroundColor: cSuccess,
                          behavior: SnackBarBehavior.floating,
                        ));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  /// 诊断对话框内的 "字段: 值" 行
  Widget _diagRow(ThemeColors tc, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: tc.textMain, fontSize: fSmall)),
          ),
        ],
      ),
    );
  }

  Future<void> _updateKnowledgeBase(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // 显示加载对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text(l10n.settingsKnowledge, style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Row(
          children: [
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Text('...', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
          ],
        ),
      ),
    );

    try {
      final knowledge = KnowledgeService();
      await knowledge.ensureInitialized();
      final result = await knowledge.forceUpdateFromRemote();

      if (!context.mounted) return;
      Navigator.pop(context); // 关闭加载对话框

      final isSuccess = result.startsWith('更新成功') || result.startsWith('Update success');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result),
          duration: Duration(seconds: isSuccess ? 2 : 4),
          backgroundColor: isSuccess ? cSuccess : cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // 关闭加载对话框

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 获取语言显示名称（"跟随系统" 需要本地化，其他语言用原名）
  String _getLanguageName(String code, AppLocalizations l10n) {
    if (code == 'system') return l10n.languageFollowSystem;
    const names = {
      'zh': '简体中文',
      'en': 'English',
      'ja': '日本語',
      'ko': '한국어',
      'de': 'Deutsch',
      'fr': 'Français',
      'ru': 'Русский',
      'es': 'Español',
      'pt': 'Português',
      'ar': 'العربية',
      'it': 'Italiano',
      'hi': 'हिन्दी',
      'th': 'ภาษาไทย',
      'vi': 'Tiếng Việt',
    };
    return names[code] ?? l10n.languageFollowSystem;
  }

  /// 语言选择对话框
  void _showLanguageDialog(BuildContext context, WidgetRef ref) {
    final current = SettingsDao.getCached('locale', defaultValue: 'system') as String;
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) => _LanguageDialog(
          current: current,
          onConfirm: (selected) async {
            await SettingsDao.set('locale', selected);
            ref.read(settingsProvider.notifier).setSetting('locale', selected);
          },
        ),
      ),
    );
  }
}

/// 语言选择对话框（StatefulWidget，确保选中状态正确更新）
class _LanguageDialog extends StatefulWidget {
  final String current;
  final Future<void> Function(String selected) onConfirm;

  const _LanguageDialog({required this.current, required this.onConfirm});

  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  late String _selected;

  // 各语言的原文名称（'system' 在 build 中用本地化文本拼接）
  static const _languages = <(String, String)>[
    ('zh', '简体中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
    ('de', 'Deutsch'),
    ('fr', 'Français'),
    ('ru', 'Русский'),
    ('es', 'Español'),
    ('pt', 'Português'),
    ('ar', 'العربية'),
    ('it', 'Italiano'),
    ('hi', 'हिन्दी'),
    ('th', 'ภาษาไทย'),
    ('vi', 'Tiếng Việt'),
  ];

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    // 组合完整列表：system（本地化）+ 各语言（原名）
    final allOptions = <(String, String)>[
      ('system', l10n.languageFollowSystem),
      ..._languages,
    ];
    return AlertDialog(
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      title: Text(l10n.languageDialogTitle, style: TextStyle(color: tc.textMain, fontSize: fTitle)),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: allOptions.map((entry) {
              final code = entry.$1;
              final name = entry.$2;
              final isSelected = code == _selected;
              return InkWell(
                onTap: () => setState(() => _selected = code),
                borderRadius: BorderRadius.circular(rSmall),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? cPrimary.withValues(alpha: 0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(rSmall),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: isSelected ? cPrimary : tc.textMuted,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(name, style: TextStyle(color: isSelected ? cPrimary : tc.textMain, fontSize: fBody)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub)),
        ),
        ElevatedButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await widget.onConfirm(_selected);
            if (!mounted) return;
            navigator.pop();
          },
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}

/// 设置项数据模型
class _SettingItem {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
}
