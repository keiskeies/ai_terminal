import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 秘密掩码注册表（会话日志脱敏，docs §5）。
///
/// 执行器向 stdin 应答 sudo 密码前 register，命令结束的所有路径 unregister。
/// 录制器落盘前把命中串替换为 ****** —— sudo 通常关回显，但注册期内任何
/// 回显/重试提示里的密码都不会进日志。密码本身绝不写入任何日志。
class SecretMasker {
  static final Set<String> _secrets = {};

  static void register(String? secret) {
    if (secret != null && secret.isNotEmpty) _secrets.add(secret);
  }

  static void unregister(String? secret) {
    if (secret != null) _secrets.remove(secret);
  }

  static String mask(String text) => maskWith(text, _secrets);

  static String maskWith(String text, Iterable<String> secrets) {
    var out = text;
    for (final s in secrets) {
      out = out.replaceAll(s, '******');
    }
    return out;
  }

  static Iterable<String> get secrets => _secrets;

  static void clear() => _secrets.clear();
}

/// 单个标签的终端会话录制器：输出流 → 去 ANSI → 脱敏 → 追加落盘。
///
/// 录制点在 tab 输出订阅处（provider 转发之后、xterm 写入同层），
/// 录的是用户实际看到的解码文本。批量刷盘（500ms/64KB），单文件 20MB
/// 封顶（R8），失败只告警一次不拖累终端主流程。
class SessionRecorder {
  SessionRecorder({required this.label});

  final String label;

  /// 日志文件路径（start 成功后可用，供 UI 提示）
  String? filePath;

  IOSink? _sink;
  final StringBuffer _pending = StringBuffer();

  /// 待刷文本到达时注册中的秘密快照：命令结束会 unregister，但跨 chunk
  /// 的密码回显要等拼齐后才命中，刷盘时必须用到达时的秘密集合而非当前注册表。
  /// pending 清空后才释放。
  final Set<String> _pendingSecrets = {};
  Timer? _flushTimer;
  int _writtenBytes = 0;
  bool _closed = false;
  bool _stopped = false;
  bool _errorReported = false;

  static const int _maxBytes = 20 * 1024 * 1024;
  static const int _flushThresholdChars = 64 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 500);

  /// 刷盘时扣住尾部若干字符等下一轮：密码回显/ANSI 序列可能跨 chunk，
  /// 整段匹配才能命中（512 覆盖常见密码长度与 OSC 序列）。
  static const int _holdbackChars = 512;

  static final RegExp _escapes = RegExp(
    r'\x1B\[[\x20-\x3F]*[\x40-\x7E]'
    r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'
    r'|\x1B[(][A-Za-z]|\x1B[)][A-Za-z]'
    r'|\x1B[A-Za-z]|\x07',
  );

  Future<void> start() async {
    if (_closed || _sink != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final logDir = Directory('${dir.path}/session_logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final ts = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${ts.year}${two(ts.month)}${two(ts.day)}'
          '_${two(ts.hour)}${two(ts.minute)}${two(ts.second)}'
          '_${ts.millisecond}';
      final safeLabel = label.replaceAll(RegExp(r'[^\w\u4e00-\u9fff.-]'), '_');
      final file = File('${logDir.path}/${safeLabel}_$stamp.log');
      _sink = file.openWrite(mode: FileMode.append);
      filePath = file.path;
      _sink!.write('# session log: $label @ ${ts.toIso8601String()}\n');
      if (_pending.isNotEmpty) _scheduleFlush();
    } catch (e) {
      _reportError('打开会话日志失败 (label=$label): $e');
      _stopped = true;
    }
  }

  void write(String chunk) {
    if (_closed || _stopped || chunk.isEmpty) return;
    // 到达即掩码 + 记录秘密快照：命令可能在回显刷盘前就结束并 unregister
    // （超时/取消路径），只靠刷盘时掩码会漏。
    _pendingSecrets.addAll(SecretMasker.secrets);
    _pending.write(SecretMasker.mask(chunk));
    if (_pending.length >= _flushThresholdChars) {
      _flush();
      return;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(_flushInterval, _flush);
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    if (sink == null || _pending.isEmpty || _stopped) return;
    var text = _pending.toString();
    _pending.clear();
    // 尾部扣住等下一轮，close 时全量刷出；不足窗口长度则整段扣住
    if (!_closed) {
      final keep = text.length < _holdbackChars ? text.length : _holdbackChars;
      final cut = text.length - keep;
      if (keep > 0) _pending.write(text.substring(cut));
      text = text.substring(0, cut);
    }
    text = text.replaceAll(_escapes, '');
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = SecretMasker.maskWith(text, _pendingSecrets);
    if (_pending.isEmpty) _pendingSecrets.clear();
    if (text.isEmpty) return;
    try {
      sink.write(text);
      _writtenBytes += text.length;
      if (_writtenBytes >= _maxBytes) {
        sink.write('\n# [日志已达 20MB 上限，停止录制]\n');
        _stopped = true;
      }
    } catch (e) {
      _reportError('写入会话日志失败 (label=$label): $e');
      _stopped = true;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush();
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (e) {
        _reportError('关闭会话日志失败 (label=$label): $e');
      }
    }
  }

  void _reportError(String message) {
    if (_errorReported) return;
    _errorReported = true;
    debugPrint('[SessionRecorder] $message');
  }
}
