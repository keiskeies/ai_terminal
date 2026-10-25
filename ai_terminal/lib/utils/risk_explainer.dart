import '../core/safety_guard.dart';
import '../models/change_record.dart';
import '../services/change_record_service.dart';

/// 面向用户的危险命令影响说明
class RiskExplanation {
  final String impact;
  final String? reason;
  final String? rollbackCommand;
  final bool canRollback;

  const RiskExplanation({
    required this.impact,
    this.reason,
    this.rollbackCommand,
    this.canRollback = false,
  });
}

class RiskExplainer {
  /// 是否属于会改变服务器状态的命令（不含纯查询）
  static bool isMutating(String command) =>
      ChangeRecordService.inferType(command) != ChangeType.other;

  static RiskExplanation explain(String command) {
    final level = SafetyGuard.check(command);
    final type = ChangeRecordService.inferType(command);
    final rollback = ChangeRecordService.buildRollbackCommand(command, type);
    return RiskExplanation(
      impact: _impactFor(type),
      reason: SafetyGuard.getReason(command) ?? SafetyGuard.getTip(level),
      rollbackCommand: rollback,
      canRollback: rollback != null && rollback.trim().isNotEmpty,
    );
  }

  static String _impactFor(ChangeType type) {
    switch (type) {
      case ChangeType.install:
        return '安装或升级软件包，可能改变系统依赖，影响已有服务';
      case ChangeType.uninstall:
        return '卸载软件，依赖它的服务可能不可用';
      case ChangeType.startService:
        return '启动服务，会改变当前运行状态';
      case ChangeType.stopService:
        return '停止服务，依赖它的网站/接口会中断';
      case ChangeType.restartService:
        return '重启服务，网站/接口可能短暂中断';
      case ChangeType.fileOperation:
        return '修改、移动或删除文件，可能影响配置或数据';
      case ChangeType.permission:
        return '修改文件权限或属主，可能影响服务访问';
      case ChangeType.modifyConfig:
        return '修改配置文件，可能改变服务行为';
      case ChangeType.other:
        return '修改服务器状态，请确认影响范围';
    }
  }
}
