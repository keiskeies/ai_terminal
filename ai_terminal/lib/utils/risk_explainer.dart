import '../core/safety_guard.dart';
import '../core/ui_text.dart';
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
      return RiskExplanation(
        impact: UiText.t('执行工具调用，可能改动当前会话之外的状态',
            'Runs a tool call; may change state outside the current session'),
        canRollback: false,
      );
    }
    final isZh = UiText.zh;
    return RiskExplanation(
      impact: entry.impactFor(isZh),
      canRollback: false,
      restoreHint: entry.restoreHintFor(isZh),
    );
  }

  static String _impactFor(ChangeType type) {
    switch (type) {
      case ChangeType.install:
        return UiText.t('安装或升级软件包，可能改变系统依赖，影响已有服务',
            'Installs or upgrades packages; may change system dependencies and affect running services');
      case ChangeType.uninstall:
        return UiText.t('卸载软件，依赖它的服务可能不可用',
            'Uninstalls software; services that depend on it may become unavailable');
      case ChangeType.startService:
        return UiText.t('启动服务，会改变当前运行状态',
            'Starts a service; changes the current running state');
      case ChangeType.stopService:
        return UiText.t('停止服务，依赖它的网站/接口会中断',
            'Stops a service; websites/APIs depending on it will go down');
      case ChangeType.restartService:
        return UiText.t('重启服务，网站/接口可能短暂中断',
            'Restarts a service; websites/APIs may blip briefly');
      case ChangeType.fileOperation:
        return UiText.t('修改、移动或删除文件，可能影响配置或数据',
            'Modifies, moves or deletes files; may affect configuration or data');
      case ChangeType.permission:
        return UiText.t('修改文件权限或属主，可能影响服务访问',
            'Changes file permissions or ownership; may affect service access');
      case ChangeType.modifyConfig:
        return UiText.t('修改配置文件，可能改变服务行为',
            'Modifies a configuration file; may change service behavior');
      case ChangeType.other:
        return UiText.t('修改服务器状态，请确认影响范围',
            'Changes server state — confirm the blast radius');
    }
  }
}

/// 工具影响文案：影响范围 + 还原方式（null 表示沿用"无自动回滚"提示）
///
/// 中英双份 const 存表，按当前 UI 语言在读取点选择：
/// UiText.t 不是 const，不能包进 const 表；存双语、读取时选语言，
/// 用户运行时切换语言也不会停留在旧文案。
class _ToolImpact {
  const _ToolImpact(this.impact, this.impactEn,
      [this.restoreHint, this.restoreHintEn]);
  final String impact;
  final String impactEn;
  final String? restoreHint;
  final String? restoreHintEn;

  String impactFor(bool isZh) => isZh ? impact : impactEn;
  String? restoreHintFor(bool isZh) => isZh ? restoreHint : restoreHintEn;
}

const _restoreFromBackupEn =
    'Restore: the generated backup can be put back from the change log';
const _readOnlyRestoreEn = 'Restore: read-only, nothing to roll back';
const _noChangeRestoreEn = 'Restore: no changes, nothing to roll back';

const _readOnly = _ToolImpact('只读操作，不改动任何状态',
    'Read-only operation; changes nothing', '还原：只读操作无需回滚', _readOnlyRestoreEn);

const Map<String, _ToolImpact> _toolImpacts = {
  // 本机文件：路径已过 LocalFilePolicy 白名单，改动进变更台账
  'local_file_delete': _ToolImpact(
      '删除本机文件（默认移入回收区，不直接抹掉）',
      'Deletes a local file (moved to the trash by default, not erased)',
      '还原：移入回收区的文件可在改动记录放回原路径',
      'Restore: trashed files can be put back to their original path from the change log'),
  'local_file_write': _ToolImpact(
      '写入本机文件（默认覆盖前自动备份）',
      'Writes a local file (auto-backup before overwrite by default)',
      '还原：生成的备份可在改动记录放回原路径',
      _restoreFromBackupEn),
  'local_file_patch': _ToolImpact(
      '替换本机文件中的一段文本（默认覆盖前自动备份）',
      'Replaces a text block in a local file (auto-backup before overwrite by default)',
      '还原：生成的备份可在改动记录放回原路径',
      _restoreFromBackupEn),
  'local_file_move': _ToolImpact(
      '移动或重命名本机文件',
      'Moves or renames a local file',
      '还原：可在改动记录放回原路径，被占用的目标保留为 .displaced 副本',
      'Restore: can be put back from the change log; an occupied target is kept as a .displaced copy'),
  'local_file_read': _readOnly,
  'local_dir_list': _readOnly,
  'local_file_search': _readOnly,
  'project_analyze': _readOnly,
  'cert_check': _readOnly,
  'multi_grep': _readOnly,
  'diff_files': _readOnly,

  // 远程文件：file_write/file_patch 会备份，传输类不会
  'file_write': _ToolImpact(
      '写入服务器上的文件（默认覆盖前自动备份）',
      'Writes a file on the server (auto-backup before overwrite by default)',
      '还原：生成的备份可在改动记录放回原路径',
      _restoreFromBackupEn),
  'file_patch': _ToolImpact(
      '替换服务器文件中的一段文本（默认覆盖前自动备份）',
      'Replaces a text block in a server file (auto-backup before overwrite by default)',
      '还原：生成的备份可在改动记录放回原路径',
      _restoreFromBackupEn),
  'sftp_upload': _ToolImpact('上传本机文件到服务器，同名远程文件会被覆盖且不备份',
      'Uploads a local file to the server; a same-named remote file is overwritten without backup'),
  'upload_to': _ToolImpact('上传本机文件到指定主机，同名远程文件会被覆盖且不备份',
      'Uploads a local file to the selected host; a same-named remote file is overwritten without backup'),
  'broadcast_upload': _ToolImpact('向多台主机广播上传，各主机的同名文件都会被覆盖且不备份',
      'Broadcast-uploads to multiple hosts; same-named files on every host are overwritten without backup'),
  'sftp_download': _ToolImpact('下载远程文件到本机，同名本地文件会被覆盖且不备份',
      'Downloads a remote file to this machine; a same-named local file is overwritten without backup'),
  'sftp_file_read': _readOnly,
  'collect_file': _ToolImpact('从多台主机采集文件到本机目录，不改动远程状态',
      'Collects files from multiple hosts into a local directory; remote state is unchanged'),
  'file_sync': _ToolImpact('开启本地与远程目录的持续同步：本地改动会自动推送到远端',
      'Turns on continuous sync between a local and a remote directory: local edits are pushed to the remote automatically'),

  // 远程执行 / 本机构建 / 公网
  'exec_on': _ToolImpact('在远程主机上执行命令，可能改变该主机状态',
      'Runs a command on the remote host; may change that host\'s state'),
  'exec_batch': _ToolImpact('在多台主机上执行同一条命令，可能改变这些主机状态',
      'Runs the same command on multiple hosts; may change their state'),
  'check_connectivity': _ToolImpact(
      '探测各主机的连通性，不改动主机状态',
      'Probes connectivity of each host; changes nothing on them',
      '还原：只读操作无需回滚',
      _readOnlyRestoreEn),
  'build_project': _ToolImpact('在本机执行构建命令，会写入项目的产物目录',
      'Runs the build on this machine; writes into the project output directory'),
  'package_project': _ToolImpact('在本机打包构建产物，会写出压缩包文件',
      'Packages build artifacts on this machine; writes archive files'),
  'local_exec': _ToolImpact(
      '在运行 App 的本机执行命令，可能修改本机文件、Docker 或系统服务',
      'Runs a command on the machine hosting this app; may modify local files, Docker or system services',
      '还原：本机 shell 无自动回滚，请以确认卡片中的命令与 cwd 为准',
      'Restore: the local shell has no automatic rollback — rely on the command and cwd shown in the confirmation card'),
  'web_search': _ToolImpact(
      '访问公网检索，不改动任何主机状态',
      'Searches the public web; changes nothing on any host',
      '还原：不涉及改动无需回滚',
      _noChangeRestoreEn),
  'fetch_url': _ToolImpact(
      '访问公网拉取内容，不改动任何主机状态',
      'Fetches content from the public web; changes nothing on any host',
      '还原：不涉及改动无需回滚',
      _noChangeRestoreEn),
  // 密码只写进本机加密凭据库，不改动服务器；但用户要知道自己正在交出特权凭据
  'provide_password': _ToolImpact(
      '请用户输入特权（sudo）密码，保存到本机加密凭据库；不改动服务器上的任何状态',
      'Asks the user for the privileged (sudo) password and stores it in this machine\'s encrypted credential vault; nothing on the server changes',
      '还原：可在主机设置里清除已保存的 sudo 密码',
      'Restore: the saved sudo password can be cleared in host settings'),
};
