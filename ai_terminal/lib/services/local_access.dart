import 'dart:io' show Platform;

import 'package:path/path.dart' as p;

import 'local_file_policy.dart';

enum LocalAccessMode {
  read,
  write,
  execute;

  String get label => switch (this) {
        LocalAccessMode.read => '读取',
        LocalAccessMode.write => '写入',
        LocalAccessMode.execute => '执行',
      };
}

class LocalAccessGrant {
  final String id;
  final String canonicalPath;
  final LocalAccessMode mode;
  final String taskId;
  final int generation;
  final DateTime expiresAt;
  final String reason;
  final bool allowSubdirectories;

  const LocalAccessGrant({
    required this.id,
    required this.canonicalPath,
    required this.mode,
    required this.taskId,
    required this.generation,
    required this.expiresAt,
    required this.reason,
    this.allowSubdirectories = true,
  });
}

class LocalAccessDenial {
  final String reason;
  const LocalAccessDenial(this.reason);
}

/// 单任务内存授权。任务结束即撤销，不写入全局白名单，也不跨重启恢复。
class LocalAccessService {
  final String taskId;
  final int generation;
  final bool Function() isActive;
  final Duration grantTtl;
  final Map<String, LocalAccessGrant> _grants = {};
  Future<bool> Function(String path, String reason, LocalAccessMode mode)?
      authorizationRequest;

  LocalAccessService({
    required this.taskId,
    required this.generation,
    required this.isActive,
    this.grantTtl = const Duration(minutes: 15),
    this.authorizationRequest,
  });

  bool get isCurrent => isActive() && taskId.isNotEmpty;

  LocalAccessGrant? _find(String canonicalPath, LocalAccessMode mode) {
    if (!isCurrent) return null;
    final now = DateTime.now();
    final candidate = _comparePath(canonicalPath);
    for (final grant in _grants.values) {
      if (grant.mode != mode ||
          grant.taskId != taskId ||
          grant.generation != generation ||
          !grant.expiresAt.isAfter(now)) {
        continue;
      }
      final root = _comparePath(grant.canonicalPath);
      final rootPrefix = root.endsWith('/') ? root : '$root/';
      if (candidate == root ||
          grant.allowSubdirectories && candidate.startsWith(rootPrefix)) {
        return grant;
      }
    }
    return null;
  }

  Object? decide(String canonicalPath, LocalAccessMode mode) {
    final grant = _find(canonicalPath, mode);
    if (grant != null) return grant;
    if (!isCurrent) {
      return const LocalAccessDenial('任务已结束或取消，本地授权失效');
    }
    return const LocalAccessDenial('当前任务没有此目录的对应访问权限');
  }

  Future<bool> authorize(
    String canonicalPath,
    LocalAccessMode mode,
    String reason,
  ) async {
    final existing = decide(canonicalPath, mode);
    if (existing is LocalAccessGrant) return true;
    if (!isCurrent) return false;
    final request = authorizationRequest;
    if (request == null) return false;
    final approved = await request(canonicalPath, reason, mode);
    if (!approved || !isCurrent) return false;
    issue(
      canonicalPath: canonicalPath,
      mode: mode,
      reason: reason,
    );
    return true;
  }

  LocalAccessGrant issue({
    required String canonicalPath,
    required LocalAccessMode mode,
    required String reason,
  }) {
    if (!isCurrent) {
      throw StateError('不能为已结束或取消的任务签发本地授权');
    }
    final grant = LocalAccessGrant(
      id: '${taskId}_${DateTime.now().microsecondsSinceEpoch}_${_grants.length}',
      canonicalPath: p.normalize(canonicalPath),
      mode: mode,
      taskId: taskId,
      generation: generation,
      expiresAt: DateTime.now().add(grantTtl),
      reason: reason,
    );
    _grants[grant.id] = grant;
    _prune();
    return grant;
  }

  void revokeAll() => _grants.clear();

  void _prune() {
    final now = DateTime.now();
    _grants.removeWhere((_, grant) => !grant.expiresAt.isAfter(now));
  }

  String _comparePath(String value) {
    var normalized = p.normalize(value).replaceAll(r'\', '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

Future<LocalPathDecision> authorizeLocalPath({
  required String rawPath,
  required LocalAccessMode mode,
  required LocalAccessService? access,
  required LocalFilePolicy policy,
  List<String> extraRoots = const [],
  required String reason,
}) async {
  final decision = policy.decide(rawPath, extraRoots: extraRoots);
  if (decision.verdict == LocalPathVerdict.sensitive ||
      decision.verdict == LocalPathVerdict.reserved ||
      decision.verdict == LocalPathVerdict.escape) {
    return decision;
  }
  if (access != null && !access.isCurrent) {
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      decision.resolved,
      '任务已结束、暂停或取消，本地授权失效',
    );
  }
  if (decision.isAllowed) return decision;
  if (access == null) return decision;
  final approved = await access.authorize(decision.resolved, mode, reason);
  if (!approved) {
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      decision.resolved,
      '用户未授权或任务级授权已失效（${mode.label}权限）',
    );
  }
  final rechecked = verifyLocalPathAccess(
    rawPath: rawPath,
    expectedResolved: decision.resolved,
    mode: mode,
    access: access,
    policy: policy,
    extraRoots: extraRoots,
  );
  if (rechecked.verdict == LocalPathVerdict.sensitive ||
      rechecked.verdict == LocalPathVerdict.reserved ||
      rechecked.verdict == LocalPathVerdict.escape) {
    return rechecked;
  }
  if (!rechecked.isAllowed) {
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      rechecked.resolved,
      '授权等待期间路径或任务状态已变化（${mode.label}权限）',
    );
  }
  return rechecked;
}

LocalPathDecision verifyLocalPathAccess({
  required String rawPath,
  required String expectedResolved,
  required LocalAccessMode mode,
  required LocalAccessService? access,
  required LocalFilePolicy policy,
  List<String> extraRoots = const [],
}) {
  final current = policy.decide(rawPath, extraRoots: extraRoots);
  if (current.verdict == LocalPathVerdict.sensitive ||
      current.verdict == LocalPathVerdict.reserved ||
      current.verdict == LocalPathVerdict.escape) {
    return current;
  }
  if (access != null && !access.isCurrent) {
    return LocalPathDecision(
      LocalPathVerdict.notInAllowlist,
      current.resolved,
      '任务已结束、暂停或取消，本地授权失效',
    );
  }
  final grant = access?.decide(expectedResolved, mode);
  final effectivePolicy = grant is LocalAccessGrant
      ? policy.copyWith(
          enabled: true,
          allowedDirs: [...policy.allowedDirs, grant.canonicalPath],
        )
      : policy;
  return effectivePolicy.verify(
    rawPath,
    expectedResolved,
    extraRoots: extraRoots,
  );
}
