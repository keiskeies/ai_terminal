import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';
import 'sftp_service.dart';

/// 同步方向
enum SyncDirection {
  /// 本地 → 远端（上传）
  localToRemote,
  /// 双向
  bidirectional,
}

/// 同步事件类型
enum SyncEventType {
  uploadStart,
  uploadProgress,
  uploadSuccess,
  uploadFailed,
  downloadStart,
  downloadSuccess,
  downloadFailed,
  info,
}

/// 同步事件
class SyncEvent {
  final SyncEventType type;
  final String message;
  final String? filePath;
  final int? uploaded;
  final int? total;

  const SyncEvent({
    required this.type,
    required this.message,
    this.filePath,
    this.uploaded,
    this.total,
  });

  @override
  String toString() => 'SyncEvent($type: $message)';
}

/// 同步任务配置
class SyncConfig {
  /// 本地目录绝对路径
  final String localDir;
  /// 远端目录绝对路径
  final String remoteDir;
  /// 同步方向
  final SyncDirection direction;
  /// 排除的文件/目录名
  final List<String> excludeNames;
  /// 是否启用（可暂停/恢复）
  bool enabled;

  SyncConfig({
    required this.localDir,
    required this.remoteDir,
    this.direction = SyncDirection.localToRemote,
    List<String>? excludeNames,
    this.enabled = true,
  }) : excludeNames = excludeNames ?? ['node_modules', '.git', '.DS_Store'];
}

/// 文件同步服务
///
/// 设计：
/// - 本地 → 远端：用 watcher 监听本地变化，变化即上传
/// - 远端 → 本地：定期轮询（每 30s）对比 mtime，新增/修改的下载
/// - 双向：合并两种模式，冲突时以 mtime 较新的为准
/// - 单连接：复用 SSHService 的 SSHClient 打开 SFTP
class FileSyncService {
  final SftpService _sftp = SftpService();
  /// client getter：每次操作时获取最新 SSHClient（避免持有重连后过期的 client）
  SSHClient? Function()? _clientGetter;
  SSHClient? _lastAttachedClient;
  SyncConfig? _config;
  StreamSubscription<WatchEvent>? _watchSub;
  Timer? _pollTimer;
  bool _isSyncing = false;
  bool _disposed = false;
  /// watcher 待处理变更队列：path → 变更类型（同路径多次修改自动合并为最后一次）
  final Map<String, ChangeType> _pendingChanges = {};
  bool _watcherProcessing = false;
  final Map<String, DateTime> _lastSyncTime = {};
  /// _lastSyncTime 容量上限（R8：避免无限增长）
  static const int _maxLastSyncEntries = 500;

  /// 事件流（UI 订阅显示同步状态）
  final StreamController<SyncEvent> _eventController =
      StreamController<SyncEvent>.broadcast();
  Stream<SyncEvent> get events => _eventController.stream;

  bool get isRunning => _watchSub != null || _pollTimer != null;
  SyncConfig? get config => _config;

  /// R2: 统一的事件发射，守卫 isClosed
  void _emit(SyncEventType type, String message, {String? filePath, int? uploaded, int? total}) {
    if (_eventController.isClosed) return;
    _eventController.add(SyncEvent(
      type: type,
      message: message,
      filePath: filePath,
      uploaded: uploaded,
      total: total,
    ));
  }

  /// 启动同步
  /// [clientGetter] 返回当前 SSHClient（支持 SSHService 重连后获取新 client）
  Future<bool> start({
    required SSHClient? Function() clientGetter,
    required SyncConfig config,
  }) async {
    if (isRunning) {
      debugPrint('[FileSync] 已在运行，先停止再启动');
      return false;
    }

    _clientGetter = clientGetter;
    _config = config;

    // 初次 attach
    if (!await _ensureClient()) {
      return false;
    }

    // 校验本地目录
    final localDir = Directory(config.localDir);
    if (!await localDir.exists()) {
      _emit(SyncEventType.uploadFailed, '本地目录不存在: ${config.localDir}');
      return false;
    }

    // 1. 启动本地 watcher（localToRemote 或 bidirectional）
    if (config.direction == SyncDirection.localToRemote ||
        config.direction == SyncDirection.bidirectional) {
      await _startLocalWatcher(config);
    }

    // 2. 启动远端轮询（仅 bidirectional）
    if (config.direction == SyncDirection.bidirectional) {
      _startRemotePolling(config);
    }

    _emit(SyncEventType.info, '同步已启动: ${config.localDir} ↔ ${config.remoteDir}');
    return true;
  }

  /// 确保持有有效的 SFTP 连接：检测 client 变化（重连）并重新 attach
  Future<bool> _ensureClient() async {
    if (_disposed || _clientGetter == null) return false;
    final current = _clientGetter!();
    if (current == null) {
      _emit(SyncEventType.uploadFailed, 'SSH 连接已断开，请重连后重启同步');
      return false;
    }
    // client 变化（重连后）→ 重新 attach SFTP
    if (current != _lastAttachedClient) {
      try {
        await _sftp.attachToClient(current);
        _lastAttachedClient = current;
      } catch (e) {
        _emit(SyncEventType.uploadFailed, 'SFTP 连接失败: $e');
        return false;
      }
    }
    return true;
  }

  /// 停止同步
  Future<void> stop() async {
    await _watchSub?.cancel();
    _watchSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _lastAttachedClient = null;
    _emit(SyncEventType.info, '同步已停止');
  }

  /// 启动本地文件监听
  Future<void> _startLocalWatcher(SyncConfig config) async {
    final watcher = DirectoryWatcher(config.localDir);
    final stream = watcher.events;

    _watchSub = stream.listen((event) {
      if (_disposed || !config.enabled) return;

      // 检查排除项
      final relative = p.relative(event.path, from: config.localDir);
      final parts = p.split(relative);
      if (parts.any((part) => config.excludeNames.contains(part))) {
        return;
      }

      // 入队（Map 自动去重：同路径多次修改只保留最后一次类型）
      _pendingChanges[event.path] = event.type;

      // 启动处理循环（如果未运行）
      _kickWatcherQueue(config);
    });
  }

  /// 启动 watcher 队列处理（如果未在运行）
  void _kickWatcherQueue(SyncConfig config) {
    if (_watcherProcessing || _disposed) return;
    if (_pendingChanges.isEmpty) return;
    _watcherProcessing = true;
    // 不 await：让 stream 继续接收事件
    _processWatcherQueue(config);
  }

  /// 串行处理 watcher 待处理变更队列
  Future<void> _processWatcherQueue(SyncConfig config) async {
    try {
      // 初始延迟让连续写入聚集
      await Future.delayed(const Duration(milliseconds: 300));
      while (_pendingChanges.isNotEmpty && config.enabled && !_disposed) {
        // 批量取出当前所有待处理
        final batch = _pendingChanges.entries.toList();
        _pendingChanges.clear();

        for (final entry in batch) {
          if (!config.enabled || _disposed) break;
          final path = entry.key;
          final type = entry.value;

          // 防抖：同一文件 500ms 内只处理一次
          final lastTime = _lastSyncTime[path];
          final now = DateTime.now();
          if (lastTime != null && now.difference(lastTime).inMilliseconds < 500) {
            // 重新入队延后处理
            _pendingChanges[path] = type;
            continue;
          }
          _lastSyncTime[path] = now;
          // R8: _lastSyncTime 容量控制（保留最近的）
          if (_lastSyncTime.length > _maxLastSyncEntries) {
            final oldest = _lastSyncTime.keys
                .reduce((a, b) => _lastSyncTime[a]!.isBefore(_lastSyncTime[b]!) ? a : b);
            _lastSyncTime.remove(oldest);
          }

          try {
            if (type == ChangeType.MODIFY || type == ChangeType.ADD) {
              await _uploadSingleFile(path, config);
            } else if (type == ChangeType.REMOVE) {
              await _deleteRemoteFile(path, config);
            }
          } catch (e) {
            debugPrint('[FileSync] 处理变更失败 $path: $e');
          }
        }
        // 短暂等待让处理期间产生的新事件聚集
        if (_pendingChanges.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      _watcherProcessing = false;
    }
  }

  /// 启动远端轮询
  void _startRemotePolling(SyncConfig config) {
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!config.enabled) return;
      if (_isSyncing) return;
      await _pollRemoteChanges(config);
    });
  }

  /// 上传单个文件
  Future<void> _uploadSingleFile(String localPath, SyncConfig config) async {
    if (!await _ensureClient()) return;
    try {
      final file = File(localPath);
      if (!await file.exists()) return;

      // R6: 远端路径用 posix
      final relative = p.relative(localPath, from: config.localDir);
      final remotePath = p.posix.joinAll([config.remoteDir, ...p.split(relative)]);

      _emit(SyncEventType.uploadStart, '上传: $relative', filePath: localPath);

      // 确保远端父目录存在
      final remoteParent = p.posix.dirname(remotePath);
      await _sftp.createDirectory(remoteParent);

      await _sftp.uploadFile(localPath, remotePath);

      _emit(SyncEventType.uploadSuccess, '已上传: $relative', filePath: localPath);
    } catch (e) {
      _emit(SyncEventType.uploadFailed, '上传失败: $e', filePath: localPath);
    }
  }

  /// 删除远端文件（本地删除时同步删除远端）
  Future<void> _deleteRemoteFile(String localPath, SyncConfig config) async {
    if (!await _ensureClient()) return;
    try {
      final relative = p.relative(localPath, from: config.localDir);
      final remotePath = p.posix.joinAll([config.remoteDir, ...p.split(relative)]);

      await _sftp.deleteFile(remotePath);
      _emit(SyncEventType.info, '已删除远端: $relative', filePath: localPath);
    } catch (e) {
      // 删除失败不严重（可能远端本来就没有）
      debugPrint('[FileSync] 删除远端失败: $e');
    }
  }

  /// 轮询远端变化，下载新增/修改的文件
  Future<void> _pollRemoteChanges(SyncConfig config) async {
    if (!await _ensureClient()) return;
    _isSyncing = true;
    try {
      final remoteFiles = <_RemoteFileInfo>[];
      await _collectRemoteFiles(config.remoteDir, config.remoteDir, remoteFiles, config.excludeNames);

      for (final remoteFile in remoteFiles) {
        final localPath = p.join(config.localDir, remoteFile.relativePath);
        final localFile = File(localPath);

        bool needDownload = false;
        if (!await localFile.exists()) {
          needDownload = true;
        } else {
          final localMtime = await localFile.lastModified();
          // 远端 mtime 更新则下载
          if (remoteFile.modified.isAfter(localMtime)) {
            needDownload = true;
          }
        }

        if (needDownload) {
          _emit(SyncEventType.downloadStart, '下载: ${remoteFile.relativePath}', filePath: localPath);
          try {
            // 确保本地父目录存在
            final localParent = p.dirname(localPath);
            await Directory(localParent).create(recursive: true);
            await _sftp.downloadFile(remoteFile.fullPath, localPath);
            _emit(SyncEventType.downloadSuccess, '已下载: ${remoteFile.relativePath}', filePath: localPath);
          } catch (err) {
            _emit(SyncEventType.downloadFailed, '下载失败: $err', filePath: localPath);
          }
        }
      }
    } catch (e) {
      _emit(SyncEventType.info, '轮询远端失败: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// 递归收集远端文件列表
  Future<void> _collectRemoteFiles(
    String rootPath,
    String currentPath,
    List<_RemoteFileInfo> result,
    List<String> excludeNames,
  ) async {
    try {
      final entries = await _sftp.listDirectory(currentPath);
      for (final entry in entries) {
        if (excludeNames.contains(entry.name)) continue;
        final fullPath = p.posix.join(currentPath, entry.name);
        final relative = p.posix.relative(fullPath, from: rootPath);

        if (entry.isDirectory) {
          await _collectRemoteFiles(rootPath, fullPath, result, excludeNames);
        } else {
          // 文件项
          result.add(_RemoteFileInfo(
            fullPath: fullPath,
            relativePath: relative,
            modified: entry.modifiedTime ?? DateTime.now(),
          ));
        }
      }
    } catch (e) {
      debugPrint('[FileSync] 收集远端文件失败: $e');
    }
  }

  /// 立即执行一次全量同步（不等待 watcher 触发）
  Future<void> fullSync() async {
    if (_config == null) return;
    if (_disposed) return;
    // 避免与 watcher 上传 / poll 下载并发操作 SFTP
    if (_isSyncing) {
      _emit(SyncEventType.info, '同步进行中，全量同步已跳过');
      return;
    }
    if (!await _ensureClient()) return;
    final config = _config!;

    _isSyncing = true;
    _emit(SyncEventType.info, '开始全量同步...');

    try {
      final result = await _sftp.uploadDirectory(
        config.localDir,
        config.remoteDir,
        excludeNames: config.excludeNames,
        onProgress: (uploaded, total) {
          _emit(SyncEventType.uploadProgress, '全量上传进度: $uploaded/$total',
              uploaded: uploaded, total: total);
        },
      );
      _emit(SyncEventType.uploadSuccess, result.summary);
    } catch (e) {
      _emit(SyncEventType.uploadFailed, '全量同步失败: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// R2: 同步清理资源（不依赖 async stop，避免 dispose 后 async 回调写已关闭的 controller）
  void dispose() {
    _disposed = true;
    // 同步取消订阅和定时器（watcher 的 cancel 返回 Future 但我们不等它，事件流已关闭后回调无效）
    _watchSub?.cancel();
    _watchSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pendingChanges.clear();
    _clientGetter = null;
    _lastAttachedClient = null;
    if (!_eventController.isClosed) {
      _eventController.close();
    }
  }
}

/// 远端文件信息（内部用）
class _RemoteFileInfo {
  final String fullPath;
  final String relativePath;
  final DateTime modified;

  _RemoteFileInfo({
    required this.fullPath,
    required this.relativePath,
    required this.modified,
  });
}
