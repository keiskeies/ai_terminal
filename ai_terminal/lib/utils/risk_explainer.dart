import '../core/safety_guard.dart';
import '../models/change_record.dart';
import '../services/change_record_service.dart';

/// 面向用户的危险命令影响说明
class RiskExplanation {
  final String impact;
  final String? reason;
  final String? rollbackCommand;
  final bool canRollback;

  /// 还原方式说明（工具用）。null 时 UI 回落到"无自动回滚，建议先快照"。
  ///
  /// 工具没有 shell 回滚命令（还原走变更台账的备份/回收区），把提示塞进
  /// [rollbackCommand] 会显示一条并不存在的 shell 命令。
  final String? restoreHint;

  const RiskExplanation({
    required this.impact,
    this.reason,
    this.rollbackCommand,
    this.canRollback = false,
    this.restoreHint,
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

  /// 工具调用的影响说明
  ///
  /// 工具没有 shell 命令原文：把 `local_file_delete\n  path: x` 交给 [explain]
  /// 会按 shell 语义猜类型，落到 other 分支说出"修改服务器状态" —— 而 `local_*`
  /// 改的是跑 App 的这台机器。确认框说错影响对象，等于让用户在错误前提下点批准。
  ///
  /// 影响与还原两句成对维护：只读工具说"无需回滚"、有台账的说"可还原"、
  /// 没备份的（sftp/file_sync）必须承认"不自动备份"——多报安全性比不报更糟。
  static RiskExplanation explainTool(String toolName) {
    final entry = _toolImpacts[toolName];
    if (entry == null) {
      // 兜底不给"服务器/本机"结论：说错机器比说得不具体更危险
      return const RiskExplanation(
        impact: '执行工具调用，可能改动当前会话之外的状态',
        canRollback: false,
      );
    }
    return RiskExplanation(
      impact: entry.impact,
      canRollback: false,
      restoreHint: entry.restoreHint,
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

/// 工具影响文案：影响范围 + 还原方式（null 表示沿用"无自动回滚"提示）
class _ToolImpact {
  const _ToolImpact(this.impact, [this.restoreHint]);
  final String impact;
  final String? restoreHint;
}

const _readOnly = _ToolImpact('只读操作，不改动任何状态', '还原：只读操作无需回滚');

const Map<String, _ToolImpact> _toolImpacts = {
  // 本机文件：路径已过 LocalFilePolicy 白名单，改动进变更台账
  'local_file_delete': _ToolImpact(
      '删除本机文件（默认移入回收区，不直接抹掉）', '还原：移入回收区的文件可在改动记录放回原路径'),
  'local_file_write': _ToolImpact('写入本机文件（默认覆盖前自动备份）',
      '还原：生成的备份可在改动记录放回原路径'),
  'local_file_patch': _ToolImpact('替换本机文件中的一段文本（默认覆盖前自动备份）',
      '还原：生成的备份可在改动记录放回原路径'),
  'local_file_move': _ToolImpact('移动或重命名本机文件',
      '还原：可在改动记录放回原路径，被占用的目标保留为 .displaced 副本'),
  'local_file_read': _readOnly,
  'local_dir_list': _readOnly,
  'local_file_search': _readOnly,
  'project_analyze': _readOnly,
  'cert_check': _readOnly,
  'multi_grep': _readOnly,
  'diff_files': _readOnly,

  // 远程文件：file_write/file_patch 会备份，传输类不会
  'file_write':
      _ToolImpact('写入服务器上的文件（默认覆盖前自动备份）', '还原：生成的备份可在改动记录放回原路径'),
  'file_patch': _ToolImpact('替换服务器文件中的一段文本（默认覆盖前自动备份）',
      '还原：生成的备份可在改动记录放回原路径'),
  'sftp_upload': _ToolImpact('上传本机文件到服务器，同名远程文件会被覆盖且不备份'),
  'upload_to': _ToolImpact('上传本机文件到指定主机，同名远程文件会被覆盖且不备份'),
  'broadcast_upload': _ToolImpact(
      '向多台主机广播上传，各主机的同名文件都会被覆盖且不备份'),
  'sftp_download': _ToolImpact('下载远程文件到本机，同名本地文件会被覆盖且不备份'),
  'collect_file': _ToolImpact('从多台主机采集文件到本机目录，不改动远程状态'),
  'file_sync': _ToolImpact('开启本地与远程目录的持续同步：本地改动会自动推送到远端'),

  // 远程执行 / 本机构建 / 公网
  'exec_on': _ToolImpact('在远程主机上执行命令，可能改变该主机状态'),
  'exec_batch': _ToolImpact('在多台主机上执行同一条命令，可能改变这些主机状态'),
  'check_connectivity': _ToolImpact('探测各主机的连通性，不改动主机状态', '还原：只读操作无需回滚'),
  'build_project': _ToolImpact('在本机执行构建命令，会写入项目的产物目录'),
  'package_project': _ToolImpact('在本机打包构建产物，会写出压缩包文件'),
  'web_search': _ToolImpact('访问公网检索，不改动任何主机状态', '还原：不涉及改动无需回滚'),
  'fetch_url': _ToolImpact('访问公网拉取内容，不改动任何主机状态', '还原：不涉及改动无需回滚'),
  // 密码只写进本机加密凭据库，不改动服务器；但用户要知道自己正在交出特权凭据
  'provide_password': _ToolImpact(
      '请用户输入特权（sudo）密码，保存到本机加密凭据库；不改动服务器上的任何状态',
      '还原：可在主机设置里清除已保存的 sudo 密码'),
};
