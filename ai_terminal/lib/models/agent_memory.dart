/// Agent 记忆条目（纯内存，不持久化）
class MemoryEntry {
  final String id;
  final String type;
  final String content;
  final String? metadata;
  final DateTime timestamp;

  MemoryEntry({
    required this.id,
    required this.type,
    required this.content,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic>? get metadataMap {
    if (metadata == null) return null;
    return _parseSimpleJson(metadata!);
  }

  static MemoryEntry command(String command, {String? description, String? result}) {
    return MemoryEntry(
      id: 'cmd_${DateTime.now().millisecondsSinceEpoch}',
      type: 'command',
      content: command,
      metadata: '{"description":"$description","result":"$result"}',
    );
  }

  static MemoryEntry systemInfo(String info, {String? category}) {
    return MemoryEntry(
      id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
      type: 'system_info',
      content: info,
      metadata: '{"category":"$category"}',
    );
  }

  static MemoryEntry result(String command, String output, {bool success = true}) {
    return MemoryEntry(
      id: 'res_${DateTime.now().millisecondsSinceEpoch}',
      type: 'result',
      content: '$command\n$output',
      metadata: '{"success":$success}',
    );
  }

  static MemoryEntry context(String context) {
    return MemoryEntry(
      id: 'ctx_${DateTime.now().millisecondsSinceEpoch}',
      type: 'context',
      content: context,
    );
  }
}

Map<String, dynamic>? _parseSimpleJson(String s) {
  s = s.trim();
  if (!s.startsWith('{') || !s.endsWith('}')) return null;
  final inner = s.substring(1, s.length - 1);
  final map = <String, dynamic>{};
  if (inner.isNotEmpty) {
    for (final pair in inner.split(',')) {
      final idx = pair.indexOf(':');
      if (idx > 0) {
        final key = pair.substring(0, idx).trim();
        var val = pair.substring(idx + 1).trim();
        if (val.startsWith('"') && val.endsWith('"')) {
          val = val.substring(1, val.length - 1);
        } else if (val == 'true') {
          map[key] = true;
          continue;
        } else if (val == 'false') {
          map[key] = false;
          continue;
        }
        map[key] = val;
      }
    }
  }
  return map;
}

/// Agent 记忆系统（纯内存，每个连接/Tab 独立实例）
class AgentMemory {
  static const int _maxEntries = 50;
  static const int _systemInfoMax = 10;

  final List<MemoryEntry> _entries = [];

  void add(MemoryEntry entry) {
    _entries.add(entry);
    _trim();
  }

  void rememberCommand(String command, {String? description}) {
    add(MemoryEntry.command(command, description: description));
  }

  void rememberResult(String command, String output, {bool success = true}) {
    add(MemoryEntry.result(command, output, success: success));
  }

  void rememberSystemInfo(String info, {String? category}) {
    add(MemoryEntry.systemInfo(info, category: category));
  }

  List<MemoryEntry> getRecent({int limit = 20}) {
    final sorted = List<MemoryEntry>.from(_entries)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.take(limit).toList();
  }

  List<MemoryEntry> getRecentCommands({int limit = 10}) {
    return getRecent(limit: limit)
        .where((e) => e.type == 'command' || e.type == 'result')
        .toList();
  }

  String getSystemSummary() {
    final systemInfos = _entries
        .where((e) => e.type == 'system_info')
        .toList()
        .reversed
        .take(_systemInfoMax);
    return systemInfos.map((e) => e.content).join('\n');
  }

  String buildContext() {
    final recent = getRecent(limit: 10);
    if (recent.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('【Agent 记忆】');

    final systemInfos = recent.where((e) => e.type == 'system_info');
    if (systemInfos.isNotEmpty) {
      buffer.writeln('系统环境:');
      for (final info in systemInfos.take(3)) {
        buffer.writeln('  - ${info.content}');
      }
    }

    final commands = recent.where((e) => e.type == 'command').take(3);
    if (commands.isNotEmpty) {
      buffer.writeln('最近命令:');
      for (final cmd in commands) {
        buffer.writeln('  - ${cmd.content}');
      }
    }

    return buffer.toString();
  }

  void _trim() {
    _entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
  }

  void clear() {
    _entries.clear();
  }

  Map<String, int> get stats {
    return {
      'total': _entries.length,
      'commands': _entries.where((e) => e.type == 'command').length,
      'results': _entries.where((e) => e.type == 'result').length,
      'system_info': _entries.where((e) => e.type == 'system_info').length,
      'context': _entries.where((e) => e.type == 'context').length,
    };
  }
}
