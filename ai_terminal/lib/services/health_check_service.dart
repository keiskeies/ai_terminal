import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'agent_logger.dart';
import 'ssh_connection_pool.dart';

/// P2-8: 健康检查 — 周期性检查本地磁盘可写性 + SSH 池活性
///
/// 设计要点：
/// - 不主动做 AI API ping（避免消耗配额；连接失败时 OpenAIProvider 自身会重试 + 上报）
/// - 应用目录不可写时 ERROR（数据库/日志都无法写入，是致命问题）
/// - SSH 池中存在 isConnected=false 的条目时 WARN（连接已死但未 release）
/// - 检查结果通过 agentLogger 输出，并提供 lastSnapshot 供 UI 读取
class HealthCheckService {
  HealthCheckService._();
  static final HealthCheckService instance = HealthCheckService._();

  Timer? _timer;
  bool _running = false;
  DateTime? _lastCheckTime;
  HealthSnapshot? _lastSnapshot;

  /// 最近一次快照（UI 读取）
  HealthSnapshot? get lastSnapshot => _lastSnapshot;
  DateTime? get lastCheckTime => _lastCheckTime;

  /// 启动周期性检查（默认每 5 分钟一次）
  /// 首次检查延迟 30 秒，避免与启动期 IO 抢资源；之后按 interval 周期执行
  void start({Duration interval = const Duration(minutes: 5)}) {
    if (_timer != null) return;
    Timer(const Duration(seconds: 30), _runOnce);
    _timer = Timer.periodic(interval, (_) => _runOnce());
    agentLogger.info('HealthCheck', '健康检查已启动 (间隔 ${interval.inMinutes} 分钟)');
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  /// 手动触发一次检查（诊断页按钮调用）
  Future<HealthSnapshot> checkNow() async {
    return _runOnce();
  }

  Future<HealthSnapshot> _runOnce() async {
    if (_running) {
      return _lastSnapshot ?? HealthSnapshot();
    }
    _running = true;
    try {
      final now = DateTime.now();

      // 1. 本地磁盘可写性探测
      bool diskWritable = true;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final probe = File('${dir.path}/.health_probe');
        try {
          await probe.writeAsString('ok', flush: true);
          await probe.delete();
        } catch (e) {
          // 目录不可写：致命问题（数据库/日志都无法写入）
          agentLogger.error('HealthCheck', '应用目录不可写: $e');
          diskWritable = false;
        }
      } catch (e) {
        agentLogger.warn('HealthCheck', '磁盘检查失败: $e');
      }

      // 2. SSH 连接池活性
      final stats = SSHConnectionPool.stats;
      final total = (stats['totalConnections'] as int?) ?? 0;
      final connections = stats['connections'] as Map? ?? {};
      int deadCount = 0;
      int totalRefCount = 0;
      connections.forEach((_, value) {
        final m = value as Map?;
        final connected = m?['isConnected'] as bool? ?? false;
        if (!connected) deadCount++;
        final refCount = m?['refCount'] as int? ?? 0;
        totalRefCount += refCount;
      });
      if (deadCount > 0) {
        agentLogger.warn('HealthCheck',
            'SSH 池存在 $deadCount/$total 个已死连接（未正常 release）');
      }

      final snap = HealthSnapshot(
        timestamp: now,
        sshTotalConnections: total,
        sshDeadConnections: deadCount,
        sshTotalRefCount: totalRefCount,
        diskWritable: diskWritable,
      );
      _lastSnapshot = snap;
      _lastCheckTime = now;
      return snap;
    } catch (e, stack) {
      agentLogger.error('HealthCheck', '健康检查执行异常: $e\n$stack');
      return HealthSnapshot(timestamp: DateTime.now());
    } finally {
      _running = false;
    }
  }
}

class HealthSnapshot {
  final DateTime timestamp;
  final int sshTotalConnections;
  final int sshDeadConnections;
  final int sshTotalRefCount;
  final bool diskWritable;

  HealthSnapshot({
    DateTime? timestamp,
    this.sshTotalConnections = 0,
    this.sshDeadConnections = 0,
    this.sshTotalRefCount = 0,
    this.diskWritable = true,
  }) : timestamp = timestamp ?? DateTime.utc(1970);

  bool get hasIssues => sshDeadConnections > 0 || !diskWritable;

  String get summary =>
      'SSH池: $sshTotalConnections 连接 ($sshDeadConnections 死, ref=$sshTotalRefCount) | 磁盘可写: $diskWritable';
}

final healthCheckService = HealthCheckService.instance;
