import 'package:hive/hive.dart';

part 'change_record.g.dart';

/// 变更记录类型
@HiveType(typeId: 30)
enum ChangeType {
  @HiveField(0)
  install, // 安装软件
  @HiveField(1)
  uninstall, // 卸载软件
  @HiveField(2)
  modifyConfig, // 修改配置文件
  @HiveField(3)
  startService, // 启动服务
  @HiveField(4)
  stopService, // 停止服务
  @HiveField(5)
  restartService, // 重启服务
  @HiveField(6)
  fileOperation, // 文件操作（cp/mv/rm）
  @HiveField(7)
  permission, // 权限修改
  @HiveField(8)
  other, // 其他修改
}

/// 变更台账记录 — 每次执行修改性命令时记录
@HiveType(typeId: 31)
class ChangeRecord extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String hostId;

  @HiveField(2)
  String command;

  @HiveField(3)
  ChangeType type;

  /// 回滚命令（如有）
  @HiveField(4)
  String? rollbackCommand;

  /// 回滚说明
  @HiveField(5)
  String? rollbackDescription;

  /// 执行时间
  @HiveField(6)
  DateTime timestamp;

  /// 执行是否成功
  @HiveField(7)
  bool success;

  /// 执行用户（从 HostConfig.username 推断）
  @HiveField(8)
  String? username;

  /// 会话 ID（关联到具体会话）
  @HiveField(9)
  String? conversationId;

  /// 是否已回滚
  @HiveField(10)
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
