import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../services/ssh_config_import_service.dart';
import '../utils/ssh_config_parser.dart';

/// 从 `~/.ssh/config` 导入主机。
///
/// 只导入连接坐标（地址/端口/用户/跳板机），**不导入凭据**：
/// 私钥内容必须用户自己选文件、密码无法从配置里凭空得到，
/// 静默留空比误导用户「已导入」更安全，故在 UI 里写明。
class SshConfigImportDialog extends ConsumerStatefulWidget {
  const SshConfigImportDialog({super.key});

  @override
  ConsumerState<SshConfigImportDialog> createState() =>
      _SshConfigImportDialogState();
}

class _SshConfigImportDialogState extends ConsumerState<SshConfigImportDialog> {
  static const _uuid = Uuid();

  SshConfigImportSource? _source;
  SshConfigParseResult? _result;
  final Set<String> _selected = {};
  final Set<String> _existingAliases = {};
  bool _loading = true;
  bool _importing = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final source = await SshConfigImportService.load();
    if (!mounted) return;
    if (!source.isReadable) {
      setState(() {
        _source = source;
        _loading = false;
        _loadError = source.exists
            ? (source.readError ?? UiText.t('无法读取配置文件', 'Cannot read config'))
            : UiText.t('未找到配置文件', 'No config file found');
      });
      return;
    }
    final result = SshConfigImportService.parse(source.content!);
    final hosts = ref.read(hostsProvider).valueOrNull ?? const <HostConfig>[];
    final selected = <String>{};
    final existing = <String>{};
    for (final e in result.entries) {
      if (SshConfigImportService.isDuplicate(e, hosts)) {
        existing.add(e.alias);
      } else {
        selected.add(e.alias);
      }
    }
    setState(() {
      _source = source;
      _result = result;
      _selected.addAll(selected);
      _existingAliases.addAll(existing);
      _loading = false;
    });
  }

  Future<void> _import() async {
    final result = _result;
    if (result == null) return;
    final chosen =
        result.entries.where((e) => _selected.contains(e.alias)).toList();
    if (chosen.isEmpty) return;
    setState(() => _importing = true);
    final notifier = ref.read(hostsProvider.notifier);
    var ok = 0;
    for (final entry in chosen) {
      try {
        await notifier.addHost(buildHostConfig(
          entry: entry,
          id: _uuid.v4(),
          group: sshConfigImportGroup,
        ));
        ok++;
      } catch (e) {
        if (!mounted) return;
        setState(() => _importing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${UiText.t('导入失败', 'Import failed')}: ${entry.alias} — $e'),
        ));
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(UiText.t('已导入 $ok 台主机（凭据需在主机编辑页补填）',
          'Imported $ok host(s); add credentials in host edit')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final result = _result;
    final entries = result?.entries ?? const <SshConfigEntry>[];

    return AlertDialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rLarge),
      ),
      title: Text(
        UiText.t('导入 SSH 配置', 'Import SSH config'),
        style: const TextStyle(fontSize: fBody, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(pStandard),
                child: Center(child: CircularProgressIndicator()),
              )
            : _loadError != null
                ? _message(tc)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _source?.path ?? '',
                        style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        UiText.t(
                          '只导入地址、端口、用户名与跳板机；密码和私钥内容需导入后在主机编辑页补填。',
                          'Imports address, port, user and jump host only. '
                          'Passwords and private keys must be added after import.',
                        ),
                        style: TextStyle(color: tc.warn, fontSize: fMicro),
                      ),
                      const SizedBox(height: 8),
                      if (entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            UiText.t('配置里没有可导入的主机', 'No importable hosts'),
                            style: TextStyle(color: tc.textSub, fontSize: fSmall),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                for (final e in entries) _row(tc, e),
                              ],
                            ),
                          ),
                        ),
                      if ((result?.warnings ?? const <String>[]).isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          UiText.t('解析提示', 'Parse notes'),
                          style: TextStyle(
                              color: tc.textSub,
                              fontSize: fMicro,
                              fontWeight: FontWeight.w600),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 90),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final w in result!.warnings)
                                  Text('· $w',
                                      style: TextStyle(
                                          color: tc.textMuted,
                                          fontSize: fMicro)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(UiText.t('取消', 'Cancel')),
        ),
        FilledButton.icon(
          onPressed:
              _importing || _selected.isEmpty ? null : _import,
          icon: _importing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download, size: 16),
          label: Text('${UiText.t('导入', 'Import')} (${_selected.length})'),
        ),
      ],
    );
  }

  Widget _message(ThemeColors tc) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_loadError!,
                style: TextStyle(color: tc.error, fontSize: fSmall)),
            if (_source != null && _source!.path.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_source!.path,
                  style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
            ],
          ],
        ),
      );

  Widget _row(ThemeColors tc, SshConfigEntry e) {
    final isDuplicate = _existingAliases.contains(e.alias);
    final checked = _selected.contains(e.alias);
    void toggle() => setState(() =>
        checked ? _selected.remove(e.alias) : _selected.add(e.alias));
    return InkWell(
      onTap: isDuplicate ? null : toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: isDuplicate ? false : checked,
              onChanged: isDuplicate ? null : (_) => toggle(),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.alias}  →  ${e.username}@${e.host}:${e.port}',
                    style: TextStyle(
                      fontSize: fSmall,
                      color: isDuplicate ? tc.textMuted : tc.textMain,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (e.proxyJump != null || e.hasPrivateKey || e.ignoredKeys.isNotEmpty)
                    Text(
                      [
                        if (e.proxyJump != null)
                          '${UiText.t('跳板', 'jump')}: ${e.proxyJump}',
                        if (e.hasPrivateKey)
                          UiText.t('需补私钥', 'key needed'),
                        if (e.ignoredKeys.isNotEmpty)
                          '+${e.ignoredKeys.length} ${UiText.t('项未导入', 'ignored')}',
                      ].join(' · '),
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                ],
              ),
            ),
            if (isDuplicate)
              Text(UiText.t('已存在', 'exists'),
                  style: TextStyle(color: tc.warn, fontSize: fMicro)),
          ],
        ),
      ),
    );
  }
}
