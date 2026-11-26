import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/security/known_hosts_service.dart';
import '../core/security/ssh_host_key_policy.dart';
import '../core/security/ssh_host_key_store.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/ssh_host_key.dart';

Future<void> showSshHostKeyManagerDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (_) => const SshHostKeyManagerDialog(),
    );

class SshHostKeyManagerDialog extends StatefulWidget {
  const SshHostKeyManagerDialog({super.key, this.store});

  final SshHostKeyStore? store;

  @override
  State<SshHostKeyManagerDialog> createState() =>
      _SshHostKeyManagerDialogState();
}

class _SshHostKeyManagerDialogState extends State<SshHostKeyManagerDialog> {
  late final SshHostKeyStore _store = widget.store ?? SshHostKeyStore();
  late final KnownHostsService _knownHosts = KnownHostsService(_store);
  final _routeController =
      TextEditingController(text: SshHostKeyPolicy.directRoute);
  final _contentController = TextEditingController();

  List<SshHostKey> _keys = [];
  KnownHostsPreview? _preview;
  final Set<String> _selectedImports = {};
  final Set<SshHostKey> _selectedExports = {};
  bool _loading = true;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _routeController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final keys = await _store.getAll();
      if (mounted) {
        setState(() {
          _keys = keys;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = '${UiText.t('读取失败', 'Load failed')}: $error';
        });
      }
    }
  }

  Future<void> _previewImport() async {
    try {
      final preview = await _knownHosts.preview(
        _contentController.text,
        routeKey: _routeController.text.trim(),
      );
      setState(() {
        _preview = preview;
        _selectedImports
          ..clear()
          ..addAll(preview.items
              .where((item) =>
                  item.action == KnownHostsAction.add ||
                  item.action == KnownHostsAction.revoke)
              .map((item) => item.entry.id));
        _message = '';
      });
    } catch (error) {
      setState(
          () => _message = '${UiText.t('预览失败', 'Preview failed')}: $error');
    }
  }

  Future<void> _import() async {
    try {
      final result = await _knownHosts.import(
        _contentController.text,
        routeKey: _routeController.text.trim(),
        acceptedIds: _selectedImports,
      );
      _contentController.clear();
      setState(() {
        _preview = null;
        _selectedImports.clear();
        _message = UiText.t(
          '导入完成：新增 ${result.added}，撤销 ${result.revoked}，跳过 ${result.skipped}',
          'Imported: ${result.added} added, ${result.revoked} revoked, ${result.skipped} skipped',
        );
      });
      await _load();
    } catch (error) {
      setState(() => _message = '${UiText.t('导入失败', 'Import failed')}: $error');
    }
  }

  Future<void> _revoke(SshHostKey key) async {
    final tc = ThemeColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        title: Text(UiText.t('撤销主机信任', 'Revoke host trust')),
        content: Text(
          UiText.t(
            '撤销后该地址和算法将直接拒绝连接，且不能通过确认弹窗重新授权。',
            'This address and key type will be rejected and cannot be reauthorized through the confirmation dialog.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(UiText.t('取消', 'Cancel'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: tc.warn),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(UiText.t('确认撤销', 'Revoke'))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _store.revoke(key);
      await _load();
    } catch (error) {
      setState(() => _message = '${UiText.t('撤销失败', 'Revoke failed')}: $error');
    }
  }

  void _export() {
    final selected = _keys.where(_selectedExports.contains).toList();
    if (selected.isEmpty) {
      setState(
          () => _message = UiText.t('请先选择要导出的主机', 'Select hosts to export'));
      return;
    }
    final result = _knownHosts.export(selected);
    setState(() {
      _message = result.skipped.isEmpty
          ? UiText.t('已生成 known_hosts，可复制或保存',
              'known_hosts generated; copy or save it')
          : '${UiText.t('已生成，跳过 ${result.skipped.length} 条', 'Generated; ${result.skipped.length} skipped')}\n${result.skipped.join('\n')}';
    });
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(UiText.t('导出 known_hosts', 'Export known_hosts')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: SelectableText(result.content)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: result.content));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(UiText.t('复制', 'Copy')),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(UiText.t('关闭', 'Close'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return AlertDialog(
      backgroundColor: tc.cardElevated,
      title: Text(UiText.t('SSH 主机信任', 'SSH host trust')),
      content: SizedBox(
        width: 720,
        height: (MediaQuery.sizeOf(context).height * 0.68).clamp(260.0, 620.0),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        UiText.t('导入 OpenSSH known_hosts',
                            'Import OpenSSH known_hosts'),
                        style: TextStyle(color: tc.textMain, fontSize: fBody)),
                    const SizedBox(height: 6),
                    Text(
                      UiText.t(
                        '只导入你主动粘贴的内容，不自动读取 .ssh。冲突记录不会被覆盖。',
                        'Only explicitly pasted content is imported; .ssh is never read automatically. Conflicts are not overwritten.',
                      ),
                      style: TextStyle(color: tc.textSub, fontSize: fMicro),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _routeController,
                      decoration: InputDecoration(
                        labelText: UiText.t('路由（direct 或 jump[...]）',
                            'Route (direct or jump[...])'),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _contentController,
                      minLines: 4,
                      maxLines: 6,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: fMicro),
                      decoration: InputDecoration(
                        hintText:
                            'host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                            onPressed: _previewImport,
                            child: Text(UiText.t('预览', 'Preview'))),
                        FilledButton(
                            onPressed:
                                _preview == null || _selectedImports.isEmpty
                                    ? null
                                    : _import,
                            child: Text(UiText.t('导入所选', 'Import selected'))),
                      ],
                    ),
                    if (_preview != null) ...[
                      const SizedBox(height: 8),
                      ..._preview!.items.map((item) => CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _selectedImports.contains(item.entry.id),
                            onChanged: item.action == KnownHostsAction.add ||
                                    item.action == KnownHostsAction.revoke
                                ? (selected) => setState(() {
                                      if (selected == true) {
                                        _selectedImports.add(item.entry.id);
                                      } else {
                                        _selectedImports.remove(item.entry.id);
                                      }
                                    })
                                : null,
                            title: Text(
                              '${item.entry.alias} · ${item.entry.keyType} · ${_actionLabel(item.action)}',
                              style: TextStyle(
                                  color:
                                      item.action == KnownHostsAction.conflict
                                          ? tc.warn
                                          : tc.textMain,
                                  fontSize: fMicro),
                            ),
                            subtitle: Text(item.entry.fingerprintSha256,
                                style: TextStyle(
                                    color: tc.textSub, fontSize: fMicro)),
                          )),
                      ..._preview!.issues.map((issue) => Text(
                            '${UiText.t('第 ${issue.line} 行', 'Line ${issue.line}')}: ${issue.message}',
                            style: TextStyle(color: tc.warn, fontSize: fMicro),
                          )),
                    ],
                    const Divider(height: 28),
                    Text(UiText.t('已保存的信任', 'Saved trust'),
                        style: TextStyle(color: tc.textMain, fontSize: fBody)),
                    const SizedBox(height: 4),
                    OutlinedButton(
                        onPressed: _export,
                        child: Text(UiText.t('导出所选', 'Export selected'))),
                    const SizedBox(height: 4),
                    if (_keys.isEmpty)
                      Text(UiText.t('暂无记录', 'No records'),
                          style: TextStyle(color: tc.textSub, fontSize: fMicro))
                    else
                      ..._keys.map((key) => CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _selectedExports.contains(key),
                            onChanged: (selected) => setState(() {
                              if (selected == true) {
                                _selectedExports.add(key);
                              } else {
                                _selectedExports.remove(key);
                              }
                            }),
                            title: Text(
                              '${key.alias} · ${key.keyType} · ${key.routeKey}',
                              style: TextStyle(
                                  color: key.status == SshHostKeyStatus.revoked
                                      ? tc.warn
                                      : tc.textMain,
                                  fontSize: fMicro),
                            ),
                            subtitle: Text(
                              '${key.fingerprintSha256}\n${key.status == SshHostKeyStatus.revoked ? UiText.t('已撤销', 'Revoked') : UiText.t('已信任', 'Trusted')}',
                              style: TextStyle(
                                  color: tc.textSub, fontSize: fMicro),
                            ),
                            secondary: key.status == SshHostKeyStatus.trusted
                                ? IconButton(
                                    tooltip: UiText.t('撤销', 'Revoke'),
                                    icon: const Icon(Icons.block, size: 18),
                                    onPressed: () => _revoke(key),
                                  )
                                : null,
                          )),
                    if (_message.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      SelectableText(_message,
                          style: TextStyle(color: tc.warn, fontSize: fMicro)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(UiText.t('关闭', 'Close'))),
      ],
    );
  }

  String _actionLabel(KnownHostsAction action) => switch (action) {
        KnownHostsAction.add => UiText.t('新增', 'Add'),
        KnownHostsAction.revoke => UiText.t('撤销', 'Revoke'),
        KnownHostsAction.unchanged => UiText.t('已存在', 'Existing'),
        KnownHostsAction.conflict => UiText.t('冲突，跳过', 'Conflict, skipped'),
      };
}
