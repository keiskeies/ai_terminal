import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import '../core/constants.dart';
import '../core/hive_init.dart';

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
    final settings = HiveInit.settingsBox.get('appLockEnabled', defaultValue: false);
    setState(() => _appLockEnabled = settings as bool);
  }

  Future<void> _checkBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (canCheck && isDeviceSupported) {
        final availableBiometrics = await _localAuth.getAvailableBiometrics();

        if (availableBiometrics.contains(BiometricType.face)) {
          _biometricType = '面容 ID';
        } else if (availableBiometrics.contains(BiometricType.fingerprint)) {
          _biometricType = '指纹';
        } else {
          _biometricType = '生物识别';
        }

        setState(() => _biometricsAvailable = true);
      }
    } catch (e) {
      setState(() => _biometricsAvailable = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('安全设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // 应用锁
          Card(
            child: SwitchListTile(
              title: const Text('启用应用锁'),
              subtitle: Text(
                _appLockEnabled
                    ? '启动时需要$_biometricType或密码'
                    : '关闭后可直接访问应用',
              ),
              value: _appLockEnabled,
              onChanged: _biometricsAvailable
                  ? (value) async {
                      if (value) {
                        // 验证生物识别
                        final authenticated = await _localAuth.authenticate(
                          localizedReason: '验证身份以启用应用锁',
                          options: const AuthenticationOptions(
                            biometricOnly: false,
                          ),
                        );
                        if (authenticated) {
                          await HiveInit.settingsBox.put('appLockEnabled', true);
                          setState(() => _appLockEnabled = true);
                        }
                      } else {
                        await HiveInit.settingsBox.put('appLockEnabled', false);
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
              title: const Text('生物识别状态'),
              subtitle: Text(
                _biometricsAvailable
                    ? '✅ 支持 $_biometricType'
                    : '⚠️ 设备不支持生物识别',
              ),
            ),
          ),

          const Divider(height: 32),

          // 审计日志
          Card(
            child: ListTile(
              leading: Icon(Icons.history, color: cPrimary),
              title: const Text('审计日志'),
              subtitle: const Text('查看 AI 命令执行记录'),
              trailing: Icon(Icons.chevron_right, color: cTextSub),
              onTap: () => context.push('/audit-log'),
            ),
          ),

          const Divider(height: 32),

          // 清除数据
          Card(
            child: ListTile(
              leading: Icon(Icons.delete_forever, color: cDanger),
              title: Text(
                '清除所有数据',
                style: TextStyle(color: cDanger),
              ),
              subtitle: const Text('删除服务器配置、聊天记录、凭据 (不可恢复)'),
              onTap: _showClearDataDialog,
            ),
          ),
        ],
      ),
    );
  }

  void _showClearDataDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ 危险操作'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('此操作将删除所有数据，包括:'),
            const SizedBox(height: 8),
            const Text('• 服务器配置'),
            const Text('• AI 模型配置'),
            const Text('• 聊天记录'),
            const Text('• 快捷命令'),
            const Text('• 所有凭据'),
            const SizedBox(height: 16),
            const Text('此操作不可恢复！', style: TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            const Text('请输入 DELETE 确认:'),
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
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text == 'DELETE') {
                Navigator.pop(context);
                await _clearAllData();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: const Text('确认删除'),
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
      // 清空 Hive
      await HiveInit.hostsBox.clear();
      await HiveInit.aiModelsBox.clear();
      await HiveInit.chatSessionsBox.clear();
      await HiveInit.snippetsBox.clear();
      await HiveInit.settingsBox.clear();

      if (mounted) {
        Navigator.pop(context); // 关闭加载
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所有数据已清除')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除失败: $e')),
        );
      }
    }
  }
}
