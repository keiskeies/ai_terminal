import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/safety_guard.dart';
import 'daos.dart';

/// 本地文件路径判定结果
enum LocalPathVerdict {
  /// 允许访问
  allowed,

  /// 未落在用户授权的目录内
  notInAllowlist,

  /// 命中敏感路径黑名单（即使落在授权目录内也拒绝）
  sensitive,

  /// 路径里含 `..` 且跳出授权根目录
  escape,

  /// 系统保留目录（回收区），AI 不得直接读写
  reserved,
}

/// 一次路径判定的完整结论
class LocalPathDecision {
  final LocalPathVerdict verdict;

  /// 解析过符号链接、规范化后的绝对路径；后续 I/O 必须用它，避免 TOCTOU 换名
  final String resolved;
  final String? reason;

  const LocalPathDecision(this.verdict, this.resolved, [this.reason]);

  bool get isAllowed => verdict == LocalPathVerdict.allowed;
}

/// 本地文件工具的作用域策略
///
/// 仅当总开关开启时启用白名单；无论开关状态，敏感路径黑名单与回收区都不可访问。
/// 默认关闭且白名单为空：未授权前拒绝所有本地文件访问。
///
/// 符号链接单独处理：[SafetyGuard._normalizePath] 只做字面量规范化，不解析链接。
/// 允许 `work -> /home/user/.ssh` 这种软链存在就意味着白名单形同虚设，
/// 所以这里对**已存在的最深祖先**解析链接后再判定。
class LocalFilePolicy {
  /// 回收区目录名 —— 系统保留，AI 不能直接读写
  ///
  /// `local_file_delete` 默认把文件移进这里，"可回滚"完全依赖这份副本。
  /// 如果不保留它，AI 只要 `local_file_delete` 之后再 `local_file_write`
  /// 或再删一次回收区，就能把自己刚保护起来的东西抹掉 ——
  /// 回收区就从安全机制变成了攻击面。工具自身写入走的是 rename，
  /// 不经过 [decide]，所以保留目录不影响删除功能。
  static const String trashDirName = '.ai_terminal_trash';

  final bool enabled;
  final List<String> allowedDirs;

  /// 单次读取的字节上限：超过即拒绝，提示改用编辑器/SFTP，避免整份日志灌进对话历史
  final int maxReadBytes;

  const LocalFilePolicy({
    this.enabled = false,
    this.allowedDirs = const [],
    this.maxReadBytes = 2 * 1024 * 1024,
  });

  static const String _settingsKey = 'localFilePolicy';

  static LocalFilePolicy load() {
    try {
      final raw = SettingsDao.getCached(_settingsKey);
      if (raw == null) return const LocalFilePolicy();
      if (raw is Map) {
        return LocalFilePolicy.fromMap(raw.cast<String, dynamic>());
      }
      throw const FormatException('localFilePolicy 必须是 Map');
    } catch (e) {
      // 配置损坏时保持默认关闭且无授权目录，绝不能退化成开放语义。
      debugPrint('[LocalFilePolicy] 配置解析失败，已拒绝本地文件访问: $e');
      return const LocalFilePolicy();
    }
  }

  Future<void> save() async {
    await SettingsDao.set(_settingsKey, toMap());
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'allowedDirs': allowedDirs,
        'maxReadBytes': maxReadBytes,
      };

  factory LocalFilePolicy.fromMap(Map<String, dynamic> map) {
    final enabledValue = map['enabled'];
    if (enabledValue != null && enabledValue is! bool) {
      throw const FormatException('enabled 必须是 bool');
    }
    final dirsValue = map['allowedDirs'];
    if (dirsValue != null && dirsValue is! List) {
      throw const FormatException('allowedDirs 必须是 List');
    }
    final dirs = dirsValue == null
        ? const <String>[]
        : (dirsValue as List).map((value) {
            if (value is! String) {
              throw const FormatException('allowedDirs 每项必须是字符串');
            }
            return value;
          }).toList(growable: false);
    final readLimit = map['maxReadBytes'];
    if (readLimit != null &&
        (readLimit is! int || readLimit <= 0 || readLimit > 16 * 1024 * 1024)) {
      throw const FormatException('maxReadBytes 必须在 1..16MB 之间');
    }
    return LocalFilePolicy(
      enabled: enabledValue == true,
      allowedDirs: dirs,
      maxReadBytes: readLimit as int? ?? 2 * 1024 * 1024,
    );
  }

  LocalFilePolicy copyWith({
    bool? enabled,
    List<String>? allowedDirs,
    int? maxReadBytes,
  }) =>
      LocalFilePolicy(
        enabled: enabled ?? this.enabled,
        allowedDirs: allowedDirs ?? this.allowedDirs,
        maxReadBytes: maxReadBytes ?? this.maxReadBytes,
      );

  /// 判定一个 AI 给出的路径能否访问
  ///
  /// [extraRoots] 本次任务额外授权的根（如 project_analyze 记录过的项目目录）。
  /// 传空时只看用户白名单。
  LocalPathDecision decide(String rawPath,
      {List<String> extraRoots = const []}) {
    if (rawPath.trim().isEmpty) {
      return const LocalPathDecision(
          LocalPathVerdict.notInAllowlist, '', '路径为空');
    }

    final expanded = _expand(rawPath);
    final lexical = p.normalize(expanded);
    // 字面路径本身命中黑名单/回收区时也不能借符号链接改名绕过。
    final lexicalDenied = _hardDenial(lexical);
    if (lexicalDenied != null) return lexicalDenied;

    final resolved = _resolveNoFollow(lexical);
    if (resolved == null) {
      return LocalPathDecision(
        LocalPathVerdict.escape,
        lexical,
        '符号链接解析失败，无法验证真实路径，已拒绝访问。',
      );
    }
    final canonical = p.normalize(resolved);
    final resolvedDenied = _hardDenial(canonical);
    if (resolvedDenied != null) return resolvedDenied;

    if (!enabled) {
      return LocalPathDecision(
        LocalPathVerdict.notInAllowlist,
        canonical,
        '本地文件访问总开关已关闭，请在设置中开启并授权目录。',
      );
    }

    final roots = <String>[];
    for (final root in [...allowedDirs, ...extraRoots]) {
      if (root.trim().isEmpty) continue;
      final normalizedRoot = _resolveNoFollow(_expand(root));
      if (normalizedRoot == null) {
        return LocalPathDecision(
          LocalPathVerdict.escape,
          canonical,
          '授权目录符号链接解析失败，已拒绝访问。',
        );
      }
      roots.add(_normalizeForCompare(normalizedRoot));
    }
    if (roots.isEmpty) {
      return LocalPathDecision(
        LocalPathVerdict.notInAllowlist,
        canonical,
        '尚未配置任何允许访问的目录，请先在设置中添加授权目录。',
      );
    }
    final probe = _normalizeForCompare(canonical);
    for (final root in roots) {
      if (_isWithin(probe, root)) {
        return LocalPathDecision(LocalPathVerdict.allowed, canonical);
      }
    }
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      canonical,
      '路径不在授权目录内。当前授权: ${allowedDirs.join(', ')}',
    );
  }

  /// 在即将发生 I/O 前重新解析原始路径，并确认它仍指向本次已授权的同一对象。
  /// 可拦截校验后发生的 link-swap；最后检查与打开文件之间仍存在无法消除的
  /// 平台级 TOCTOU 窗口，因此调用方还应优先使用已打开的句柄写入。
  LocalPathDecision verify(String rawPath, String expectedResolved,
      {List<String> extraRoots = const []}) {
    final current = decide(rawPath, extraRoots: extraRoots);
    if (!current.isAllowed) return current;
    if (_normalizeForCompare(current.resolved) !=
        _normalizeForCompare(expectedResolved)) {
      return LocalPathDecision(
        LocalPathVerdict.escape,
        current.resolved,
        '路径在校验后发生变化，已拒绝访问。',
      );
    }
    return current;
  }

  LocalPathDecision? _hardDenial(String path) {
    if (p.split(path).contains(trashDirName)) {
      return LocalPathDecision(
        LocalPathVerdict.reserved,
        path,
        '$trashDirName 是回收区，只能由删除工具自身写入，不能直接访问。',
      );
    }
    final safety = SafetyGuard.checkPath(path);
    if (safety.level == SafetyLevel.blocked) {
      return LocalPathDecision(
          LocalPathVerdict.sensitive, path, safety.reason ?? '敏感路径');
    }
    return null;
  }

  /// 列出当前授权目录（设置页与错误提示用）
  List<String> get roots => allowedDirs;

  // ──────────────────────────────────────────────────────────
  // 内部工具
  // ──────────────────────────────────────────────────────────

  String _expand(String path) {
    var s = path.trim();
    if (s == '~' || s.startsWith('~/') || s.startsWith(r'~\')) {
      final home = _homeDir();
      if (home != null) {
        s = p.join(home, s.substring(1).replaceFirst(RegExp(r'^[/\\]'), ''));
      }
    }
    if (!p.isAbsolute(s)) {
      s = p.join(Directory.current.path, s);
    }
    return s;
  }

  static String? _homeDir() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  /// 比较用的规范化：统一分隔符 + Windows 下大小写不敏感
  String _normalizeForCompare(String path) {
    var s = p.normalize(path).replaceAll(r'\', '/');
    if (Platform.isWindows) s = s.toLowerCase();
    return s.endsWith('/') && s.length > 1 ? s.substring(0, s.length - 1) : s;
  }

  bool _isWithin(String child, String root) {
    if (child == root) return true;
    final prefix = root.endsWith('/') ? root : '$root/';
    return child.startsWith(prefix);
  }

  /// 解析路径里的符号链接，但允许末段不存在（新建文件的场景）。
  ///
  /// 做法：从目标往上找到最深的**已存在**祖先，解析它的真实路径，再把剩余段拼回去。
  /// 这样 `work/evil -> /etc` 这类跳出会在祖先这一层就被识别出来。
  String? _resolveNoFollow(String absolute) {
    try {
      var normalized = p.normalize(absolute);
      // POSIX 下前导 // 的实现定义且可能绕过字符串前缀比较，统一收敛为 /。
      // Windows 的 UNC 根必须保留，不能按 POSIX 规则折叠。
      if (!Platform.isWindows) {
        normalized = normalized.replaceFirst(RegExp(r'^/+'), '/');
      }
      if (normalized.isEmpty) return null;

      final missing = <String>[];
      var cursor = normalized;
      var type = FileSystemEntity.typeSync(cursor, followLinks: false);
      while (type == FileSystemEntityType.notFound) {
        final parent = p.dirname(cursor);
        if (parent == cursor) return null;
        missing.insert(0, p.basename(cursor));
        cursor = parent;
        type = FileSystemEntity.typeSync(cursor, followLinks: false);
      }

      final String real;
      switch (type) {
        case FileSystemEntityType.link:
          // Link.resolveSymbolicLinksSync 会解析目标；断链同样抛错，必须拒绝。
          real = Link(cursor).resolveSymbolicLinksSync();
          break;
        case FileSystemEntityType.file:
          real = File(cursor).resolveSymbolicLinksSync();
          break;
        case FileSystemEntityType.directory:
          real = Directory(cursor).resolveSymbolicLinksSync();
          break;
        default:
          return null;
      }
      final result = missing.isEmpty
          ? p.normalize(real)
          : p.normalize(p.joinAll([real, ...missing]));
      return result;
    } catch (e) {
      // 权限、断链、平台不支持等任何解析失败都 fail-closed，不能退回字面量。
      debugPrint('[LocalFilePolicy] 符号链接解析失败($absolute): $e');
      return null;
    }
  }
}
