import 'dart:convert';
import 'package:hive/hive.dart';
import '../core/hive_init.dart';

part 'agent_memory.g.dart';

/// Agent 记忆条目
@HiveType(typeId: 10)
class MemoryEntry {
  @HiveField(0) final String id;
  @HiveField(1) final String type;
  @HiveField(2) final String content;
  @HiveField(3) final String? metadata;
  @HiveField(4) final DateTime timestamp;

  MemoryEntry({
    required this.id,
    required this.type,
    required this.content,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic>? get metadataMap {
    if (metadata == null) return null;
    try {
      return jsonDecode(metadata!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static MemoryEntry command(String command, {String? description, String? result}) {
    return MemoryEntry(
      id: 'cmd_${DateTime.now().millisecondsSinceEpoch}',
      type: 'command',
      content: command,
      metadata: jsonEncode({
        'description': description,
        'result': result,
      }),
    );
  }

  static MemoryEntry systemInfo(String info, {String? category}) {
    return MemoryEntry(
      id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
      type: 'system_info',
      content: info,
      metadata: jsonEncode({'category': category}),
    );
  }

  static MemoryEntry result(String command, String output, {bool success = true}) {
    return MemoryEntry(
      id: 'res_${DateTime.now().millisecondsSinceEpoch}',
      type: 'result',
      content: '$command\n$output',
      metadata: jsonEncode({'success': success}),
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

/// Agent 记忆系统
class AgentMemory {
  static const int _maxEntries = 100;
  static const int _systemInfoMax = 10;

  Box<MemoryEntry> get _box => HiveInit.agentMemoryBox;

  Future<void> add(MemoryEntry entry) async {
    await _box.put(entry.id, entry);
    await _trim();
  }

  Future<void> rememberCommand(String command, {String? description}) async {
    await add(MemoryEntry.command(command, description: description));
  }

  Future<void> rememberResult(String command, String output, {bool success = true}) async {
    await add(MemoryEntry.result(command, output, success: success));
  }

  Future<void> rememberSystemInfo(String info, {String? category}) async {
    await add(MemoryEntry.systemInfo(info, category: category));
  }

  List<MemoryEntry> getRecent({int limit = 20}) {
    final entries = _box.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries.take(limit).toList();
  }

  List<MemoryEntry> getRecentCommands({int limit = 10}) {
    return getRecent(limit: limit)
        .where((e) => e.type == 'command' || e.type == 'result')
        .toList();
  }

  String getSystemSummary() {
    final systemInfos = _box.values
        .where((e) => e.type == 'system_info')
        .toList()
        .reversed
        .take(_systemInfoMax);
    return systemInfos.map((e) => e.content).join('\n');
  }

  String buildContext() {
    final recent = getRecent(limit: 30);
    if (recent.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('【Agent 记忆】');

    final systemInfos = recent.where((e) => e.type == 'system_info');
    if (systemInfos.isNotEmpty) {
      buffer.writeln('系统环境:');
      for (final info in systemInfos.take(5)) {
        buffer.writeln('  - ${info.content}');
      }
    }

    final commands = recent.where((e) => e.type == 'command').take(5);
    if (commands.isNotEmpty) {
      buffer.writeln('最近命令:');
      for (final cmd in commands) {
        buffer.writeln('  - ${cmd.content}');
      }
    }

    return buffer.toString();
  }

  Future<void> _trim() async {
    final all = _box.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (all.length > _maxEntries) {
      final toDelete = all.skip(_maxEntries).map((e) => e.id).toList();
      await _box.deleteAll(toDelete);
    }
  }

  Future<void> clear() async {
    await _box.clear();
  }

  Map<String, int> get stats {
    final entries = _box.values.toList();
    return {
      'total': entries.length,
      'commands': entries.where((e) => e.type == 'command').length,
      'results': entries.where((e) => e.type == 'result').length,
      'system_info': entries.where((e) => e.type == 'system_info').length,
      'context': entries.where((e) => e.type == 'context').length,
    };
  }
}
