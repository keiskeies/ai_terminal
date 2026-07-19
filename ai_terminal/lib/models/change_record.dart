/// 变更记录类型
enum ChangeType {
  install, // 安装软件
  uninstall, // 卸载软件
  modifyConfig, // 修改配置文件
  startService, // 启动服务
  stopService, // 停止服务
  restartService, // 重启服务
  fileOperation, // 文件操作（cp/mv/rm）
  permission, // 权限修改
  other, // 其他修改
}

/// 变更台账记录 — 每次执行修改性命令时记录
class ChangeRecord {
  String id;

  String hostId;

  String command;

  ChangeType type;

  /// 回滚命令（如有）
  String? rollbackCommand;

  /// 回滚说明
  String? rollbackDescription;

  /// 执行时间
  DateTime timestamp;

  /// 执行是否成功
  bool success;

  /// 执行用户（从 HostConfig.username 推断）
  String? username;

  /// 会话 ID（关联到具体会话）
  String? conversationId;

  /// 是否已回滚
  bool rolledBack;

  ChangeRecord({
    required this.id,
    required this.hostId,
    required this.command,
    required this.type,
    this.rollbackCommand,
    this.rollbackDescription,
    required this.timestamp,
    required this.success,
    this.username,
    this.conversationId,
    this.rolledBack = false,
  });
}
