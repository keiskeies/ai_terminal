import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/host_config.dart';
import 'ssh_service.dart';

class _PoolEntry {
  final SSHService service;
  int refCount = 1;
  DateTime lastActive;

  _PoolEntry({
    required this.service,
    DateTime? lastActive,
  }) : lastActive = lastActive ?? DateTime.now();
}

class SSHConnectionPool {
  static final Map<String, _PoolEntry> _pool = {};
  static Timer? _cleanupTimer;

  /// 仅供测试注入假的 SSHService 工厂，避免单测依赖真实 SSH 连接。
  /// 生产路径恒为 null → 正常构造 SSHService。
  @visibleForTesting
  static SSHService Function(HostConfig config)? serviceFactoryForTesting;

  /// 正在进行的 acquire（去重，避免并发创建多个连接）
  static final Map<String, Future<SSHService>> _pendingAcquires = {};

  /// 获取或创建连接
  static Future<SSHService> acquire(
    String hostId,
    HostConfig config, {
    String? password,
    String? privateKeyContent,
    String? passphrase,
    HostConfig? jumpHostConfig,
    String? jumpPassword,
    String? jumpPrivateKeyContent,
  }) async {
    // 检查是否存在且仍然连接
    if (_pool.containsKey(hostId)) {
      final entry = _pool[hostId]!;
      if (entry.service.isConnected) {
        entry.refCount++;
        entry.lastActive = DateTime.now();
        return entry.service;
      }
      entry.service.dispose();
      _pool.remove(hostId);
    }

    // A7: 并发去重 — 同一 hostId 的并发 acquire 复用同一个 Future
    if (_pendingAcquires.containsKey(hostId)) {
      final svc = await _pendingAcquires[hostId]!;
      if (_pool.containsKey(hostId)) {
        _pool[hostId]!.refCount++;
      }
      return svc;
    }

    final future = _doAcquire(
      hostId, config,
      password: password,
      privateKeyContent: privateKeyContent,
      passphrase: passphrase,
      jumpHostConfig: jumpHostConfig,
      jumpPassword: jumpPassword,
      jumpPrivateKeyContent: jumpPrivateKeyContent,
    );
    _pendingAcquires[hostId] = future;
    try {
      return await future;
    } finally {
      _pendingAcquires.remove(hostId);
    }
  }

  static Future<SSHService> _doAcquire(
    String hostId,
    HostConfig config, {
    String? password,
    String? privateKeyContent,
    String? passphrase,
    HostConfig? jumpHostConfig,
    String? jumpPassword,
    String? jumpPrivateKeyContent,
  }) async {
    final service = serviceFactoryForTesting?.call(config) ?? SSHService(config);
    try {
      // 总超时必须大于单次建连超时（跳板机要串两段），否则用户把
      // 「连接超时」调到 60 s 也会被这里 30 s 先掐断。
      await service
          .connect(
        password: password,
        privateKeyContent: privateKeyContent,
        passphrase: passphrase,
        jumpHostConfig: jumpHostConfig,
        jumpPassword: jumpPassword,
        jumpPrivateKeyContent: jumpPrivateKeyContent,
      )
          .timeout(overallConnectTimeoutFor(
        config,
        jumpHostConfig: jumpHostConfig,
      ));
    } catch (e) {
      // N4: 异常时清理 service，避免连接泄漏
      service.dispose();
      rethrow;
    }

    _pool[hostId] = _PoolEntry(service: service);
    return service;
  }

  /// 池侧整体建连超时：必须覆盖每一段的建连超时（跳板机串两段），
  /// 否则用户把「连接超时」调大反而会被池里的固定值先掐断。
  /// 跳板机段的超时按 [jumpHostConfig] 自己算，不按主机配置猜：
  /// 调用方合成的跳板机 HostConfig 不带 timeout，两段并不相等。
  static Duration overallConnectTimeoutFor(
    HostConfig config, {
    HostConfig? jumpHostConfig,
  }) {
    final legs = SSHService.connectTimeoutFor(config) +
        (jumpHostConfig == null
            ? Duration.zero
            : SSHService.connectTimeoutFor(jumpHostConfig));
    return legs + const Duration(seconds: 15);
  }

  /// 释放连接
  /// 异步执行 disconnect（关闭 SSH session/socket 是异步操作）
  /// 调用方无需 await — 引用计数已同步递减，连接已从池中移除
  static void release(String hostId) {
    if (!_pool.containsKey(hostId)) return;

    final entry = _pool[hostId]!;
    entry.refCount--;

    if (entry.refCount <= 0) {
      _pool.remove(hostId);
      // R2: dispose 同时断开 SSH 会话并关闭 outputController。
      // disconnect() 内部全是同步操作（签名 async 只是历史遗留），
      // 不需要 fire-and-forget 的 async 闭包。
      try {
        entry.service.dispose();
      } catch (e) {
        // dispose 失败通常是重复关闭，仅记录，不影响引用计数已递减的事实
        debugPrint('[SSHConnectionPool] dispose 失败 (hostId=$hostId): $e');
      }
    }
  }

  /// 获取连接（不增加引用计数）
  static SSHService? get(String hostId) {
    return _pool[hostId]?.service;
  }

  /// 检查连接是否存在且已连接
  static bool isConnected(String hostId) {
    return _pool[hostId]?.service.isConnected ?? false;
  }

  /// 强制断开连接
  static Future<void> forceDisconnect(String hostId) async {
    final entry = _pool.remove(hostId);
    if (entry != null) {
      // dispose = disconnect + 关闭 outputController；重连会新建 service，
      // 旧 service 的流对象必须一并释放，否则每次重连泄漏一个 StreamController。
      entry.service.dispose();
    }
  }

  /// 启动空闲清理
  static void startIdleCleanup(Duration timeout) {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanup(timeout);
    });
  }

  /// 停止清理
  static void stopIdleCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  static void _cleanup(Duration timeout) {
    final now = DateTime.now();
    final toRemove = <String>[];

    _pool.forEach((hostId, entry) {
      // 归零条目已在 release() 中立即移出池，这里兜底回收"仅创建者持有、
      // 且超过 idle 阈值未再被 acquire"的孤儿条目。有并发借用者（>1）
      // 时不能回收；原判定 refCount == 0 因归零即移除而永假。
      if (entry.refCount <= 1 && now.difference(entry.lastActive) > timeout) {
        entry.service.dispose();
        toRemove.add(hostId);
      }
    });

    for (final hostId in toRemove) {
      _pool.remove(hostId);
    }
  }

  /// 仅供测试触发一次空闲回收，无需等 5 分钟定时器
  @visibleForTesting
  static void cleanupForTesting(Duration timeout) => _cleanup(timeout);

  /// 获取统计信息
  static Map<String, dynamic> get stats {
    return {
      'totalConnections': _pool.length,
      'connections': _pool.map((key, value) => MapEntry(key, {
        'refCount': value.refCount,
        'isConnected': value.service.isConnected,
        'osInfo': value.service.osInfo,
      })),
    };
  }

  /// 清理所有连接
  static Future<void> dispose() async {
    stopIdleCleanup();
    for (final entry in _pool.values) {
      entry.service.dispose();
    }
    _pool.clear();
  }
}
