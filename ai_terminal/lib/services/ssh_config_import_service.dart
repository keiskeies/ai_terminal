/// `~/.ssh/config` 导入的 IO 层：定位文件、展开 `Include`、与已有主机比对。
///
/// 解析本身在 `utils/ssh_config_parser.dart`（纯函数、可单测）；
/// 这里只负责文件系统，便于把「读不到/无权限」这类错误集中在一处上报（R8）。
library;

import 'dart:io';

import '../models/host_config.dart';
import '../utils/ssh_config_parser.dart';

/// 默认配置文件路径（不含内容）；不存在时 [SshConfigImportSource.exists] 为 false。
class SshConfigImportSource {
  final String path;
  final bool exists;
  final String? content;

  /// 读取失败的原因（权限/是目录等），与「文件不存在」区分开，
  /// 前者要告诉用户去改权限，后者只是提示「没找到配置」
  final String? readError;

  const SshConfigImportSource({
    required this.path,
    required this.exists,
    this.content,
    this.readError,
  });

  bool get isReadable => exists && readError == null && content != null;
}

class SshConfigImportService {
  /// 读取用户 SSH 配置。[overridePath] 供「选择其他文件」使用。
  static Future<SshConfigImportSource> load({String? overridePath}) async {
    final path = overridePath ?? defaultConfigPath();
    if (path == null) {
      return const SshConfigImportSource(
          path: '', exists: false, readError: '无法确定用户主目录');
    }
    final file = File(path);
    try {
      if (!await file.exists()) {
        return SshConfigImportSource(path: path, exists: false);
      }
      // 配置文件可能含敏感结构，读取失败必须可见，不能静默当空文件
      return SshConfigImportSource(
        path: path,
        exists: true,
        content: await file.readAsString(),
      );
    } on FileSystemException catch (e) {
      return SshConfigImportSource(
          path: path, exists: true, readError: '读取失败: ${e.message}');
    }
  }

  static String? defaultConfigPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOMEPATH'];
    if (home == null || home.isEmpty) return null;
    return '$home${Platform.pathSeparator}.ssh${Platform.pathSeparator}config';
  }

  static String homeDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOMEPATH'];
    return home ?? '.';
  }

  /// 解析已读取的配置文本，Include 走真实文件系统
  static SshConfigParseResult parse(String content, {String? dirOfConfig}) {
    final home = homeDir();
    final baseDir = dirOfConfig ??
        (defaultConfigPath() != null
            ? File(defaultConfigPath()!).parent.path
            : home);
    return parseSshConfig(
      content,
      homeDir: home,
      includeResolver: (pattern, _) => _resolveInclude(pattern, home, baseDir),
    );
  }

  /// 与已有主机比对：同 host:port 视为已存在（用户名可能不同，仍标出来让用户判断）
  static bool isDuplicate(
      SshConfigEntry entry, List<HostConfig> existing) {
    return existing.any((h) =>
        h.host.toLowerCase() == entry.host.toLowerCase() && h.port == entry.port);
  }

  static List<SshConfigIncludedFile> _resolveInclude(
      String pattern, String home, String baseDir) {
    final expanded = _expandHome(pattern, home);
    final absolute = _isAbsolute(expanded) ? expanded : '$baseDir/$expanded';
    final results = <SshConfigIncludedFile>[];

    if (!_hasGlob(absolute)) {
      final file = File(absolute);
      if (file.existsSync()) {
        final text = _tryRead(file);
        if (text != null) results.add(SshConfigIncludedFile(absolute, text));
        return results;
      }
      // ssh_config 允许 Include 指向目录：目录下所有可读文件都算
      final dir = Directory(absolute);
      if (dir.existsSync()) {
        for (final e in dir.listSync().whereType<File>().toList()..sort(_byName)) {
          final text = _tryRead(e);
          if (text != null) results.add(SshConfigIncludedFile(e.path, text));
        }
      }
      return results;
    }

    final normalized = absolute.replaceAll(r'\', '/');
    final slash = normalized.lastIndexOf('/');
    final dirPath = slash <= 0 ? normalized : normalized.substring(0, slash);
    final namePattern = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return results;
    final matcher = _globMatcher(namePattern);
    final matched = dir
        .listSync()
        .whereType<File>()
        .where((f) => matcher(_basename(f.path)))
        .toList()
      ..sort(_byName);
    for (final f in matched) {
      final text = _tryRead(f);
      if (text != null) results.add(SshConfigIncludedFile(f.path, text));
    }
    return results;
  }

  static int _byName(File a, File b) =>
      _basename(a.path).compareTo(_basename(b.path));

  static String _basename(String path) {
    final i = path.replaceAll(r'\', '/').lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  static String? _tryRead(File f) {
    try {
      return f.readAsStringSync();
    } catch (_) {
      // Include 里单个文件读不到不该中断整个导入；上层 warnings 里会出现「未匹配到文件」
      return null;
    }
  }

  static String _expandHome(String path, String home) {
    if (path == '~') return home;
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      return '$home${path.substring(1)}';
    }
    return path;
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  static bool _hasGlob(String path) =>
      path.contains('*') || path.contains('?') || path.contains('[');

  static bool Function(String) _globMatcher(String pattern) {
    final sb = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '*') {
        sb.write('.*');
      } else if (ch == '?') {
        sb.write('.');
      } else if (ch == '[') {
        final end = pattern.indexOf(']', i);
        if (end < 0) {
          sb.write(RegExp.escape(ch));
        } else {
          sb.write(pattern.substring(i, end + 1));
          i = end;
        }
      } else {
        sb.write(RegExp.escape(ch));
      }
    }
    sb.write(r'$');
    final re = RegExp(sb.toString());
    return (name) => re.hasMatch(name);
  }
}
