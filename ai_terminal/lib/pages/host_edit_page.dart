import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/credentials_store.dart';
import '../core/ui_text.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../widgets/color_picker_row.dart';
import '../widgets/settings_row_card.dart';
import '../l10n/app_localizations.dart';
import '../core/l10n_holder.dart';
import '../core/app_toast.dart';

const _uuid = Uuid();

class HostEditPage extends ConsumerStatefulWidget {
  final String? hostId;

  /// 内嵌模式：不套 Scaffold / AppBar，由外层（抽屉子视图）提供返回与标题。
  ///
  /// 主机表单字段多（凭据、跳板机、sudo、编码），**只保留这一份实现** ——
  /// 抽屉和整页路由渲染的都是它，不会出现两处各改一半。
  final bool embedded;
  final VoidCallback? onSaved;
  final VoidCallback? onCancel;

  const HostEditPage({
    super.key,
    this.hostId,
    this.embedded = false,
    this.onSaved,
    this.onCancel,
  });

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
  bool _obscureJumpPassword = true;
  bool _obscureJumpPrivateKey = true;
  bool _obscureSudoPassword = true;
  bool _jumpExpanded = false; // 跳板机区域展开状态（展开 = 启用）
  bool _sudoExpanded = false;
  bool _moreExpanded = false;
  bool _keyFromPaste = true; // 私钥录入方式：粘贴内容 / 从文件选择
  String? _keyFileName;

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
      _groupController.text =
          host.group == '默认' ? L10n.str.hostDefaultGroup : host.group;
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
        final password =
            await CredentialsStore.get(hostId: host.id, type: 'password');
        _passwordController.text = password ?? '';
      } else {
        final privateKey =
            await CredentialsStore.get(hostId: host.id, type: 'privateKey');
        _privateKeyController.text = privateKey ?? '';
      }

      // 加载跳板机凭据
      if (host.hasJumpHost) {
        final jumpPassword = await CredentialsStore.get(
            hostId: '${host.id}_jump', type: 'password');
        _jumpPasswordController.text = jumpPassword ?? '';
        final jumpPrivateKey = await CredentialsStore.get(
            hostId: '${host.id}_jump', type: 'privateKey');
        _jumpPrivateKeyController.text = jumpPrivateKey ?? '';
      }

      // 加载 sudo 密码（用于 AI 执行 sudo 命令时自动注入）
      final sudoPassword =
          await CredentialsStore.get(hostId: host.id, type: 'sudoPassword');
      _sudoPasswordController.text = sudoPassword ?? '';
      _sudoExpanded = (sudoPassword ?? '').isNotEmpty;

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
      backgroundColor: widget.embedded ? Colors.transparent : null,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(
                  _isEditing ? l10n.hostEditTitleEdit : l10n.hostEditTitleNew),
            ),
      body: _EmbeddedDensity(
        enabled: widget.embedded,
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: widget.embedded
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(
                          horizontal: pStandard, vertical: pLarge),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _buildSections(tc, l10n),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 底部操作栏：发丝线分隔，按钮与内容同宽
              Container(
                padding: EdgeInsets.fromLTRB(widget.embedded ? 0 : pStandard, 8,
                    widget.embedded ? 0 : pStandard, widget.embedded ? 8 : 12),
                decoration: BoxDecoration(
                  color: widget.embedded ? null : tc.card,
                  border: Border(top: BorderSide(color: tc.hairline)),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: widget.onCancel ?? () => context.pop(),
                            child: Text(l10n.commonCancel),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _saveHost,
                            icon: const Icon(Icons.check_rounded, size: 16),
                            label: Text(l10n.save),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSections(ThemeColors tc, AppLocalizations l10n) {
    return [
      // ── 基本信息 ──
      SettingsSectionLabel(l10n.hostEditSectionBasic),
      _formCard(tc, [
        _FieldLabel(l10n.hostEditNameLabel),
        TextFormField(
          controller: _nameController,
          decoration: InputDecoration(hintText: l10n.hostEditNameHint),
          maxLength: 20,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return l10n.hostEditNameRequired;
            }
            return null;
          },
        ),
        const SizedBox(height: 10),
        _FieldLabel(l10n.hostEditHostLabel),
        TextFormField(
          controller: _hostController,
          decoration: InputDecoration(hintText: l10n.hostEditHostHint),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return l10n.hostEditHostRequired;
            }
            return null;
          },
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FieldLabel(l10n.port),
                  TextFormField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FieldLabel(l10n.hostEditUsernameLabel),
                  TextFormField(controller: _usernameController),
                ],
              ),
            ),
          ],
        ),
      ]),
      const SizedBox(height: 20),

      // ── 认证方式 ──
      SettingsSectionLabel(l10n.hostEditSectionAuth),
      _formCard(tc, [
        _FieldLabel(l10n.hostEditAuthTypeLabel),
        _ChoiceChips(
          options: [
            _ChipOption(
                'password', l10n.hostEditPassword, Icons.lock_outline_rounded),
            _ChipOption(
                'privateKey', l10n.hostEditPrivateKey, Icons.key_rounded),
          ],
          value: _authType,
          onChanged: (v) => setState(() => _authType = v),
        ),
        const SizedBox(height: 12),
        if (_authType == 'password') ...[
          _FieldLabel(l10n.hostEditPassword),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              suffixIcon: _eyeSuffix(_obscurePassword,
                  () => setState(() => _obscurePassword = !_obscurePassword)),
            ),
          ),
        ],
        if (_authType == 'privateKey') ...[
          _ChoiceChips(
            options: [
              _ChipOption('paste', UiText.t('粘贴内容', 'Paste key'),
                  Icons.content_paste_rounded),
              _ChipOption('file', UiText.t('从文件选择', 'From file'),
                  Icons.file_open_outlined),
            ],
            value: _keyFromPaste ? 'paste' : 'file',
            onChanged: (v) => setState(() => _keyFromPaste = v == 'paste'),
          ),
          const SizedBox(height: 10),
          if (_keyFromPaste)
            TextFormField(
              controller: _privateKeyController,
              maxLines: 6,
              minLines: 4,
              style: const TextStyle(fontSize: fSmall, height: 1.5),
              decoration: const InputDecoration(
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
              ),
            )
          else
            _buildKeyFileRow(tc, l10n),
          const SizedBox(height: 12),
          _FieldLabel(l10n.hostEditPassphraseLabel),
          TextFormField(
            controller: _passphraseController,
            obscureText: _obscurePassphrase,
            decoration: InputDecoration(
              suffixIcon: _eyeSuffix(
                  _obscurePassphrase,
                  () =>
                      setState(() => _obscurePassphrase = !_obscurePassphrase)),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 20),

      // ── 分组与标签 ──
      SettingsSectionLabel(l10n.hostEditSectionGroupTag),
      _formCard(tc, [
        _FieldLabel(l10n.hostEditGroupLabel),
        _buildGroupField(tc, l10n),
        const SizedBox(height: 12),
        _FieldLabel(l10n.hostEditTagColor),
        ColorPickerRow(
          selectedColor: _tagColor,
          onColorSelected: (color) => setState(() => _tagColor = color),
        ),
      ]),
      const SizedBox(height: 20),

      // ── 高级设置：rowcard，副标题即当前状态读数 ──
      SettingsSectionLabel(l10n.commonAdvancedSettings),
      SettingsRowCard(
        title: l10n.hostEditSectionJumpHost,
        subtitle: _jumpExpanded
            ? (_jumpHostController.text.trim().isEmpty
                ? UiText.t('已启用 · 待填写地址', 'Enabled · address pending')
                : '${_jumpUsernameController.text.trim()}@${_jumpHostController.text.trim()}')
            : l10n.hostEditUseJumpHostSubtitle,
        expanded: _jumpExpanded,
        onToggle: () => setState(() => _jumpExpanded = !_jumpExpanded),
        dense: widget.embedded,
        detail: _buildJumpDetail(tc, l10n),
      ),
      const SizedBox(height: kSettingsRowGap),
      SettingsRowCard(
        title: l10n.hostEditSectionSudo,
        subtitle: _sudoPasswordController.text.isNotEmpty
            ? UiText.t('已配置 · AI 自动注入', 'Configured · auto-injected')
            : l10n.hostEditSudoPasswordHint,
        expanded: _sudoExpanded,
        onToggle: () => setState(() => _sudoExpanded = !_sudoExpanded),
        dense: widget.embedded,
        detail: [
          _FieldLabel(l10n.hostEditSudoPasswordLabel),
          TextFormField(
            controller: _sudoPasswordController,
            obscureText: _obscureSudoPassword,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l10n.hostEditSudoPasswordHint,
              suffixIcon: _eyeSuffix(
                  _obscureSudoPassword,
                  () => setState(
                      () => _obscureSudoPassword = !_obscureSudoPassword)),
            ),
          ),
          const SizedBox(height: 10),
          _HintBox(l10n.hostEditSudoPasswordDesc),
        ],
      ),
      const SizedBox(height: kSettingsRowGap),
      SettingsRowCard(
        title: l10n.hostEditMoreSettings,
        subtitle:
            '${l10n.hostEditTimeoutSeconds(_timeout)} · ${_encoding.toUpperCase()}',
        expanded: _moreExpanded,
        onToggle: () => setState(() => _moreExpanded = !_moreExpanded),
        dense: widget.embedded,
        detail: [
          Row(
            children: [
              Expanded(
                child: Text(
                  UiText.t('连接超时', 'Connection timeout'),
                  style: TextStyle(fontSize: fSmall, color: tc.textBody),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: tc.goldBg,
                  borderRadius: BorderRadius.circular(rFull),
                ),
                child: Text(
                  '${_timeout}s',
                  style: TextStyle(
                      fontSize: fMicro,
                      fontWeight: FontWeight.w500,
                      color: tc.gold),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: tc.brand,
              inactiveTrackColor: tc.surface,
              thumbColor: tc.brand,
              overlayColor: tc.brandBg,
              valueIndicatorColor: tc.cardElevated,
              valueIndicatorTextStyle:
                  TextStyle(color: tc.textMain, fontSize: fMicro),
            ),
            child: Slider(
              value: _timeout.toDouble(),
              min: 10,
              max: 120,
              divisions: 11,
              label: l10n.hostEditTimeoutSeconds(_timeout),
              onChanged: (value) => setState(() => _timeout = value.toInt()),
            ),
          ),
          const SizedBox(height: 10),
          _FieldLabel(l10n.hostEditEncodingLabel),
          _ChoiceChips(
            options: const [
              _ChipOption('utf-8', 'UTF-8'),
              _ChipOption('gbk', 'GBK'),
              _ChipOption('big5', 'BIG5'),
            ],
            value: _encoding,
            onChanged: (v) => setState(() => _encoding = v),
          ),
        ],
      ),
      const SizedBox(height: 24),
    ];
  }

  /// 设计稿 `.rowcard` 的表单变体：1px 边框 + 10 圆角 + card 底，字段坐落其中。
  Widget _formCard(ThemeColors tc, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rMedium),
        border: Border.all(color: tc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _eyeSuffix(bool obscure, VoidCallback onToggle) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(
        obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        size: 16,
      ),
      onPressed: onToggle,
    );
  }

  Widget _buildKeyFileRow(ThemeColors tc, AppLocalizations l10n) {
    final hasKey = _privateKeyController.text.isNotEmpty;
    final label = _keyFileName ??
        (hasKey
            ? UiText.t('已载入保存的私钥', 'Saved key loaded')
            : l10n.hostEditSelectPrivateKeyFile);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.surface,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      child: Row(
        children: [
          Icon(
            hasKey ? Icons.verified_outlined : Icons.description_outlined,
            size: 15,
            color: hasKey ? tc.ok : tc.gold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fSmall, color: tc.textSub),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 30,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 30),
              ),
              onPressed: () => _pickKeyFile(l10n),
              child: Text(l10n.hostEditSelect,
                  style: const TextStyle(fontSize: fSmall)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickKeyFile(AppLocalizations l10n) async {
    final tc = ThemeColors.of(context);
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
          _keyFileName = result.files.single.name;
        });
        if (mounted) {
          showTopSnackBar(
            context,
            SnackBar(
              content: Text(
                  l10n.hostEditPrivateKeyFileRead(result.files.single.name)),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          SnackBar(
            content: Text(l10n.hostEditReadFileFailed(e.toString())),
            backgroundColor: tc.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// 分组字段：自由输入 + 输入框内下拉候选（来自现有分组）
  Widget _buildGroupField(ThemeColors tc, AppLocalizations l10n) {
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

    return TextFormField(
      controller: _groupController,
      decoration: InputDecoration(
        hintText: l10n.hostEditGroupHint,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 32),
        suffixIcon: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          icon: Icon(Icons.expand_more_rounded, size: 16, color: tc.textSub),
          tooltip: l10n.hostEditSelectGroupTooltip,
          onSelected: (value) {
            setState(() => _groupController.text = value);
          },
          itemBuilder: (_) => groupList
              .map((g) => PopupMenuItem(value: g, child: Text(g)))
              .toList(),
        ),
      ),
    );
  }

  List<Widget> _buildJumpDetail(ThemeColors tc, AppLocalizations l10n) {
    return [
      _FieldLabel(l10n.hostEditJumpHostLabel),
      TextFormField(
        controller: _jumpHostController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(hintText: l10n.hostEditHostHint),
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FieldLabel(l10n.hostEditJumpPortLabel),
                TextFormField(
                  controller: _jumpPortController,
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FieldLabel(l10n.hostEditJumpUsernameLabel),
                TextFormField(controller: _jumpUsernameController),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _FieldLabel(l10n.hostEditJumpAuthTypeLabel),
      _ChoiceChips(
        options: [
          _ChipOption(
              'password', l10n.hostEditPassword, Icons.lock_outline_rounded),
          _ChipOption('privateKey', l10n.hostEditPrivateKey, Icons.key_rounded),
        ],
        value: _jumpAuthType ?? 'password',
        onChanged: (v) => setState(() => _jumpAuthType = v),
      ),
      const SizedBox(height: 10),
      if (_jumpAuthType == 'password')
        TextFormField(
          controller: _jumpPasswordController,
          obscureText: _obscureJumpPassword,
          decoration: InputDecoration(
            hintText: l10n.hostEditJumpPasswordLabel,
            suffixIcon: _eyeSuffix(
                _obscureJumpPassword,
                () => setState(
                    () => _obscureJumpPassword = !_obscureJumpPassword)),
          ),
        ),
      if (_jumpAuthType == 'privateKey')
        TextFormField(
          controller: _jumpPrivateKeyController,
          obscureText: _obscureJumpPrivateKey,
          maxLines: 4,
          style: const TextStyle(fontSize: fSmall, height: 1.5),
          decoration: InputDecoration(
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
            suffixIcon: _eyeSuffix(
                _obscureJumpPrivateKey,
                () => setState(
                    () => _obscureJumpPrivateKey = !_obscureJumpPrivateKey)),
          ),
        ),
      const SizedBox(height: 10),
      _HintBox(l10n.hostEditJumpHostFlowHint),
    ];
  }

  Future<void> _saveHost() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);

    final hostId = _isEditing ? _existingHost!.id : _uuid.v4();
    final config = HostConfig.create(
      id: hostId,
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text) ?? 22,
      username: _usernameController.text.trim(),
      authType: _authType,
      group: _groupController.text.trim().isEmpty ||
              _groupController.text.trim() == L10n.str.hostDefaultGroup
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
    } else if (_authType == 'privateKey' &&
        _privateKeyController.text.isNotEmpty) {
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
    if (_isEditing &&
        _authType == 'password' &&
        _passwordController.text.isEmpty &&
        _existingHost?.isPasswordAuth == true) {
      // 用户清空了密码，保持原来的密码不变
    } else if (_isEditing &&
        _authType == 'privateKey' &&
        _privateKeyController.text.isEmpty &&
        _existingHost?.isKeyAuth == true) {
      // 用户清空了私钥，保持原来的私钥不变
    }

    // 保存跳板机凭据
    if (_jumpExpanded) {
      final jumpCredKey = '${hostId}_jump';
      if (_jumpAuthType == 'password' &&
          _jumpPasswordController.text.isNotEmpty) {
        await CredentialsStore.save(
          hostId: jumpCredKey,
          type: 'password',
          value: _jumpPasswordController.text,
        );
      } else if (_jumpAuthType == 'privateKey' &&
          _jumpPrivateKeyController.text.isNotEmpty) {
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
        showTopSnackBar(
          context,
          SnackBar(
            content:
                Text(l10n.hostEditConfigSavedButCredFailed(credentialsError)),
            backgroundColor: tc.warn,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        showTopSnackBar(
          context,
          SnackBar(content: Text(l10n.hostEditSaveSuccess)),
        );
      }
      if (widget.embedded) {
        widget.onSaved?.call();
      } else {
        context.pop();
      }
    }
  }
}

/// 字段小标签：11px / w500 / textSub。必填星号已含在 l10n 文案里。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fMicro,
          fontWeight: FontWeight.w500,
          color: tc.textSub,
        ),
      ),
    );
  }
}

class _ChipOption {
  const _ChipOption(this.value, this.label, [this.icon]);

  final String value;
  final String label;
  final IconData? icon;
}

/// 设计稿 `.theme-chips` 的分段选择：选中 = 品牌青描边 + 10% 青底 + 青字。
class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<_ChipOption> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          _ChoiceChip(
            option: o,
            selected: o.value == value,
            onTap: () => onChanged(o.value),
            tc: tc,
          ),
      ],
    );
  }
}

class _ChoiceChip extends StatefulWidget {
  const _ChoiceChip({
    required this.option,
    required this.selected,
    required this.onTap,
    required this.tc,
  });

  final _ChipOption option;
  final bool selected;
  final VoidCallback onTap;
  final ThemeColors tc;

  @override
  State<_ChoiceChip> createState() => _ChoiceChipState();
}

class _ChoiceChipState extends State<_ChoiceChip> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final selected = widget.selected;
    final fg = selected ? tc.brand : (_hovering ? tc.textMain : tc.textBody);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: animFast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? tc.brandBg : tc.surface,
            borderRadius: BorderRadius.circular(rFull),
            border: Border.all(
              color: selected
                  ? tc.brand
                  : (_hovering ? tc.borderHover : tc.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.option.icon != null) ...[
                Icon(widget.option.icon, size: 13, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                widget.option.label,
                style: TextStyle(
                  fontSize: fSmall,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 提示盒：品牌青 10% 底 + 淡青描边，信息不再用旧蓝色系。
class _HintBox extends StatelessWidget {
  const _HintBox(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.brandBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.brand.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 13, color: tc.brand),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: fMicro,
                height: 1.5,
                color: tc.textSub,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 抽屉内嵌时统一输入框密度：Material 默认 16px 的字段在 600 宽的抽屉里显得
/// 又高又肿，和旁边 11–13px 的标签对不上。整页模式不受影响。
class _EmbeddedDensity extends StatelessWidget {
  const _EmbeddedDensity({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final tc = ThemeColors.of(context);
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: tc.surface,
          labelStyle: TextStyle(fontSize: fSmall, color: tc.textSub),
          hintStyle: TextStyle(fontSize: fSmall, color: tc.textMuted),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
            borderSide: BorderSide(color: tc.brand, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: tc.error),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: tc.error, width: 1.5),
          ),
        ),
        textTheme: base.textTheme.apply(fontSizeFactor: 0.86),
        snackBarTheme: base.snackBarTheme,
      ),
      child: child,
    );
  }
}
