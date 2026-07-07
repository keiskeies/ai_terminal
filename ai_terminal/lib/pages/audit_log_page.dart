import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
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
    if (_filteredLogs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可导出的日志'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final buffer = StringBuffer();
    buffer.writeln('# 审计日志导出');
    buffer.writeln('# 导出时间: ${DateTime.now().toIso8601String()}');
    buffer.writeln('# 总条数: ${_filteredLogs.length}');
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
        content: Text('已复制 ${_filteredLogs.length} 条日志到剪贴板'),
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
        return cTextSub;
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
    switch (level) {
      case 'safe':
        return '安全';
      case 'warning':
        return '警告';
      case 'danger':
        return '危险';
      case 'blocked':
        return '已阻止';
      default:
        return level;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_filterHostId != null ? '审计日志' : '全部审计日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download, size: 20),
            tooltip: '导出日志',
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
              const PopupMenuItem(value: 'all', child: Text('全部日志')),
              const PopupMenuItem(value: 'blocked', child: Text('仅已阻止')),
              if (widget.hostId != null)
                const PopupMenuItem(value: 'thisHost', child: Text('仅当前主机')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: pStandard, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: tc.textMain, fontSize: fBody),
              decoration: InputDecoration(
                hintText: '搜索命令、主机ID、输出...',
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
                  borderSide: BorderSide(color: cPrimary),
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
                        Text(_searchQuery.isNotEmpty ? '未匹配到日志' : '暂无审计日志',
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
    );
  }

  Widget _buildLogCard(Map<String, dynamic> log) {
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
                Text(formattedTime, style: const TextStyle(fontSize: fMicro, color: cTextMuted, fontFamily: 'JetBrainsMono')),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (executed ? cSuccess : cDanger).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Text(
                    executed ? '已执行' : '未执行',
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
                color: ThemeColors.of(context).bg,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: SelectableText(
                command,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: ThemeColors.of(context).terminalGreen,
                ),
              ),
            ),
            // 主机名
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.dns_outlined, size: 10, color: cTextMuted),
                const SizedBox(width: 4),
                Text(hostName, style: const TextStyle(fontSize: fMicro, color: cTextMuted)),
              ],
            ),
            // 输出（如果有）
            if (output != null && output.isNotEmpty) ...[
              const SizedBox(height: 6),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('输出', style: TextStyle(fontSize: fMicro, color: cTextMuted)),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 120),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: ThemeColors.of(context).bg,
                      borderRadius: BorderRadius.circular(rXSmall),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        output,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: fMicro,
                          color: cTextSub,
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
