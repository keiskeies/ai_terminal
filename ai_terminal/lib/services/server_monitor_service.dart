import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/l10n_holder.dart';
import 'ssh_service.dart';
import 'local_terminal_service.dart';

/// 网卡接口流量信息
class NetInterface {
  /// 接口名，如 eth0、docker0、br-xxx、en0 等
  final String name;

  /// 累计接收字节
  final int rxBytes;

  /// 累计发送字节
  final int txBytes;

  /// 接收错误包数
  final int rxErrors;

  /// 发送错误包数
  final int txErrors;

  /// 接收丢包数
  final int rxDropped;

  /// 发送丢包数
  final int txDropped;

  /// 下行速率（KB/s）
  final double downKBps;

  /// 上行速率（KB/s）
  final double upKBps;

  const NetInterface({
    required this.name,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxErrors = 0,
    this.txErrors = 0,
    this.rxDropped = 0,
    this.txDropped = 0,
    this.downKBps = 0,
    this.upKBps = 0,
  });

  /// 是否为空接口（无任何流量）
  bool get isIdle => rxBytes == 0 && txBytes == 0;

  NetInterface copyWithRate(double down, double up) {
    return NetInterface(
      name: name,
      rxBytes: rxBytes,
      txBytes: txBytes,
      rxErrors: rxErrors,
      txErrors: txErrors,
      rxDropped: rxDropped,
      txDropped: txDropped,
      downKBps: down,
      upKBps: up,
    );
  }
}

/// 磁盘分区信息
class DiskPartition {
  /// 文件系统/设备名
  final String filesystem;

  /// 挂载点
  final String mountPoint;

  /// 总量（GB）
  final double totalGB;

  /// 已用（GB）
  final double usedGB;

  /// 可用（GB）
  final double freeGB;

  /// 使用率（0~100）
  final double usePercent;

  const DiskPartition({
    required this.filesystem,
    required this.mountPoint,
    required this.totalGB,
    required this.usedGB,
    required this.freeGB,
    required this.usePercent,
  });
}

/// 单次采集到的服务器快照
class ServerSnapshot {
  /// 0.0 ~ 100.0（总体使用率）
  final double cpuPercent;

  /// CPU 用户态百分比
  final double cpuUser;

  /// CPU 内核态百分比
  final double cpuSystem;

  /// CPU 空闲百分比
  final double cpuIdle;

  /// 0.0 ~ 100.0（内存使用率）
  final double memPercent;

  /// 已用内存（MB）
  final double memUsedMB;

  /// 总内存（MB）
  final double memTotalMB;

  /// 可用内存（MB，Linux memAvailable / macOS free+wired 计算）
  final double memAvailableMB;

  /// 缓存内存（MB）
  final double memCachedMB;

  /// 缓冲内存（MB）
  final double memBuffersMB;

  /// 空闲内存（MB）
  final double memFreeMB;

  /// Swap 总量（MB）
  final double swapTotalMB;

  /// Swap 已用（MB）
  final double swapUsedMB;

  /// 0.0 ~ 100.0（根分区已用百分比）
  final double diskPercent;

  /// 根分区已用（GB）
  final double diskUsedGB;

  /// 根分区总量（GB）
  final double diskTotalGB;

  /// 根分区可用（GB）
  final double diskFreeGB;

  /// 所有磁盘分区（过滤掉 tmpfs/overlay/devtmpfs 等虚拟文件系统）
  final List<DiskPartition> diskPartitions;

  /// 网络上行总速率（KB/s）
  final double netUpKBps;

  /// 网络下行总速率（KB/s）
  final double netDownKBps;

  /// 累计上行字节
  final int netTotalUpBytes;

  /// 累计下行字节
  final int netTotalDownBytes;

  /// 各网卡接口明细
  final List<NetInterface> interfaces;

  /// 当前登录用户数
  final int userCount;

  /// 开机时长（人类可读，如 "3 days, 02:15"）
  final String uptime;

  /// 1 分钟平均负载
  final double loadAvg1;

  /// 5 分钟平均负载
  final double loadAvg5;

  /// 15 分钟平均负载
  final double loadAvg15;

  /// 进程数
  final int processCount;

  /// 内核版本
  final String kernelVersion;

  /// 主机名
  final String hostname;

  /// 采集时间戳
  final DateTime timestamp;

  /// 错误信息（采集失败时填充）
  final String? error;

  const ServerSnapshot({
    this.cpuPercent = 0,
    this.cpuUser = 0,
    this.cpuSystem = 0,
    this.cpuIdle = 0,
    this.memPercent = 0,
    this.memUsedMB = 0,
    this.memTotalMB = 0,
    this.memAvailableMB = 0,
    this.memCachedMB = 0,
    this.memBuffersMB = 0,
    this.memFreeMB = 0,
    this.swapTotalMB = 0,
    this.swapUsedMB = 0,
    this.diskPercent = 0,
    this.diskUsedGB = 0,
    this.diskTotalGB = 0,
    this.diskFreeGB = 0,
    this.diskPartitions = const [],
    this.netUpKBps = 0,
    this.netDownKBps = 0,
    this.netTotalUpBytes = 0,
    this.netTotalDownBytes = 0,
    this.interfaces = const [],
    this.userCount = 0,
    this.uptime = '-',
    this.loadAvg1 = 0,
    this.loadAvg5 = 0,
    this.loadAvg15 = 0,
    this.processCount = 0,
    this.kernelVersion = '',
    this.hostname = '',
    required this.timestamp,
    this.error,
  });
}

/// 服务器监控采集器
///
/// 通过 SSHService.runOnce 或 LocalTerminalService.runOnce 周期性采集
/// CPU/内存/磁盘/网络/用户/开机时间，维护历史数据环形缓冲供折线图使用。
class ServerMonitorService {
  final dynamic executor;
  final bool isLocal;

  final List<ServerSnapshot> _history = [];
  /// 历史数据上限：5s × 120 = 10 分钟
  static const int _maxHistory = 120;

  /// 各接口上次累计字节，用于计算速率
  final Map<String, _NetCounter> _lastNetCounters = {};

  bool _isCollecting = false;

  ServerMonitorService({required this.executor, required this.isLocal});

  List<ServerSnapshot> get history => List.unmodifiable(_history);

  bool get canCollect {
    if (executor == null) return false;
    try {
      return (executor as dynamic).isConnected as bool;
    } catch (_) {
      return false;
    }
  }

  Future<ServerSnapshot> collect() async {
    if (_isCollecting) {
      // 上一次还没结束，返回上一次成功数据（如有），否则空快照
      return _history.isNotEmpty
          ? _history.last
          : ServerSnapshot(timestamp: DateTime.now(), error: L10n.str.monitorErrorCollecting);
    }
    _isCollecting = true;
    try {
      if (!canCollect) {
        // 未连接：返回上次数据（如有），不污染历史
        return _history.isNotEmpty
            ? _history.last
            : ServerSnapshot(timestamp: DateTime.now(), error: '未连接');
      }
      final snap = isLocal ? await _collectLocal() : await _collectRemote();
      // 只有成功采集（无 error）才 push history
      if (snap.error == null) {
        _pushHistory(snap);
        return snap;
      }
      // 采集失败：返回上次成功数据（如有），保持折线图平直而非掉 0
      return _history.isNotEmpty ? _history.last : snap;
    } catch (e) {
      debugPrint('[Monitor] 采集异常: $e');
      // 异常时返回上次数据，不 push history
      return _history.isNotEmpty
          ? _history.last
          : ServerSnapshot(timestamp: DateTime.now(), error: '$e');
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

  void reset() {
    _history.clear();
    _lastNetCounters.clear();
  }

  // ==================== 远程（SSH）采集 ====================

  Future<ServerSnapshot> _collectRemote() async {
    final ssh = executor as SSHService;
    final osInfo = ssh.osInfo.toLowerCase();
    if (osInfo.contains('linux')) {
      return _collectLinux(ssh);
    } else if (osInfo.contains('darwin')) {
      return _collectMacOS(ssh);
    } else {
      return _collectLinux(ssh);
    }
  }

  /// Linux 采集：一次 runOnce 取所有指标
  Future<ServerSnapshot> _collectLinux(SSHService ssh) async {
    final script = [
      'echo @@CPU@@',
      "top -bn1 | grep 'Cpu(s)'",
      'echo @@MEM@@',
      "free -m",
      'echo @@DISK@@',
      "df -BG -PT",
      'echo @@NET@@',
      "cat /proc/net/dev",
      'echo @@USER@@',
      "who | wc -l",
      'echo @@UPTIME@@',
      "uptime -p 2>/dev/null || uptime",
      'echo @@LOAD@@',
      "cat /proc/loadavg",
      'echo @@PROC@@',
      "ls /proc | grep -c '^[0-9]'",
      'echo @@KERNEL@@',
      'uname -r',
      'echo @@HOSTNAME@@',
      'hostname',
      'echo @@END@@',
    ].join('; ');

    final out = await ssh.runOnce(script, timeout: const Duration(seconds: 8));
    return _parseLinuxOutput(out);
  }

  ServerSnapshot _parseLinuxOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: L10n.str.monitorErrorEmptyOutput);
    }

    final sections = _splitSections(raw);

    double cpu = 0, cpuUser = 0, cpuSystem = 0, cpuIdle = 0;
    double memPercent = 0, memUsedMB = 0, memTotalMB = 0, memAvailableMB = 0;
    double memCachedMB = 0, memBuffersMB = 0, memFreeMB = 0;
    double swapTotalMB = 0, swapUsedMB = 0;
    double diskPercent = 0, diskUsedGB = 0, diskTotalGB = 0, diskFreeGB = 0;
    List<DiskPartition> partitions = [];
    int userCount = 0;
    String uptime = '-';
    double load1 = 0, load5 = 0, load15 = 0;
    int processCount = 0;
    String kernel = '', hostname = '';

    try {
      // CPU：%Cpu(s):  8.0 us,  3.0 sy,  0.0 ni, 88.0 id,  0.0 wa,  1.0 hi,  0.0 si,  0.0 st
      final cpuRaw = sections['CPU']?.trim() ?? '';
      final usMatch = RegExp(r'([\d.]+)\s*us').firstMatch(cpuRaw);
      final syMatch = RegExp(r'([\d.]+)\s*sy').firstMatch(cpuRaw);
      final idMatch = RegExp(r'([\d.]+)\s*id').firstMatch(cpuRaw);
      cpuUser = usMatch != null ? (double.tryParse(usMatch.group(1)!) ?? 0) : 0;
      cpuSystem = syMatch != null ? (double.tryParse(syMatch.group(1)!) ?? 0) : 0;
      cpuIdle = idMatch != null ? (double.tryParse(idMatch.group(1)!) ?? 0) : 0;
      cpu = (100 - cpuIdle).clamp(0, 100);

      // MEM：free -m 输出
      final memRaw = sections['MEM']?.trim() ?? '';
      final memLines = memRaw.split('\n');
      for (final line in memLines) {
        if (line.startsWith('Mem:')) {
          final parts = line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 7) {
            memTotalMB = double.tryParse(parts[1]) ?? 0;
            memUsedMB = double.tryParse(parts[2]) ?? 0;
            memFreeMB = double.tryParse(parts[3]) ?? 0;
            memBuffersMB = double.tryParse(parts[5]) ?? 0;
            memAvailableMB = double.tryParse(parts[6]) ?? 0;
            // cached 需要单独取，free -m 在某些版本有 cached 列
            if (parts.length >= 8) {
              memCachedMB = double.tryParse(parts[7]) ?? 0;
            }
            if (memTotalMB > 0) {
              memPercent = (memUsedMB / memTotalMB * 100).clamp(0, 100);
            }
          }
        } else if (line.startsWith('-/+ buffers/cache:')) {
          final parts = line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 3) {
            memUsedMB = double.tryParse(parts[1]) ?? memUsedMB;
            memAvailableMB = double.tryParse(parts[2]) ?? memAvailableMB;
            if (memTotalMB > 0) {
              memPercent = (memUsedMB / memTotalMB * 100).clamp(0, 100);
            }
          }
        } else if (line.startsWith('Swap:')) {
          final parts = line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 4) {
            swapTotalMB = double.tryParse(parts[1]) ?? 0;
            swapUsedMB = double.tryParse(parts[2]) ?? 0;
          }
        }
      }

      // DISK — df -BG -PT 输出：Filesystem Type 1024-blocks Used Available Capacity Mounted on
      final diskRaw = sections['DISK']?.trim() ?? '';
      partitions = _parseLinuxDiskPartitions(diskRaw);
      for (final p in partitions) {
        if (p.mountPoint == '/') {
          diskTotalGB = p.totalGB;
          diskUsedGB = p.usedGB;
          diskFreeGB = p.freeGB;
          diskPercent = p.usePercent;
          break;
        }
      }

      // USER
      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

      // UPTIME
      uptime = sections['UPTIME']?.trim() ?? '-';
      if (uptime.startsWith('up ')) uptime = uptime.substring(3);
      if (uptime.isEmpty) uptime = '-';

      // LOAD
      final loadRaw = sections['LOAD']?.trim() ?? '';
      final loadParts = loadRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (loadParts.length >= 3) {
        load1 = double.tryParse(loadParts[0]) ?? 0;
        load5 = double.tryParse(loadParts[1]) ?? 0;
        load15 = double.tryParse(loadParts[2]) ?? 0;
      }

      // PROC
      final procRaw = sections['PROC']?.trim() ?? '';
      processCount = int.tryParse(procRaw) ?? 0;

      // KERNEL & HOSTNAME
      kernel = sections['KERNEL']?.trim() ?? '';
      hostname = sections['HOSTNAME']?.trim() ?? '';
    } catch (e) {
      debugPrint('[Monitor] Linux 解析失败: $e');
    }

    final (interfaces, totalRx, totalTx) = _parseLinuxNet(sections['NET'] ?? '', now);

    // 总速率 = 各接口速率之和（KB/s）
    final totalUpRate = interfaces.fold<double>(0, (s, i) => s + i.upKBps);
    final totalDownRate = interfaces.fold<double>(0, (s, i) => s + i.downKBps);

    return ServerSnapshot(
      cpuPercent: cpu,
      cpuUser: cpuUser,
      cpuSystem: cpuSystem,
      cpuIdle: cpuIdle,
      memPercent: memPercent,
      memUsedMB: memUsedMB,
      memTotalMB: memTotalMB,
      memAvailableMB: memAvailableMB,
      memCachedMB: memCachedMB,
      memBuffersMB: memBuffersMB,
      memFreeMB: memFreeMB,
      swapTotalMB: swapTotalMB,
      swapUsedMB: swapUsedMB,
      diskPercent: diskPercent,
      diskUsedGB: diskUsedGB,
      diskTotalGB: diskTotalGB,
      diskFreeGB: diskFreeGB,
      diskPartitions: partitions,
      netUpKBps: totalUpRate,
      netDownKBps: totalDownRate,
      netTotalUpBytes: totalTx,
      netTotalDownBytes: totalRx,
      interfaces: interfaces,
      userCount: userCount,
      uptime: uptime,
      loadAvg1: load1,
      loadAvg5: load5,
      loadAvg15: load15,
      processCount: processCount,
      kernelVersion: kernel,
      hostname: hostname,
      timestamp: now,
    );
  }

  /// 解析 Linux /proc/net/dev
  (List<NetInterface>, int totalRx, int totalTx) _parseLinuxNet(String raw, DateTime now) {
    final interfaces = <NetInterface>[];
    var totalRx = 0;
    var totalTx = 0;

    for (final line in raw.split('\n')) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final name = line.substring(0, colon).trim();
      final parts = line.substring(colon + 1).trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (parts.length < 9) continue;
      // 跳过 loopback
      if (name == 'lo') continue;
      try {
        final rx = int.tryParse(parts[0]) ?? 0;
        final rxErr = int.tryParse(parts[2]) ?? 0;
        final rxDrop = int.tryParse(parts[3]) ?? 0;
        final tx = int.tryParse(parts[8]) ?? 0;
        final txErr = int.tryParse(parts[10]) ?? 0;
        final txDrop = int.tryParse(parts[11]) ?? 0;
        totalRx += rx;
        totalTx += tx;
        final (downRate, upRate) = _computeInterfaceRate(name, rx, tx, now);
        interfaces.add(NetInterface(
          name: name,
          rxBytes: rx,
          txBytes: tx,
          rxErrors: rxErr,
          txErrors: txErr,
          rxDropped: rxDrop,
          txDropped: txDrop,
          downKBps: downRate,
          upKBps: upRate,
        ));
      } catch (_) {}
    }

    return (interfaces, totalRx, totalTx);
  }

  /// macOS 采集
  Future<ServerSnapshot> _collectMacOS(SSHService ssh) async {
    final script = [
      'echo @@CPU@@',
      "top -l 1 -n 0 | grep 'CPU usage'",
      'echo @@MEM@@',
      "vm_stat",
      'echo @@MEMSIZE@@',
      'sysctl -n hw.memsize',
      'echo @@DISK@@',
      "df -g -PT",
      'echo @@NET@@',
      "netstat -ib",
      'echo @@USER@@',
      'who | wc -l',
      'echo @@UPTIME@@',
      'uptime',
      'echo @@LOAD@@',
      'sysctl -n vm.loadavg',
      'echo @@PROC@@',
      "ps aux | wc -l",
      'echo @@KERNEL@@',
      'uname -r',
      'echo @@HOSTNAME@@',
      'hostname',
      'echo @@END@@',
    ].join('; ');

    final out = await ssh.runOnce(script, timeout: const Duration(seconds: 10));
    return _parseMacOSOutput(out);
  }

  ServerSnapshot _parseMacOSOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: L10n.str.monitorErrorEmptyOutput);
    }

    final sections = _splitSections(raw);

    double cpu = 0, cpuUser = 0, cpuSystem = 0, cpuIdle = 100;
    double memPercent = 0, memUsedMB = 0, memTotalMB = 0, memAvailableMB = 0;
    double memCachedMB = 0, memBuffersMB = 0, memFreeMB = 0;
    double swapTotalMB = 0, swapUsedMB = 0;
    double diskPercent = 0, diskUsedGB = 0, diskTotalGB = 0, diskFreeGB = 0;
    List<DiskPartition> partitions = [];
    int userCount = 0;
    String uptime = '-';
    double load1 = 0, load5 = 0, load15 = 0;
    int processCount = 0;
    String kernel = '', hostname = '';

    try {
      // CPU usage: 8% user, 20% sys, 71% idle
      final cpuRaw = sections['CPU']?.trim() ?? '';
      final usMatch = RegExp(r'([\d.]+)%\s*user').firstMatch(cpuRaw);
      final syMatch = RegExp(r'([\d.]+)%\s*sys').firstMatch(cpuRaw);
      final idMatch = RegExp(r'([\d.]+)%\s*idle').firstMatch(cpuRaw);
      cpuUser = usMatch != null ? (double.tryParse(usMatch.group(1)!) ?? 0) : 0;
      cpuSystem = syMatch != null ? (double.tryParse(syMatch.group(1)!) ?? 0) : 0;
      cpuIdle = idMatch != null ? (double.tryParse(idMatch.group(1)!) ?? 0) : 100;
      cpu = (cpuUser + cpuSystem).clamp(0, 100);

      // MEM：vm_stat 输出（pages，单位 4096 字节）
      final memRaw = sections['MEM']?.trim() ?? '';
      const pageSize = 4096;
      double pagesActive = 0, pagesFree = 0, pagesWired = 0, pagesCompressed = 0;
      double pagesInactive = 0, pagesSpeculative = 0;
      for (final line in memRaw.split('\n')) {
        final m = RegExp(r'"?([^":]+)"?:\s*(.+)').firstMatch(line);
        if (m != null) {
          final key = m.group(1)!.trim().toLowerCase();
          final val = double.tryParse(m.group(2)!.replaceAll('.', '').trim()) ?? 0;
          if (key.contains('active')) {
            pagesActive = val;
          } else if (key.contains('free')) {
            pagesFree = val;
          } else if (key.contains('wired')) {
            pagesWired = val;
          } else if (key.contains('occupied by compressor') || key.contains('compressor')) {
            pagesCompressed = val;
          } else if (key.contains('inactive')) {
            pagesInactive = val;
          } else if (key.contains('speculative')) {
            pagesSpeculative = val;
          }
        }
      }
      final memSizeRaw = sections['MEMSIZE']?.trim() ?? '0';
      final totalBytes = double.tryParse(memSizeRaw) ?? 0;
      memTotalMB = totalBytes / (1024 * 1024);
      final usedBytes = (pagesActive + pagesWired + pagesCompressed) * pageSize;
      memUsedMB = usedBytes / (1024 * 1024);
      final availBytes = (pagesFree + pagesInactive + pagesSpeculative) * pageSize;
      memAvailableMB = availBytes / (1024 * 1024);
      memFreeMB = (pagesFree * pageSize) / (1024 * 1024);
      if (totalBytes > 0) {
        memPercent = (usedBytes / totalBytes * 100).clamp(0, 100);
      }

      // DISK — df -g -PT 输出（macOS 格式类似 Linux）
      final diskRaw = sections['DISK']?.trim() ?? '';
      partitions = _parseMacOSDiskPartitions(diskRaw);
      for (final p in partitions) {
        if (p.mountPoint == '/') {
          diskTotalGB = p.totalGB;
          diskUsedGB = p.usedGB;
          diskFreeGB = p.freeGB;
          diskPercent = p.usePercent;
          break;
        }
      }

      // USER
      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

      // UPTIME
      uptime = sections['UPTIME']?.trim() ?? '-';
      final upMatch = RegExp(r'up\s+(.+?),\s*\d+\s*user').firstMatch(uptime);
      if (upMatch != null) uptime = upMatch.group(1)!;
      if (uptime.isEmpty) uptime = '-';

      // LOAD
      final loadRaw = sections['LOAD']?.trim() ?? '';
      final loadMatches = RegExp(r'([\d.]+)').allMatches(loadRaw).toList();
      if (loadMatches.length >= 3) {
        load1 = double.tryParse(loadMatches[0].group(1)!) ?? 0;
        load5 = double.tryParse(loadMatches[1].group(1)!) ?? 0;
        load15 = double.tryParse(loadMatches[2].group(1)!) ?? 0;
      }

      // PROC
      final procRaw = sections['PROC']?.trim() ?? '';
      processCount = (int.tryParse(procRaw) ?? 1) - 1;
      if (processCount < 0) processCount = 0;

      kernel = sections['KERNEL']?.trim() ?? '';
      hostname = sections['HOSTNAME']?.trim() ?? '';
    } catch (e) {
      debugPrint('[Monitor] macOS 解析失败: $e');
    }

    final (interfaces, totalRx, totalTx) = _parseMacOSNet(sections['NET'] ?? '', now);

    // 总速率 = 各接口速率之和（KB/s）
    final totalUpRate = interfaces.fold<double>(0, (s, i) => s + i.upKBps);
    final totalDownRate = interfaces.fold<double>(0, (s, i) => s + i.downKBps);

    return ServerSnapshot(
      cpuPercent: cpu,
      cpuUser: cpuUser,
      cpuSystem: cpuSystem,
      cpuIdle: cpuIdle,
      memPercent: memPercent,
      memUsedMB: memUsedMB,
      memTotalMB: memTotalMB,
      memAvailableMB: memAvailableMB,
      memCachedMB: memCachedMB,
      memBuffersMB: memBuffersMB,
      memFreeMB: memFreeMB,
      swapTotalMB: swapTotalMB,
      swapUsedMB: swapUsedMB,
      diskPercent: diskPercent,
      diskUsedGB: diskUsedGB,
      diskTotalGB: diskTotalGB,
      diskFreeGB: diskFreeGB,
      diskPartitions: partitions,
      netUpKBps: totalUpRate,
      netDownKBps: totalDownRate,
      netTotalUpBytes: totalTx,
      netTotalDownBytes: totalRx,
      interfaces: interfaces,
      userCount: userCount,
      uptime: uptime,
      loadAvg1: load1,
      loadAvg5: load5,
      loadAvg15: load15,
      processCount: processCount,
      kernelVersion: kernel,
      hostname: hostname,
      timestamp: now,
    );
  }

  /// 解析 macOS netstat -ib
  (List<NetInterface>, int totalRx, int totalTx) _parseMacOSNet(String raw, DateTime now) {
    final interfaces = <NetInterface>[];
    var totalRx = 0;
    var totalTx = 0;

    // netstat -ib 第一行是 header
    final lines = raw.split('\n');
    if (lines.isEmpty) return (interfaces, totalRx, totalTx);

    final headerParts = lines.first.trim().split(RegExp(r'\s+'));
    int idx(String key) => headerParts.indexOf(key);
    final iName = idx('Name');
    final iIbytes = idx('Ibytes');
    final iObytes = idx('Obytes');
    final iIerrs = idx('Ierrs');
    final iOerrs = idx('Oerrs');
    final iDrop = idx('Drop');

    if (iName == -1 || iIbytes == -1 || iObytes == -1) return (interfaces, totalRx, totalTx);

    final seen = <String>{};
    for (int i = 1; i < lines.length; i++) {
      final parts = lines[i].trim().split(RegExp(r'\s+'));
      if (parts.length <= iName) continue;
      final name = parts[iName];
      if (name == 'lo0') continue;
      if (seen.contains(name)) continue;
      seen.add(name);
      if (parts.length <= iObytes) continue;
      try {
        final rx = int.tryParse(parts[iIbytes]) ?? 0;
        final tx = int.tryParse(parts[iObytes]) ?? 0;
        final rxErr = iIerrs >= 0 && parts.length > iIerrs ? int.tryParse(parts[iIerrs]) ?? 0 : 0;
        final txErr = iOerrs >= 0 && parts.length > iOerrs ? int.tryParse(parts[iOerrs]) ?? 0 : 0;
        final rxDrop = iDrop >= 0 && parts.length > iDrop ? int.tryParse(parts[iDrop]) ?? 0 : 0;
        totalRx += rx;
        totalTx += tx;
        final (downRate, upRate) = _computeInterfaceRate(name, rx, tx, now);
        interfaces.add(NetInterface(
          name: name,
          rxBytes: rx,
          txBytes: tx,
          rxErrors: rxErr,
          txErrors: txErr,
          rxDropped: rxDrop,
          txDropped: 0,
          downKBps: downRate,
          upKBps: upRate,
        ));
      } catch (_) {}
    }

    return (interfaces, totalRx, totalTx);
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
      "top -bn1 | grep 'Cpu(s)'",
      'echo @@MEM@@',
      "free -m",
      'echo @@DISK@@',
      "df -BG -PT",
      'echo @@NET@@',
      "cat /proc/net/dev",
      'echo @@USER@@',
      "who | wc -l",
      'echo @@UPTIME@@',
      "uptime -p 2>/dev/null || uptime",
      'echo @@LOAD@@',
      "cat /proc/loadavg",
      'echo @@PROC@@',
      "ls /proc | grep -c '^[0-9]'",
      'echo @@KERNEL@@',
      'uname -r',
      'echo @@HOSTNAME@@',
      'hostname',
      'echo @@END@@',
    ].join('; ');

    final out = await local.runOnce(script, timeout: const Duration(seconds: 8));
    return _parseLinuxOutput(out);
  }

  Future<ServerSnapshot> _collectMacOSLocal(LocalTerminalService local) async {
    final script = [
      'echo @@CPU@@',
      "top -l 1 -n 0 | grep 'CPU usage'",
      'echo @@MEM@@',
      "vm_stat",
      'echo @@MEMSIZE@@',
      'sysctl -n hw.memsize',
      'echo @@DISK@@',
      "df -g -PT",
      'echo @@NET@@',
      "netstat -ib",
      'echo @@USER@@',
      'who | wc -l',
      'echo @@UPTIME@@',
      'uptime',
      'echo @@LOAD@@',
      'sysctl -n vm.loadavg',
      'echo @@PROC@@',
      "ps aux | wc -l",
      'echo @@KERNEL@@',
      'uname -r',
      'echo @@HOSTNAME@@',
      'hostname',
      'echo @@END@@',
    ].join('; ');

    final out = await local.runOnce(script, timeout: const Duration(seconds: 10));
    return _parseMacOSOutput(out);
  }

  Future<ServerSnapshot> _collectWindowsLocal(LocalTerminalService local) async {
    const ps = '''
echo @@CPU@@
wmic cpu get loadpercentage /value | findstr LoadPercentage
echo @@MEM@@
wmic OS get FreePhysicalMemory,TotalVisibleMemorySize,FreeVirtualMemory,TotalVirtualMemorySize /value | findstr =
echo @@DISK@@
wmic logicaldisk get DeviceID,DriveType,FileSystem,FreeSpace,Size /value | findstr =
echo @@NET@@
wmic path Win32_PerfRawData_Tcpip_NetworkInterface get Name,BytesReceivedPersec,BytesSentPersec,PacketsReceivedErrors,PacketsOutboundErrors /value
echo @@USER@@
query user | find /c ">"
echo @@UPTIME@@
wmic os get LastBootUpTime /value | findstr =
echo @@LOAD@@
echo N/A
echo @@PROC@@
tasklist /nh | find /c ">"
echo @@KERNEL@@
ver
echo @@HOSTNAME@@
hostname
echo @@END@@
''';
    final out = await local.runOnce('powershell -Command "$ps"', timeout: const Duration(seconds: 12));
    return _parseWindowsOutput(out);
  }

  ServerSnapshot _parseWindowsOutput(String raw) {
    final now = DateTime.now();
    if (raw.isEmpty) {
      return ServerSnapshot(timestamp: now, error: L10n.str.monitorErrorEmptyOutput);
    }

    final sections = _splitSections(raw);

    double cpu = 0, cpuUser = 0, cpuSystem = 0, cpuIdle = 0;
    double memPercent = 0, memUsedMB = 0, memTotalMB = 0, memAvailableMB = 0;
    double swapTotalMB = 0, swapUsedMB = 0;
    double diskPercent = 0, diskUsedGB = 0, diskTotalGB = 0, diskFreeGB = 0;
    List<DiskPartition> partitions = [];
    int userCount = 0;
    String uptime = '-';
    int processCount = 0;
    String kernel = '', hostname = '';

    try {
      final cpuRaw = sections['CPU']?.trim() ?? '';
      final cpuMatch = RegExp(r'LoadPercentage=(\d+)').firstMatch(cpuRaw);
      if (cpuMatch != null) {
        cpu = double.tryParse(cpuMatch.group(1)!) ?? 0;
        cpuIdle = 100 - cpu;
      }

      final memRaw = sections['MEM']?.trim() ?? '';
      final freeMatch = RegExp(r'FreePhysicalMemory=(\d+)').firstMatch(memRaw);
      final totalMatch = RegExp(r'TotalVisibleMemorySize=(\d+)').firstMatch(memRaw);
      final freeVirtMatch = RegExp(r'FreeVirtualMemory=(\d+)').firstMatch(memRaw);
      final totalVirtMatch = RegExp(r'TotalVirtualMemorySize=(\d+)').firstMatch(memRaw);
      if (freeMatch != null && totalMatch != null) {
        final freeKB = double.tryParse(freeMatch.group(1)!) ?? 0;
        final totalKB = double.tryParse(totalMatch.group(1)!) ?? 0;
        memTotalMB = totalKB / 1024;
        memUsedMB = (totalKB - freeKB) / 1024;
        memAvailableMB = freeKB / 1024;
        if (totalKB > 0) {
          memPercent = ((totalKB - freeKB) / totalKB * 100).clamp(0, 100);
        }
      }
      if (freeVirtMatch != null && totalVirtMatch != null) {
        final freeVKB = double.tryParse(freeVirtMatch.group(1)!) ?? 0;
        final totalVKB = double.tryParse(totalVirtMatch.group(1)!) ?? 0;
        swapTotalMB = totalVKB / 1024;
        swapUsedMB = (totalVKB - freeVKB) / 1024;
      }

      // DISK — wmic logicaldisk get DeviceID,DriveType,FileSystem,FreeSpace,Size /value
      final diskRaw = sections['DISK']?.trim() ?? '';
      partitions = _parseWindowsDiskPartitions(diskRaw);
      for (final p in partitions) {
        if (p.mountPoint.toLowerCase() == 'c:') {
          diskTotalGB = p.totalGB;
          diskUsedGB = p.usedGB;
          diskFreeGB = p.freeGB;
          diskPercent = p.usePercent;
          break;
        }
      }

      final userRaw = sections['USER']?.trim() ?? '';
      userCount = int.tryParse(userRaw) ?? 0;

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
          uptime = d > 0
              ? '$d days, ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}'
              : '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
        } catch (_) {}
      }

      final procRaw = sections['PROC']?.trim() ?? '';
      processCount = int.tryParse(procRaw) ?? 0;

      kernel = sections['KERNEL']?.trim() ?? '';
      hostname = sections['HOSTNAME']?.trim() ?? '';
    } catch (e) {
      debugPrint('[Monitor] Windows 解析失败: $e');
    }

    final (interfaces, totalRx, totalTx) = _parseWindowsNet(sections['NET'] ?? '', now);

    // 总速率 = 各接口速率之和（KB/s）
    final totalUpRate = interfaces.fold<double>(0, (s, i) => s + i.upKBps);
    final totalDownRate = interfaces.fold<double>(0, (s, i) => s + i.downKBps);

    return ServerSnapshot(
      cpuPercent: cpu,
      cpuUser: cpuUser,
      cpuSystem: cpuSystem,
      cpuIdle: cpuIdle,
      memPercent: memPercent,
      memUsedMB: memUsedMB,
      memTotalMB: memTotalMB,
      memAvailableMB: memAvailableMB,
      memCachedMB: 0,
      memBuffersMB: 0,
      memFreeMB: memAvailableMB,
      swapTotalMB: swapTotalMB,
      swapUsedMB: swapUsedMB,
      diskPercent: diskPercent,
      diskUsedGB: diskUsedGB,
      diskTotalGB: diskTotalGB,
      diskFreeGB: diskFreeGB,
      diskPartitions: partitions,
      netUpKBps: totalUpRate,
      netDownKBps: totalDownRate,
      netTotalUpBytes: totalTx,
      netTotalDownBytes: totalRx,
      interfaces: interfaces,
      userCount: userCount,
      uptime: uptime,
      loadAvg1: 0,
      loadAvg5: 0,
      loadAvg15: 0,
      processCount: processCount,
      kernelVersion: kernel,
      hostname: hostname,
      timestamp: now,
    );
  }

  /// 解析 Windows wmic perf raw 输出（/value 格式）
  (List<NetInterface>, int totalRx, int totalTx) _parseWindowsNet(String raw, DateTime now) {
    final interfaces = <NetInterface>[];
    var totalRx = 0;
    var totalTx = 0;

    // 按 Name 拆分块
    final blocks = raw.split('\n\n');
    final seen = <String>{};

    for (final block in blocks) {
      final nameMatch = RegExp(r'Name=(.+)').firstMatch(block);
      if (nameMatch == null) continue;
      final name = nameMatch.group(1)!.trim();
      if (name.toLowerCase().contains('loopback')) continue;
      if (seen.contains(name)) continue;
      seen.add(name);

      final rxMatch = RegExp(r'BytesReceivedPersec=(\d+)').firstMatch(block);
      final txMatch = RegExp(r'BytesSentPersec=(\d+)').firstMatch(block);
      final rxErrMatch = RegExp(r'PacketsReceivedErrors=(\d+)').firstMatch(block);
      final txErrMatch = RegExp(r'PacketsOutboundErrors=(\d+)').firstMatch(block);

      if (rxMatch == null || txMatch == null) continue;

      try {
        final rx = int.tryParse(rxMatch.group(1)!) ?? 0;
        final tx = int.tryParse(txMatch.group(1)!) ?? 0;
        final rxErr = int.tryParse(rxErrMatch?.group(1) ?? '0') ?? 0;
        final txErr = int.tryParse(txErrMatch?.group(1) ?? '0') ?? 0;
        totalRx += rx;
        totalTx += tx;
        final (downRate, upRate) = _computeInterfaceRate(name, rx, tx, now);
        interfaces.add(NetInterface(
          name: name,
          rxBytes: rx,
          txBytes: tx,
          rxErrors: rxErr,
          txErrors: txErr,
          rxDropped: 0,
          txDropped: 0,
          downKBps: downRate,
          upKBps: upRate,
        ));
      } catch (_) {}
    }

    return (interfaces, totalRx, totalTx);
  }

  // ==================== 工具方法 ====================

  /// 切分 @@SECTION@@ 标记的输出
  Map<String, String> _splitSections(String raw) {
    final sections = <String, String>{};
    String? currentSection;
    for (final line in raw.split('\n')) {
      final m = RegExp(r'^@@(\w+)@@$').firstMatch(line.trim());
      if (m != null) {
        currentSection = m.group(1);
        sections[currentSection!] = '';
      } else if (currentSection != null) {
        final existing = sections[currentSection] ?? '';
        sections[currentSection] = existing.isEmpty ? line : '$existing\n$line';
      }
    }
    return sections;
  }

  /// 计算单个接口速率
  (double down, double up) _computeInterfaceRate(String name, int rx, int tx, DateTime now) {
    final last = _lastNetCounters[name];
    if (last == null) {
      _lastNetCounters[name] = _NetCounter(rx: rx, tx: tx, time: now);
      return (0.0, 0.0);
    }
    final dt = now.difference(last.time).inMilliseconds;
    if (dt <= 0) return (0.0, 0.0);
    final dRx = (rx - last.rx) / 1024;
    final dTx = (tx - last.tx) / 1024;
    final seconds = dt / 1000.0;
    final downRate = dRx < 0 ? 0.0 : dRx / seconds;
    final upRate = dTx < 0 ? 0.0 : dTx / seconds;
    _lastNetCounters[name] = _NetCounter(rx: rx, tx: tx, time: now);
    return (downRate, upRate);
  }

  // ==================== 磁盘分区解析 ====================

  /// 虚拟文件系统类型（过滤掉）
  static const Set<String> _virtualFsTypes = {
    'tmpfs', 'devtmpfs', 'sysfs', 'proc', 'devpts', 'overlay',
    'squashfs', 'cgroup', 'cgroup2', 'pstore', 'bpf', 'tracefs',
    'securityfs', 'debugfs', 'hugetlbfs', 'mqueue', 'autofs',
    'configfs', 'fusectl', 'efivarfs', 'ramfs',
  };

  /// 解析 Linux df -BG -PT 输出
  List<DiskPartition> _parseLinuxDiskPartitions(String raw) {
    final result = <DiskPartition>[];
    final lines = raw.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      // 跳过表头
      if (line.startsWith('Filesystem')) continue;
      final parts = line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      // df -PT: Filesystem Type 1024-blocks Used Available Capacity Mounted on
      if (parts.length < 7) continue;
      final fs = parts[0];
      final fstype = parts[1];
      // 过滤虚拟文件系统
      if (_virtualFsTypes.contains(fstype)) continue;
      // 过滤掉 /dev/loop、/dev/sr0 等设备
      if (fs.startsWith('/dev/loop') || fs.startsWith('/dev/sr')) continue;
      final totalGB = double.tryParse(parts[2].replaceAll('G', '')) ?? 0;
      final usedGB = double.tryParse(parts[3].replaceAll('G', '')) ?? 0;
      final freeGB = double.tryParse(parts[4].replaceAll('G', '')) ?? 0;
      final usePercent = double.tryParse(parts[5].replaceAll('%', '')) ?? 0;
      final mountPoint = parts.sublist(6).join(' ');
      if (totalGB <= 0) continue;
      result.add(DiskPartition(
        filesystem: fs,
        mountPoint: mountPoint,
        totalGB: totalGB,
        usedGB: usedGB,
        freeGB: freeGB,
        usePercent: usePercent.clamp(0, 100),
      ));
    }
    result.sort((a, b) => b.totalGB.compareTo(a.totalGB));
    return result;
  }

  /// 解析 macOS df -g -PT 输出（格式与 Linux 类似）
  List<DiskPartition> _parseMacOSDiskPartitions(String raw) {
    return _parseLinuxDiskPartitions(raw);
  }

  /// 解析 Windows wmic logicaldisk 输出
  List<DiskPartition> _parseWindowsDiskPartitions(String raw) {
    final result = <DiskPartition>[];
    // wmic /value 格式：每个磁盘一组键值对，组之间有空行
    final blocks = raw.split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.contains('=')).toList();
      if (lines.isEmpty) continue;
      String deviceId = '';
      String driveType = '';
      String fileSystem = '';
      double freeBytes = 0;
      double sizeBytes = 0;
      for (final line in lines) {
        final idx = line.indexOf('=');
        if (idx == -1) continue;
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        switch (key) {
          case 'DeviceID': deviceId = value;
          case 'DriveType': driveType = value;
          case 'FileSystem': fileSystem = value;
          case 'FreeSpace': freeBytes = double.tryParse(value) ?? 0;
          case 'Size': sizeBytes = double.tryParse(value) ?? 0;
        }
      }
      if (deviceId.isEmpty || sizeBytes <= 0) continue;
      // DriveType: 2=可移动, 3=本地磁盘, 4=网络, 5=CD-ROM
      if (driveType != '3' && driveType != '2') continue;
      final totalGB = sizeBytes / (1024 * 1024 * 1024);
      final freeGB = freeBytes / (1024 * 1024 * 1024);
      final usedGB = totalGB - freeGB;
      final usePercent = totalGB > 0 ? (usedGB / totalGB * 100).clamp(0.0, 100.0) : 0.0;
      result.add(DiskPartition(
        filesystem: fileSystem.isEmpty ? 'unknown' : fileSystem,
        mountPoint: deviceId,
        totalGB: totalGB,
        usedGB: usedGB,
        freeGB: freeGB,
        usePercent: usePercent,
      ));
    }
    result.sort((a, b) => b.totalGB.compareTo(a.totalGB));
    return result;
  }
}

class _NetCounter {
  final int rx;
  final int tx;
  final DateTime time;
  _NetCounter({required this.rx, required this.tx, required this.time});
}
