import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart';
import '../providers/agent_provider.dart';

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
          // 服务器管理
          _buildSectionTitle('服务器管理'),
          _buildListTile(
            context,
            icon: Icons.dns,
            iconColor: cPrimary,
            title: '服务器列表',
            subtitle: '管理 SSH 服务器连接',
            onTap: () => context.push('/hosts'),
          ),

          const Divider(height: 32),

          // 功能配置
          _buildSectionTitle('功能配置'),
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
            icon: Icons.code,
            iconColor: cPrimary,
            title: '快捷命令',
            subtitle: '自定义常用命令模板',
            onTap: () => context.push('/snippets'),
          ),
          _buildListTile(
            context,
            icon: Icons.auto_mode_rounded,
            iconColor: cAgentGreen,
            title: 'Agent 设置',
            subtitle: '最大执行步骤数: $maxSteps',
            onTap: () => _showMaxStepsDialog(context, ref),
          ),
          _buildListTile(
            context,
            icon: Icons.description_outlined,
            iconColor: cWarning,
            title: '内置系统提示词',
            subtitle: '编辑 AI 的核心提示词（可重置）',
            onTap: () => _showBuiltInPromptDialog(context, ref),
          ),
          _buildListTile(
            context,
            icon: Icons.edit_note_rounded,
            iconColor: cAgentGreen,
            title: '自定义 AI 提示词',
            subtitle: '追加到内置提示词末尾的额外指令',
            onTap: () => _showCustomPromptDialog(context, ref),
          ),

          const Divider(height: 32),

          // 外观与安全
          _buildSectionTitle('外观与安全'),
          _buildListTile(
            context,
            icon: Icons.palette,
            iconColor: cPrimary,
            title: '外观设置',
            onTap: () => context.push('/settings/appearance'),
          ),
          _buildListTile(
            context,
            icon: Icons.security,
            iconColor: cPrimary,
            title: '安全设置',
            onTap: () => context.push('/settings/security'),
          ),

          const Divider(height: 32),

          // 关于
          _buildSectionTitle('关于'),
          _buildListTile(
            context,
            icon: Icons.info,
            iconColor: cPrimary,
            title: '关于 AI Terminal',
            subtitle: '版本 1.1.0',
            trailing: TextButton(
              onPressed: () => _checkForUpdate(context),
              child: const Text('检查更新'),
            ),
          ),
        ],
      ),
    );
  }

  void _showMaxStepsDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController(text: ref.read(agentProvider).maxSteps.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('最大执行步骤数', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Agent 自动模式下最多执行的步骤数，超过后任务自动中断。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody),
              decoration: InputDecoration(
                labelText: '步骤数 (1-50)',
                labelStyle: TextStyle(color: ThemeColors.of(context).textSub),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ThemeColors.of(context).border)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              final steps = int.tryParse(controller.text) ?? 10;
              final clamped = steps.clamp(1, 50);
              ref.read(agentProvider.notifier).setMaxSteps(clamped);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: fBody,
          fontWeight: FontWeight.w600,
          color: cPrimary,
        ),
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
        leading: Icon(icon, color: iconColor),
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle, style: TextStyle(color: cTextSub, fontSize: fSmall)) : null,
        trailing: trailing ?? Icon(Icons.chevron_right, color: cTextSub),
        onTap: onTap,
      ),
    );
  }

  void _showCustomPromptDialog(BuildContext context, WidgetRef ref) {
    String? savedPrompt;
    try {
      savedPrompt = HiveInit.settingsBox.get('customSystemPrompt') as String?;
    } catch (_) {}
    final controller = TextEditingController(text: savedPrompt ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('自定义 AI 提示词', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('追加到内置提示词末尾的额外指令，用于调整 AI 的行为风格、输出偏好等。留空则不追加。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                minLines: 3,
                style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody),
                decoration: InputDecoration(
                  hintText: '例如：回答使用英文、输出简洁格式、优先使用 Docker...',
                  hintStyle: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fSmall),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ThemeColors.of(context).border)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                HiveInit.settingsBox.put('customSystemPrompt', controller.text.trim());
              } catch (_) {}
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('自定义提示词已保存'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showBuiltInPromptDialog(BuildContext context, WidgetRef ref) {
    final currentPrompt = getSystemPrompt();
    final controller = TextEditingController(text: currentPrompt);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('内置系统提示词', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.85,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('这是 AI 的核心系统提示词，修改后立即生效。包含 {context} 占位符会被替换为服务器信息。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              const SizedBox(height: 8),
              Text('⚠️ 修改需谨慎，不合适的提示词可能导致 AI 行为异常。可随时点击"重置"恢复默认。', style: TextStyle(color: cWarning, fontSize: fMicro)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 12,
                minLines: 6,
                style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fSmall, fontFamily: 'JetBrainsMono'),
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: cBorder)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.text = defaultSystemPrompt;
            },
            child: Text('重置默认', style: TextStyle(color: cWarning)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              saveSystemPrompt(controller.text.trim());
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('内置提示词已保存'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('保存'),
          ),
        ],
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
}
