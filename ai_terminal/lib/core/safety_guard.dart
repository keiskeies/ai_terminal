import 'dart:io' show Platform;

import 'ui_text.dart';
import '../core/l10n_holder.dart';

/// 命令安全等级
enum SafetyLevel {
  safe, // 安全（只读命令）
  info, // 仅提示（低风险修改）
  warn, // 需二次确认（高风险修改）
  blocked, // 直接拦截（不可逆操作）
}

/// 路径安全检查结果
class PathSafetyResult {
  final SafetyLevel level;
  final String? reason;

  const PathSafetyResult(this.level, this.reason);

  bool get isAllowed => level == SafetyLevel.safe || level == SafetyLevel.info;
}

/// 安全规则：正则模式 + 人类可读的风险说明（中英双语）
class _SafetyRule {
  final RegExp pattern;
  final String reason;
  final String reasonEn;
  const _SafetyRule(this.pattern, this.reason, this.reasonEn);

  /// 按当前 UI 语言取文案
  String textFor(bool isZh) => isZh ? reason : reasonEn;
}

class SafetyGuard {
  /// 静态缓存，避免对同一条命令重复正则匹配
  static final Map<String, SafetyLevel> _cache = {};

  /// 缓存命中的风险规则（含 null，表示已查过但未命中），避免重复匹配。
  /// 缓存规则对象而非已选语言的文案：用户运行时切换 UI 语言后，
  /// 读缓存时仍按当前语言取字段，不会停留在旧语言。
  static final Map<String, _SafetyRule?> _reasonCache = {};

  // 直接拦截的命令模式（不可逆操作）
  static final List<_SafetyRule> _blockRules = [
    _SafetyRule(
        RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/\s*$'),
        '递归删除根目录，将清空整个文件系统，完全不可恢复',
        'Recursively deletes the filesystem root; destroys all data and cannot be undone'),
    _SafetyRule(
        RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+\/\*?\s*$'),
        '递归删除根目录下所有内容，将清空整个文件系统，完全不可恢复',
        'Recursively deletes everything under the root directory; destroys the entire filesystem and cannot be undone'),
    _SafetyRule(RegExp(r'^dd\s+if=.*of=/dev/'), '直接写入块设备，将覆盖目标磁盘所有数据，不可恢复',
        'Writes directly to a block device; overwrites all data on the target disk and cannot be undone'),
    _SafetyRule(
        RegExp(r'^:\(\)\{\s*:\|\:&\s*\};:', caseSensitive: false),
        'Fork 炸弹，将瞬间耗尽系统进程资源导致系统崩溃',
        'Fork bomb; instantly exhausts process resources and crashes the system'),
    _SafetyRule(
        RegExp(r'chmod\s+-R\s+777\s+/'),
        '递归修改根目录权限为 777，将破坏所有文件权限，系统将无法正常运行',
        'Recursively sets 777 permissions on the root directory; breaks all file permissions and the system will stop working correctly'),
    _SafetyRule(RegExp(r'^init\s+0\s*$'), '立即关机，所有未保存数据将丢失',
        'Shuts the system down immediately; all unsaved data will be lost'),
    _SafetyRule(RegExp(r'^shutdown\s+-h\s+now'), '立即关机，所有未保存数据将丢失',
        'Shuts the system down immediately; all unsaved data will be lost'),
    _SafetyRule(
        RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/etc/'),
        '删除 /etc 下的系统配置文件，相关服务可能无法运行，且不可恢复',
        'Recursively deletes system configuration under /etc; dependent services may fail to run and the change cannot be undone'),
    _SafetyRule(
        RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/boot/'),
        '删除 /boot 启动目录，系统将无法启动',
        'Recursively deletes /boot; the system will no longer boot'),
    _SafetyRule(
        RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+~'),
        '递归删除用户主目录，所有用户数据将丢失',
        'Recursively deletes the user home directory; all user data will be lost'),
    _SafetyRule(RegExp(r'^mkfs\.'), '格式化磁盘，目标分区所有数据将被擦除，不可恢复',
        'Formats a filesystem; all data on the target partition will be erased and cannot be recovered'),
    _SafetyRule(RegExp(r'^>\s*/etc/'), '清空系统配置文件，相关服务将无法运行',
        'Truncates a system configuration file; dependent services will stop working'),
    // 新增：常见高危操作
    _SafetyRule(RegExp(r'^crontab\s+-r\b'), '清空当前用户的所有定时任务，所有 cron 作业将丢失且不可恢复',
        'Removes all cron jobs for the current user; every scheduled task is lost and cannot be recovered'),
    _SafetyRule(
        RegExp(r'^systemctl\s+mask\s+'),
        '屏蔽系统服务，被 mask 的服务将无法启动，需手动 unmask 恢复',
        'Masks a system service; it cannot be started until manually unmasked'),
    _SafetyRule(
        RegExp(r'iptables\s+.*-P\s+(INPUT|OUTPUT|FORWARD)\s+DROP'),
        '设置防火墙默认策略为 DROP，将立即断开所有网络连接，可能导致远程无法访问',
        'Sets the firewall default policy to DROP; severs all network connections immediately and may lock you out of remote access'),
    _SafetyRule(
        RegExp(r'echo\s+c\s*>\s*/proc/sysrq-trigger'),
        '触发 SysRq 崩溃，将导致系统立即崩溃重启',
        'Triggers a SysRq crash; the system will immediately crash and reboot'),
    _SafetyRule(RegExp(r'^pkill\s+-9\b'), '强制杀死所有匹配进程，可能导致数据损坏或服务异常',
        'Force-kills all matching processes; may cause data corruption or service outages'),
    _SafetyRule(RegExp(r'^killall\s+-9\b'), '强制杀死所有同名进程，可能导致数据损坏或服务异常',
        'Force-kills all processes with the given name; may cause data corruption or service outages'),
    _SafetyRule(
        RegExp(r'^kill\s+-9\s+-1\b'),
        '杀死所有用户进程（kill -9 -1），将终止除 init 外的所有进程',
        'Kills all user processes (kill -9 -1); terminates every process except init'),
    _SafetyRule(RegExp(r'^>\s*/dev/sda'), '清空磁盘设备数据，将破坏磁盘分区表和所有数据',
        'Truncates a disk device; destroys the partition table and all data on the disk'),
    _SafetyRule(RegExp(r'^swapoff\s+-a\b'), '关闭所有交换分区，内存不足时系统将直接 OOM 杀进程',
        'Disables all swap; under memory pressure the kernel will OOM-kill processes directly'),
    // Windows 磁盘级破坏操作，对应 POSIX 的 mkfs / dd 直接拦截
    _SafetyRule(
        RegExp(
            r'^\s*(&\s*)?(format-volume|clear-disk|initialize-disk|remove-partition)\b',
            caseSensitive: false),
        '格式化/初始化/清除磁盘或分区，目标磁盘数据将被擦除，不可恢复',
        'Formats/initializes/clears a disk or partition; all data on it is erased and cannot be recovered'),
  ];

  // 需二次确认的命令模式（高风险修改操作）
  static final List<_SafetyRule> _warnRules = [
    // PowerShell/CMD 写操作：本表其余规则全是 POSIX 模式，Windows 本机终端
    // 跑的是 PowerShell 5.1，Set-Content 这类 cmdlet 若不在此登记就会被判成
    // safe，导致「只读档」在 Windows 上形同虚设（实测 Set-Content 直接写盘成功）。
    // 统一按 warn 处理：只读档拒绝、询问档确认、自动/全自动照常执行。
    _SafetyRule(
        RegExp(
            r'^(&\s*)?(set-content|add-content|out-file|new-item|remove-item|rename-item|move-item|copy-item|clear-content|set-itemproperty|new-itemproperty|remove-itemproperty|set-acl|icacls|takeown|robocopy|xcopy|attrib)\b',
            caseSensitive: false),
        '执行文件/目录写入、修改或删除操作，可能改变或丢失数据，请确认目标路径',
        'Writes, modifies, or deletes files/directories; data may be changed or lost — confirm the target path'),
    // PowerShell 重定向写文件：POSIX 的 `> file` 在本表里一直是 safe（只有
    // `> /etc/` 这类系统路径被拦），为不改动既有跨平台语义，这里不笼统拦
    // `>`，只拦显式写系统路径的盘符/绝对路径形式。
    _SafetyRule(
        RegExp(r'>>?\s*[A-Za-z]:[\\/][^\s|;]*', caseSensitive: false),
        '通过重定向写入磁盘文件，将覆盖或追加目标文件内容，请确认目标路径',
        'Redirects output into a disk file; overwrites or appends to the target — confirm the target path'),
    // CMD 系写操作（Windows 本机也可能被建议使用）
    _SafetyRule(
        RegExp(r'^(del|erase|rd|rmdir|move|copy|ren|rename|mkdir)\s+',
            caseSensitive: false),
        '执行文件/目录创建、移动、重命名或删除操作，可能改变或丢失数据，请确认目标路径',
        'Creates, moves, renames, or deletes files/directories; data may be changed or lost — confirm the target path'),
    // POSIX 通用写操作：只按“是否命中系统路径”判定会让普通 cp/mv/chmod
    // 落成 safe，只读档在 Linux/macOS 上对最常见的数据修改形同虚设。
    _SafetyRule(
        RegExp(r'^(sudo\s+)?(cp|mv)\s+'),
        '复制/移动文件或目录，可能覆盖目标路径的现有内容，请确认源和目标',
        'Copies/moves files or directories; may overwrite the destination — confirm source and target'),
    _SafetyRule(
        // -i 不一定紧跟 sed：`sed -E -i`、`sed -n -i`、`sed -e ... -i`、
        // `sudo -E sed -i` 都是原地改写。按“参数里出现 -i/--in-place”匹配。
        // 不锚定行首：`sudo -u root sed -i`、`LC_ALL=C sed -i`、`env X=1 sed -i`、
        // `bash -c 'sed -i ...'` 里 sed 都不是第一个 token，锚定会被绕过。
        RegExp(r'\bsed\b.*(\s-[a-zA-Z]*i[a-zA-Z]*\b|\s--in-place\b)'),
        '原地编辑文件（sed -i），会直接改写目标文件内容',
        'Edits a file in place (sed -i); rewrites the target file content directly'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?tee\s+'),
        '通过 tee 写入文件，会覆盖或追加目标文件内容，请确认目标路径',
        'Writes to a file via tee; overwrites or appends to the target — confirm the target path'),
    _SafetyRule(RegExp(r'^(sudo\s+)?chmod\s+'), '修改文件权限，可能影响服务的访问控制',
        'Changes file permissions; may affect service access control'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?chown\s+|^(sudo\s+)?chgrp\s+'),
        '修改文件所有者/所属组，可能影响服务的访问控制',
        'Changes file ownership/group; may affect service access control'),
    _SafetyRule(RegExp(r'^(sudo\s+)?touch\s+'), '创建文件或更新文件时间戳，可能改变目标路径状态',
        'Creates files or updates timestamps; may change the target path state'),
    _SafetyRule(RegExp(r'^(sudo\s+)?ln\s+'), '创建链接，可能覆盖已有路径或指向错误目标',
        'Creates links; may overwrite an existing path or point at the wrong target'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?dd\s+.*\bof=\S+'),
        '通过 dd 写入文件，会覆盖目标文件内容且不可恢复',
        'Writes to a file via dd; overwrites the target and cannot be undone'),
    // 文件/目录删除：任何形式的删除都不可恢复，必须让用户确认
    // （rm -rf / 等系统级删除已被 _blockRules 直接拦截，此处覆盖其余删除）
    _SafetyRule(RegExp(r'^(sudo\s+)?rm\s+'), '删除文件或目录，操作不可恢复，请确认目标路径',
        'Deletes files or directories; the change cannot be undone — confirm the target path'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?(unlink|shred)\s+'),
        '删除/粉碎文件，操作不可恢复，请确认目标路径',
        'Deletes/shreds files; the change cannot be undone — confirm the target path'),
    _SafetyRule(RegExp(r'\bfind\b.*\s-delete\b'), '批量删除匹配的文件，操作不可恢复，请确认匹配范围',
        'Bulk-deletes all matched files; the change cannot be undone — confirm the match scope'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?truncate\s+.*-s\s*0\b'),
        '清空文件内容，原数据不可恢复，请确认目标文件',
        'Truncates a file to zero bytes; the original content cannot be recovered — confirm the target file'),
    _SafetyRule(
        RegExp(r'^(sudo\s+)?truncate\s+'),
        '调整文件大小，可能截断或丢失原文件内容，请确认目标文件',
        'Resizes a file; may truncate or lose existing content — confirm the target file'),
    // 系统级操作
    _SafetyRule(
        RegExp(r'^sudo\s+(reboot|shutdown|halt|poweroff|init\s+)'),
        '关机/重启服务器，所有运行中的进程将终止，未保存数据丢失',
        'Shuts down or reboots the server; all running processes terminate and unsaved data is lost'),
    _SafetyRule(
        RegExp(r'^systemctl\s+(stop|disable)\s+ssh'),
        '停止/禁用 SSH 服务，将断开所有远程连接，可能导致无法再次远程登录',
        'Stops/disables the SSH service; drops all remote sessions and may lock you out of remote login'),
    _SafetyRule(
        RegExp(r'^(iptables|firewall-cmd|ufw).*(-F|--flush|--delete-chain)'),
        '清空防火墙规则，将影响网络安全策略',
        'Flushes firewall rules; changes the host network security policy'),
    _SafetyRule(RegExp(r'^fdisk\s+/'), '分区操作，错误的分区表修改可能导致磁盘数据丢失',
        'Partitioning operation; a wrong partition-table change can lose disk data'),
    _SafetyRule(
        RegExp(r'^mkfs\.(ext4|xfs|btrfs)\s+/dev/'),
        '格式化分区为文件系统，目标分区所有数据将被擦除',
        'Creates a filesystem on a partition; all data on the target partition will be erased'),
    _SafetyRule(RegExp(r'^dd\s+if=.*of=/dev/'), '直接写入块设备，将覆盖目标磁盘数据',
        'Writes directly to a block device; overwrites data on the target disk'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+/'), '递归删除系统目录，可能影响系统运行，不可恢复',
        'Recursively deletes a system directory; may break the running system and cannot be undone'),
    // 安装/升级/替换软件包
    _SafetyRule(
        RegExp(
            r'^sudo\s+(apt|apt-get)\s+(install|upgrade|dist-upgrade|remove|purge)\s+'),
        '安装/升级/卸载软件包，可能改变系统依赖关系，影响其他服务',
        'Installs/upgrades/removes packages; may change system dependencies and affect other services'),
    _SafetyRule(
        RegExp(r'^sudo\s+yum\s+(install|update|remove|erase)\s+'),
        '安装/更新/卸载软件包，可能改变系统依赖关系',
        'Installs/updates/removes packages; may change system dependencies'),
    _SafetyRule(
        RegExp(r'^sudo\s+dnf\s+(install|upgrade|remove)\s+'),
        '安装/升级/卸载软件包，可能改变系统依赖关系',
        'Installs/upgrades/removes packages; may change system dependencies'),
    _SafetyRule(RegExp(r'^sudo\s+apk\s+add\s+'), '安装软件包，可能改变系统配置',
        'Installs packages; may change system configuration'),
    _SafetyRule(RegExp(r'^sudo\s+pacman\s+-S\s+'), '安装软件包，可能改变系统依赖关系',
        'Installs packages; may change system dependencies'),
    _SafetyRule(RegExp(r'^sudo\s+snap\s+install\s+'), '安装 Snap 软件包',
        'Installs a Snap package'),
    // 修改环境配置
    _SafetyRule(
        RegExp(
            r'(>>|>)\s*(/etc/profile|/etc/environment|/etc/bashrc|~/\.bashrc|~/\.zshrc|~/\.bash_profile|~/\.profile)\s*$'),
        '修改 Shell 环境配置文件，可能影响所有用户的登录环境',
        'Modifies a shell environment config file; may affect the login environment of all users'),
    _SafetyRule(
        RegExp(
            r'^sudo\s+(tee|sed|echo.*>)\s+.*(/etc/profile|/etc/environment|/etc/bashrc)\s*$'),
        '修改系统级环境配置文件，可能影响所有用户',
        'Modifies a system-wide environment config file; may affect all users'),
    // alternatives/update-alternatives
    _SafetyRule(
        RegExp(r'^sudo\s+update-alternatives\s+--set\s+'),
        '修改系统默认程序指向，影响相关命令的默认版本',
        'Changes the system default program alternative; switches the default version of related commands'),
    _SafetyRule(RegExp(r'^sudo\s+alternatives\s+--set\s+'), '修改系统默认程序指向',
        'Changes the system default program alternative'),
    // 卸载操作
    _SafetyRule(
        RegExp(r'^sudo\s+(apt|apt-get)\s+(remove|purge|autoremove)\s+'),
        '卸载软件包，依赖该包的其他服务可能无法运行；purge 会同时删除配置文件',
        'Removes packages; services depending on them may fail to run — purge also deletes their config files'),
    _SafetyRule(RegExp(r'^sudo\s+yum\s+remove\s+'), '卸载软件包，依赖该包的其他服务可能无法运行',
        'Removes packages; services depending on them may fail to run'),
    _SafetyRule(RegExp(r'^sudo\s+dnf\s+remove\s+'), '卸载软件包，依赖该包的其他服务可能无法运行',
        'Removes packages; services depending on them may fail to run'),
    _SafetyRule(RegExp(r'^sudo\s+pacman\s+-R\s+'), '卸载软件包，依赖该包的其他服务可能无法运行',
        'Removes packages; services depending on them may fail to run'),
    // 源码编译安装
    _SafetyRule(RegExp(r'^sudo\s+make\s+install'), '源码编译安装到系统目录，可能覆盖系统已有的同名程序',
        'Installs a source build into system directories; may overwrite existing programs with the same names'),
    // 覆盖写入系统文件
    _SafetyRule(RegExp(r'^sudo\s+cp\s+.*\s+/etc/'), '复制文件到系统配置目录，可能覆盖现有配置',
        'Copies a file into the system config directory; may overwrite the existing configuration'),
    _SafetyRule(RegExp(r'^sudo\s+mv\s+.*\s+/etc/'), '移动文件到系统配置目录，可能覆盖现有配置',
        'Moves a file into the system config directory; may overwrite the existing configuration'),
  ];

  // 仅高亮提示的命令模式
  static final List<RegExp> _infoPatterns = [
    RegExp(r'curl\s+http'),
    RegExp(r'wget\s+http'),
    RegExp(r'git\s+clone'),
    RegExp(r'^(firewall-cmd|ufw|iptables).*port'),
    RegExp(r'^systemctl\s+(start|restart|reload)\s+'),
    RegExp(r'^service\s+\w+\s+(start|restart|reload)'),
    RegExp(r'^npm\s+install\s+-g'),
    RegExp(r'^pip\s+install\s+'),
    RegExp(r'^brew\s+install\s+'),
    RegExp(r'^sudo\s+(apt|apt-get)\s+update\s*$'),
    RegExp(r'^sudo\s+yum\s+makecache'),
    RegExp(r'^update-alternatives\s+--(list|display)\s+'),
    RegExp(r'^export\s+'),
  ];

  /// 检查命令安全等级（带缓存）
  static SafetyLevel check(String command) {
    if (_cache.containsKey(command)) {
      return _cache[command]!;
    }

    final result = _checkInternal(command);
    _cache[command] = result;
    if (_cache.length > 500) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  /// 内部检查逻辑：对完整命令的所有子命令分别检查，取最高危险等级
  static SafetyLevel _checkInternal(String command) {
    // 先对完整命令做一次检查（处理 fork 炸弹等本身含 | ; 字符的单条命令，
    // 这类命令会被 splitSubCommands 拆分导致无法匹配整体模式）
    final fullLevel = _checkSingle(command);
    if (fullLevel == SafetyLevel.blocked) return fullLevel;

    final subCommands = splitSubCommands(command);
    var maxLevel = SafetyLevel.safe;

    for (final sub in subCommands) {
      final cleaned = _removeComments(sub).trim();
      if (cleaned.isEmpty) continue;

      final level = _checkSingle(cleaned);
      if (_compareLevel(level, maxLevel) > 0) {
        maxLevel = level;
      }
      // 如果已经是 blocked，直接返回
      if (maxLevel == SafetyLevel.blocked) return maxLevel;
    }

    return maxLevel;
  }

  /// 检查单条命令（不含链式操作符）
  static SafetyLevel _checkSingle(String command) {
    // 命令规范化：防止通过空格变化、引号包裹等绕过安全检查
    final normalized = _normalizeCommand(command);
    for (final rule in _blockRules) {
      if (rule.pattern.hasMatch(normalized)) {
        return SafetyLevel.blocked;
      }
    }
    for (final rule in _warnRules) {
      if (rule.pattern.hasMatch(normalized)) {
        return SafetyLevel.warn;
      }
    }
    for (final pattern in _infoPatterns) {
      if (pattern.hasMatch(normalized)) {
        return SafetyLevel.info;
      }
    }
    return SafetyLevel.safe;
  }

  /// 命令规范化：去除常见绕过手法
  /// - 合并多余空格
  /// - 去除命令名周围的引号（如 "rm" → rm）
  /// - 去除反斜杠转义（如 r\m → rm）
  static String _normalizeCommand(String command) {
    var cmd = command.trim();
    // 剥掉解释器外壳后再判定：`powershell -Command "Set-Content ..."` 的真实
    // 动作是 Set-Content，若按外层 powershell 判定就永远命不中 cmdlet 规则。
    // 循环几次以覆盖嵌套调用。
    for (var i = 0; i < 3; i++) {
      final unwrapped = _unwrapInterpreter(cmd);
      if (unwrapped == cmd) break;
      cmd = unwrapped.trim();
    }
    // 去除命令名周围的引号：匹配开头的 "xxx" 或 'xxx" 并去除引号
    // 注意：replaceFirst 不支持 $1 反向引用，必须用 replaceFirstMapped
    cmd = cmd.replaceFirstMapped(
      RegExp(r'''^["\']([a-zA-Z_][\w.-]*)["\']'''),
      (m) => m.group(1)!,
    );
    // 去除反斜杠转义：r\m → rm（仅命令名部分）
    cmd = cmd.replaceFirstMapped(
      RegExp(r'^([a-zA-Z])(\\)([a-zA-Z])'),
      (m) => '${m.group(1)}${m.group(3)}',
    );
    // 合并多余空格
    cmd = cmd.replaceAll(RegExp(r'\s{2,}'), ' ');
    return cmd;
  }

  /// 去掉 `powershell|pwsh ... -Command "..."` / `cmd /c "..."` 外壳，
  /// 返回真正被执行的命令；无法识别时原样返回。
  static String _unwrapInterpreter(String cmd) {
    final ps = RegExp(r'^(?:powershell|pwsh)(?:\.exe)?\s+(.+)$',
            caseSensitive: false, dotAll: true)
        .firstMatch(cmd);
    if (ps != null) {
      final rest = ps.group(1)!;
      final flag =
          RegExp('(?:^|\\s)-(?:command|c)(?=\\s|["\'])', caseSensitive: false)
              .firstMatch(rest);
      if (flag != null) {
        return _stripOuterQuotes(rest.substring(flag.end).trim());
      }
      return cmd;
    }
    final cmdExe = RegExp(r'^cmd(?:\.exe)?\s+/c\s+(.+)$',
            caseSensitive: false, dotAll: true)
        .firstMatch(cmd);
    if (cmdExe != null) {
      return _stripOuterQuotes(cmdExe.group(1)!.trim());
    }
    return cmd;
  }

  static String _stripOuterQuotes(String s) {
    if (s.length < 2) return s;
    final first = s[0];
    final last = s[s.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  /// 获取命令的风险说明（人类可读的具体原因，按当前 UI 语言）
  /// 返回命中的第一条规则的说明；未命中返回 null
  static String? getReason(String command) =>
      _matchReasonRule(command)?.textFor(UiText.zh);

  /// 风险说明的规范中文串：ReAct observation 会把该文案原样喂回模型，
  /// 语言不跟随 UI（见 R2：喂给模型的规范串保持中文，只在用户事件里本地化）
  static String? getReasonZh(String command) =>
      _matchReasonRule(command)?.reason;

  /// 命中规则查询（带缓存）：缓存规则对象本身，语言在读取点选择
  static _SafetyRule? _matchReasonRule(String command) {
    if (_reasonCache.containsKey(command)) {
      return _reasonCache[command];
    }
    _SafetyRule? matched;

    // 先对完整命令做一次检查（处理 fork 炸弹等本身含 | ; 字符的单条命令）
    final fullNormalized = _normalizeCommand(command);
    for (final rule in _blockRules) {
      if (rule.pattern.hasMatch(fullNormalized)) {
        matched = rule;
        break;
      }
    }
    if (matched == null) {
      for (final rule in _warnRules) {
        if (rule.pattern.hasMatch(fullNormalized)) {
          matched = rule;
          break;
        }
      }
    }

    // 如果完整命令未命中，再逐条检查拆分后的子命令
    if (matched == null) {
      final subCommands = splitSubCommands(command);
      for (final sub in subCommands) {
        final cleaned = _removeComments(sub).trim();
        if (cleaned.isEmpty) continue;
        final normalized = _normalizeCommand(cleaned);
        // 先查 block 规则
        for (final rule in _blockRules) {
          if (rule.pattern.hasMatch(normalized)) {
            matched = rule;
            break;
          }
        }
        if (matched != null) break;
        // 再查 warn 规则
        for (final rule in _warnRules) {
          if (rule.pattern.hasMatch(normalized)) {
            matched = rule;
            break;
          }
        }
        if (matched != null) break;
      }
    }
    _reasonCache[command] = matched;
    if (_reasonCache.length > 500) {
      _reasonCache.remove(_reasonCache.keys.first);
    }
    return matched;
  }

  /// heredoc 起始标记：<<-? 空白? 引号? TAG 引号?（反向引用保证引号配对）
  static final RegExp _heredocStartPattern =
      RegExp(r'''<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1''');

  /// 拆分链式命令：按 && || ; | 与换行分割，返回所有子命令（含空段，调用方自行过滤）。
  /// 引号感知：单/双引号内的操作符不拆分，反斜杠转义的字符不参与匹配。
  /// heredoc（<<EOF / <<'EOF' / <<-EOF）的内容与起始行保持整体，不按行拆开——
  /// heredoc 是单条写文件命令，内容行不是独立子命令。
  /// 注意：不处理 $() 和反引号内的内容（保守处理，宁可误报也不漏报）
  static List<String> splitSubCommands(String command) {
    final results = <String>[];
    final buf = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    String? heredocTag;
    String? pendingHeredocTag;

    for (final line in command.split('\n')) {
      if (heredocTag != null) {
        buf.write('\n');
        buf.write(line);
        if (line.trim() == heredocTag) {
          heredocTag = null;
          results.add(buf.toString());
          buf.clear();
        }
        continue;
      }

      for (int i = 0; i < line.length; i++) {
        final c = line[i];
        if (c == "'" && !inDouble) {
          inSingle = !inSingle;
          buf.write(c);
          continue;
        }
        if (c == '"' && !inSingle) {
          inDouble = !inDouble;
          buf.write(c);
          continue;
        }
        if (c == '\\' && !inSingle && i + 1 < line.length) {
          buf.write(c);
          buf.write(line[i + 1]);
          i++;
          continue;
        }
        if (!inSingle && !inDouble) {
          if (c == ';' || c == '|') {
            results.add(buf.toString());
            buf.clear();
            if (c == '|' && i + 1 < line.length && line[i + 1] == '|') i++;
            continue;
          }
          if (c == '&' && i + 1 < line.length && line[i + 1] == '&') {
            results.add(buf.toString());
            buf.clear();
            i++;
            continue;
          }
          if (c == '<' &&
              i + 1 < line.length &&
              line[i + 1] == '<' &&
              (i == 0 || line[i - 1] != '<') &&
              (i + 2 >= line.length || line[i + 2] != '<')) {
            final m = _heredocStartPattern.matchAsPrefix(line, i);
            // 起始标记后必须跟行尾/空白/分隔符，排除 $((1<<2)) 这类算术移位
            if (m != null &&
                (m.end == line.length || ' \t;|&'.contains(line[m.end]))) {
              pendingHeredocTag = m.group(2);
              buf.write(m.group(0));
              i = m.end - 1;
              continue;
            }
          }
        }
        buf.write(c);
      }

      if (pendingHeredocTag != null) {
        heredocTag = pendingHeredocTag;
        pendingHeredocTag = null;
      } else {
        results.add(buf.toString());
        buf.clear();
      }
    }
    // 未闭合的 heredoc：剩余内容整体作为一段
    if (buf.isNotEmpty) results.add(buf.toString());
    return results;
  }

  /// 是否包含引号外、未转义的指定操作符（如 &&）。用于 shell 语法兼容提示。
  static bool containsUnquotedOperator(String command, String operator) {
    var inSingle = false;
    var inDouble = false;
    for (int i = 0; i < command.length; i++) {
      final c = command[i];
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if (c == '\\' && !inSingle && i + 1 < command.length) {
        i++;
        continue;
      }
      if (!inSingle && !inDouble && command.startsWith(operator, i)) {
        return true;
      }
    }
    return false;
  }

  /// 移除行内注释（# 之后的内容，但不是 #! 且不在引号内）
  static String _removeComments(String command) {
    // 简化处理：扫描 # 之前的内容，跳过引号内的 #
    final chars = command.codeUnits;
    bool inSingle = false;
    bool inDouble = false;
    for (int i = 0; i < chars.length; i++) {
      final c = chars[i];
      if (c == 0x27 && !inDouble) {
        inSingle = !inSingle; // '
      } else if (c == 0x22 && !inSingle) {
        inDouble = !inDouble; // "
      } else if (c == 0x23 && !inSingle && !inDouble) {
        // #
        // # 前需有空格或位于行首才算注释
        if (i == 0 || chars[i - 1] == 0x20) {
          return command.substring(0, i);
        }
      }
    }
    return command;
  }

  /// 比较安全等级：blocked > warn > info > safe
  static int _compareLevel(SafetyLevel a, SafetyLevel b) {
    const order = [
      SafetyLevel.safe,
      SafetyLevel.info,
      SafetyLevel.warn,
      SafetyLevel.blocked
    ];
    return order.indexOf(a) - order.indexOf(b);
  }

  /// 获取提示文案（简短，用于状态标签，按当前 UI 语言）
  static String getTip(SafetyLevel level) {
    switch (level) {
      case SafetyLevel.safe:
        return UiText.t('安全命令', 'Safe command');
      case SafetyLevel.info:
        return UiText.t('此操作涉及系统配置或网络下载，请确认操作',
            'This touches system configuration or downloads from the network — please confirm');
      case SafetyLevel.warn:
        return UiText.t('危险操作，请仔细确认后再执行',
            'Risky operation — review and confirm carefully before running');
      case SafetyLevel.blocked:
        return UiText.t('高危操作，已被安全策略拦截',
            'High-risk operation; blocked by the safety policy');
    }
  }

  /// getTip 的规范中文版：ReAct observation 会原样喂回模型，
  /// 必须固定中文、不跟随 UI 语言（与 getReasonZh 同一约定）
  static String getTipZh(SafetyLevel level) {
    switch (level) {
      case SafetyLevel.safe:
        return '安全命令';
      case SafetyLevel.info:
        return '此操作涉及系统配置或网络下载，请确认操作';
      case SafetyLevel.warn:
        return '危险操作，请仔细确认后再执行';
      case SafetyLevel.blocked:
        return '高危操作，已被安全策略拦截';
    }
  }

  /// 是否需要二次确认
  static bool requireConfirm(SafetyLevel level) {
    return level == SafetyLevel.warn || level == SafetyLevel.blocked;
  }

  // ════════════════════════════════════════════════════════════════
  // 路径安全检查（用于本地项目分析/构建/打包工具）
  // ════════════════════════════════════════════════════════════════

  /// 全局路径黑名单（绝对路径前缀，永远禁止访问）
  /// 用于防止 AI 读取 SSH 私钥、系统配置、root 目录等敏感位置
  static const List<String> _blockedPathPrefixes = [
    '/etc',
    '/root',
    '/var/log',
    '/proc',
    '/sys',
    '/dev',
    '/boot',
    '/srv',
    '/run',
    '/usr/local/etc',
  ];

  /// 敏感文件名模式（黑名单，永远禁止读取）
  static final List<RegExp> _blockedFilePatterns = [
    RegExp(r'^id_rsa$'),
    RegExp(r'^id_rsa\.pub$'),
    RegExp(r'^id_ed25519$'),
    RegExp(r'^id_ed25519\.pub$'),
    RegExp(r'^id_ecdsa$'),
    RegExp(r'^id_dsa$'),
    RegExp(r'\.key$'),
    RegExp(r'\.pem$'),
    RegExp(r'^credentials(\.json|\.yaml|\.yml)?$'),
    // 普通 .env 才是最常见的密钥文件；原来只挡了 .env.production/.prod/.local
    RegExp(r'^\.env$'),
    RegExp(r'^\.env\..+$'),
    RegExp(r'^shadow$'),
    RegExp(r'^passwd$'),
    RegExp(r'^\.netrc$'),
    RegExp(r'^\.htpasswd$'),
  ];

  /// 敏感目录名（路径分段匹配，黑名单）
  static const List<String> _blockedDirNames = [
    '.ssh',
    '.gnupg',
    '.aws',
    '.docker',
    '.kube',
  ];

  /// 用户主目录下的敏感路径（运行时拼接 $HOME）
  static const List<String> _homeBlockedSuffixes = [
    '.ssh',
    '.gnupg',
    '.aws',
    '.docker',
    '.kube',
    '.config/google-chrome',
    '.config/Code',
    '.password-store',
  ];

  /// 检查路径安全性
  ///
  /// [path] 待检查的路径（绝对路径）
  /// [projectRoot] 可选：用户授权的项目根目录，在项目内视为安全
  /// [isWrite] 是否为写操作（写操作更严格）
  ///
  /// 返回 PathSafetyResult，包含等级和说明
  static PathSafetyResult checkPath(String path,
      {String? projectRoot, bool isWrite = false}) {
    if (path.isEmpty) {
      return PathSafetyResult(
          SafetyLevel.warn, UiText.t('路径为空', 'Path is empty'));
    }

    // 规范化路径（去尾斜杠、合并重复斜杠）
    final normalized = _normalizePath(path);
    if (normalized.isEmpty) {
      return PathSafetyResult(SafetyLevel.warn,
          UiText.t('路径规范化后为空', 'Path is empty after normalization'));
    }

    // 1. 检查是否在项目根目录内（最高优先级白名单）
    if (projectRoot != null && projectRoot.isNotEmpty) {
      final root = _normalizePath(projectRoot);
      if (_isPathWithin(normalized, root)) {
        // 项目内：检查是否命中文件名/目录黑名单
        final fileName = normalized.split('/').last;
        for (final pattern in _blockedFilePatterns) {
          if (pattern.hasMatch(fileName)) {
            return PathSafetyResult(
                SafetyLevel.blocked, L10n.str.ut_e275b00675(fileName));
          }
        }
        // 检查路径分段是否含敏感目录名
        for (final segment in normalized.split('/')) {
          if (_blockedDirNames.contains(segment)) {
            return PathSafetyResult(
                SafetyLevel.blocked, L10n.str.ut_3ae63b10aa(segment));
          }
        }
        return const PathSafetyResult(SafetyLevel.safe, null);
      }
    }

    // 2. 检查全局路径黑名单前缀
    for (final prefix in _blockedPathPrefixes) {
      if (normalized == prefix || normalized.startsWith('$prefix/')) {
        return PathSafetyResult(
            SafetyLevel.blocked, L10n.str.ut_5b6668af25(prefix));
      }
    }

    // 3. 检查用户主目录下的敏感路径
    final home = _getHomeDir();
    if (home != null) {
      for (final suffix in _homeBlockedSuffixes) {
        final sensitivePath = '$home/$suffix';
        if (normalized == sensitivePath ||
            normalized.startsWith('$sensitivePath/')) {
          return PathSafetyResult(
              SafetyLevel.blocked, L10n.str.ut_337b92f903(suffix));
        }
      }
      // 直接读 ~/.ssh/id_rsa 这种情况已被上面覆盖
    }

    // 4. 检查文件名黑名单（项目外也要查）
    final fileName = normalized.split('/').last;
    for (final pattern in _blockedFilePatterns) {
      if (pattern.hasMatch(fileName)) {
        return PathSafetyResult(
            SafetyLevel.blocked, L10n.str.ut_0c25c4bff1(fileName));
      }
    }

    // 5. 检查路径分段中的敏感目录
    for (final segment in normalized.split('/')) {
      if (_blockedDirNames.contains(segment)) {
        return PathSafetyResult(
            SafetyLevel.blocked, L10n.str.ut_fffc2d39d8(segment));
      }
    }

    // 6. 项目外的路径需确认（防止 AI 乱跑）
    return PathSafetyResult(
      SafetyLevel.warn,
      L10n.str.ut_61f32e7e81(normalized),
    );
  }

  /// 路径规范化：合并重复斜杠、去尾斜杠、解析 . 和 ..
  static String _normalizePath(String path) {
    var p = path.replaceAll(RegExp(r'\\'), '/'); // Windows 路径转 POSIX
    p = p.replaceAll(RegExp(r'/+'), '/'); // 合并重复斜杠
    // 简单解析 . 和 ..
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    final result = segments.join('/');
    return path.startsWith('/') ? '/$result' : result;
  }

  /// 判断 path 是否在 root 目录内（规范化后的路径）
  static bool _isPathWithin(String path, String root) {
    if (path == root) return true;
    return path.startsWith('$root/');
  }

  /// 获取用户主目录（用于检查 ~/.ssh 等）
  static String? _getHomeDir() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return home != null ? _normalizePath(home) : null;
  }

  /// 检查路径是否允许读取（综合判断，给工具层用）
  /// [path] 待读取路径
  /// [projectRoot] 项目根目录
  /// [sourceCodeGranted] 是否已获得源码读取授权（会话级）
  static PathSafetyResult checkReadPath(
    String path, {
    String? projectRoot,
    bool sourceCodeGranted = false,
  }) {
    final result = checkPath(path, projectRoot: projectRoot, isWrite: false);
    // blocked 永远不允许
    if (result.level == SafetyLevel.blocked) return result;
    // safe 直接放行
    if (result.level == SafetyLevel.safe) return result;
    // warn：若已授权则放行，否则需确认
    if (sourceCodeGranted) {
      return const PathSafetyResult(SafetyLevel.safe, null);
    }
    return result;
  }
}
