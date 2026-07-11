import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Agent 日志记录器
///
/// 性能优化要点：
/// 1. 使用循环缓冲区（Queue）替代 List + removeAt(0)，避免 O(n) 移动
/// 2. 文件写入改为异步 + 批量缓冲（500ms 聚合一次），避免每条日志都同步 IO
/// 3. 控制台输出改用 debugPrint（release 模式自动禁用），并按级别过滤
/// 4. 提供同步 getLogs() 用于 UI 读取，避免 UI 卡顿
class AgentLogger {
  static final AgentLogger _instance = AgentLogger._internal();
  factory AgentLogger() => _instance;
  AgentLogger._internal() : _logFile = null {
    // 异步初始化日志文件，避免阻塞启动
    _initLogFileAsync();
  }

  /// 循环缓冲区：入队 O(1)，超出容量时 removeFirst O(1)
  final Queue<String> _logs = Queue();
  static const int _maxLogs = 1000;

  File? _logFile;

  /// 当前日志路由的 hostId（由 AgentNotifier 在切换 host 时设置）
  /// 订阅器据此将日志写入对应会话，避免多 host 串台
  String? currentHostId;

  /// 文件写入缓冲区：聚合多条件日志一次性异步写入
  final StringBuffer _fileBuffer = StringBuffer();
  Timer? _flushTimer;
  bool _fileWriting = false;

  /// 控制台输出级别控制（避免 release 模式下大量 print 阻塞）
  /// 仅在 debug 模式输出 INFO/DEBUG，WARN/ERROR 始终输出
  static bool get _isDebugMode {
    bool inDebugMode = false;
    assert(() { inDebugMode = true; return true; }());
    return inDebugMode;
  }

  /// 异步初始化日志文件：写入应用文档目录（持久化），append 模式
  Future<void> _initLogFileAsync() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/agent.log');
      // 启动时写入分隔标记（append 模式，保留历史日志）
      _logFile!.writeAsString(
        '\n=== Agent Log Started ${DateTime.now()} ===\n',
        mode: FileMode.append,
      );
    } catch (e) {
      debugPrint('[AgentLogger] 日志文件初始化失败: $e');
    }
  }

  void log(String level, String tag, String message) {
    final timestamp = DateTime.now();
    final logEntry = '[$timestamp] [$level] [$tag] $message';

    // 入队循环缓冲区
    _logs.addLast(logEntry);
    if (_logs.length > _maxLogs) _logs.removeFirst();

    // 控制台输出：release 模式只输出 WARN/ERROR，debug 模式全量
    if (level == 'WARN' || level == 'ERROR' || _isDebugMode) {
      debugPrint(logEntry);
    }

    // 文件写入：缓冲聚合，500ms 刷一次
    _fileBuffer.writeln(logEntry);
    _scheduleFlush();

    // 通知订阅者（会话持久化层订阅，将日志写入对应 Conversation）
    // 复制监听器列表避免回调中修改列表导致并发问题
    if (_listeners.isNotEmpty) {
      final listeners = List<void Function(String, String, String, DateTime, String?)>.from(_listeners);
      for (final l in listeners) {
        try {
          l(level, tag, message, timestamp, currentHostId);
        } catch (e) { debugPrint('[AgentLogger] 日志监听器异常: $e'); }
      }
    }
  }

  /// 调度异步刷盘（500ms 内的多条日志合并为一次 IO）
  void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(milliseconds: 500), _flushToFile);
  }

  Future<void> _flushToFile() async {
    _flushTimer = null;
    if (_fileWriting) {
      // 上一次还没写完，重新调度
      _scheduleFlush();
      return;
    }
    final file = _logFile;
    if (file == null || _fileBuffer.isEmpty) {
      // 日志文件初始化失败时清空缓冲区，防止 StringBuffer 无限增长导致 OOM
      if (file == null && _fileBuffer.length > 10000) {
        _fileBuffer.clear();
      }
      return;
    }

    final pending = _fileBuffer.toString();
    _fileBuffer.clear();
    _fileWriting = true;
    try {
      await file.writeAsString(pending, mode: FileMode.append, flush: false);
      // 日志轮转：文件超过 5MB 时保留尾部 2MB，防止无限增长
      await _rotateIfNeeded(file);
    } catch (e) {
      debugPrint('[AgentLogger] 日志文件写入失败: $e');
      // 写入失败时把内容放回缓冲区，下次再试
      _fileBuffer.write(pending);
    } finally {
      _fileWriting = false;
    }
  }

  /// 日志文件轮转：超过 5MB 时保留尾部 2MB
  static const int _maxLogSize = 5 * 1024 * 1024;  // 5MB
  static const int _keepLogSize = 2 * 1024 * 1024;  // 2MB

  Future<void> _rotateIfNeeded(File file) async {
    try {
      final size = await file.length();
      if (size < _maxLogSize) return;
      // 原子轮转：先写临时文件再 rename，防止 truncate 和 writeFrom 之间崩溃导致日志清空
      final tail = await file.open(mode: FileMode.read);
      List<int> tailBytes;
      try {
        await tail.setPosition(size - _keepLogSize);
        tailBytes = await tail.read(_keepLogSize);
      } finally {
        await tail.close();
      }
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsBytes(tailBytes, flush: true);
      await tmpFile.rename(file.path);
    } catch (e) {
      debugPrint('[AgentLogger] 日志轮转失败: $e');
    }
  }

  void debug(String tag, String message) => log('DEBUG', tag, message);
  void info(String tag, String message) => log('INFO', tag, message);
  void warn(String tag, String message) => log('WARN', tag, message);
  void error(String tag, String message) => log('ERROR', tag, message);

  /// 返回日志副本（正序：最早在前，最新在后，UI 滚动到底部看最新）
  List<String> getLogs() => _logs.toList(growable: false);

  String getLogsAsString() => _logs.join('\n');

  // ═══════════════════════════════════════════
  // 日志订阅：供会话持久化层订阅，将日志写入对应 Conversation
  // ═══════════════════════════════════════════
  final List<void Function(String level, String tag, String message, DateTime timestamp, String? hostId)> _listeners = [];

  /// 订阅日志写入事件（返回取消订阅的函数）
  /// 回调参数 hostId 是日志产生时的当前 hostId，订阅方据此路由到对应会话
  void Function() subscribe(void Function(String level, String tag, String message, DateTime timestamp, String? hostId) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// 确保所有缓冲日志刷盘（应用退出时调用）
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flushToFile();
  }
}

final agentLogger = AgentLogger();
