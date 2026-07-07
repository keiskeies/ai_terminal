import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/notification_service.dart';

/// 任务完成通知设置页
///
/// 配置 webhook URL，任务完成/失败时自动推送通知。
/// 支持钉钉、飞书、企业微信群机器人。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late bool _enabled;
  late TextEditingController _webhookController;
  late String _trigger;
  bool _testing = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final cfg = NotificationService.config;
    _enabled = cfg.enabled;
    _webhookController = TextEditingController(text: cfg.webhookUrl);
    _trigger = cfg.trigger;
    _loaded = true;
  }

  @override
  void dispose() {
    _webhookController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _webhookController.text.trim();
    if (_enabled && url.isNotEmpty) {
      final err = NotificationService.validateWebhookUrl(url);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('URL 校验失败: $err'),
            backgroundColor: cDanger,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }
    final cfg = NotificationConfig(
      enabled: _enabled,
      webhookUrl: url,
      trigger: _trigger,
    );
    try {
      await NotificationService.save(cfg);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('通知配置已保存'),
          backgroundColor: cSuccess,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: $e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _testNotification() async {
    final url = _webhookController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 webhook URL'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final err = NotificationService.validateWebhookUrl(url);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('URL 校验失败: $err'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // 先保存当前配置再测试
    await _save();
    setState(() => _testing = true);
    try {
      final ok = await NotificationService.sendTest();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '测试通知已发送，请检查目标群' : '推送失败，请检查 webhook URL'),
          backgroundColor: ok ? cSuccess : cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('测试失败: $e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('任务完成通知')),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // 启用开关
          Card(
            color: tc.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Row(
                children: [
                  Icon(_enabled ? Icons.notifications_active : Icons.notifications_off,
                      color: _enabled ? cWarning : tc.textSub),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('启用任务完成通知', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                        Text('任务完成或失败时向 webhook 推送通知',
                            style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _enabled,
                    activeColor: cWarning,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                ],
              ),
            ),
          ),

          if (_enabled) ...[
            const SizedBox(height: 16),

            // Webhook URL
            _buildSectionTitle('Webhook URL'),
            Card(
              color: tc.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
              child: Padding(
                padding: const EdgeInsets.all(pStandard),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _webhookController,
                      style: TextStyle(color: tc.textMain, fontSize: fBody),
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'https://oapi.dingtalk.com/robot/send?access_token=xxx',
                        hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
                        filled: true,
                        fillColor: tc.bg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(rSmall),
                          borderSide: BorderSide(color: tc.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(rSmall),
                          borderSide: BorderSide(color: tc.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(rSmall),
                          borderSide: BorderSide(color: cPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('支持：钉钉、飞书、企业微信群机器人、Slack、自定义 HTTP endpoint',
                        style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 触发条件
            _buildSectionTitle('触发条件'),
            Card(
              color: tc.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
              child: Padding(
                padding: const EdgeInsets.all(pStandard),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      value: 'failedOnly',
                      groupValue: _trigger,
                      onChanged: (v) => setState(() => _trigger = v ?? 'failedOnly'),
                      title: const Text('仅失败时推送'),
                      subtitle: const Text('只有任务失败时才推送通知'),
                      activeColor: cPrimary,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    Divider(color: tc.border, height: 1),
                    RadioListTile<String>(
                      value: 'always',
                      groupValue: _trigger,
                      onChanged: (v) => setState(() => _trigger = v ?? 'always'),
                      title: const Text('总是推送'),
                      subtitle: const Text('任务完成和失败都推送通知'),
                      activeColor: cPrimary,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 测试按钮
            OutlinedButton.icon(
              onPressed: _testing ? null : _testNotification,
              icon: _testing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send, size: 16),
              label: Text(_testing ? '发送中...' : '发送测试通知'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                foregroundColor: cPrimary,
                side: BorderSide(color: cPrimary.withValues(alpha: 0.5)),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // 保存按钮
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save, size: 16),
            label: const Text('保存配置'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: cPrimary,
            ),
          ),

          const SizedBox(height: 16),
          // 使用说明
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cInfo.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: cInfo.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: cInfo),
                    const SizedBox(width: 6),
                    Text('使用说明', style: TextStyle(color: cInfo, fontSize: fSmall, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '1. 在钉钉/飞书/企业微信群中添加"自定义机器人"，获取 webhook URL\n'
                  '2. 将 URL 粘贴到上方输入框\n'
                  '3. 点击"发送测试通知"验证是否生效\n'
                  '4. 此后 Agent 任务完成/失败时会自动推送通知到该群',
                  style: TextStyle(color: tc.textBody, fontSize: fMicro, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
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
}
