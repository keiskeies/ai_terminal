/// 一条终端命令历史（跨会话持久化）。
///
/// [id] 未落库时是负数占位（`record` 拿到自增 id 后替换），落库后为真实行号。
class CommandHistoryEntry {
  const CommandHistoryEntry({
    required this.id,
    required this.command,
    required this.usedAt,
    required this.useCount,
    this.hostId,
  });

  final int id;
  final String command;

  /// 最后一次使用该命令的主机（本地终端或已删除的主机为 null）
  final String? hostId;

  final DateTime usedAt;
  final int useCount;

  CommandHistoryEntry copyWith({int? id, DateTime? usedAt, int? useCount}) {
    return CommandHistoryEntry(
      id: id ?? this.id,
      command: command,
      hostId: hostId,
      usedAt: usedAt ?? this.usedAt,
      useCount: useCount ?? this.useCount,
    );
  }
}
