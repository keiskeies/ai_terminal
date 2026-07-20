import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// P2-8: 崩溃上报 — 把 Zone 级和 FlutterError 异常持久化到独立 crash.log
///
/// 与 agentLogger 的差异：
/// - agentLogger 是通用日志，crash.log 只记录未捕获异常（信噪比高）
/// - 每条崩溃带结构化字段：时间、版本、平台、错误类型、堆栈
/// - 文件轮转：超过 1MB 保留尾部 512KB
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  File? _crashFile;
  String? _appVersion;
  String? _buildNumber;
  bool _initialized = false;

  /// 最近一次崩溃时间（内存缓存，供 UI 快速展示）
  DateTime? _lastCrashTime;
  DateTime? get lastCrashTime => _lastCrashTime;

  /// 最近一次崩溃摘要（错误类型 + 消息前 200 字符）
  String? _lastCrashSummary;
  String? get lastCrashSummary => _lastCrashSummary;

  /// 累计崩溃次数（仅本次会话，重启后清零；持久化次数需读文件）
  int _sessionCrashCount = 0;
  int get sessionCrashCount => _sessionCrashCount;

  static const int _maxLogSize = 1 * 1024 * 1024; // 1MB
  static const int _keepLogSize = 512 * 1024; // 512KB

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _crashFile = File('${dir.path}/crash.log');
      if (!_crashFile!.existsSync()) {
        await _crashFile!.create(recursive: true);
      }
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
      _buildNumber = info.buildNumber;
      // 启动时回扫一次，填充 _lastCrashTime / _lastCrashSummary
      _scanLastCrash();
    } catch (e) {
      debugPrint('[CrashReporter] 初始化失败: $e');
    }
  }

  /// 上报一次崩溃（Zone 级异常 / FlutterError / 主动捕获的严重错误）
  /// [context] 标记来源，如 'Zone' / 'FlutterError' / 'AgentEngine'
  Future<void> report(
    Object error,
    StackTrace? stack, {
    String? context,
  }) async {
    if (!_initialized) {
      // 防御：未初始化时也尝试写，但可能失败
      await init();
    }
    _sessionCrashCount++;
    _lastCrashTime = DateTime.now();
    final errStr = error.toString();
    _lastCrashSummary = errStr.length > 200
        ? errStr.substring(0, 200)
        : errStr;

    final file = _crashFile;
    if (file == null) {
      debugPrint('[CrashReporter] crash.log 不可用，仅记录到内存');
      return;
    }

    final now = DateTime.now();
    final entry = StringBuffer()
      ..writeln('=== CRASH ${now.toIso8601String()} ===')
      ..writeln('context: ${context ?? "unknown"}')
      ..writeln('appVersion: ${_appVersion ?? "unknown"}+${_buildNumber ?? "0"}')
      ..writeln('platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('error: $errStr')
      ..writeln('stack:')
      ..writeln(stack?.toString() ?? '<no stack>')
      ..writeln('');

    try {
      await file.writeAsString(entry.toString(), mode: FileMode.append, flush: true);
      await _rotateIfNeeded(file);
    } catch (e) {
      debugPrint('[CrashReporter] 写入失败: $e');
    }
  }

  /// 读取完整 crash.log 内容（UI 查看用）
  Future<String> readLog() async {
    final file = _crashFile;
    if (file == null || !file.existsSync()) return '';
    try {
      return await file.readAsString();
    } catch (e) {
      debugPrint('[CrashReporter] 读取失败: $e');
      return '';
    }
  }

  /// 清空 crash.log（用户在诊断页点 "清除" 用）
  Future<void> clearLog() async {
    final file = _crashFile;
    if (file == null) return;
    try {
      await file.writeAsString('', mode: FileMode.write, flush: true);
      _lastCrashTime = null;
      _lastCrashSummary = null;
    } catch (e) {
      debugPrint('[CrashReporter] 清除失败: $e');
    }
  }

  /// 回扫文件填充 _lastCrashTime / _lastCrashSummary（启动时调用一次）
  void _scanLastCrash() {
    final file = _crashFile;
    if (file == null || !file.existsSync()) return;
    try {
      final content = file.readAsStringSync();
      final lines = content.split('\n');
      String? lastTimeStr;
      String? lastError;
      for (final line in lines) {
        if (line.startsWith('=== CRASH ')) {
          // 提取时间戳
          final start = '=== CRASH '.length;
          final end = line.indexOf(' ===', start);
          if (end > start) {
            lastTimeStr = line.substring(start, end);
          }
        } else if (line.startsWith('error: ')) {
          lastError = line.substring('error: '.length);
        }
      }
      if (lastTimeStr != null) {
        _lastCrashTime = DateTime.tryParse(lastTimeStr);
      }
      if (lastError != null) {
        _lastCrashSummary = lastError.length > 200
            ? lastError.substring(0, 200)
            : lastError;
      }
    } catch (e) {
      debugPrint('[CrashReporter] 回扫失败: $e');
    }
  }

  /// 文件超过 1MB 时保留尾部 512KB
  Future<void> _rotateIfNeeded(File file) async {
    try {
      final size = await file.length();
      if (size < _maxLogSize) return;
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
      debugPrint('[CrashReporter] 轮转失败: $e');
    }
  }
}

/// 全局便捷访问
final crashReporter = CrashReporter.instance;
