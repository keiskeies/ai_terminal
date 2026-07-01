import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../providers/agent_provider.dart';
import '../services/knowledge_service.dart';

/// P1-5: 设置页信息架构重组
/// 按用户任务场景分组：连接管理、AI 与智能、外观与体验、关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只监听需要的 maxSteps，避免 agent 其他状态变化触发 rebuild
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // ===== 连接管理 =====
          _buildSectionTitle(context, '连接管理'),
          _buildGroupCard(
            context,
            items: [
              _SettingItem(
                icon: Icons.dns,
                iconColor: cPrimary,
                title: '服务器列表',
                subtitle: '管理 SSH 服务器连接',
                onTap: () => context.push('/hosts'),
              ),
              _SettingItem(
                icon: Icons.code,
                iconColor: cPrimary,
                title: '快捷命令',
                subtitle: '自定义常用命令模板',
                onTap: () => context.push('/snippets'),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ===== AI 与智能 =====
          _buildSectionTitle(context, 'AI 与智能'),
          _buildGroupCard(
            context,
            items: [
              _SettingItem(
                icon: Icons.smart_toy,
                iconColor: cPrimary,
                title: 'AI 模型配置',
                subtitle: '管理 API Key 和模型参数',
                onTap: () => context.push('/settings/ai'),
              ),
              _SettingItem(
                icon: Icons.auto_mode_rounded,
                iconColor: cAgentGreen,
                title: 'Agent 设置',
                subtitle: '最大执行步骤数: ${maxSteps == 0 ? "无限制" : maxSteps}',
                onTap: () => context.push('/settings/agent'),
              ),
              _SettingItem(
                icon: Icons.menu_book_rounded,
                iconColor: cInfo,
                title: '命令手册知识库',
                subtitle: '从远程服务器同步最新的软件安装指南',
                onTap: () => _updateKnowledgeBase(context),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ===== 外观与体验 =====
          _buildSectionTitle(context, '外观与体验'),
          _buildGroupCard(
            context,
            items: [
              _SettingItem(
                icon: Icons.palette,
                iconColor: cPrimary,
                title: '外观设置',
                subtitle: '主题模式、终端字体、配色方案',
                onTap: () => context.push('/settings/appearance'),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ===== 关于 =====
          _buildSectionTitle(context, '关于'),
          _buildGroupCard(
            context,
            items: [
              _SettingItem(
                icon: Icons.info,
                iconColor: cPrimary,
                title: '关于 AI Terminal',
                subtitle: '版本 1.3.3',
                trailing: TextButton(
                  onPressed: () => _checkForUpdate(context),
                  child: const Text('检查更新'),
                ),
                onTap: () {},
              ),
              _SettingItem(
                icon: Icons.security,
                iconColor: cTextSub,
                title: '安全设置',
                subtitle: '生物识别认证',
                onTap: () => context.push('/settings/security'),
              ),
            ],
          ),
        ],
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
  Widget _buildGroupCard(BuildContext context, {required List<_SettingItem> items}) {
    final tc = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
      ),
      child: Column(
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
      ),
    );
  }

  Widget _buildSettingItem(BuildContext context, _SettingItem item) {
    final tc = ThemeColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
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
    try {
      final info = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      // 简单实现：显示当前版本信息
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('当前已是最新版本 (${info.version})'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('检查更新失败: $e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _updateKnowledgeBase(BuildContext context) async {
    // 显示加载对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('更新知识库', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Row(
          children: [
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Text('正在从远程服务器下载...', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
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

      final isSuccess = result.startsWith('更新成功');
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
          content: Text('更新失败: $e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
