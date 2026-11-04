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

  /// 本机文件还原：备份/回收区里的源路径
  ///
  /// 与 [rollbackCommand] 互斥使用。回滚命令是丢给当前会话 executor 执行的，
  /// 而本机文件变更发生在跑 App 的这台机器上 —— 在 SSH 会话里用 `mv` 还原
  /// 会把命令打到远端，改错机器。所以本机还原必须走 Dart 文件 I/O，
  /// 由 [localRestoreTo] 指明放回哪里。
  String? localRestoreFrom;

  /// 本机文件还原：要放回的原路径
  String? localRestoreTo;

  /// 是否可回滚（有远程回滚命令，或有本机还原对）
  bool get isRollbackable {
    if (rollbackCommand?.trim().isNotEmpty ?? false) return true;
    return (localRestoreFrom?.isNotEmpty ?? false) &&
        (localRestoreTo?.isNotEmpty ?? false);
  }

  /// 本机还原对（供 UI 显示"从回收区移回 X"）
  bool get isLocalFileRestore =>
      (localRestoreFrom?.isNotEmpty ?? false) &&
      (localRestoreTo?.isNotEmpty ?? false);

  /// UI 提示文案：本机还原没有"回滚命令"可展示，显示还原目标
  String get rollbackHint => isLocalFileRestore
      ? '还原本机文件 → $localRestoreTo'
      : (rollbackCommand ?? '');

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
    this.localRestoreFrom,
    this.localRestoreTo,
    required this.timestamp,
    required this.success,
    this.username,
    this.conversationId,
    this.rolledBack = false,
  });
}
