import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ssh_service.dart';
import 'local_terminal_service.dart';

/// 单次采集到的服务器快照
class ServerSnapshot {
  /// 0.0 ~ 100.0
  final double cpuPercent;

  /// 0.0 ~ 100.0（已用百分比）
  final double memPercent;

  /// 已用内存（MB）
  final double memUsedMB;

  /// 总内存（MB）
  final double memTotalMB;

  /// 0.0 ~ 100.0（根分区已用百分比）
  final double diskPercent;

  /// 网络上行速率（KB/s）
  final double netUpKBps;

  /// 网络下行速率（KB/s）
  final double netDownKBps;

  /// 当前登录用户数
  final int userCount;

  /// 开机时长（人类可读，如 "3 days, 02:15"）
  final String uptime;

  /// 采集时间戳
  final DateTime timestamp;

  /// 错误信息（采集失败时填充）
  final String? error;

  const ServerSnapshot({
    this.cpuPercent = 0,
    this.memPercent = 0,
    this.memUsedMB = 0,
    this.memTotalMB = 0,
    this.diskPercent = 0,
    this.netUpKBps = 0,
    this.netDownKBps = 0,
    this.userCount = 0,
    this.uptime = '-',
    required this.timestamp,
    this.error,
  });

  ServerSnapshot copyWithError(String e) => ServerSnapshot(
        cpuPercent: cpuPercent,
        memPercent: memPercent,
        memUsedMB: memUsedMB,
        memTotalMB: memTotalMB,
        diskPercent: diskPercent,
        netUpKBps: netUpKBps,
        netDownKBps: netDownKBps,
        userCount: userCount,
        uptime: uptime,
        timestamp: timestamp,
        error: e,
      );
}

/// 服务器监控采集器
///
/// 通过 SSHService.runOnce 或 LocalTerminalService.runOnce 周期性采集
/// CPU/内存/磁盘/网络/用户/开机时间，维护历史数据环形缓冲供折线图使用。
class ServerMonitorService {
  /// 执行器（SSHService 或 LocalTerminalService）
  final dynamic executor;

  /// 是否为本地终端
  final bool isLocal;

  /// 历史数据点（最多保留 [_maxHistory] 个）
  final List<ServerSnapshot> _history = [];
  static const int _maxHistory = 60; // 5s × 60 = 5 分钟历史

  /// 上一次网络字节（用于计算速率）
  int? _lastNetRxBytes;
  int? _lastNetTxBytes;
  DateTime? _lastNetTime;

  /// 是否正在采集（重入保护）
  bool _isCollecting = false;

  ServerMonitorService({required this.executor, required this.isLocal});

  List<ServerSnapshot> get history => List.unmodifiable(_history);

  /// 当前是否可采集
  bool get canCollect {
    if (executor == null) return false;
    try {
      return (executor as dynamic).isConnected as bool;
    } catch (_) {
      return false;
    }
  }

  /// 采集一次快照
  ///
  /// 通过合并多条命令到一次 runOnce 调用减少 RTT。
  /// Linux/macOS 用 `;` 串联并加分隔符；Windows 用 PowerShell 分步采集。
  Future<ServerSnapshot> collect() async {
    if (_isCollecting) {
      // 上一次还没结束，返回上一次快照或空快照
      return _history.isNotEmpty
          ? _history.last
          : ServerSnapshot(timestamp: DateTime.now(), error: '采集进行中');
    }
    _isCollecting = true;
    try {
      if (!canCollect) {
        return ServerSnapshot(timestamp: DateTime.now(), error: '未连接');
      }
      final snap = isLocal
          ? await _collectLocal()
          : await _collectRemote();
      _pushHistory(snap);
      return snap;
    } catch (e) {
      final errSnap = ServerSnapshot(timestamp: DateTime.now(), error: '$e');
      _pushHistory(errSnap);
      return errSnap;
    } finally {
      _isCollecting = false;
    }
  }

  void _pushHistory(ServerSnapshot snap) {
    _history.add(snap);
    if (_history.length > _maxHistory) {
      _history.removeRange(0, _history.length - _maxHistory);
    }
  }

  /// 重置历史数据（切换 host 或断开重连时调用）
  void reset() {
    _history.clear();
    _lastNetRxBytes = null;
    _lastNetTxBytes = null;
    _lastNetTime = null;
  }

  // ==================== 远程（SSH）采集 ====================

  Future<ServerSnapshot> _collectRemote() async {
    final ssh = executor as SSHService;
    // 判断远端平台（osInfo 形如 "Linux x86_64" / "Darwin arm64"）
    final osInfo = ssh.osInfo.toLowerCase();
    if (osInfo.contains('linux')) {
      return _collectLinux(ssh);
    } else if (osInfo.contains('darwin')) {
      return _collectMacOS(ssh);
    } else {
      // 兜底：尝试 Linux 命令
      return _collectLinux(ssh);
    }
  }

  /// Linux 采集：用分隔符一次性取所有指标，减少 RTT
  Future<ServerSnapshot> _collectLinux(SSHService ssh) async {
    // 一次执行多条命令，用 @@ 分隔输出
    final script = [
      'echo @@CPU@@',
      "top -bn1 | grep 'Cpu(s)' | awk -F',' '{print \$4}' | awk '{print 100-\$1}'",
      'echo @@MEM@@',
      "free -m | awk '/Mem:/ {print \$3, \$2, \$3/\$2*100}'",
      'echo @@DISK@@',
      "df -P / | awk 'NR==2 {print \$5}' | tr -d '%'",
      'echo @@NET@@',
      "cat /proc/net/dev | awk 'NR>2 {rx+=\$2; tx+=\$10} END {print rx, tx}'",
      'echo @@USER@@',
      "who | wc -l",
      'echo @@UPTIME@@',
      "uptime -p 2>/dev/null || uptime | sed 's/.*up /up /'",
      'echo @@END@@',
    ].join('; ');

    final out = await ssh.runOnce(script, timeout: const Duration(seconds: 8));
    return _parseLinuxOutput(out);
  }

  ServerSnapshot _parseLinuxOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: '采集输出为空');
    }

    double cpu = 0, memUsed = 0, memTotal = 0, memPercent = 0, diskPercent = 0;
    int netRx = 0, netTx = 0;
    int userCount = 0;
    String uptime = '-';

    try {
      // 按 @@SECTION@@ 切分
      final sections = <String, String>{};
      String? currentSection;
      for (final line in raw.split('\n')) {
        final m = RegExp(r'^@@(\w+)@@$').firstMatch(line.trim());
        if (m != null) {
          currentSection = m.group(1);
          sections[currentSection!] = '';
        } else if (currentSection != null) {
          final existing = sections[currentSection!] ?? '';
          sections[currentSection!] = existing.isEmpty ? line : '$existing\n$line';
        }
      }

      // CPU：%idle → 100-idle = used
      final cpuRaw = sections['CPU']?.trim() ?? '';
      final cpuMatch = RegExp(r'([\d.]+)').firstMatch(cpuRaw);
      if (cpuMatch != null) {
        final idle = double.tryParse(cpuMatch.group(1)!) ?? 100;
        cpu = (100 - idle).clamp(0, 100);
      }

      // MEM：used total percent
      final memRaw = sections['MEM']?.trim() ?? '';
      final memParts = memRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (memParts.length >= 3) {
        memUsed = double.tryParse(memParts[0]) ?? 0;
        memTotal = double.tryParse(memParts[1]) ?? 0;
        memPercent = double.tryParse(memParts[2]) ?? 0;
      }

      // DISK：根分区已用百分比
      final diskRaw = sections['DISK']?.trim() ?? '';
      diskPercent = double.tryParse(diskRaw) ?? 0;

      // NET：rx tx（累计字节）
      final netRaw = sections['NET']?.trim() ?? '';
      final netParts = netRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (netParts.length >= 2) {
        netRx = int.tryParse(netParts[0]) ?? 0;
        netTx = int.tryParse(netParts[1]) ?? 0;
      }

      // USER
      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

      // UPTIME
      uptime = sections['UPTIME']?.trim() ?? '-';
      if (uptime.isEmpty) uptime = '-';
    } catch (e) {
      debugPrint('[Monitor] Linux 解析失败: $e');
    }

    final (netUp, netDown) = _computeNetRate(netRx, netTx, now);

    return ServerSnapshot(
      cpuPercent: cpu,
      memPercent: memPercent,
      memUsedMB: memUsed,
      memTotalMB: memTotal,
      diskPercent: diskPercent,
      netUpKBps: netUp,
      netDownKBps: netDown,
      userCount: userCount,
      uptime: uptime,
      timestamp: now,
    );
  }

  /// macOS 采集（远端为 macOS 时）
  Future<ServerSnapshot> _collectMacOS(SSHService ssh) async {
    final script = [
      'echo @@CPU@@',
      "top -l 1 -n 0 | grep 'CPU usage' | awk -F'[, ]+' '{for(i=1;i<=NF;i++) if(\$i==\"user\") print \$(i+1)}'",
      'echo @@MEM@@',
      "vm_stat | awk '/Pages free/ {free=\$3} /Pages active/ {active=\$3} /Pages wired/ {wired=\$3} /Pages occupied by compressor/ {comp=\$5} END {print active, free, wired, comp}'",
      'echo @@MEMSIZE@@',
      'sysctl -n hw.memsize',
      'echo @@DISK@@',
      "df -P / | awk 'NR==2 {print \$5}' | tr -d '%'",
      'echo @@NET@@',
      "netstat -ib | awk '/en0/ && /Link/ {rx+=\$7; tx+=\$10} END {print rx, tx}'",
      'echo @@USER@@',
      'who | wc -l',
      'echo @@UPTIME@@',
      'uptime | sed "s/.*up /up /" | sed "s/,.*//"',
      'echo @@END@@',
    ].join('; ');

    final out = await ssh.runOnce(script, timeout: const Duration(seconds: 10));
    return _parseMacOSOutput(out);
  }

  ServerSnapshot _parseMacOSOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: '采集输出为空');
    }

    double cpu = 0, memPercent = 0, memUsedMB = 0, memTotalMB = 0, diskPercent = 0;
    int netRx = 0, netTx = 0;
    int userCount = 0;
    String uptime = '-';

    try {
      final sections = <String, String>{};
      String? currentSection;
      for (final line in raw.split('\n')) {
        final m = RegExp(r'^@@(\w+)@@$').firstMatch(line.trim());
        if (m != null) {
          currentSection = m.group(1);
          sections[currentSection!] = '';
        } else if (currentSection != null) {
          final existing = sections[currentSection!] ?? '';
          sections[currentSection!] = existing.isEmpty ? line : '$existing\n$line';
        }
      }

      // CPU：macOS top -l 1 输出 CPU usage: 8% user, 20% sys, 71% idle
      final cpuRaw = sections['CPU']?.trim() ?? '';
      // 取 % 数字
      final cpuMatch = RegExp(r'([\d.]+)').firstMatch(cpuRaw);
      if (cpuMatch != null) {
        final userCpu = double.tryParse(cpuMatch.group(1)!) ?? 0;
        cpu = userCpu.clamp(0, 100);
      }

      // MEM：vm_stat pages
      final memRaw = sections['MEM']?.trim() ?? '';
      final memParts = memRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      // macOS pages 单位是 4096 字节
      const pageSize = 4096;
      double active = 0, wired = 0, comp = 0;
      if (memParts.length >= 4) {
        active = double.tryParse(memParts[0].replaceAll('.', '')) ?? 0;
        wired = double.tryParse(memParts[2].replaceAll('.', '')) ?? 0;
        comp = double.tryParse(memParts[3].replaceAll('.', '')) ?? 0;
      }
      // 已用 = active + wired + comp（不含 free）
      final usedBytes = (active + wired + comp) * pageSize;
      final memSizeRaw = sections['MEMSIZE']?.trim() ?? '0';
      final totalBytes = double.tryParse(memSizeRaw) ?? 0;
      memTotalMB = totalBytes / (1024 * 1024);
      memUsedMB = usedBytes / (1024 * 1024);
      if (totalBytes > 0) {
        memPercent = (usedBytes / totalBytes * 100).clamp(0, 100);
      }

      // DISK
      final diskRaw = sections['DISK']?.trim() ?? '';
      diskPercent = double.tryParse(diskRaw) ?? 0;

      // NET
      final netRaw = sections['NET']?.trim() ?? '';
      final netParts = netRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (netParts.length >= 2) {
        netRx = int.tryParse(netParts[0]) ?? 0;
        netTx = int.tryParse(netParts[1]) ?? 0;
      }

      // USER
      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

      // UPTIME
      uptime = sections['UPTIME']?.trim() ?? '-';
      if (uptime.isEmpty) uptime = '-';
    } catch (e) {
      debugPrint('[Monitor] macOS 解析失败: $e');
    }

    final (netUp, netDown) = _computeNetRate(netRx, netTx, now);

    return ServerSnapshot(
      cpuPercent: cpu,
      memPercent: memPercent,
      memUsedMB: memUsedMB,
      memTotalMB: memTotalMB,
      diskPercent: diskPercent,
      netUpKBps: netUp,
      netDownKBps: netDown,
      userCount: userCount,
      uptime: uptime,
      timestamp: now,
    );
  }

  // ==================== 本地采集 ====================

  Future<ServerSnapshot> _collectLocal() async {
    final local = executor as LocalTerminalService;
    if (Platform.isWindows) {
      return _collectWindowsLocal(local);
    } else if (Platform.isMacOS) {
      return _collectMacOSLocal(local);
    } else {
      return _collectLinuxLocal(local);
    }
  }

  Future<ServerSnapshot> _collectLinuxLocal(LocalTerminalService local) async {
    final script = [
      'echo @@CPU@@',
      "top -bn1 | grep 'Cpu(s)' | awk -F',' '{print \$4}' | awk '{print 100-\$1}'",
      'echo @@MEM@@',
      "free -m | awk '/Mem:/ {print \$3, \$2, \$3/\$2*100}'",
      'echo @@DISK@@',
      "df -P / | awk 'NR==2 {print \$5}' | tr -d '%'",
      'echo @@NET@@',
      "cat /proc/net/dev | awk 'NR>2 {rx+=\$2; tx+=\$10} END {print rx, tx}'",
      'echo @@USER@@',
      "who | wc -l",
      'echo @@UPTIME@@',
      "uptime -p 2>/dev/null || uptime | sed 's/.*up /up /'",
      'echo @@END@@',
    ].join('; ');

    final out = await local.runOnce(script, timeout: const Duration(seconds: 8));
    return _parseLinuxOutput(out);
  }

  Future<ServerSnapshot> _collectMacOSLocal(LocalTerminalService local) async {
    final script = [
      'echo @@CPU@@',
      "top -l 1 -n 0 | grep 'CPU usage' | awk -F'[, ]+' '{for(i=1;i<=NF;i++) if(\$i==\"user\") print \$(i+1)}'",
      'echo @@MEM@@',
      "vm_stat | awk '/Pages free/ {free=\$3} /Pages active/ {active=\$3} /Pages wired/ {wired=\$3} /Pages occupied by compressor/ {comp=\$5} END {print active, free, wired, comp}'",
      'echo @@MEMSIZE@@',
      'sysctl -n hw.memsize',
      'echo @@DISK@@',
      "df -P / | awk 'NR==2 {print \$5}' | tr -d '%'",
      'echo @@NET@@',
      "netstat -ib | awk '/en0/ && /Link/ {rx+=\$7; tx+=\$10} END {print rx, tx}'",
      'echo @@USER@@',
      'who | wc -l',
      'echo @@UPTIME@@',
      'uptime | sed "s/.*up /up /" | sed "s/,.*//"',
      'echo @@END@@',
    ].join('; ');

    final out = await local.runOnce(script, timeout: const Duration(seconds: 10));
    return _parseMacOSOutput(out);
  }

  Future<ServerSnapshot> _collectWindowsLocal(LocalTerminalService local) async {
    // Windows 用 PowerShell 分别采集（合并到一次 runOnce）
    final ps = r'''
echo @@CPU@@
wmic cpu get loadpercentage /value | findstr LoadPercentage
echo @@MEM@@
wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value | findstr =
echo @@DISK@@
wmic logicaldisk where "DeviceID='C:'" get FreeSpace,Size /value | findstr =
echo @@USER@@
query user | find /c ">"
echo @@UPTIME@@
wmic os get LastBootUpTime /value | findstr =
echo @@END@@
''';
    final out = await local.runOnce('powershell -Command "$ps"', timeout: const Duration(seconds: 12));
    return _parseWindowsOutput(out);
  }

  ServerSnapshot _parseWindowsOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: '采集输出为空');
    }

    double cpu = 0, memPercent = 0, memUsedMB = 0, memTotalMB = 0, diskPercent = 0;
    int userCount = 0;
    String uptime = '-';

    try {
      final sections = <String, String>{};
      String? currentSection;
      for (final line in raw.split('\n')) {
        final m = RegExp(r'^@@(\w+)@@$').firstMatch(line.trim());
        if (m != null) {
          currentSection = m.group(1);
          sections[currentSection!] = '';
        } else if (currentSection != null) {
          final existing = sections[currentSection!] ?? '';
          sections[currentSection!] = existing.isEmpty ? line : '$existing\n$line';
        }
      }

      // CPU：LoadPercentage=12
      final cpuRaw = sections['CPU']?.trim() ?? '';
      final cpuMatch = RegExp(r'LoadPercentage=(\d+)').firstMatch(cpuRaw);
      if (cpuMatch != null) {
        cpu = double.tryParse(cpuMatch.group(1)!) ?? 0;
      }

      // MEM：FreePhysicalMemory=123456 TotalVisibleMemorySize=9876543（KB）
      final memRaw = sections['MEM']?.trim() ?? '';
      final freeMatch = RegExp(r'FreePhysicalMemory=(\d+)').firstMatch(memRaw);
      final totalMatch = RegExp(r'TotalVisibleMemorySize=(\d+)').firstMatch(memRaw);
      if (freeMatch != null && totalMatch != null) {
        final freeKB = double.tryParse(freeMatch.group(1)!) ?? 0;
        final totalKB = double.tryParse(totalMatch.group(1)!) ?? 0;
        memTotalMB = totalKB / 1024;
        memUsedMB = (totalKB - freeKB) / 1024;
        if (totalKB > 0) {
          memPercent = ((totalKB - freeKB) / totalKB * 100).clamp(0, 100);
        }
      }

      // DISK：C: FreeSpace Size
      final diskRaw = sections['DISK']?.trim() ?? '';
      final freeMatch2 = RegExp(r'FreeSpace=(\d+)').firstMatch(diskRaw);
      final sizeMatch = RegExp(r'Size=(\d+)').firstMatch(diskRaw);
      if (freeMatch2 != null && sizeMatch != null) {
        final free = double.tryParse(freeMatch2.group(1)!) ?? 0;
        final size = double.tryParse(sizeMatch.group(1)!) ?? 0;
        if (size > 0) {
          diskPercent = ((size - free) / size * 100).clamp(0, 100);
        }
      }

      // USER：query user 行数
      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

      // UPTIME：LastBootUpTime=20260701000000.000000+480
      final upRaw = sections['UPTIME']?.trim() ?? '';
      final upMatch = RegExp(r'LastBootUpTime=(\d{14})').firstMatch(upRaw);
      if (upMatch != null) {
        final s = upMatch.group(1)!;
        try {
          final boot = DateTime(
            int.parse(s.substring(0, 4)),
            int.parse(s.substring(4, 6)),
            int.parse(s.substring(6, 8)),
            int.parse(s.substring(8, 10)),
            int.parse(s.substring(10, 12)),
            int.parse(s.substring(12, 14)),
          );
          final dur = DateTime.now().difference(boot);
          final d = dur.inDays;
          final h = dur.inHours % 24;
          final m = dur.inMinutes % 60;
          uptime = d > 0 ? '$d days, ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}' : '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Monitor] Windows 解析失败: $e');
    }

    // Windows 暂不采集网络速率（需 performance counter，命令较复杂）
    return ServerSnapshot(
      cpuPercent: cpu,
      memPercent: memPercent,
      memUsedMB: memUsedMB,
      memTotalMB: memTotalMB,
      diskPercent: diskPercent,
      netUpKBps: 0,
      netDownKBps: 0,
      userCount: userCount,
      uptime: uptime,
      timestamp: now,
    );
  }

  // ==================== 网络速率计算 ====================

  /// 根据本次和上次累计字节差 / 时间差，计算上下行 KB/s
  (double up, double down) _computeNetRate(int rxBytes, int txBytes, DateTime now) {
    if (_lastNetRxBytes == null || _lastNetTxBytes == null || _lastNetTime == null) {
      _lastNetRxBytes = rxBytes;
      _lastNetTxBytes = txBytes;
      _lastNetTime = now;
      return (0.0, 0.0);
    }
    final dt = now.difference(_lastNetTime!).inMilliseconds;
    if (dt <= 0) {
      _lastNetRxBytes = rxBytes;
      _lastNetTxBytes = txBytes;
      _lastNetTime = now;
      return (0.0, 0.0);
    }
    final dRx = (rxBytes - _lastNetRxBytes!) / 1024; // KB
    final dTx = (txBytes - _lastNetTxBytes!) / 1024;
    final seconds = dt / 1000.0;
    // 防止计数器回绕（重启网卡）
    final downRate = dRx < 0 ? 0.0 : dRx / seconds;
    final upRate = dTx < 0 ? 0.0 : dTx / seconds;
    _lastNetRxBytes = rxBytes;
    _lastNetTxBytes = txBytes;
    _lastNetTime = now;
    return (upRate, downRate);
  }
}
