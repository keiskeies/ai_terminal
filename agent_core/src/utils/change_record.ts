// utils/change_record.ts - r210 port of the pure parts of
// services/change_record_service.dart (inferType/buildRollbackCommand/regexes)
// + the ChangeType enum from models/change_record.dart.
//
// The Dart service class also does Hive persistence; that half has no Node
// counterpart here (agent_core keeps audit/change state via CheckpointStore and
// the audit_log module). What IS portable - the static rule table and rollback
// synthesis - is reproduced 1:1, regex literals character-identical to the
// Dart raw strings.

/// 变更类型（models/change_record.dart ChangeType）
export const CHANGE_TYPES = [
  "install", // 安装软件
  "uninstall", // 卸载软件
  "modifyConfig", // 修改配置文件
  "startService", // 启动服务
  "stopService", // 停止服务
  "restartService", // 重启服务
  "fileOperation", // 文件操作（cp/mv/rm）
  "permission", // 权限修改
  "other", // 其他修改
] as const;
export type ChangeType = (typeof CHANGE_TYPES)[number];

const sudoPrefixRegex = /^sudo\s+(?:-u\s+\S+\s+)?(?:-[A-Za-z]+\s+)*/;
const sudoAnywhereRegex = /^sudo\s+/;
const installRegex = /^(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)/;
const uninstallRegex = /^(apt|apt-get|yum|dnf|apk|pacman)\s+(remove|purge|erase|-R|autoremove)/;
const systemctlStartRegex = /^systemctl\s+start/;
const systemctlStopRegex = /^systemctl\s+stop/;
const systemctlRestartRegex = /^systemctl\s+restart/;
const serviceStartRegex = /^service\s+\w+\s+start/;
const serviceStopRegex = /^service\s+\w+\s+stop/;
const serviceRestartRegex = /^service\s+\w+\s+restart/;
const permissionRegex = /chmod|chown/;
const fileOpRegex = /^(cp|mv|rm|mkdir|tee|sed|echo.*>)/;
const redirectRegex = /(>>|>)\s*(\/etc\/|~\/)/;
const installWithPkgRegex = /^(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)\s+(\S+)/;
const systemctlStartWithUnitRegex = /^systemctl\s+start\s+(\S+)/;
const serviceStartWithUnitRegex = /^service\s+(\w+)\s+start/;
const systemctlStopWithUnitRegex = /^systemctl\s+stop\s+(\S+)/;
const serviceStopWithUnitRegex = /^service\s+(\w+)\s+stop/;

/// 去除 sudo 前缀，便于统一匹配；保留原始命令用于生成回滚命令
function stripSudo(command: string): string {
  return command.trim().replace(sudoPrefixRegex, "");
}

function hasSudo(command: string): boolean {
  return sudoAnywhereRegex.test(command.trim());
}

/// 根据 SafetyGuard 规则推断变更类型
export function inferChangeType(command: string): ChangeType {
  const c = stripSudo(command);
  if (installRegex.test(c)) return "install";
  if (uninstallRegex.test(c)) return "uninstall";
  if (systemctlStartRegex.test(c)) return "startService";
  if (systemctlStopRegex.test(c)) return "stopService";
  if (systemctlRestartRegex.test(c)) return "restartService";
  if (serviceStartRegex.test(c)) return "startService";
  if (serviceStopRegex.test(c)) return "stopService";
  if (serviceRestartRegex.test(c)) return "restartService";
  if (permissionRegex.test(c)) return "permission";
  if (fileOpRegex.test(c) || redirectRegex.test(c)) {
    return "fileOperation";
  }
  return "other";
}

/// 生成回滚命令（基于命令类型）
export function buildRollbackCommand(command: string, type: ChangeType): string | null {
  const c = stripSudo(command);
  const prefix = hasSudo(command) ? "sudo " : "";
  switch (type) {
    case "install": {
      // apt install nginx → apt remove nginx
      const match = installWithPkgRegex.exec(c);
      if (match !== null) {
        const pm = match[1];
        const pkg = match[3];
        if (pm === "apt" || pm === "apt-get") return prefix + pm + " remove " + pkg;
        if (pm === "yum" || pm === "dnf") return prefix + pm + " remove " + pkg;
        if (pm === "apk") return prefix + pm + " del " + pkg;
        if (pm === "pacman") return prefix + pm + " -R " + pkg;
        if (pm === "snap") return prefix + "snap remove " + pkg;
        if (pm === "brew") return "brew uninstall " + pkg;
      }
      return null;
    }
    case "uninstall":
      // 卸载的逆操作无法准确推断（需重装），返回 null
      return null;
    case "startService": {
      // systemctl start nginx → systemctl stop nginx
      const match = systemctlStartWithUnitRegex.exec(c);
      if (match !== null) return prefix + "systemctl stop " + match[1];
      const m2 = serviceStartWithUnitRegex.exec(c);
      if (m2 !== null) return prefix + "service " + m2[1] + " stop";
      return null;
    }
    case "stopService": {
      const match = systemctlStopWithUnitRegex.exec(c);
      if (match !== null) return prefix + "systemctl start " + match[1];
      const m2 = serviceStopWithUnitRegex.exec(c);
      if (m2 !== null) return prefix + "service " + m2[1] + " start";
      return null;
    }
    case "restartService":
      // 重启不可逆，返回 null
      return null;
    case "fileOperation":
      // cp/mv/rm 的回滚需要快照，这里无法准确推断
      // 实际回滚依赖 RollbackAdvisor 的快照
      return null;
    case "permission":
      // chmod/chown 回滚需要原始权限，无法推断
      return null;
    case "modifyConfig":
      return null;
    case "other":
      return null;
  }
}
