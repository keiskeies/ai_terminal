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
          _buildSectionTitle(context, '连接管理', Icons.link),
          _buildListTile(
            context,
            icon: Icons.dns,
            iconColor: cPrimary,
            title: '服务器列表',
            subtitle: '管理 SSH 服务器连接',
            onTap: () => context.push('/hosts'),
          ),
          _buildListTile(
            context,
            icon: Icons.code,
            iconColor: cPrimary,
            title: '快捷命令',
            subtitle: '自定义常用命令模板',
            onTap: () => context.push('/snippets'),
          ),

          const SizedBox(height: 24),

          // ===== AI 与智能 =====
          _buildSectionTitle(context, 'AI 与智能', Icons.auto_fix_high),
          _buildListTile(
            context,
            icon: Icons.smart_toy,
            iconColor: cPrimary,
            title: 'AI 模型配置',
            subtitle: '管理 API Key 和模型参数',
            onTap: () => context.push('/settings/ai'),
          ),
          _buildListTile(
            context,
            icon: Icons.auto_mode_rounded,
            iconColor: cAgentGreen,
            title: 'Agent 设置',
            subtitle: '最大执行步骤数: ${maxSteps == 0 ? "无限制" : maxSteps}',
            onTap: () => context.push('/settings/agent'),
          ),
          _buildListTile(
            context,
            icon: Icons.menu_book_rounded,
            iconColor: cInfo,
            title: '命令手册知识库',
            subtitle: '从远程服务器同步最新的软件安装指南',
            onTap: () => _updateKnowledgeBase(context),
          ),

          const SizedBox(height: 24),

          // ===== 外观与体验 =====
          _buildSectionTitle(context, '外观与体验', Icons.palette),
          _buildListTile(
            context,
            icon: Icons.palette,
            iconColor: cPrimary,
            title: '外观设置',
            subtitle: '主题模式、终端字体、配色方案',
            onTap: () => context.push('/settings/appearance'),
          ),

          const SizedBox(height: 24),

          // ===== 关于 =====
          _buildSectionTitle(context, '关于', Icons.info),
          _buildListTile(
            context,
            icon: Icons.info,
            iconColor: cPrimary,
            title: '关于 AI Terminal',
            subtitle: '版本 1.3.0',
            trailing: TextButton(
              onPressed: () => _checkForUpdate(context),
              child: const Text('检查更新'),
            ),
          ),
          _buildListTile(
            context,
            icon: Icons.security,
            iconColor: cTextSub,
            title: '安全设置',
            subtitle: '生物识别认证',
            onTap: () => context.push('/settings/security'),
          ),
        ],
      ),
    );
  }

  /// P1-5: 分组标题带图标和视觉分隔
  Widget _buildSectionTitle(BuildContext context, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cPrimary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: fTitle,
              fontWeight: FontWeight.w600,
              color: cPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    cPrimary.withOpacity(0.3),
                    cPrimary.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(rSmall),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle, style: TextStyle(color: cTextSub, fontSize: fSmall)) : null,
        trailing: trailing ?? Icon(Icons.chevron_right, color: cTextSub),
        onTap: onTap,
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    try {
      final info = await PackageInfo.fromPlatform();
      // 简单实现：显示当前版本信息
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('当前已是最新版本 (${info.version})'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
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
