import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../utils/audit_logger.dart';
import '../providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuditLogPage extends ConsumerStatefulWidget {
  final String? hostId;

  const AuditLogPage({super.key, this.hostId});

  @override
  ConsumerState<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends ConsumerState<AuditLogPage> {
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _filteredLogs = [];
  bool _showOnlyBlocked = false;
  String? _filterHostId;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filterHostId = widget.hostId;
    _loadLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadLogs() {
    if (_filterHostId != null) {
      _logs = AuditLogger.getLogsForHost(_filterHostId!, limit: 200);
    } else {
      _logs = AuditLogger.getRecentLogs(limit: 200);
    }

    _applyFilter();
  }

  void _applyFilter() {
    var result = _logs;
    if (_showOnlyBlocked) {
      result = result.where((log) => log['safetyLevel'] == 'blocked').toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((log) {
        final cmd = (log['command'] as String? ?? '').toLowerCase();
        final hostId = (log['hostId'] as String? ?? '').toLowerCase();
        final output = (log['output'] as String? ?? '').toLowerCase();
        return cmd.contains(q) || hostId.contains(q) || output.contains(q);
      }).toList();
    }
    _filteredLogs = result;
    setState(() {});
  }

  void _exportLogs() {
    final l10n = AppLocalizations.of(context)!;
    if (_filteredLogs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.auditLogNoRecordsToCopy), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final buffer = StringBuffer();
    buffer.writeln(l10n.auditLogExportHeader);
    buffer.writeln(l10n.auditLogExportTime(DateTime.now().toIso8601String()));
    buffer.writeln(l10n.auditLogExportTotal(_filteredLogs.length));
    buffer.writeln('---');
    for (final log in _filteredLogs) {
      buffer.writeln('[${log['timestamp']}] host=${log['hostId']} level=${log['safetyLevel']} executed=${log['executed']}');
      buffer.writeln('  cmd: ${log['command']}');
      if (log['output'] != null && (log['output'] as String).isNotEmpty) {
        buffer.writeln('  out: ${log['output']}');
      }
      buffer.writeln('');
    }
    final text = buffer.toString();
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.auditLogCopied(_filteredLogs.length)),
        backgroundColor: cSuccess,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Color _safetyColor(String level) {
    switch (level) {
      case 'safe':
        return cSuccess;
      case 'warning':
        return cWarning;
      case 'danger':
        return cDanger;
      case 'blocked':
        return cDanger;
      default:
        return ThemeColors.of(context).textSub;
    }
  }

  IconData _safetyIcon(String level) {
    switch (level) {
      case 'safe':
        return Icons.check_circle;
      case 'warning':
        return Icons.warning;
      case 'danger':
        return Icons.dangerous;
      case 'blocked':
        return Icons.block;
      default:
        return Icons.info;
    }
  }

  String _safetyLabel(String level) {
    final l10n = AppLocalizations.of(context)!;
    switch (level) {
      case 'safe':
        return l10n.auditLogSafetySafe;
      case 'warning':
        return l10n.auditLogSafetyWarning;
      case 'danger':
        return l10n.auditLogSafetyDanger;
      case 'blocked':
        return l10n.auditLogSafetyBlocked;
      default:
        return level;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_filterHostId != null ? l10n.auditLogTitle : l10n.auditLogAllTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.download, size: 20),
            tooltip: l10n.auditLogCopyTooltip,
            onPressed: _exportLogs,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list, size: 20),
            onSelected: (value) {
              switch (value) {
                case 'all':
                  _showOnlyBlocked = false;
                  _filterHostId = null;
                  break;
                case 'blocked':
                  _showOnlyBlocked = true;
                  break;
                case 'thisHost':
                  _filterHostId = widget.hostId;
                  _showOnlyBlocked = false;
                  break;
              }
              _loadLogs();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'all', child: Text(l10n.auditLogFilterAll)),
              PopupMenuItem(value: 'blocked', child: Text(l10n.auditLogFilterBlocked)),
              if (widget.hostId != null)
                PopupMenuItem(value: 'thisHost', child: Text(l10n.auditLogFilterThisHost)),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: pStandard, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: tc.textMain, fontSize: fBody),
              decoration: InputDecoration(
                hintText: l10n.auditLogSearchHint,
                hintStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                prefixIcon: Icon(Icons.search, size: 18, color: tc.textSub),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, size: 18, color: tc.textSub),
                        onPressed: () {
                          _searchController.clear();
                          _searchQuery = '';
                          _applyFilter();
                        },
                      )
                    : null,
                filled: true,
                fillColor: tc.card,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                isDense: true,
              ),
              onChanged: (value) {
                _searchQuery = value.trim();
                _applyFilter();
              },
            ),
          ),
          Expanded(
            child: _filteredLogs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.history, size: 48, color: tc.textMuted),
                        const SizedBox(height: 8),
                        Text(_searchQuery.isNotEmpty ? l10n.auditLogNoMatch : l10n.auditLogEmpty,
                            style: TextStyle(color: tc.textSub, fontSize: fBody)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(pStandard, 0, pStandard, pStandard),
                    itemCount: _filteredLogs.length,
                    itemBuilder: (context, index) {
                      final log = _filteredLogs[index];
                      return _buildLogCard(log);
                    },
                  ),
          ),
        ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogCard(Map<String, dynamic> log) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final safetyLevel = log['safetyLevel'] as String? ?? 'unknown';
    final executed = log['executed'] as bool? ?? false;
    final timestamp = log['timestamp'] as String? ?? '';
    final command = log['command'] as String? ?? '';
    final hostId = log['hostId'] as String? ?? '';
    final output = log['output'] as String?;

    // 获取主机名
    final host = ref.read(hostsProvider.notifier).getHostById(hostId);
    final hostName = host?.name ?? hostId;

    String formattedTime = '';
    try {
      final dt = DateTime.parse(timestamp);
      formattedTime = '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      formattedTime = timestamp;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(pCompact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：安全等级 + 时间 + 执行状态
            Row(
              children: [
                Icon(_safetyIcon(safetyLevel), size: 16, color: _safetyColor(safetyLevel)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: _safetyColor(safetyLevel).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(color: _safetyColor(safetyLevel).withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    _safetyLabel(safetyLevel),
                    style: TextStyle(
                      fontSize: fMicro,
                      color: _safetyColor(safetyLevel),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                Text(formattedTime, style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono')),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (executed ? cSuccess : cDanger).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Text(
                    executed ? l10n.auditLogExecuted : l10n.auditLogNotExecuted,
                    style: TextStyle(
                      fontSize: fMicro,
                      color: executed ? cSuccess : cDanger,
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
                command,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: tc.terminalGreen,
                ),
              ),
            ),
            // 主机名
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.dns_outlined, size: 10, color: tc.textMuted),
                const SizedBox(width: 4),
                Text(hostName, style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
              ],
            ),
            // 输出（如果有）
            if (output != null && output.isNotEmpty) ...[
              const SizedBox(height: 6),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                dense: true,
                title: Text(l10n.auditLogOutput, style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 120),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: tc.bg,
                      borderRadius: BorderRadius.circular(rXSmall),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        output,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: fMicro,
                          color: tc.textSub,
                        ),
                        maxLines: null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
