import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context)!;
    final url = _webhookController.text.trim();
    if (_enabled && url.isNotEmpty) {
      final err = NotificationService.validateWebhookUrl(url);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.notificationInvalidUrl(err)),
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
        SnackBar(
          content: Text(l10n.notificationSaved),
          backgroundColor: cSuccess,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.notificationSaveFailed(e.toString())),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _testNotification() async {
    final l10n = AppLocalizations.of(context)!;
    final url = _webhookController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.notificationEnterUrlFirst), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final err = NotificationService.validateWebhookUrl(url);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.notificationInvalidUrl(err)),
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
          content: Text(ok ? l10n.notificationTestSent : l10n.notificationTestSendFailed),
          backgroundColor: ok ? cSuccess : cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.notificationTestFailed(e.toString())),
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
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.notificationTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
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
                        Text(l10n.notificationEnable, style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                        Text(l10n.notificationEnableHint,
                            style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _enabled,
                    activeThumbColor: cWarning,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                ],
              ),
            ),
          ),

          if (_enabled) ...[
            const SizedBox(height: 16),

            // Webhook URL
            _buildSectionTitle(l10n.notificationWebhookUrl),
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
                          borderSide: const BorderSide(color: cPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(l10n.notificationWebhookSupport,
                        style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 触发条件
            _buildSectionTitle(l10n.notificationTriggerTitle),
            Card(
              color: tc.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
              child: Padding(
                padding: const EdgeInsets.all(pStandard),
                child: RadioGroup<String>(
                  groupValue: _trigger,
                  onChanged: (v) => setState(() => _trigger = v ?? 'failedOnly'),
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        value: 'failedOnly',
                        title: Text(l10n.notificationFailedOnly),
                        subtitle: Text(l10n.notificationFailedOnlySubtitle),
                        activeColor: cPrimary,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      Divider(color: tc.border, height: 1),
                      RadioListTile<String>(
                        value: 'always',
                        title: Text(l10n.notificationAlways),
                        subtitle: Text(l10n.notificationAlwaysSubtitle),
                        activeColor: cPrimary,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
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
              label: Text(_testing ? l10n.notificationSending : l10n.notificationSendTest),
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
            label: Text(l10n.notificationSaveConfig),
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
                    const Icon(Icons.info_outline, size: 14, color: cInfo),
                    const SizedBox(width: 6),
                    Text(l10n.notificationInstructionsTitle, style: const TextStyle(color: cInfo, fontSize: fSmall, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.notificationInstructionsBody,
                  style: TextStyle(color: tc.textBody, fontSize: fMicro, height: 1.6),
                ),
              ],
            ),
          ),
        ],
          ),
        ),
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
