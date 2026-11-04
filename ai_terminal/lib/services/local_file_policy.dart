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
/// 两道门，缺一不可：
/// 1. **白名单**：路径必须落在用户显式授权的目录内。默认空 —— 装完不授权就一个文件都读不到。
/// 2. **黑名单**：复用 [SafetyGuard.checkPath]（`~/.ssh`、`.env`、`/etc` 等）。
///    白名单是"能进哪些门"，黑名单是"进了门也不能碰什么"，后者优先级更高：
///    用户把整个家目录加进白名单时，`~/.ssh/authorized_keys` 仍然必须拒绝 ——
///    否则 AI 拿到本机写权限就等于能持久化控制这台机器。
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
      if (raw is Map) {
        return LocalFilePolicy.fromMap(raw.cast<String, dynamic>());
      }
    } catch (e) {
      // 配置读不出来时按"未授权"处理，绝不因为解析失败就放开文件访问
      debugPrint('[LocalFilePolicy] 配置解析失败，按关闭处理: $e');
    }
    return const LocalFilePolicy();
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
    return LocalFilePolicy(
      enabled: map['enabled'] == true,
      allowedDirs: (map['allowedDirs'] as List?)?.map((e) => '$e').toList() ?? const [],
      maxReadBytes: map['maxReadBytes'] is int ? map['maxReadBytes'] as int : 2 * 1024 * 1024,
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
  LocalPathDecision decide(String rawPath, {List<String> extraRoots = const []}) {
    if (rawPath.trim().isEmpty) {
      return const LocalPathDecision(
          LocalPathVerdict.notInAllowlist, '', '路径为空');
    }
    if (!enabled) {
      return LocalPathDecision(
        LocalPathVerdict.notInAllowlist,
        rawPath,
        '本地文件访问未开启。请在 设置 → Agent → 本地文件 中添加允许访问的目录。',
      );
    }

    final absolute = _resolveNoFollow(_expand(rawPath));
    final lexical = p.normalize(absolute);

    // 0. 系统保留目录（回收区）先拒：它由删除工具自己写入，
    //    AI 直接访问会破坏"删了还能捞回来"这个前提
    if (p.split(lexical).contains(trashDirName)) {
      return LocalPathDecision(
        LocalPathVerdict.reserved,
        lexical,
        '$trashDirName 是回收区，只能由删除工具自身写入，不能直接访问。',
      );
    }

    // 1. 黑名单优先：进了白名单目录也不能碰敏感路径
    final safety = SafetyGuard.checkPath(lexical);
    if (safety.level == SafetyLevel.blocked) {
      return LocalPathDecision(
          LocalPathVerdict.sensitive, lexical, safety.reason ?? '敏感路径');
    }

    // 2. 白名单
    final roots = [...allowedDirs, ...extraRoots]
        .where((r) => r.trim().isNotEmpty)
        .map((r) => _normalizeForCompare(_resolveNoFollow(_expand(r))))
        .toList();
    if (roots.isEmpty) {
      return LocalPathDecision(
        LocalPathVerdict.notInAllowlist,
        lexical,
        '尚未配置任何允许访问的目录。',
      );
    }
    final probe = _normalizeForCompare(lexical);
    for (final root in roots) {
      if (_isWithin(probe, root)) {
        return LocalPathDecision(LocalPathVerdict.allowed, lexical);
      }
    }
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      lexical,
      '路径不在授权目录内。当前授权: ${allowedDirs.join(', ')}',
    );
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

  static String? _homeDir() => Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];

  /// 比较用的规范化：统一分隔符 + Windows 下大小写不敏感
  String _normalizeForCompare(String path) {
    var s = p.normalize(path).replaceAll(r'\', '/');
    if (Platform.isWindows) s = s.toLowerCase();
    return s.endsWith('/') && s.length > 1 ? s.substring(0, s.length - 1) : s;
  }

  bool _isWithin(String child, String root) {
    if (child == root) return true;
    return child.startsWith('$root/');
  }

  /// 解析路径里的符号链接，但允许末段不存在（新建文件的场景）。
  ///
  /// 做法：从目标往上找到最深的**已存在**祖先，解析它的真实路径，再把剩余段拼回去。
  /// 这样 `work/evil -> /etc` 这类跳出会在祖先这一层就被识别出来。
  String _resolveNoFollow(String absolute) {
    final normalized = p.normalize(absolute);
    final missing = <String>[];
    var cursor = normalized;

    while (!_exists(cursor)) {
      final parent = p.dirname(cursor);
      if (parent == cursor) break; // 已到根
      missing.insert(0, p.basename(cursor));
      cursor = parent;
    }

    String real = cursor;
    try {
      
      if (FileSystemEntity.isFileSync(cursor)) {
        real = File(cursor).resolveSymbolicLinksSync();
      } else if (FileSystemEntity.isDirectorySync(cursor)) {
        real = Directory(cursor).resolveSymbolicLinksSync();
      }
    } catch (e) {
      // 解析失败（权限、平台不支持）时退回字面量路径。
      // 注意这里不能"失败即放行"：退回的字面量仍要过白名单与黑名单判定，
      // 只是少了一层链接解析的强度。
      debugPrint('[LocalFilePolicy] 符号链接解析失败($cursor): $e');
    }

    if (missing.isEmpty) return p.normalize(real);
    return p.normalize(p.joinAll([real, ...missing]));
  }

  bool _exists(String path) {
    try {
      // 三种实体都查一遍：File/Directory 的 existsSync 会跟随链接，
      // 断链两者都返回 false，只有 Link 查得出来 —— 而断链也必须算"存在"，
      // 否则 _resolveNoFollow 会把祖先一路走到根，判定就失效了。
      return File(path).existsSync() ||
          Directory(path).existsSync() ||
          Link(path).existsSync();
    } catch (_) {
      return false;
    }
  }
}
