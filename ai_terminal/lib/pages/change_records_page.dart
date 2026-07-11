import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/change_record.dart';
import '../providers/app_providers.dart';
import '../services/change_record_service.dart';
import '../providers/terminal_provider.dart' as tp;

/// 变更台账页面 — 展示修改性命令历史，支持回滚
class ChangeRecordsPage extends ConsumerStatefulWidget {
  final String? hostId;

  const ChangeRecordsPage({super.key, this.hostId});

  @override
  ConsumerState<ChangeRecordsPage> createState() => _ChangeRecordsPageState();
}

class _ChangeRecordsPageState extends ConsumerState<ChangeRecordsPage> {
  List<ChangeRecord> _records = [];
  String? _filterHostId;
  bool _showOnlyRollbackable = false;

  @override
  void initState() {
    super.initState();
    _filterHostId = widget.hostId;
    _loadRecords();
  }

  void _loadRecords() {
    if (_filterHostId != null) {
      _records = ChangeRecordService.getHistory(_filterHostId!, limit: 200);
    } else {
      _records = ChangeRecordService.getAllHistory(limit: 200);
    }
    if (_showOnlyRollbackable) {
      _records = _records.where((r) => r.rollbackCommand != null && !r.rolledBack).toList();
    }
    setState(() {});
  }

  Color _typeColor(ChangeType type) {
    final tc = ThemeColors.of(context);
    switch (type) {
      case ChangeType.install:
        return cKleinBlue;
      case ChangeType.uninstall:
        return cChineseRed;
      case ChangeType.startService:
        return cLimeGreen;
      case ChangeType.stopService:
        return cHermesOrange;
      case ChangeType.restartService:
        return cHermesOrange;
      case ChangeType.permission:
        return cViolet;
      case ChangeType.fileOperation:
        return cKleinBlueLight;
      case ChangeType.modifyConfig:
        return cViolet;
      case ChangeType.other:
        return tc.textSub;
    }
  }

  IconData _typeIcon(ChangeType type) {
    switch (type) {
      case ChangeType.install:
        return Icons.download;
      case ChangeType.uninstall:
        return Icons.delete_outline;
      case ChangeType.startService:
        return Icons.play_arrow;
      case ChangeType.stopService:
        return Icons.stop;
      case ChangeType.restartService:
        return Icons.refresh;
      case ChangeType.permission:
        return Icons.lock;
      case ChangeType.fileOperation:
        return Icons.file_copy_outlined;
      case ChangeType.modifyConfig:
        return Icons.settings;
      case ChangeType.other:
        return Icons.history;
    }
  }

  String _typeLabel(ChangeType type) {
    final l10n = AppLocalizations.of(context)!;
    switch (type) {
      case ChangeType.install:
        return l10n.changeRecordTypeInstall;
      case ChangeType.uninstall:
        return l10n.changeRecordTypeUninstall;
      case ChangeType.startService:
        return l10n.changeRecordTypeStartService;
      case ChangeType.stopService:
        return l10n.changeRecordTypeStopService;
      case ChangeType.restartService:
        return l10n.changeRecordTypeRestartService;
      case ChangeType.permission:
        return l10n.changeRecordTypePermission;
      case ChangeType.fileOperation:
        return l10n.changeRecordTypeFileOperation;
      case ChangeType.modifyConfig:
        return l10n.changeRecordTypeModifyConfig;
      case ChangeType.other:
        return l10n.changeRecordTypeOther;
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  void _confirmRollback(ChangeRecord record) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final host = ref.read(hostsProvider.notifier).getHostById(record.hostId);
    final hostName = host?.name ?? record.hostId;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text(l10n.changeRecordConfirmRollback, style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.changeRecordRollbackOnHost(hostName),
                style: TextStyle(color: tc.textSub, fontSize: fSmall)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tc.bg,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: SelectableText(
                record.rollbackCommand ?? '',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: tc.terminalGreen,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.changeRecordOriginalCommand(record.command),
                style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: cWarning,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _executeRollback(record);
            },
            child: Text(l10n.changeRecordConfirmRollback),
          ),
        ],
      ),
    );
  }

  Future<void> _executeRollback(ChangeRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    if (record.rollbackCommand == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.changeRecordNotRollbackable), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    // 查找该主机的 SSHService
    final tabs = ref.read(tp.terminalProvider).tabs;
    tp.TerminalTab? targetTab;
    for (final tab in tabs) {
      if (tab.hostId == record.hostId && tab.isConnected) {
        targetTab = tab;
        break;
      }
    }

    if (targetTab == null || targetTab.service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.changeRecordHostNotConnected(record.hostId)),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final executor = targetTab.service!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.changeRecordRollingBack(record.rollbackCommand!)),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      final result = await ChangeRecordService.executeRollback(
        record,
        executor,
        timeout: const Duration(seconds: 60),
      );
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.changeRecordRollbackFailedNoExec), backgroundColor: cDanger,
              behavior: SnackBarBehavior.floating),
        );
        return;
      }
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.changeRecordRollbackSuccess(record.rollbackCommand!)),
            backgroundColor: cSuccess,
            behavior: SnackBarBehavior.floating,
          ),
        );
        _loadRecords();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.changeRecordRollbackFailed(result.stderr)),
            backgroundColor: cDanger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.changeRecordRollbackError(e.toString())),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_filterHostId != null ? l10n.changeRecordTitle : l10n.changeRecordAllTitle),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list, size: 20),
            onSelected: (value) {
              switch (value) {
                case 'all':
                  _showOnlyRollbackable = false;
                  _filterHostId = null;
                  break;
                case 'rollbackable':
                  _showOnlyRollbackable = true;
                  break;
                case 'thisHost':
                  _filterHostId = widget.hostId;
                  _showOnlyRollbackable = false;
                  break;
              }
              _loadRecords();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'all', child: Text(l10n.changeRecordFilterAll)),
              PopupMenuItem(value: 'rollbackable', child: Text(l10n.changeRecordFilterRollbackable)),
              if (widget.hostId != null)
                PopupMenuItem(value: 'thisHost', child: Text(l10n.changeRecordFilterThisHost)),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: _records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history, size: 48, color: tc.textMuted),
                      const SizedBox(height: 8),
                      Text(l10n.changeRecordEmpty, style: TextStyle(color: tc.textSub, fontSize: fBody)),
                      const SizedBox(height: 4),
                      Text(l10n.changeRecordEmptyHint,
                          style: TextStyle(color: tc.textMuted, fontSize: fSmall)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(pStandard),
                  itemCount: _records.length,
                  itemBuilder: (context, index) => _buildRecordCard(_records[index]),
                ),
        ),
      ),
    );
  }

  Widget _buildRecordCard(ChangeRecord record) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final host = ref.read(hostsProvider.notifier).getHostById(record.hostId);
    final hostName = host?.name ?? record.hostId;
    final typeColor = _typeColor(record.type);

    return Card(
      color: tc.card,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: tc.border, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(pCompact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：类型 + 时间 + 状态
            Row(
              children: [
                Icon(_typeIcon(record.type), size: 14, color: typeColor),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: typeColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(color: typeColor.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    _typeLabel(record.type),
                    style: TextStyle(
                      fontSize: fMicro,
                      color: typeColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (record.rolledBack)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: tc.textSub.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Text(
                      l10n.changeRecordRolledBack,
                      style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w500),
                    ),
                  ),
                const Spacer(),
                Text(_formatTime(record.timestamp),
                    style: TextStyle(
                        fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono')),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (record.success ? cSuccess : cDanger).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Text(
                    record.success ? l10n.changeRecordSuccess : l10n.changeRecordFailed,
                    style: TextStyle(
                      fontSize: fMicro,
                      color: record.success ? cSuccess : cDanger,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 命令
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tc.bg,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: SelectableText(
                record.command,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: tc.terminalGreen,
                ),
              ),
            ),
            // 主机名 + 回滚按钮
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.dns_outlined, size: 10, color: tc.textMuted),
                const SizedBox(width: 4),
                Text(hostName, style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
                const Spacer(),
                if (record.rollbackCommand != null && !record.rolledBack && record.success)
                  TextButton.icon(
                    onPressed: () => _confirmRollback(record),
                    icon: const Icon(Icons.undo, size: 14),
                    label: Text(l10n.changeRecordRollbackButton, style: const TextStyle(fontSize: fMicro)),
                    style: TextButton.styleFrom(
                      foregroundColor: cWarning,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
