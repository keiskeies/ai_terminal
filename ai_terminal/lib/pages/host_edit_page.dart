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
import '../l10n/app_localizations.dart';
import '../core/l10n_holder.dart';

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
  final _groupController = TextEditingController();

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
  final _sudoPasswordController = TextEditingController();
  String? _jumpAuthType = 'password';
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;
  bool _obscurePrivateKey = true;
  bool _obscureJumpPassword = true;
  bool _obscureJumpPrivateKey = true;
  bool _obscureSudoPassword = true;
  bool _jumpExpanded = false; // 跳板机区域展开状态

  bool get _isEditing => widget.hostId != null;
  HostConfig? _existingHost;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _loadExistingHost();
    } else {
      _groupController.text = L10n.str.hostDefaultGroup;
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
      _groupController.text = host.group == '默认' ? L10n.str.hostDefaultGroup : host.group;
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

      // 加载 sudo 密码（用于 AI 执行 sudo 命令时自动注入）
      final sudoPassword = await CredentialsStore.get(hostId: host.id, type: 'sudoPassword');
      _sudoPasswordController.text = sudoPassword ?? '';

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
    _sudoPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.hostEditTitleEdit : l10n.hostEditTitleNew),
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
                  _buildSectionTitle(l10n.hostEditSectionBasic),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: l10n.hostEditNameLabel,
                      hintText: l10n.hostEditNameHint,
                    ),
                    maxLength: 20,
                    validator: (value) {
                      if (value == null || value.isEmpty) return l10n.hostEditNameRequired;
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _hostController,
                    decoration: InputDecoration(
                      labelText: l10n.hostEditHostLabel,
                      hintText: l10n.hostEditHostHint,
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) return l10n.hostEditHostRequired;
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _portController,
                          decoration: InputDecoration(
                            labelText: l10n.port,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _usernameController,
                          decoration: InputDecoration(
                            labelText: l10n.hostEditUsernameLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 认证方式
                  _buildSectionTitle(l10n.hostEditSectionAuth),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    initialValue: _authType,
                    decoration: InputDecoration(
                      labelText: l10n.hostEditAuthTypeLabel,
                    ),
                    items: [
                      DropdownMenuItem(value: 'password', child: Text(l10n.hostEditPassword)),
                      DropdownMenuItem(value: 'privateKey', child: Text(l10n.hostEditPrivateKey)),
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
                        labelText: l10n.hostEditPassword,
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                    ),

                  // 私钥输入
                  if (_authType == 'privateKey') ...[
                    SwitchListTile(
                      title: Text(l10n.hostEditPastePrivateKey),
                      subtitle: Text(l10n.hostEditPastePrivateKeySubtitle),
                      value: _obscurePrivateKey,
                      onChanged: (value) => setState(() => _obscurePrivateKey = value),
                    ),
                    if (_obscurePrivateKey)
                      TextFormField(
                        controller: _privateKeyController,
                        maxLines: 6,
                        decoration: InputDecoration(
                          labelText: l10n.hostEditPrivateKeyContent,
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                        ),
                      )
                    else
                      ListTile(
                        title: Text(l10n.hostEditSelectPrivateKeyFile),
                        trailing: TextButton(
                          onPressed: () async {
                            try {
                              final result = await FilePicker.platform.pickFiles(
                                type: FileType.custom,
                                allowedExtensions: ['pem', 'key', 'ppk', 'id_rsa', '*'],
                                dialogTitle: l10n.hostEditSelectPrivateKeyFile,
                              );
                              if (result != null && result.files.single.path != null) {
                                final file = File(result.files.single.path!);
                                final content = await file.readAsString();
                                setState(() {
                                  _privateKeyController.text = content;
                                });
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.hostEditPrivateKeyFileRead(result.files.single.name)),
                                      duration: const Duration(seconds: 2),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.hostEditReadFileFailed(e.toString())),
                                    backgroundColor: cDanger,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            }
                          },
                          child: Text(l10n.hostEditSelect),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passphraseController,
                      obscureText: _obscurePassphrase,
                      decoration: InputDecoration(
                        labelText: l10n.hostEditPassphraseLabel,
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassphrase ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscurePassphrase = !_obscurePassphrase),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),

                  // 分组与标签
                  _buildSectionTitle(l10n.hostEditSectionGroupTag),
                  const SizedBox(height: 12),

                  // 分组：下拉候选 + 自由输入（新建分组）
                  _buildGroupField(),
                  const SizedBox(height: 12),

                  Text(l10n.hostEditTagColor, style: TextStyle(color: tc.textSub)),
                  const SizedBox(height: 8),
                  ColorPickerRow(
                    selectedColor: _tagColor,
                    onColorSelected: (color) => setState(() => _tagColor = color),
                  ),
                  const SizedBox(height: 24),

                  // 高级设置
                  _buildSectionTitle(l10n.commonAdvancedSettings),
                  const SizedBox(height: 12),

                  // 跳板机/堡垒机配置（内联）
                  _buildSectionTitle(l10n.hostEditSectionJumpHost),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: Text(l10n.hostEditUseJumpHost),
                    subtitle: Text(l10n.hostEditUseJumpHostSubtitle),
                    value: _jumpExpanded,
                    onChanged: (value) => setState(() => _jumpExpanded = value),
                  ),
                  if (_jumpExpanded) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _jumpHostController,
                      decoration: InputDecoration(
                        labelText: l10n.hostEditJumpHostLabel,
                        hintText: l10n.hostEditHostHint,
                        prefixIcon: const Icon(Icons.swap_horiz, size: 16),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _jumpPortController,
                            decoration: InputDecoration(labelText: l10n.hostEditJumpPortLabel),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: _jumpUsernameController,
                            decoration: InputDecoration(labelText: l10n.hostEditJumpUsernameLabel),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _jumpAuthType,
                      decoration: InputDecoration(labelText: l10n.hostEditJumpAuthTypeLabel),
                      items: [
                        DropdownMenuItem(value: 'password', child: Text(l10n.hostEditPassword)),
                        DropdownMenuItem(value: 'privateKey', child: Text(l10n.hostEditPrivateKey)),
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
                          labelText: l10n.hostEditJumpPasswordLabel,
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
                          labelText: l10n.hostEditJumpPrivateKeyContent,
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
                        color: cInfo.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cInfo.withValues(alpha: 0.15)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 12, color: cInfo),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              l10n.hostEditJumpHostFlowHint,
                              style: TextStyle(fontSize: fMicro, color: cInfo.withValues(alpha: 0.8)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // 权限提升 (sudo) — AI 执行 sudo 命令时自动注入此密码
                  _buildSectionTitle(l10n.hostEditSectionSudo),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _sudoPasswordController,
                    obscureText: _obscureSudoPassword,
                    decoration: InputDecoration(
                      labelText: l10n.hostEditSudoPasswordLabel,
                      hintText: l10n.hostEditSudoPasswordHint,
                      suffixIcon: IconButton(
                        icon: Icon(_obscureSudoPassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscureSudoPassword = !_obscureSudoPassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: cInfo.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(rSmall),
                      border: Border.all(color: cInfo.withValues(alpha: 0.15)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 12, color: cInfo),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l10n.hostEditSudoPasswordDesc,
                            style: TextStyle(fontSize: fMicro, color: cInfo.withValues(alpha: 0.8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  ExpansionTile(
                    title: Text(l10n.hostEditMoreSettings),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(pStandard),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.hostEditConnectionTimeout(_timeout)),
                            Slider(
                              value: _timeout.toDouble(),
                              min: 10,
                              max: 120,
                              divisions: 11,
                              label: l10n.hostEditTimeoutSeconds(_timeout),
                              onChanged: (value) => setState(() => _timeout = value.toInt()),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              initialValue: _encoding,
                              decoration: InputDecoration(labelText: l10n.hostEditEncodingLabel),
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
                color: tc.card,
                border: Border(top: BorderSide(color: tc.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => context.pop(),
                      child: Text(l10n.commonCancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _saveHost,
                      child: Text(l10n.hostEditSave),
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
      style: const TextStyle(
        fontSize: fBody,
        fontWeight: FontWeight.w600,
        color: cPrimary,
      ),
    );
  }

  /// 分组字段：下拉候选（来自现有分组）+ 自由输入（新建分组）
  Widget _buildGroupField() {
    final l10n = AppLocalizations.of(context)!;
    // 收集现有分组（去重，保留出现顺序）
    final hosts = ref.read(hostsProvider).valueOrNull ?? [];
    final existingGroups = <String>{};
    for (final h in hosts) {
      existingGroups.add(h.group);
    }
    final groupList = existingGroups.toList()..sort();
    if (!groupList.any((g) => g == '默认' || g == L10n.str.hostDefaultGroup)) {
      groupList.insert(0, L10n.str.hostDefaultGroup);
    }

    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: _groupController,
            decoration: InputDecoration(
              labelText: l10n.hostEditGroupLabel,
              hintText: l10n.hostEditGroupHint,
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          icon: const Icon(Icons.arrow_drop_down, size: 20),
          tooltip: l10n.hostEditSelectGroupTooltip,
          onSelected: (value) {
            setState(() => _groupController.text = value);
          },
          itemBuilder: (_) => groupList
              .map((g) => PopupMenuItem(value: g, child: Text(g)))
              .toList(),
        ),
      ],
    );
  }

  Future<void> _saveHost() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context)!;

    final hostId = _isEditing ? _existingHost!.id : _uuid.v4();
    final config = HostConfig.create(
      id: hostId,
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text) ?? 22,
      username: _usernameController.text.trim(),
      authType: _authType,
      group: _groupController.text.trim().isEmpty || _groupController.text.trim() == L10n.str.hostDefaultGroup
          ? '默认'
          : _groupController.text.trim(),
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
        credentialsError = l10n.hostEditPasswordSaveFailed;
      }
    } else if (_authType == 'privateKey' && _privateKeyController.text.isNotEmpty) {
      credentialsSaved = await CredentialsStore.save(
        hostId: hostId,
        type: 'privateKey',
        value: _privateKeyController.text,
      );
      if (!credentialsSaved) {
        credentialsError = l10n.hostEditPrivateKeySaveFailed;
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

    // 保存 sudo 密码（用于 AI 执行 sudo 命令时自动注入）
    // 非空则保存，为空则删除（关闭 sudo 自动注入）
    if (_sudoPasswordController.text.isNotEmpty) {
      await CredentialsStore.save(
        hostId: hostId,
        type: 'sudoPassword',
        value: _sudoPasswordController.text,
      );
    } else {
      await CredentialsStore.delete(hostId: hostId, type: 'sudoPassword');
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
            content: Text(l10n.hostEditConfigSavedButCredFailed(credentialsError)),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.hostEditSaveSuccess)),
        );
      }
      context.pop();
    }
  }
}
