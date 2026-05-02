import 'dart:async';
import '../models/host_config.dart';
import 'ssh_service.dart';

class _PoolEntry {
  final SSHService service;
  int refCount;
  DateTime lastActive;

  _PoolEntry({
    required this.service,
    this.refCount = 1,
    DateTime? lastActive,
  }) : lastActive = lastActive ?? DateTime.now();
}

class SSHConnectionPool {
  static final Map<String, _PoolEntry> _pool = {};
  static Timer? _cleanupTimer;

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
      // 如果连接仍然有效，复用它
      if (entry.service.isConnected) {
        entry.refCount++;
        entry.lastActive = DateTime.now();
        return entry.service;
      }
      // 连接已断开，清理旧条目
      entry.service.dispose();
      _pool.remove(hostId);
    }

    final service = SSHService(config);
    await service.connect(
      password: password,
      privateKeyContent: privateKeyContent,
      passphrase: passphrase,
      jumpHostConfig: jumpHostConfig,
      jumpPassword: jumpPassword,
      jumpPrivateKeyContent: jumpPrivateKeyContent,
    );

    _pool[hostId] = _PoolEntry(service: service);
    return service;
  }

  /// 释放连接
  static void release(String hostId) {
    if (!_pool.containsKey(hostId)) return;

    final entry = _pool[hostId]!;
    entry.refCount--;

    if (entry.refCount <= 0) {
      entry.service.disconnect();
      _pool.remove(hostId);
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
    if (_pool.containsKey(hostId)) {
      await _pool[hostId]!.service.disconnect();
      _pool.remove(hostId);
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
      if (entry.refCount == 0 && now.difference(entry.lastActive) > timeout) {
        entry.service.disconnect();
        toRemove.add(hostId);
      }
    });

    for (final hostId in toRemove) {
      _pool.remove(hostId);
    }
  }

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
      await entry.service.disconnect();
    }
    _pool.clear();
  }
}
