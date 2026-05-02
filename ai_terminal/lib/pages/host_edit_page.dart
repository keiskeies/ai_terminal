import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../widgets/color_picker_row.dart';

const _uuid = Uuid();

class HostEditPage extends ConsumerStatefulWidget {
  final String? hostId;

  const HostEditPage({super.key, this.hostId});

  @override
  ConsumerState<HostEditPage> createState() => _HostEditPageState();
}

class _HostEditPageState extends ConsumerState<HostEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _usernameController = TextEditingController(text: 'root');
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _groupController = TextEditingController(text: '默认');

  String _authType = 'password';
  String? _tagColor;
  int _timeout = 30;
  String _encoding = 'utf-8';
  // 跳板机内联配置
  final _jumpHostController = TextEditingController();
  final _jumpPortController = TextEditingController(text: '22');
  final _jumpUsernameController = TextEditingController(text: 'root');
  final _jumpPasswordController = TextEditingController();
  final _jumpPrivateKeyController = TextEditingController();
  String? _jumpAuthType = 'password';
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;
  bool _obscurePrivateKey = true;
  bool _obscureJumpPassword = true;
  bool _obscureJumpPrivateKey = true;
  bool _jumpExpanded = false; // 跳板机区域展开状态

  bool get _isEditing => widget.hostId != null;
  HostConfig? _existingHost;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _loadExistingHost();
    }
  }

  Future<void> _loadExistingHost() async {
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId!);
    if (host != null) {
      _existingHost = host;
      _nameController.text = host.name;
      _hostController.text = host.host;
      _portController.text = host.port.toString();
      _usernameController.text = host.username;
      _authType = host.authType;
      _groupController.text = host.group;
      _tagColor = host.tagColor;
      _timeout = host.timeout;
      _encoding = host.encoding;
      // 加载跳板机内联配置
      _jumpHostController.text = host.jumpHost ?? '';
      _jumpPortController.text = (host.jumpPort).toString();
      _jumpUsernameController.text = host.jumpUsername ?? 'root';
      _jumpAuthType = host.jumpAuthType ?? 'password';
      _jumpExpanded = host.hasJumpHost;

      // 加载凭据
      if (host.isPasswordAuth) {
        final password = await CredentialsStore.get(hostId: host.id, type: 'password');
        _passwordController.text = password ?? '';
      } else {
        final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');
        _privateKeyController.text = privateKey ?? '';
      }

      // 加载跳板机凭据
      if (host.hasJumpHost) {
        final jumpPassword = await CredentialsStore.get(hostId: '${host.id}_jump', type: 'password');
        _jumpPasswordController.text = jumpPassword ?? '';
        final jumpPrivateKey = await CredentialsStore.get(hostId: '${host.id}_jump', type: 'privateKey');
        _jumpPrivateKeyController.text = jumpPrivateKey ?? '';
      }

      setState(() {});
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    _groupController.dispose();
    _jumpHostController.dispose();
    _jumpPortController.dispose();
    _jumpUsernameController.dispose();
    _jumpPasswordController.dispose();
    _jumpPrivateKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑服务器' : '新建服务器'),
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(pStandard),
                children: [
                  // 基本信息
                  _buildSectionTitle('基本信息'),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '名称 *',
                      hintText: '例如: 生产服务器',
                    ),
                    maxLength: 20,
                    validator: (value) {
                      if (value == null || value.isEmpty) return '请输入名称';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: '主机地址 *',
                      hintText: 'IP 地址或域名',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) return '请输入主机地址';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _portController,
                          decoration: const InputDecoration(
                            labelText: '端口',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _usernameController,
                          decoration: const InputDecoration(
                            labelText: '用户名',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 认证方式
                  _buildSectionTitle('认证方式'),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: _authType,
                    decoration: const InputDecoration(
                      labelText: '认证方式 *',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'password', child: Text('密码')),
                      DropdownMenuItem(value: 'privateKey', child: Text('私钥')),
                    ],
                    onChanged: (value) => setState(() => _authType = value!),
                  ),
                  const SizedBox(height: 12),

                  // 密码输入
                  if (_authType == 'password')
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: '密码',
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                    ),

                  // 私钥输入
                  if (_authType == 'privateKey') ...[
                    SwitchListTile(
                      title: const Text('粘贴私钥'),
                      subtitle: const Text('关闭则从文件选择'),
                      value: _obscurePrivateKey,
                      onChanged: (value) => setState(() => _obscurePrivateKey = value),
                    ),
                    if (_obscurePrivateKey)
                      TextFormField(
                        controller: _privateKeyController,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: '私钥内容',
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                        ),
                      )
                    else
                      ListTile(
                        title: const Text('选择私钥文件'),
                        trailing: TextButton(
                          onPressed: () async {
                            try {
                              final result = await FilePicker.platform.pickFiles(
                                type: FileType.custom,
                                allowedExtensions: ['pem', 'key', 'ppk', 'id_rsa', '*'],
                                dialogTitle: '选择私钥文件',
                              );
                              if (result != null && result.files.single.path != null) {
                                final file = File(result.files.single.path!);
                                final content = await file.readAsString();
                                setState(() {
                                  _privateKeyController.text = content;
                                });
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('已读取私钥文件: ${result.files.single.name}'),
                                      duration: const Duration(seconds: 2),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('读取文件失败: $e'),
                                    backgroundColor: cDanger,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('选择'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passphraseController,
                      obscureText: _obscurePassphrase,
                      decoration: InputDecoration(
                        labelText: '私钥密码 (可选)',
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassphrase ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscurePassphrase = !_obscurePassphrase),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),

                  // 分组与标签
                  _buildSectionTitle('分组与标签'),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _groupController,
                    decoration: const InputDecoration(
                      labelText: '分组',
                    ),
                  ),
                  const SizedBox(height: 12),

                  const Text('标签颜色', style: TextStyle(color: cTextSub)),
                  const SizedBox(height: 8),
                  ColorPickerRow(
                    selectedColor: _tagColor,
                    onColorSelected: (color) => setState(() => _tagColor = color),
                  ),
                  const SizedBox(height: 24),

                  // 高级设置
                  _buildSectionTitle('高级设置'),
                  const SizedBox(height: 12),

                  // 跳板机/堡垒机配置（内联）
                  _buildSectionTitle('跳板机 / 堡垒机'),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('使用跳板机'),
                    subtitle: const Text('通过跳板机/堡垒机中转连接'),
                    value: _jumpExpanded,
                    onChanged: (value) => setState(() => _jumpExpanded = value),
                  ),
                  if (_jumpExpanded) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _jumpHostController,
                      decoration: const InputDecoration(
                        labelText: '跳板机地址 *',
                        hintText: 'IP 地址或域名',
                        prefixIcon: Icon(Icons.swap_horiz, size: 16),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _jumpPortController,
                            decoration: const InputDecoration(labelText: '跳板机端口'),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: _jumpUsernameController,
                            decoration: const InputDecoration(labelText: '跳板机用户名'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _jumpAuthType,
                      decoration: const InputDecoration(labelText: '跳板机认证方式'),
                      items: const [
                        DropdownMenuItem(value: 'password', child: Text('密码')),
                        DropdownMenuItem(value: 'privateKey', child: Text('私钥')),
                      ],
                      onChanged: (value) => setState(() => _jumpAuthType = value),
                    ),
                    const SizedBox(height: 12),
                    // 跳板机密码
                    if (_jumpAuthType == 'password')
                      TextFormField(
                        controller: _jumpPasswordController,
                        obscureText: _obscureJumpPassword,
                        decoration: InputDecoration(
                          labelText: '跳板机密码',
                          suffixIcon: IconButton(
                            icon: Icon(_obscureJumpPassword ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscureJumpPassword = !_obscureJumpPassword),
                          ),
                        ),
                      ),
                    // 跳板机私钥
                    if (_jumpAuthType == 'privateKey')
                      TextFormField(
                        controller: _jumpPrivateKeyController,
                        obscureText: _obscureJumpPrivateKey,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: '跳板机私钥内容',
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                          suffixIcon: IconButton(
                            icon: Icon(_obscureJumpPrivateKey ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscureJumpPrivateKey = !_obscureJumpPrivateKey),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: cInfo.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cInfo.withOpacity(0.15)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 12, color: cInfo),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '将先连接跳板机，再通过跳板机转发到目标服务器',
                              style: TextStyle(fontSize: fMicro, color: cInfo.withOpacity(0.8)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  ExpansionTile(
                    title: const Text('更多设置'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(pStandard),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('连接超时: $_timeout 秒'),
                            Slider(
                              value: _timeout.toDouble(),
                              min: 10,
                              max: 120,
                              divisions: 11,
                              label: '$_timeout 秒',
                              onChanged: (value) => setState(() => _timeout = value.toInt()),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: _encoding,
                              decoration: const InputDecoration(labelText: '字符编码'),
                              items: const [
                                DropdownMenuItem(value: 'utf-8', child: Text('UTF-8')),
                                DropdownMenuItem(value: 'gbk', child: Text('GBK')),
                                DropdownMenuItem(value: 'big5', child: Text('BIG5')),
                              ],
                              onChanged: (value) => setState(() => _encoding = value!),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
            // 底部操作栏
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: pStandard, vertical: 8),
              decoration: BoxDecoration(
                color: ThemeColors.of(context).card,
                border: Border(top: BorderSide(color: ThemeColors.of(context).border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => context.pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _saveHost,
                      child: const Text('💾 保存'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: fBody,
        fontWeight: FontWeight.w600,
        color: cPrimary,
      ),
    );
  }

  Future<void> _saveHost() async {
    if (!_formKey.currentState!.validate()) return;

    final hostId = _isEditing ? _existingHost!.id : _uuid.v4();
    final config = HostConfig.create(
      id: hostId,
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text) ?? 22,
      username: _usernameController.text.trim(),
      authType: _authType,
      group: _groupController.text.trim().isEmpty ? '默认' : _groupController.text.trim(),
      tagColor: _tagColor,
      jumpHost: _jumpExpanded ? _jumpHostController.text.trim() : null,
      jumpPort: int.tryParse(_jumpPortController.text) ?? 22,
      jumpUsername: _jumpExpanded ? _jumpUsernameController.text.trim() : null,
      jumpAuthType: _jumpExpanded ? _jumpAuthType : null,
      timeout: _timeout,
      encoding: _encoding,
    );

    // 保存凭据
    bool credentialsSaved = true;
    String? credentialsError;
    
    if (_authType == 'password' && _passwordController.text.isNotEmpty) {
      credentialsSaved = await CredentialsStore.save(
        hostId: hostId,
        type: 'password',
        value: _passwordController.text,
      );
      if (!credentialsSaved) {
        credentialsError = '密码保存失败';
      }
    } else if (_authType == 'privateKey' && _privateKeyController.text.isNotEmpty) {
      credentialsSaved = await CredentialsStore.save(
        hostId: hostId,
        type: 'privateKey',
        value: _privateKeyController.text,
      );
      if (!credentialsSaved) {
        credentialsError = '私钥保存失败';
      }
    }
    
    // 如果是编辑模式，检查是否需要保留旧凭据
    if (_isEditing && _authType == 'password' && _passwordController.text.isEmpty && _existingHost?.isPasswordAuth == true) {
      // 用户清空了密码，保持原来的密码不变
    } else if (_isEditing && _authType == 'privateKey' && _privateKeyController.text.isEmpty && _existingHost?.isKeyAuth == true) {
      // 用户清空了私钥，保持原来的私钥不变
    }

    // 保存跳板机凭据
    if (_jumpExpanded) {
      final jumpCredKey = '${hostId}_jump';
      if (_jumpAuthType == 'password' && _jumpPasswordController.text.isNotEmpty) {
        await CredentialsStore.save(
          hostId: jumpCredKey,
          type: 'password',
          value: _jumpPasswordController.text,
        );
      } else if (_jumpAuthType == 'privateKey' && _jumpPrivateKeyController.text.isNotEmpty) {
        await CredentialsStore.save(
          hostId: jumpCredKey,
          type: 'privateKey',
          value: _jumpPrivateKeyController.text,
        );
      }
    }

    // 保存配置
    if (_isEditing) {
      await ref.read(hostsProvider.notifier).updateHost(config);
    } else {
      await ref.read(hostsProvider.notifier).addHost(config);
    }

    if (mounted) {
      if (credentialsError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ 配置保存成功，但 $credentialsError，请重试'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ 保存成功')),
        );
      }
      context.pop();
    }
  }
}
