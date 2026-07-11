import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import '../core/constants.dart';
import '../services/daos.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  final _localAuth = LocalAuthentication();
  bool _appLockEnabled = false;
  bool _biometricsAvailable = false;
  String _biometricType = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkBiometrics();
  }

  Future<void> _loadSettings() async {
    final settings = SettingsDao.getCached('appLockEnabled', defaultValue: false);
    setState(() => _appLockEnabled = settings as bool);
  }

  Future<void> _checkBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (canCheck && isDeviceSupported) {
        final availableBiometrics = await _localAuth.getAvailableBiometrics();

        if (availableBiometrics.contains(BiometricType.face)) {
          _biometricType = 'face';
        } else if (availableBiometrics.contains(BiometricType.fingerprint)) {
          _biometricType = 'fingerprint';
        } else {
          _biometricType = 'generic';
        }

        setState(() => _biometricsAvailable = true);
      }
    } catch (e) {
      setState(() => _biometricsAvailable = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final biometricType = _biometricType == 'face'
        ? l10n.securityBiometricFaceId
        : _biometricType == 'fingerprint'
            ? l10n.securityBiometricFingerprint
            : l10n.securityBiometricGeneric;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.securityTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(pStandard),
            children: [
          // 应用锁
          Card(
            child: SwitchListTile(
              title: Text(l10n.securityEnableAppLock),
              subtitle: Text(
                _appLockEnabled
                    ? l10n.securityAppLockSubtitleOn(biometricType)
                    : l10n.securityAppLockSubtitleOff,
              ),
              value: _appLockEnabled,
              onChanged: _biometricsAvailable
                  ? (value) async {
                      if (value) {
                        // 验证生物识别
                        final authenticated = await _localAuth.authenticate(
                          localizedReason: l10n.securityAuthenticateReason,
                          options: const AuthenticationOptions(
                            biometricOnly: false,
                          ),
                        );
                        if (authenticated) {
                          await SettingsDao.set('appLockEnabled', true);
                          setState(() => _appLockEnabled = true);
                        }
                      } else {
                        await SettingsDao.set('appLockEnabled', false);
                        setState(() => _appLockEnabled = false);
                      }
                    }
                  : null,
            ),
          ),

          // 生物识别状态
          Card(
            child: ListTile(
              leading: Icon(
                _biometricsAvailable ? Icons.check_circle : Icons.warning,
                color: _biometricsAvailable ? cSuccess : cWarning,
              ),
              title: Text(l10n.securityBiometricStatusTitle),
              subtitle: Text(
                _biometricsAvailable
                    ? l10n.securityBiometricSupported(biometricType)
                    : l10n.securityBiometricNotSupported,
              ),
            ),
          ),

          const Divider(height: 32),

          // 审计日志
          Card(
            child: ListTile(
              leading: const Icon(Icons.history, color: cPrimary),
              title: Text(l10n.securityAuditLogTitle),
              subtitle: Text(l10n.securityAuditLogSubtitle),
              trailing: Icon(Icons.chevron_right, color: tc.textSub),
              onTap: () => context.push('/audit-log'),
            ),
          ),

          const Divider(height: 32),

          // 清除数据
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_forever, color: cDanger),
              title: Text(
                l10n.securityClearAllData,
                style: const TextStyle(color: cDanger),
              ),
              subtitle: Text(l10n.securityClearAllDataSubtitle),
              onTap: _showClearDataDialog,
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }

  void _showClearDataDialog() {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.securityDangerAction),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.securityClearWarning),
            const SizedBox(height: 8),
            Text(l10n.securityClearItemServers),
            Text(l10n.securityClearItemAiModels),
            Text(l10n.securityClearItemChats),
            Text(l10n.securityClearItemSnippets),
            Text(l10n.securityClearItemPasswords),
            const SizedBox(height: 16),
            Text(l10n.securityClearIrreversible, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            Text(l10n.securityClearConfirmPrompt),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'DELETE',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text == 'DELETE') {
                Navigator.pop(context);
                await _clearAllData();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(l10n.securityConfirmDelete),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAllData() async {
    // 显示加载
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 清空所有数据
      await HostsDao.clearAll();
      await AIModelsDao.clearAll();
      await ChatSessionsDao.clearAll();
      await SnippetsDao.clearAll();
      await SettingsDao.clear();

      if (mounted) {
        Navigator.pop(context); // 关闭加载
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.securityAllDataCleared)),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.securityClearFailed(e.toString()))),
        );
      }
    }
  }
}
