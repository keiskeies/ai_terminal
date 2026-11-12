// RollbackAdvisor - port of Dart rollback_advisor.dart 1-328.
//
// Analyzes shell commands for modification intent, generates pre-snapshot
// commands (read-only), and produces rollback suggestions on failure.
// Pure logic, no file I/O - the engine executes the snapshot commands.

export enum ModifyTargetType {
  configFile = "configFile",
  service = "service",
  package = "package",
  permission = "permission",
  fileWrite = "fileWrite",
  unknown = "unknown",
}

export interface ModifyTarget {
  type: ModifyTargetType;
  name: string;
  command: string;
}

export interface PreSnapshot {
  target: ModifyTarget;
  snapshotCommand: string;
  snapshotOutput?: string | null;
  rollbackSuggestion?: string | null;
}

export class RollbackAdvisor {
  // Dart 65-89: analyze a command for modification intent
  static analyze(command: string): ModifyTarget | null {
    const cmd = command.trim();
    const cmdLower = cmd.toLowerCase();

    // Dart 70: skip pure query commands
    if (RollbackAdvisor._isQueryCommand(cmdLower)) return null;

    const cfg = RollbackAdvisor._detectConfigFileModify(cmd, cmdLower);
    if (cfg !== null) return cfg;
    const svc = RollbackAdvisor._detectServiceModify(cmdLower);
    if (svc !== null) return svc;
    const pkg = RollbackAdvisor._detectPackageModify(cmdLower);
    if (pkg !== null) return pkg;
    const perm = RollbackAdvisor._detectPermissionModify(cmdLower);
    if (perm !== null) return perm;

    return null;
  }

  // Dart 94-126: build a read-only snapshot command for the target
  static buildSnapshotCommand(target: ModifyTarget): string | null {
    switch (target.type) {
      case ModifyTargetType.configFile:
        return `echo "=== \u4fee\u6539\u524d\u5feb\u7167 ===" && ls -la "${target.name}" 2>/dev/null && echo "--- \u5185\u5bb9\u524d5\u884c ---" && head -5 "${target.name}" 2>/dev/null && echo "--- \u884c\u6570/\u5927\u5c0f ---" && wc -lc "${target.name}" 2>/dev/null || echo "\u6587\u4ef6\u4e0d\u5b58\u5728\u6216\u65e0\u6cd5\u8bfb\u53d6"`;
      case ModifyTargetType.service:
        if (target.command.includes("update-alternatives")) {
          return `update-alternatives --display ${target.name} 2>/dev/null | head -10 || echo "alternatives \u72b6\u6001\u672a\u77e5"`;
        }
        return `systemctl status ${target.name} 2>/dev/null | head -10 || service ${target.name} status 2>/dev/null | head -10 || echo "\u670d\u52a1\u72b6\u6001\u672a\u77e5"`;
      case ModifyTargetType.package:
        return `dpkg -l "${target.name}" 2>/dev/null | tail -1 || rpm -q "${target.name}" 2>/dev/null || echo "\u5305 ${target.name} \u5f53\u524d\u672a\u5b89\u88c5"`;
      case ModifyTargetType.permission:
        return `ls -la "${target.name}" 2>/dev/null || echo "\u76ee\u6807\u4e0d\u5b58\u5728"`;
      case ModifyTargetType.fileWrite:
        return `ls -la "${target.name}" 2>/dev/null && wc -l "${target.name}" 2>/dev/null || echo "\u6587\u4ef6\u4e0d\u5b58\u5728"`;
      case ModifyTargetType.unknown:
        return null;
    }
  }

  // Dart 129-194: build rollback suggestion from snapshot + failed command
  static buildRollbackSuggestion(target: ModifyTarget, snapshotOutput?: string | null): string | null {
    switch (target.type) {
      case ModifyTargetType.configFile:
        if (target.name === "crontab") {
          return "\u56de\u6eda\u5efa\u8bae: crontab \u5df2\u88ab\u4fee\u6539\u3002\u5982\u9700\u6062\u590d\uff0c\u53c2\u8003\u5feb\u7167\u4e2d\u7684\u539f crontab \u5185\u5bb9\uff0c\u7528 crontab < backup_file \u6062\u590d";
        }
        return `\u56de\u6eda\u5efa\u8bae: ${target.name} \u4fee\u6539\u524d\u5feb\u7167\u89c1\u4e0a\u65b9\u8f93\u51fa\u3002\u82e5\u9700\u6062\u590d\uff0c\u8bf7\u4ece\u7248\u672c\u63a7\u5236(git)\u3001\u5305\u7ba1\u7406\u5668\u91cd\u88c5\u6216\u540c\u73af\u5883\u8282\u70b9\u62f7\u8d1d\u539f\u6587\u4ef6`;
      case ModifyTargetType.service:
        if (target.command.includes("update-alternatives --set")) {
          return `\u56de\u6eda\u5efa\u8bae: sudo update-alternatives --auto ${target.name} (\u6062\u590d\u81ea\u52a8\u6a21\u5f0f\uff0c\u6216\u7528 --set \u6307\u5411\u539f\u7248\u672c)`;
        }
        if (target.command.includes("systemctl enable ")) {
          return `\u56de\u6eda\u5efa\u8bae: sudo systemctl disable ${target.name} (\u64a4\u9500 enable)`;
        }
        if (target.command.includes("systemctl disable ")) {
          return `\u56de\u6eda\u5efa\u8bae: sudo systemctl enable ${target.name} (\u64a4\u9500 disable)`;
        }
        return `\u56de\u6eda\u5efa\u8bae: \u53c2\u8003\u5feb\u7167\u4e2d\u7684\u4fee\u6539\u524d\u72b6\u6001\uff0csudo systemctl start ${target.name} (\u5982\u539f\u4e3a\u8fd0\u884c) \u6216 stop (\u5982\u539f\u4e3a\u505c\u6b62)`;
      case ModifyTargetType.package:
        return `\u56de\u6eda\u5efa\u8bae: sudo apt remove ${target.name} \u6216 sudo yum remove ${target.name} (\u56de\u6eda\u5b89\u88c5\u64cd\u4f5c)`;
      case ModifyTargetType.permission:
        {
          const m = /chmod\s+(\S+)\s+(.+)/.exec(target.command);
          if (m !== null) {
            return `\u56de\u6eda\u5efa\u8bae: \u53c2\u8003\u5feb\u7167\u4e2d\u7684\u539f\u6743\u9650\uff0c\u7528\u4ee5\u4e0b\u547d\u4ee4\u6062\u590d: chmod <\u539f\u6743\u9650> ${m[2].trim()} (\u539f\u6743\u9650\u89c1 ls -la \u8f93\u51fa)`;
          }
          const cm = /chown\s+(\S+)\s+(.+)/.exec(target.command);
          if (cm !== null) {
            return `\u56de\u6eda\u5efa\u8bae: \u53c2\u8003\u5feb\u7167\u4e2d\u7684\u539f\u5c5e\u4e3b\uff0c\u7528\u4ee5\u4e0b\u547d\u4ee4\u6062\u590d: chown <\u539f\u5c5e\u4e3b:\u539f\u7ec4> ${cm[2].trim()} (\u539f\u5c5e\u4e3b\u89c1 ls -la \u8f93\u51fa)`;
          }
          if (target.command.includes("useradd")) {
            const um = /useradd\s+(?:.*?\s+)?(\S+)\s*$/.exec(target.command);
            const user = um !== null ? um[1] : "\u65b0\u7528\u6237";
            return `\u56de\u6eda\u5efa\u8bae: sudo userdel -r ${user} (\u5220\u9664\u521a\u521b\u5efa\u7684\u7528\u6237\u53ca\u5bb6\u76ee\u5f55)`;
          }
          return "\u56de\u6eda\u5efa\u8bae: \u53c2\u8003\u5feb\u7167\u4e2d\u7684\u539f\u6743\u9650(ls -la \u8f93\u51fa)\uff0c\u7528 chmod/chown \u6062\u590d";
        }
      case ModifyTargetType.fileWrite:
        {
          const mvM = /^mv\s+(\S+)\s+(\S+)/.exec(target.command);
          if (mvM !== null) {
            return `\u56de\u6eda\u5efa\u8bae: mv ${mvM[2]} ${mvM[1]} (\u5c06\u6587\u4ef6\u79fb\u56de\u539f\u4f4d\u7f6e)`;
          }
          const lnM = /^ln\s+-\w*s\w*\s+\S+\s+(\S+)/.exec(target.command);
          if (lnM !== null) {
            return `\u56de\u6eda\u5efa\u8bae: rm ${lnM[1]} (\u5220\u9664\u521a\u521b\u5efa\u7684\u7b26\u53f7\u94fe\u63a5)`;
          }
          return `\u56de\u6eda\u5efa\u8bae: \u53c2\u8003\u5feb\u7167\u4e2d\u7684\u539f\u6587\u4ef6\u4fe1\u606f\uff0c\u4ece\u5907\u4efd\u6216\u7248\u672c\u63a7\u5236\u6062\u590d ${target.name}`;
        }
      case ModifyTargetType.unknown:
        return null;
    }
  }

  // Dart 200-208: query command check (simplified, avoids circular dep)
  private static _isQueryCommand(cmdLower: string): boolean {
    const queryPrefixes = [
      "grep", "find", "cat", "head", "tail", "ls", "stat", "diff",
      "ps", "top", "systemctl status", "docker ps", "kubectl get",
      "ping", "curl", "wget", "uname", "whoami", "pwd",
    ];
    return queryPrefixes.some((p) => cmdLower.startsWith(p));
  }

  // Dart 210-262: detect config file / file write modifications
  private static _detectConfigFileModify(cmd: string, cmdLower: string): ModifyTarget | null {
    const sedM = /sed\s+-i.*?\s+(\S+)$/.exec(cmd);
    if (sedM !== null) {
      return {type: ModifyTargetType.configFile, name: sedM[1], command: cmd};
    }
    if (cmdLower.startsWith("cp ") || cmdLower.startsWith("mv ") || cmdLower.startsWith("rm ")) {
      const configPaths = ["/etc/", "/usr/local/etc/", "/opt/", "/var/www/", "nginx.conf", ".conf"];
      for (const pp of configPaths) {
        if (cmd.includes(pp)) {
          const parts = cmd.split(/\s+/);
          if (parts.length >= 2) {
            return {type: ModifyTargetType.configFile, name: parts[parts.length - 1], command: cmd};
          }
        }
      }
    }
    const mvM = /^mv\s+(\S+)\s+(\S+)/.exec(cmd);
    if (mvM !== null) {
      const dst = mvM[2];
      if (!/\.(bak|old|backup|orig)$/i.test(dst)) {
        return {type: ModifyTargetType.fileWrite, name: dst, command: cmd};
      }
    }
    const lnM = /^ln\s+-\w*s\w*\s+(\S+)\s+(\S+)/.exec(cmd);
    if (lnM !== null) {
      return {type: ModifyTargetType.fileWrite, name: lnM[2], command: cmd};
    }
    const writeM = /(?:cat|echo|tee)\s+>?\\?\s*(\S+)/.exec(cmd);
    if (writeM !== null) {
      const p = writeM[1];
      if (p.startsWith("/") || p.includes(".conf") || p.includes(".sh")) {
        return {type: ModifyTargetType.fileWrite, name: p, command: cmd};
      }
    }
    const herM = /cat\s*>\s*(\S+)\s*<</.exec(cmd);
    if (herM !== null) {
      return {type: ModifyTargetType.fileWrite, name: herM[1], command: cmd};
    }
    if (cmdLower.startsWith("crontab ") && !cmdLower.includes("-l")) {
      return {type: ModifyTargetType.configFile, name: "crontab", command: cmd};
    }
    return null;
  }

  // Dart 264-291: detect service modifications
  private static _detectServiceModify(cmdLower: string): ModifyTarget | null {
    const svcM = /systemctl\s+(restart|stop|start|disable|enable)\s+(\S+)/.exec(cmdLower);
    if (svcM !== null) {
      return {type: ModifyTargetType.service, name: svcM[2], command: cmdLower};
    }
    const oldM = /service\s+(\S+)\s+(restart|stop|start)/.exec(cmdLower);
    if (oldM !== null) {
      return {type: ModifyTargetType.service, name: oldM[1], command: cmdLower};
    }
    const altM = /update-alternatives\s+--set\s+(\S+)/.exec(cmdLower);
    if (altM !== null) {
      return {type: ModifyTargetType.service, name: altM[1], command: cmdLower};
    }
    return null;
  }

  // Dart 293-311: detect package installations
  private static _detectPackageModify(cmdLower: string): ModifyTarget | null {
    const patterns = [
      /apt(?:-get)?\s+install\s+(\S+)/,
      /yum\s+install\s+(\S+)/,
      /dnf\s+install\s+(\S+)/,
      /apk\s+add\s+(\S+)/,
      /pip\s+install\s+(\S+)/,
      /pip3\s+install\s+(\S+)/,
      /npm\s+install\s+(?:-g\s+)?(\S+)/,
      /npm\s+i\s+(?:-g\s+)?(\S+)/,
    ];
    for (const p of patterns) {
      const m = p.exec(cmdLower);
      if (m !== null) {
        return {type: ModifyTargetType.package, name: m[1], command: cmdLower};
      }
    }
    return null;
  }

  // Dart 313-326: detect permission modifications
  private static _detectPermissionModify(cmdLower: string): ModifyTarget | null {
    const chmodM = /chmod\s+\S+\s+(\S+)/.exec(cmdLower);
    if (chmodM !== null) {
      return {type: ModifyTargetType.permission, name: chmodM[1], command: cmdLower};
    }
    const chownM = /chown\s+\S+\s+(\S+)/.exec(cmdLower);
    if (chownM !== null) {
      return {type: ModifyTargetType.permission, name: chownM[1], command: cmdLower};
    }
    if (cmdLower.startsWith("useradd") || cmdLower.startsWith("usermod") || cmdLower.startsWith("userdel")) {
      return {type: ModifyTargetType.permission, name: "user", command: cmdLower};
    }
    return null;
  }
}
