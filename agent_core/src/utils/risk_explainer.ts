// utils/risk_explainer.ts - r210 port of utils/risk_explainer.dart (148 lines).
// 面向用户的危险命令影响说明 (doc comments transcribed from the Dart source).
//
// Dart deps mapped to their already-ported Node counterparts:
//   SafetyGuard.check     -> checkSafety     (utils/safety_guard.ts)
//   SafetyGuard.getReason -> getSafetyReason (utils/safety_guard.ts)
//   SafetyGuard.getTip    -> getSafetyTip    (utils/safety_guard.ts)
//   ChangeRecordService.inferType/buildRollbackCommand -> utils/change_record.ts
// Every zh string is byte-identical to the Dart literal (extracted from the
// source at generation time; the oracle test re-extracts and diffs everything).

import {checkSafety, getSafetyReason, getSafetyTip} from "./safety_guard.js";
import {inferChangeType, buildRollbackCommand, type ChangeType} from "./change_record.js";

/// 面向用户的危险命令影响说明
export interface RiskExplanation {
  readonly impact: string;
  readonly reason: string | null;
  readonly rollbackCommand: string | null;
  readonly canRollback: boolean;
/// 还原方式说明（工具用）。null 时 UI 回落到"无自动回滚，建议先快照"。
///
/// 工具没有 shell 回滚命令（还原走变更台账的备份/回收区），把提示塞进
/// [rollbackCommand] 会显示一条并不存在的 shell 命令。
  readonly restoreHint: string | null;
}

function explanation(e: {
  impact: string; reason?: string | null; rollbackCommand?: string | null;
  canRollback?: boolean; restoreHint?: string | null;
}): RiskExplanation {
  return {
    impact: e.impact,
    reason: e.reason ?? null,
    rollbackCommand: e.rollbackCommand ?? null,
    canRollback: e.canRollback ?? false,
    restoreHint: e.restoreHint ?? null,
  };
}

export class RiskExplainer {
  /// 是否属于会改变服务器状态的命令（不含纯查询）
  static isMutating(command: string): boolean {
    return inferChangeType(command) !== "other";
  }

  static explain(command: string): RiskExplanation {
    const level = checkSafety(command);
    const type = inferChangeType(command);
    const rollback = buildRollbackCommand(command, type);
    return explanation({
      impact: impactFor(type),
      reason: getSafetyReason(command) ?? getSafetyTip(level),
      rollbackCommand: rollback,
      canRollback: rollback !== null && rollback.trim().length > 0,
    });
  }

  /// 工具调用的影响说明
  ///
  /// 工具没有 shell 命令原文：把 `local_file_delete\n  path: x` 交给 [explain]
  /// 会按 shell 语义猜类型，落到 other 分支说出"修改服务器状态" —— 而 `local_*`
  /// 改的是跑 App 的这台机器。确认框说错影响对象，等于让用户在错误前提下点批准。
  ///
  /// 影响与还原两句成对维护：只读工具说"无需回滚"、有台账的说"可还原"、
  /// 没备份的（sftp/file_sync）必须承认"不自动备份"——多报安全性比不报更糟。
  static explainTool(toolName: string): RiskExplanation {
    const entry: ToolImpact | undefined = TOOL_IMPACTS[toolName];
    if (entry === undefined) {
      return explanation({impact: "执行工具调用，可能改动当前会话之外的状态", canRollback: false});
    }
    return explanation({impact: entry.impact, canRollback: false, restoreHint: entry.restoreHint});
  }
}

function impactFor(type: ChangeType): string {
  switch (type) {
    case "install":
      return "安装或升级软件包，可能改变系统依赖，影响已有服务";
    case "uninstall":
      return "卸载软件，依赖它的服务可能不可用";
    case "startService":
      return "启动服务，会改变当前运行状态";
    case "stopService":
      return "停止服务，依赖它的网站/接口会中断";
    case "restartService":
      return "重启服务，网站/接口可能短暂中断";
    case "fileOperation":
      return "修改、移动或删除文件，可能影响配置或数据";
    case "permission":
      return "修改文件权限或属主，可能影响服务访问";
    case "modifyConfig":
      return "修改配置文件，可能改变服务行为";
    case "other":
      return "修改服务器状态，请确认影响范围";
  }
}

/// 工具影响文案：影响范围 + 还原方式（null 表示沿用"无自动回滚"提示）
interface ToolImpact {
  readonly impact: string;
  readonly restoreHint: string | null;
}

const READ_ONLY: ToolImpact = {impact: "只读操作，不改动任何状态", restoreHint: "还原：只读操作无需回滚"};

const TOOL_IMPACTS: Readonly<Record<string, ToolImpact>> = {
  "local_file_delete": {impact: "删除本机文件（默认移入回收区，不直接抹掉）", restoreHint: "还原：移入回收区的文件可在改动记录放回原路径"},
  "local_file_write": {impact: "写入本机文件（默认覆盖前自动备份）", restoreHint: "还原：生成的备份可在改动记录放回原路径"},
  "local_file_patch": {impact: "替换本机文件中的一段文本（默认覆盖前自动备份）", restoreHint: "还原：生成的备份可在改动记录放回原路径"},
  "local_file_move": {impact: "移动或重命名本机文件", restoreHint: "还原：可在改动记录放回原路径，被占用的目标保留为 .displaced 副本"},
  "file_write": {impact: "写入服务器上的文件（默认覆盖前自动备份）", restoreHint: "还原：生成的备份可在改动记录放回原路径"},
  "file_patch": {impact: "替换服务器文件中的一段文本（默认覆盖前自动备份）", restoreHint: "还原：生成的备份可在改动记录放回原路径"},
  "sftp_upload": {impact: "上传本机文件到服务器，同名远程文件会被覆盖且不备份", restoreHint: null},
  "upload_to": {impact: "上传本机文件到指定主机，同名远程文件会被覆盖且不备份", restoreHint: null},
  "broadcast_upload": {impact: "向多台主机广播上传，各主机的同名文件都会被覆盖且不备份", restoreHint: null},
  "sftp_download": {impact: "下载远程文件到本机，同名本地文件会被覆盖且不备份", restoreHint: null},
  "collect_file": {impact: "从多台主机采集文件到本机目录，不改动远程状态", restoreHint: null},
  "file_sync": {impact: "开启本地与远程目录的持续同步：本地改动会自动推送到远端", restoreHint: null},
  "exec_on": {impact: "在远程主机上执行命令，可能改变该主机状态", restoreHint: null},
  "exec_batch": {impact: "在多台主机上执行同一条命令，可能改变这些主机状态", restoreHint: null},
  "check_connectivity": {impact: "探测各主机的连通性，不改动主机状态", restoreHint: "还原：只读操作无需回滚"},
  "build_project": {impact: "在本机执行构建命令，会写入项目的产物目录", restoreHint: null},
  "package_project": {impact: "在本机打包构建产物，会写出压缩包文件", restoreHint: null},
  "local_exec": {impact: "在运行 App 的本机执行命令，可能修改本机文件、Docker 或系统服务", restoreHint: "还原：本机 shell 无自动回滚，请以确认卡片中的命令与 cwd 为准"},
  "web_search": {impact: "访问公网检索，不改动任何主机状态", restoreHint: "还原：不涉及改动无需回滚"},
  "fetch_url": {impact: "访问公网拉取内容，不改动任何主机状态", restoreHint: "还原：不涉及改动无需回滚"},
  "provide_password": {impact: "请用户输入特权（sudo）密码，保存到本机加密凭据库；不改动服务器上的任何状态", restoreHint: "还原：可在主机设置里清除已保存的 sudo 密码"},
  "local_file_read": READ_ONLY,
  "local_dir_list": READ_ONLY,
  "local_file_search": READ_ONLY,
  "project_analyze": READ_ONLY,
  "cert_check": READ_ONLY,
  "multi_grep": READ_ONLY,
  "diff_files": READ_ONLY,
};
