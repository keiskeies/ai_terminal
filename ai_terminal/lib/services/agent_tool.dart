import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'command_executor.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'local_terminal_service.dart';
import 'file_sync_service.dart';
import 'multi_host_executor.dart';
import 'agent_host_registry.dart';
import '../core/l10n_holder.dart';
import '../core/ui_text.dart';
import '../models/host_execution_result.dart';
import '../models/agent_permission_mode.dart';
import '../utils/line_diff.dart';
import '../utils/local_file_ops.dart';
import '../utils/tool_args_parser.dart';
import 'local_file_tools.dart';
import 'local_file_policy.dart';
import 'local_access.dart';
import 'local_exec_tool.dart';
import 'project_tools.dart';
import 'web_tools.dart';

/// Agent 工具调用结果
class ToolResult {
  final bool success;
  final String output;
  final String? error;

  /// 多主机批量结果（exec_batch 等工具使用）
  final Map<String, HostExecutionResult>? hostResults;

  /// 文件补丁的行级改动统计
  final int? diffAdditions;
  final int? diffDeletions;

  /// 本机文件还原对：把 [restoreFrom]（备份或回收区里的副本）放回 [restoreTo]。
  ///
  /// 只有 `local_*` 工具会填 —— 远程文件变更的回滚走 shell 命令，
  /// 本机变更必须走 Dart I/O，否则在 SSH 会话里点"回滚"会打到远端机器。
  final String? restoreFrom;
  final String? restoreTo;

  const ToolResult({
    required this.success,
    required this.output,
    this.error,
    this.hostResults,
    this.diffAdditions,
    this.diffDeletions,
    this.restoreFrom,
    this.restoreTo,
  });

  factory ToolResult.success(
    String output, {
    Map<String, HostExecutionResult>? hostResults,
    int? diffAdditions,
    int? diffDeletions,
    String? restoreFrom,
    String? restoreTo,
  }) =>
      ToolResult(
        success: true,
        output: output,
        error: null,
        hostResults: hostResults,
        diffAdditions: diffAdditions,
        diffDeletions: diffDeletions,
        restoreFrom: restoreFrom,
        restoreTo: restoreTo,
      );

  factory ToolResult.failure(
    String error, {
    String? output,
    Map<String, HostExecutionResult>? hostResults,
  }) =>
      ToolResult(
        success: false,
        output: output ?? '',
        error: error,
        hostResults: hostResults,
      );
}

/// 工具副作用类别 — 安全语义的唯一来源
///
/// 引擎与台账都从这里派生判断，禁止再维护第二份"哪些工具会改文件"的名单：
/// 历史上 `ChangeRecordService._fileChangeTools` 就是硬编码枚举工具名，
/// 新增写类工具时忘记同步就会静默丢失变更台账（AGENTS.md R5-4 黑名单反例）。
enum ToolKind {
  /// 只读：读文件、列目录、搜索、连通性检查
  read,

  /// 写入：创建/覆盖/补丁/移动，产生可回滚的变更
  write,

  /// 破坏性：删除等不可逆操作，必须用户确认
  destructive,

  /// 外联：访问公网（web_search / fetch_url），不触碰主机状态
  network,

  /// 编排：打到多台主机的命令执行
  orchestration,
}

/// 工具来源 — 为后续接入 MCP server 预留的扩展点
enum ToolSource {
  /// Dart 内置实现
  builtin,

  /// 外部 MCP server（尚未实现，见 docs/agent-builtin-tools-timeline-design.md §6）
  mcpServer,
}

/// 工具可见作用域 — 决定工具在什么会话里暴露给 AI
///
/// 提示词与 FC schema 都必须走 [AgentToolRegistry.visibleFor]，
/// 否则会出现"提示词宣传了未注册的工具"这类必失败路径（设计稿 D1）。
enum ToolScope {
  /// 任何会话
  all,

  /// 仅 SSH 远程会话
  sshSession,

  /// 仅本地终端会话
  localSession,

  /// 仅多机编排模式
  orchestrator,
}

/// Agent 工具抽象
/// 工具是 agent_engine 之外的能力扩展点。
/// AI 通过 "动作: tool" + "工具: xxx" + "参数:" + 多行 key:value 协议调用。
/// 引擎拦截后路由到对应工具的 execute 方法。
abstract class AgentTool {
  /// 工具名（AI 调用时使用，如 sftp_upload）
  String get name;

  /// 工具描述（注入 system prompt，告诉 AI 何时用）
  String get description;

  /// 参数说明（注入 system prompt，告诉 AI 怎么填参数）
  /// 返回 JSON schema 描述字符串
  String get paramSpec;

  /// 副作用类别；默认按 write 处理（未知即保守：视为会产生变更）
  ToolKind get kind => ToolKind.write;

  /// 工具来源
  ToolSource get source => ToolSource.builtin;

  /// 当前任务取消令牌（由 AgentEngine 在 execute 前注入）
  ///
  /// 工具内部调用 [CommandExecutor.executeAndWait] / [CommandExecutor.writeFileViaPty]
  /// 时应透传此令牌，让 cancelTask 能立即中断正在执行的命令或文件写入。
  /// 串行 Agent 模型下保证一次只有一个 tool 在执行，因此单字段安全。
  Completer<void>? cancelToken;

  /// 请用户输入 sudo 密码并落到安全存储（由 AgentEngine 在 execute 前注入）。
  ///
  /// 返回 true = 已收集并启用自动应答。刻意**不**返回密码本身：
  /// 工具一旦拿到明文就可能把它拼进 ToolResult.output，而 output 会进
  /// 对话历史并被模型读到（AGENTS.md R7）。
  Future<bool> Function(String reason)? sudoPasswordRequest;

  /// 当前任务的本地授权上下文（由 AgentEngine 在 execute 前注入）。
  /// 授权按 read / write / execute 分离，任务结束即失效。
  LocalAccessService? localAccess;

  /// 当前任务是否仍有效（local_exec 在用户授权等待后、真正执行前检查）。
  /// 授权弹窗可能停留很久，期间任务被取消/暂停时不能继续产生本机副作用。
  bool Function()? isTaskActive;

  /// 本次工具调用的权限档位快照，仅供审计使用，不参与授权判定。
  AgentPermissionMode? permissionMode;

  /// 只读工具（kind == read）
  bool get isReadOnly => kind == ToolKind.read;

  /// 会产生变更、需要进台账与回滚的工具
  bool get recordsChanges =>
      kind == ToolKind.write || kind == ToolKind.destructive;

  /// MCP tool 描述符。
  ///
  /// 形状对齐 MCP 协议（name + description + inputSchema + annotations），
  /// 将来接 stdio/SSE server 时外部工具可直接映射到 [AgentTool]，
  /// 不需要再改注册表与引擎契约。
  ///
  /// 注解只发这三个：`idempotentHint` 故意**不**从 `kind` 派生 —— 同为
  /// `ToolKind.write`，`file_write` 是幂等的而 `file_patch` 不是（第二次替换
  /// 就找不到 old 了），按 kind 猜会对外部 client 撒谎。真要提供得加一个
  /// 每工具可覆写的 getter，那是 MCP 客户端落地时的事。
  Map<String, dynamic> get mcpDescriptor => {
        'name': name,
        'description': description,
        // MCP 要求 inputSchema 必须是 schema 对象；[toJsonSchema] 返回 null
        // 只表示"不参与 OpenAI FC"，不能因此吐出一个非法描述符。
        'inputSchema': toJsonSchema() ??
            {
              'type': 'object',
              'properties': const <String, dynamic>{},
              'description': paramSpec,
              'additionalProperties': true,
            },
        'annotations': {
          'readOnlyHint': kind == ToolKind.read,
          'destructiveHint': kind == ToolKind.destructive,
          'openWorldHint': kind == ToolKind.network,
        },
      };

  /// P2-6: 返回 OpenAI tools API 格式的 JSON schema。
  /// 默认实现基于 paramSpec 生成一个宽松的 schema（type=object + 任意属性）。
  /// 子类可重写以提供精确的参数类型。
  /// 返回 null 表示该工具不参与 FC（仅文本协议可用）。
  Map<String, dynamic>? toJsonSchema() {
    // 默认实现：宽松 schema，让 AI 自由填参数，由 execute 内部校验。
    // 参数必须是**顶层**键：早先这里把参数包成 `args` 对象，模型照做后
    // file_write 拿到 {"args": {path, content}}，必填校验读不到 path 直接失败
    // （真机验证：写文件工具连续两轮报「参数缺失: path 为必填项」）。
    return {
      'type': 'object',
      'description': paramSpec,
      'properties': const <String, dynamic>{},
      'additionalProperties': true,
    };
  }

  /// 执行工具
  /// [executor] 当前命令执行器（可能是 SSHService 或本地终端）
  /// [args] AI 传入的参数（已解析的 Map）
  /// [onProgress] 进度回调（可选）
  ///
  /// 子类如需响应取消，应读取 [cancelToken] 并透传给 executor.executeAndWait /
  /// writeFileViaPty。基类只提供字段，不强制要求子类使用。
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  });
}

/// SFTP 上传工具
/// 支持：单文件上传、目录递归上传
/// 参数：
///   - local: 本地文件/目录绝对路径（必填）
///   - remote: 远程目标绝对路径（必填）
///   - recursive: 是否递归上传目录（bool，默认 false）
///   - exclude: 排除的目录/文件名列表（可选，仅 recursive=true 时生效）
/// 目录上传的取消 + 同目标串行 + 进度节流。
///
/// 工具层的旧上传在任务取消后不会自己知道（工具没有 cancelToken 时尤其如此），
/// 这里用 isTaskActive 每 250ms 探测一次，并把它转成 SftpService 能识别的
/// cancelToken；同时用 host:port:user 锁避免新旧两个上传同时跑。

/// POSIX 参数引用。单引号内部不能直接转义单引号，必须结束当前引号、
/// 插入转义的单引号，再重新开始；仅替换单引号或使用黑名单都不安全。
String _quotePosixArgument(String value) =>
    "'${value.replaceAll("'", "'\\''")}'";

LocalPathDecision _decideLocalPath(
  String path, {
  LocalAccessService? access,
  LocalAccessMode mode = LocalAccessMode.read,
}) {
  final policy = LocalFilePolicy.load();
  final initial = policy.decide(path);
  if (initial.verdict == LocalPathVerdict.sensitive ||
      initial.verdict == LocalPathVerdict.reserved ||
      initial.verdict == LocalPathVerdict.escape) {
    return initial;
  }
  return verifyLocalPathAccess(
    rawPath: path,
    expectedResolved: initial.resolved,
    mode: mode,
    access: access,
    policy: policy,
  );
}

LocalPathDecision _verifyLocalPath(
  String rawPath,
  String expectedResolved, {
  LocalAccessService? access,
  LocalAccessMode mode = LocalAccessMode.read,
}) =>
    verifyLocalPathAccess(
      rawPath: rawPath,
      expectedResolved: expectedResolved,
      mode: mode,
      access: access,
      policy: LocalFilePolicy.load(),
    );

String _localPathDeniedMessage(String path, LocalPathDecision decision) =>
    '本地路径未获授权: $path${decision.reason == null ? '' : '\n${decision.reason}'}';

String? _freshLocalPathDenial(
  String rawPath,
  String expectedResolved, {
  LocalAccessService? access,
  LocalAccessMode mode = LocalAccessMode.read,
}) {
  final decision = _verifyLocalPath(
    rawPath,
    expectedResolved,
    access: access,
    mode: mode,
  );
  return decision.isAllowed ? null : _localPathDeniedMessage(rawPath, decision);
}

Future<String?> _createVerifiedLocalDirectory(
  String path,
  Completer<void>? cancelToken, {
  LocalAccessService? access,
}) async {
  if (cancelToken?.isCompleted == true) return '下载已取消';
  if (await Directory(path).exists()) {
    return _freshLocalPathDenial(path, path,
        access: access, mode: LocalAccessMode.write);
  }
  final parent = p.dirname(path);
  final parentDenial = _freshLocalPathDenial(parent, parent,
      access: access, mode: LocalAccessMode.write);
  if (parentDenial != null) return parentDenial;
  final denial = _freshLocalPathDenial(path, path,
      access: access, mode: LocalAccessMode.write);
  if (denial != null) return denial;
  await Directory(path).create(recursive: true);
  return _freshLocalPathDenial(path, path,
      access: access, mode: LocalAccessMode.write);
}

/// 返回空字符串表示已确认是 POSIX shell；否则给出保守拒绝原因。
String _unsupportedPosixShellReason(CommandExecutor? executor) {
  if (executor is SSHService) {
    final os = executor.osInfo.trim().toLowerCase();
    if (os.contains('windows') ||
        os.contains('mingw') ||
        os.contains('cygwin')) {
      return '目标主机使用 Windows shell，不支持 POSIX grep/tail/diff 命令';
    }
    if (os.isEmpty || os == 'unknown') {
      return '无法确认目标主机 shell，拒绝执行 POSIX grep/tail/diff 命令';
    }
    return '';
  }
  if (executor is LocalTerminalService) {
    return Platform.isWindows
        ? '目标主机使用 Windows PowerShell/cmd，不支持 POSIX grep/tail/diff 命令'
        : '';
  }
  return '无法确认目标主机 shell，拒绝执行 POSIX grep/tail/diff 命令';
}

String? _normalizedRemotePath(String path) {
  if (path.isEmpty || path.contains('\x00') || !p.posix.isAbsolute(path)) {
    return null;
  }
  return p.posix.normalize(path);
}

/// 目录上传会在 SftpService 内再次遍历。这里先按相同排除规则检查所有实际
/// 文件/目录，避免只检查根目录后，把授权目录内的敏感文件一并读走。
Future<String?> _preflightDirectoryUpload(
  String rawPath,
  List<String> excludeNames, {
  LocalAccessService? access,
}) async {
  final decision =
      _decideLocalPath(rawPath, access: access, mode: LocalAccessMode.read);
  if (!decision.isAllowed) return _localPathDeniedMessage(rawPath, decision);
  final root = Directory(decision.resolved);
  if (!await root.exists()) return '本地目录不存在: ${decision.resolved}';
  var entries = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (++entries > 10000) {
      return '本地目录条目超过 10000，拒绝递归上传；请缩小范围或改用归档。';
    }
    final relative = p.relative(entity.path, from: decision.resolved);
    if (p.split(relative).any(excludeNames.contains)) continue;
    if (entity is! File && entity is! Directory) continue;
    final entityDecision = _decideLocalPath(entity.path,
        access: access, mode: LocalAccessMode.read);
    if (!entityDecision.isAllowed) {
      return _localPathDeniedMessage(entity.path, entityDecision);
    }
  }
  return null;
}

class _DirectoryDownloadPlan {
  final List<String> directories = [];
  final List<_DirectoryDownloadFile> files = [];
  final DownloadDirectoryResult result = DownloadDirectoryResult();
  String? error;
}

class _DirectoryDownloadFile {
  final String remote;
  final String local;
  const _DirectoryDownloadFile(this.remote, this.local);
}

bool _isSafeRemoteEntryName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains(r'\');

/// 先列出完整远程清单并检查每个最终本地路径，全部通过后才允许创建目录或
/// 下载文件。不能直接调用 SftpService.downloadDirectory：它在内部重新遍历，
/// 预检与实际写入之间新增的路径会绕过策略。
Future<_DirectoryDownloadPlan> _planDirectoryDownload({
  required Future<List<SftpEntry>> Function(String remotePath) listDirectory,
  required String remoteDir,
  required String localRoot,
  required List<String> excludeNames,
  LocalAccessService? access,
}) async {
  final plan = _DirectoryDownloadPlan();
  var scannedEntries = 0;
  Future<void> collect(String remotePath, List<String> relativeParts) async {
    if (relativeParts.length > 64) {
      plan.error = '远程目录层级超过 64，已停止下载。';
      return;
    }
    final entries = await listDirectory(remotePath);
    for (final entry in entries) {
      if (++scannedEntries > 10000) {
        plan.error = '远程目录条目超过 10000，已停止下载；请缩小范围。';
        return;
      }
      if (excludeNames.contains(entry.name)) continue;
      if (!_isSafeRemoteEntryName(entry.name)) {
        plan.error = '远程目录包含不安全的文件名，已停止下载: ${entry.path}';
        return;
      }
      final childParts = [...relativeParts, entry.name];
      final relative = p.posix.joinAll(childParts);
      if (entry.isDirectory) {
        final localDir = p.joinAll([localRoot, ...childParts]);
        final decision = _decideLocalPath(localDir,
            access: access, mode: LocalAccessMode.write);
        if (!decision.isAllowed) {
          plan.error = _localPathDeniedMessage(localDir, decision);
          return;
        }
        if (!p.isWithin(
            p.normalize(localRoot), p.normalize(decision.resolved))) {
          plan.error = '下载目录越出本地根目录: $localDir';
          return;
        }
        plan.directories.add(decision.resolved);
        await collect(entry.path, childParts);
        if (plan.error != null) return;
      } else if (entry.isSymbolicLink) {
        plan.result.skippedLinks.add(relative);
      } else {
        final localFile = p.joinAll([localRoot, ...childParts]);
        final decision = _decideLocalPath(localFile,
            access: access, mode: LocalAccessMode.write);
        if (!decision.isAllowed) {
          plan.error = _localPathDeniedMessage(localFile, decision);
          return;
        }
        if (!p.isWithin(
            p.normalize(localRoot), p.normalize(decision.resolved))) {
          plan.error = '下载目标越出本地根目录: $localFile';
          return;
        }
        plan.files.add(_DirectoryDownloadFile(
            p.posix.join(remoteDir, relative), decision.resolved));
      }
    }
  }

  await collect(remoteDir, const []);
  plan.result.totalFiles = plan.files.length;
  return plan;
}

Future<ToolResult> _runDirectoryUploadWithCancel({
  required SftpService sftp,
  required SSHService ssh,
  required String local,
  required String effectiveRemote,
  required List<String> excludeNames,
  required void Function(String message)? onProgress,
  required Completer<void>? cancelToken,
  required bool Function()? isTaskActive,
  LocalAccessService? access,
  String prefix = '',
}) async {
  if (isTaskActive?.call() == false || cancelToken?.isCompleted == true) {
    return ToolResult.failure('$prefix上传已取消');
  }
  final policyError =
      await _preflightDirectoryUpload(local, excludeNames, access: access);
  if (policyError != null) return ToolResult.failure('$prefix$policyError');
  final checked =
      _decideLocalPath(local, access: access, mode: LocalAccessMode.read);
  if (!checked.isAllowed) {
    return ToolResult.failure(
        '$prefix${_localPathDeniedMessage(local, checked)}');
  }

  final transferCancel = Completer<void>();
  final timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (transferCancel.isCompleted) return;
    if (cancelToken?.isCompleted == true || isTaskActive?.call() == false) {
      transferCancel.complete();
    }
  });

  final lockKey = sftpUploadLockKey(
    host: ssh.config.host,
    port: ssh.config.port,
    username: ssh.config.username,
  );
  var locked = false;
  try {
    if (DirectoryUploadLock.isLocked(lockKey)) {
      onProgress?.call(L10n.str.ut_e36f09192f(prefix));
    }
    await DirectoryUploadLock.acquire(lockKey, cancelToken: transferCancel);
    locked = true;
    final beforeUpload =
        _decideLocalPath(local, access: access, mode: LocalAccessMode.read);
    if (!beforeUpload.isAllowed) {
      return ToolResult.failure(
          '$prefix${_localPathDeniedMessage(local, beforeUpload)}');
    }

    final progressWatch = Stopwatch()..start();
    var lastProgressMs = -1000;
    final result = await sftp.uploadDirectory(
      local,
      effectiveRemote,
      excludeNames: excludeNames,
      cancelToken: transferCancel,
      validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
          raw, expected,
          access: access, mode: LocalAccessMode.read),
      onProgress: (uploaded, total) {
        final now = progressWatch.elapsedMilliseconds;
        if (uploaded >= total || now - lastProgressMs >= 1000) {
          lastProgressMs = now;
          onProgress?.call(L10n.str.ut_dc39c308a2(prefix, uploaded, total));
        }
      },
    );

    if (result.cancelled) {
      return ToolResult.failure(
        '$prefix上传已取消: ${result.summary}',
        output: '$prefix${result.summary}\n目标路径: $effectiveRemote',
      );
    }
    if (result.allSuccess) {
      return ToolResult.success(
        '$prefix${result.summary}\n目标路径: $effectiveRemote',
      );
    }
    return ToolResult(
      success: false,
      output: '$prefix${result.summary}\n目标路径: $effectiveRemote',
      error: '$prefix${result.failedFiles.length} 个文件上传失败',
    );
  } on SftpTransferCancelled {
    return ToolResult.failure('$prefix上传已取消');
  } finally {
    timer.cancel();
    if (locked) DirectoryUploadLock.release(lockKey);
  }
}

class SftpUploadTool extends AgentTool {
  @override
  String get name => 'sftp_upload';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description =>
      '上传本地文件或目录到 SSH 远程服务器。用于部署项目、传输文件等场景。仅适用于已连接 SSH 远程会话。'
      '目录上传语义：把 local 目录放到 remote 目录下，自动在 remote 内创建 basename(local) 子目录。'
      '例如 local=/path/story、remote=/tmp → 实际传到 /tmp/story；若 remote 已含同名末段（如 /tmp/story）则不重复追加。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  local: 本地路径（必填）\n  remote: 远程目标父目录（必填，目录上传时自动在其下创建 basename 子目录）\n  recursive: 是否递归上传目录（true/false，默认 false）\n  exclude: 排除项（可选，逗号分隔，如 node_modules,.git）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    // 参数校验
    final local = args.getString('local');
    final rawRemote = args.getString('remote');
    final remote = _normalizedRemotePath(rawRemote);
    final recursive = args.getBool('recursive');
    final excludeArg = args.getStringList('exclude');

    if (local.isEmpty || remote == null) {
      return ToolResult.failure('参数缺失或无效: local 必填，remote 必须是 POSIX 绝对路径');
    }
    if (cancelToken?.isCompleted == true || isTaskActive?.call() == false) {
      return ToolResult.failure('上传已取消');
    }

    // 仅支持 SSH 远程会话
    if (executor is! SSHService) {
      return ToolResult.failure('sftp_upload 仅支持 SSH 远程会话，当前为本地终端');
    }

    // 本地源文件/目录与远程目标不同，必须先获得本机读取授权。
    final policy = LocalFilePolicy.load();
    final localDecision = await authorizeLocalPath(
      rawPath: local,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: policy,
      reason: 'sftp_upload 需要读取本地文件或目录并上传到远程服务器：$local',
    );
    if (!localDecision.isAllowed) {
      return ToolResult.failure(_localPathDeniedMessage(local, localDecision));
    }
    final localPath = localDecision.resolved;

    // 校验本地路径存在
    bool isDir;
    final dir = Directory(localPath);
    final file = File(localPath);
    if (await dir.exists()) {
      isDir = true;
    } else if (await file.exists()) {
      isDir = false;
    } else {
      return ToolResult.failure(L10n.str.orchToolLocalNotFound(localPath));
    }

    // 如果是目录但没指定 recursive，提示
    if (isDir && !recursive) {
      return ToolResult.failure(
        '本地路径是目录，请设置 recursive=true 以递归上传',
        output: '提示: 如需上传单文件，请指定文件路径而非目录路径',
      );
    }

    // 解析排除列表
    List<String> excludeNames =
        excludeArg.isEmpty ? ['node_modules', '.git', '.DS_Store'] : excludeArg;
    if (isDir) {
      final policyError = await _preflightDirectoryUpload(
          localPath, excludeNames,
          access: localAccess);
      if (policyError != null) return ToolResult.failure(policyError);
    }

    onProgress?.call(UiText.t('正在打开 SFTP 子系统...', 'Opening SFTP subsystem...'));
    debugPrint(
        '[SftpUploadTool] 开始上传: local=$local, remote=$remote, recursive=$recursive');

    // 复用 SSHService 的 SSHClient 打开 SFTP（不重新建连）
    final sftp = SftpService();
    try {
      final client = executor.client;
      if (client == null) {
        return ToolResult.failure('SSH 连接未建立，无法打开 SFTP');
      }
      await sftp.attachToClient(client);
    } catch (e) {
      return ToolResult.failure('SFTP 连接失败: $e');
    }

    try {
      if (!isDir) {
        // 连接/备份等异步步骤后再次验证，链接换目标不得读出敏感文件。
        final checked = _decideLocalPath(local,
            access: localAccess, mode: LocalAccessMode.read);
        if (!checked.isAllowed) {
          return ToolResult.failure(_localPathDeniedMessage(local, checked));
        }
        onProgress?.call(L10n.str.ut_91700996f4(p.basename(localPath)));
        // R6: 远程路径用 posix
        final remoteParent = p.posix.dirname(remote);
        if (remoteParent.isNotEmpty && remoteParent != '.') {
          await sftp.ensureDirectory(remoteParent);
        }
        final size = await sftp.uploadFile(
          localPath,
          remote,
          cancelToken: cancelToken,
          validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
              raw, expected,
              access: localAccess, mode: LocalAccessMode.read),
        );
        if (cancelToken?.isCompleted == true || isTaskActive?.call() == false) {
          return ToolResult.failure('上传已取消');
        }
        onProgress?.call(UiText.t('上传完成', 'Upload complete'));
        return ToolResult.success(
          L10n.str.ut_ded2242c8f(localPath, remote, _formatSize(size)),
        );
      } else {
        // 目录递归上传
        // 语义：把 local 目录传到 remote 下，期望 remote/basename(local) 存在
        // 如果 remote 路径不以 basename(local) 结尾，自动追加，避免目录内容被平铺到 remote 根下
        final baseName = p.basename(localPath);
        String effectiveRemote = remote;
        if (p.posix.basename(remote) != baseName) {
          effectiveRemote = p.posix.join(remote, baseName);
        }
        onProgress?.call(L10n.str.ut_d72746d0d0(localPath, effectiveRemote));
        return await _runDirectoryUploadWithCancel(
          sftp: sftp,
          ssh: executor,
          local: localPath,
          effectiveRemote: effectiveRemote,
          excludeNames: excludeNames,
          onProgress: onProgress,
          cancelToken: cancelToken,
          isTaskActive: isTaskActive,
          access: localAccess,
        );
      }
    } on SftpTransferCancelled {
      return ToolResult.failure('上传已取消');
    } catch (e) {
      debugPrint('[SftpUploadTool] 上传失败: $e');
      return ToolResult.failure('上传失败: $e');
    } finally {
      // R2: 仅关闭 SFTP 子系统通道，不关闭借用的 SSHClient
      sftp.closeSftpOnly();
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// SFTP 下载工具
/// 支持：单文件下载、目录递归下载
/// 参数：
///   - remote: 远程文件/目录绝对路径（必填）
///   - local: 本地目标路径（必填）
///   - recursive: 是否递归下载目录（bool，默认 false）
///   - exclude: 排除项（可选，仅 recursive=true 时生效）
class SftpDownloadTool extends AgentTool {
  @override
  String get name => 'sftp_download';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '从 SSH 远程服务器下载文件或目录到本地。用于取回日志、配置、备份等场景。'
      '单文件：local 是已存在目录或带结尾分隔符时，自动保存为 local/basename(remote)。'
      '目录下载语义：把 remote 目录放到 local 目录下，自动创建 basename(remote) 子目录；'
      '若 local 已以同名末段结尾（如 local=.../logs、remote=/var/logs）则不重复追加。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  remote: 远程文件/目录绝对路径（必填）\n'
      '  local: 本地目标路径（必填，单文件可传目录；目录下载传父目录）\n'
      '  recursive: 是否递归下载目录（true/false，默认 false）\n'
      '  exclude: 排除项（可选，逗号分隔，如 node_modules,.git）';

  /// 仅测试目录下载清单预检；返回错误表示在任何本地创建/下载前即应拒绝。
  @visibleForTesting
  static Future<String?> validateDirectoryDownloadPathsForTest({
    required String remoteDir,
    required String localRoot,
    required Future<List<SftpEntry>> Function(String remotePath) listDirectory,
    List<String> excludeNames = const ['node_modules', '.git', '.DS_Store'],
    LocalAccessService? access,
  }) async {
    final rootDecision = await authorizeLocalPath(
      rawPath: localRoot,
      mode: LocalAccessMode.write,
      access: access,
      policy: LocalFilePolicy.load(),
      reason: 'sftp_download 需要写入本地目录：$localRoot',
    );
    if (!rootDecision.isAllowed) {
      return _localPathDeniedMessage(localRoot, rootDecision);
    }
    final plan = await _planDirectoryDownload(
      listDirectory: listDirectory,
      remoteDir: remoteDir,
      localRoot: rootDecision.resolved,
      excludeNames: excludeNames,
      access: access,
    );
    return plan.error;
  }

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawRemote = args.getString('remote');
    final remote = _normalizedRemotePath(rawRemote);
    final local = args.getString('local');
    final recursive = args.getBool('recursive');
    final excludeArg = args.getStringList('exclude');

    if (remote == null || local.isEmpty) {
      return ToolResult.failure('参数缺失或无效: remote 必须是 POSIX 绝对路径，local 必填');
    }
    if (executor is! SSHService) {
      return ToolResult.failure('sftp_download 仅支持 SSH 远程会话，当前为本地终端');
    }
    final policy = LocalFilePolicy.load();
    final initial = policy.decide(local);
    if (initial.verdict == LocalPathVerdict.sensitive ||
        initial.verdict == LocalPathVerdict.reserved ||
        initial.verdict == LocalPathVerdict.escape) {
      return ToolResult.failure(_localPathDeniedMessage(local, initial));
    }
    final localPath = initial.resolved;
    final localIsDirectory = await Directory(localPath).exists();
    final authorizationRoot =
        localIsDirectory ? localPath : p.dirname(localPath);
    final localDecision = await authorizeLocalPath(
      rawPath: authorizationRoot,
      mode: LocalAccessMode.write,
      access: localAccess,
      policy: policy,
      reason: 'sftp_download 需要写入本地目标 $local（含父目录中的临时文件）',
    );
    if (!localDecision.isAllowed) {
      return ToolResult.failure(
          _localPathDeniedMessage(authorizationRoot, localDecision));
    }
    final client = executor.client;
    if (client == null) {
      return ToolResult.failure('SSH 连接未建立，无法打开 SFTP');
    }

    final sftp = SftpService();
    try {
      await sftp.attachToClient(client);
    } catch (e) {
      return ToolResult.failure('SFTP 连接失败: $e');
    }

    try {
      final stat = await sftp.statFile(remote);
      if (stat == null) {
        return ToolResult.failure('远程路径不存在: $remote');
      }

      if (!stat.isDirectory) {
        var target = localPath;
        final localIsDir = await Directory(localPath).exists();
        if (localIsDir || local.endsWith('/') || local.endsWith('\\')) {
          target = p.join(localPath, p.posix.basename(remote));
        }
        // 最终 target 可能与最初传入的 local 不同，必须在 downloadFile 前再次判定。
        final targetDecision = _decideLocalPath(target,
            access: localAccess, mode: LocalAccessMode.write);
        if (!targetDecision.isAllowed) {
          return ToolResult.failure(
              _localPathDeniedMessage(target, targetDecision));
        }
        target = targetDecision.resolved;
        if (cancelToken?.isCompleted == true) {
          return ToolResult.failure('下载已取消');
        }
        final beforeWrite = _decideLocalPath(target,
            access: localAccess, mode: LocalAccessMode.write);
        if (!beforeWrite.isAllowed) {
          return ToolResult.failure(
              _localPathDeniedMessage(target, beforeWrite));
        }
        onProgress
            ?.call(L10n.str.ut_0e800a8406(p.posix.basename(remote), target));
        await sftp.downloadFile(
          remote,
          target,
          cancelToken: cancelToken,
          validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
              raw, expected,
              access: localAccess, mode: LocalAccessMode.write),
        );
        if (cancelToken?.isCompleted == true) {
          return ToolResult.failure('下载已取消');
        }
        final size = stat.size ?? 0;
        onProgress?.call(UiText.t('下载完成', 'Download complete'));
        return ToolResult.success(
          L10n.str.ut_5c8b91122b(remote, target, _formatSize(size)),
        );
      }

      if (!recursive) {
        return ToolResult.failure(
          '远程路径是目录，请设置 recursive=true 以递归下载',
          output: '提示: 如需下载单个文件，请指定文件路径而非目录路径',
        );
      }

      final remoteBase = p.posix.basename(remote);
      var effectiveLocal = localPath;
      if (p.basename(localPath) != remoteBase) {
        effectiveLocal = p.join(localPath, remoteBase);
      }
      final rootDecision = _decideLocalPath(effectiveLocal,
          access: localAccess, mode: LocalAccessMode.write);
      if (!rootDecision.isAllowed) {
        return ToolResult.failure(
            _localPathDeniedMessage(effectiveLocal, rootDecision));
      }
      effectiveLocal = rootDecision.resolved;
      final excludeNames = excludeArg.isEmpty
          ? ['node_modules', '.git', '.DS_Store']
          : excludeArg;

      onProgress?.call(L10n.str.ut_2bc26619aa(remote, effectiveLocal));
      final plan = await _planDirectoryDownload(
        listDirectory: sftp.listDirectory,
        remoteDir: remote,
        localRoot: effectiveLocal,
        excludeNames: excludeNames,
        access: localAccess,
      );
      if (plan.error != null) return ToolResult.failure(plan.error!);
      if (cancelToken?.isCompleted == true) return ToolResult.failure('下载已取消');

      // 全部最终路径已授权，以下才允许创建目录和写入文件。
      final beforeCreate = _decideLocalPath(effectiveLocal,
          access: localAccess, mode: LocalAccessMode.write);
      if (!beforeCreate.isAllowed) {
        return ToolResult.failure(
            _localPathDeniedMessage(effectiveLocal, beforeCreate));
      }
      final createError = await _createVerifiedLocalDirectory(
          effectiveLocal, cancelToken,
          access: localAccess);
      if (createError != null) return ToolResult.failure(createError);
      for (final directory in plan.directories) {
        if (cancelToken?.isCompleted == true) {
          return ToolResult.failure('下载已取消', output: plan.result.summary);
        }
        final checked = _decideLocalPath(directory,
            access: localAccess, mode: LocalAccessMode.write);
        if (!checked.isAllowed) {
          return ToolResult.failure(
              _localPathDeniedMessage(directory, checked));
        }
        final directoryError = await _createVerifiedLocalDirectory(
            directory, cancelToken,
            access: localAccess);
        if (directoryError != null) {
          return ToolResult.failure(directoryError,
              output: plan.result.summary);
        }
      }
      for (final file in plan.files) {
        if (cancelToken?.isCompleted == true) {
          return ToolResult.failure('下载已取消', output: plan.result.summary);
        }
        try {
          final checked = _decideLocalPath(file.local,
              access: localAccess, mode: LocalAccessMode.write);
          if (!checked.isAllowed) {
            throw FileSystemException(
                _localPathDeniedMessage(file.local, checked));
          }
          await sftp.downloadFile(
            file.remote,
            file.local,
            cancelToken: cancelToken,
            validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
                raw, expected,
                access: localAccess, mode: LocalAccessMode.write),
          );
          if (cancelToken?.isCompleted == true) {
            return ToolResult.failure('下载已取消', output: plan.result.summary);
          }
          plan.result.downloadedFiles++;
          onProgress?.call(L10n.str.ut_52a01019d8(
              plan.result.downloadedFiles, plan.result.totalFiles));
        } catch (e) {
          final relative = p.relative(file.local, from: effectiveLocal);
          plan.result.failedFiles.add(relative);
          plan.result.errors.add('$relative: $e');
        }
      }
      final result = plan.result;
      if (result.allSuccess) {
        return ToolResult.success(
          L10n.str.ut_4452077d81(result.summary, effectiveLocal),
        );
      }
      return ToolResult(
        success: false,
        output: L10n.str.ut_4452077d81(result.summary, effectiveLocal),
        error: '${result.failedFiles.length} 个文件下载失败',
      );
    } catch (e) {
      debugPrint('[SftpDownloadTool] 下载失败: $e');
      return ToolResult.failure('下载失败: $e');
    } finally {
      sftp.closeSftpOnly();
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// SFTP 远程文件按行读取工具（O2）
///
/// 设计动机：改远程配置前模型必须看全文件 —— file_patch 要求精确匹配 old 串，
/// 而 shell `cat` 受观测尾保留限制，大文件头部看不到。本工具走 SFTP 直读，
/// 不经 shell（无回显/转义/分页问题），按行分段返回带行号内容。
///
/// 纯逻辑（大小判定 / 分行切片 / lossy 解码）抽成静态方法，脱离 SFTP 可单测。
class SftpFileReadTool extends AgentTool {
  /// 整体读取的文件大小上限：2MB（更大文件引导 grep 管道或 sftp_download）
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// 默认读取行数
  static const int defaultLimit = 200;

  /// 单次读取行数上限
  static const int maxLimit = 1000;

  /// 单行展示上限（超长行截断，R8 缓冲有界）
  static const int maxLineChars = 2000;

  /// 单次返回内容总字符上限（R8：2MB 文件可能只有几个超长行）
  static const int maxSliceChars = 20000;

  @override
  String get name => 'sftp_file_read';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '按行读取 SSH 远程文本文件（SFTP 直读，不经 shell，无命令回显/转义问题）。'
      '用于修改远程文件前查看内容（file_patch 需要精确的 old 串）、分段阅读配置/日志/脚本。'
      '返回总行数、带行号内容（L12: ...）、hasMore 与下次 offset 提示。'
      '只读操作，无需确认。文件超过 2MB 会拒绝读取，届时请用 grep 管道定位'
      '（如 grep -n "关键词" 文件 | head -50）或 sftp_download 取回本地。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 远程文件绝对路径（必填）\n'
      '  offset: 起始行号，1-based（可选，默认 1）\n'
      '  limit: 读取行数（可选，默认 200，上限 1000）';

  @override
  Map<String, dynamic>? toJsonSchema() => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '远程文件绝对路径',
          },
          'offset': {
            'type': 'integer',
            'description': '起始行号（1-based，默认 1）',
          },
          'limit': {
            'type': 'integer',
            'description': '读取行数（默认 200，上限 1000）',
          },
        },
        'required': ['path'],
        'additionalProperties': false,
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final String path;
    try {
      path = args.requireString('path');
    } on ToolArgException {
      return ToolResult.failure('参数缺失: path 为必填项');
    }
    final offset = args.getInt('offset', defaultValue: 1);
    var limit = args.getInt('limit', defaultValue: defaultLimit);
    if (limit < 1) limit = 1;
    if (limit > maxLimit) limit = maxLimit;
    if (offset < 1) {
      return ToolResult.failure('参数错误: offset 必须 ≥ 1（1-based 行号），实际值为 $offset');
    }
    if (executor is! SSHService) {
      return ToolResult.failure(
          'sftp_file_read 仅支持 SSH 远程会话，当前为本地终端。读本机文件请用 local_file_read');
    }
    if (looksLikeWindowsLocalPath(path)) {
      return ToolResult.failure(
        '当前是 SSH 远程会话，但 path 是本机路径格式：$path\n'
        '读本机文件请用 local_file_read；读服务器文件请给远程绝对路径（如 /etc/nginx/nginx.conf）。',
      );
    }
    final client = executor.client;
    if (client == null) {
      return ToolResult.failure('SSH 连接未建立，无法打开 SFTP');
    }

    final sftp = SftpService();
    try {
      await sftp.attachToClient(client);
    } catch (e) {
      return ToolResult.failure('SFTP 连接失败: $e');
    }

    try {
      final stat = await sftp.statFile(path);
      if (stat == null) {
        return ToolResult.failure('远程路径不存在: $path');
      }
      if (stat.isDirectory) {
        return ToolResult.failure('远程路径是目录而非文件: $path');
      }
      final sizeError = oversizeError(stat.size);
      if (sizeError != null) {
        return ToolResult.failure(sizeError);
      }
      onProgress?.call(L10n.str.ut_f4856090f2(path));
      // stat 拿不到大小时仍要兜底：多读 1 字节用于判定是否超限
      final bytes = await sftp.readFileBytes(path, maxSize: maxFileBytes + 1);
      final readSizeError = oversizeError(bytes.length);
      if (readSizeError != null) {
        return ToolResult.failure(readSizeError);
      }
      return formatSlice(decodeLossy(bytes),
          path: path, offset: offset, limit: limit);
    } catch (e) {
      return ToolResult.failure('读取文件失败: $e');
    } finally {
      // R2: 仅关闭 SFTP 子系统通道，不关闭借用的 SSHClient
      sftp.closeSftpOnly();
    }
  }

  /// 文件大小判定（纯函数）：超过 2MB 返回拒绝理由，否则 null。
  /// [sizeBytes] 为 null（stat 未给出大小）时放行，读取后再按实际字节数复核。
  static String? oversizeError(int? sizeBytes) {
    if (sizeBytes == null || sizeBytes <= maxFileBytes) return null;
    return '文件过大 ($sizeBytes 字节 > $maxFileBytes 字节 / 2MB)，拒绝整体读取。'
        '请用 grep 管道定位内容（如 grep -n "关键词" <文件> | head -50），'
        '或用 sftp_download 下载到本地后查看。';
  }

  /// UTF-8 lossy 解码（纯函数）：非法字节替换为 U+FFFD，只读场景不损坏原文件
  static String decodeLossy(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  /// 按行切片并格式化（纯函数，不依赖 SFTP）。
  /// 返回总行数、本次范围、带行号内容、hasMore 与下次 offset 提示。
  static ToolResult formatSlice(
    String text, {
    required String path,
    required int offset,
    required int limit,
  }) {
    if (offset < 1) {
      return ToolResult.failure('参数错误: offset 必须 ≥ 1，实际值为 $offset');
    }
    if (limit < 1) {
      return ToolResult.failure('参数错误: limit 必须 ≥ 1，实际值为 $limit');
    }
    var lines = text.isEmpty ? <String>[] : text.split('\n');
    // 末尾换行不算额外一行："a\nb\n" 是 2 行而不是 3 行
    if (lines.isNotEmpty && lines.last.isEmpty && text.endsWith('\n')) {
      lines = lines.sublist(0, lines.length - 1);
    }
    // CRLF 文件去掉行尾 \r，避免行号输出里混入不可见字符
    lines = [
      for (final l in lines) l.endsWith('\r') ? l.substring(0, l.length - 1) : l
    ];
    final total = lines.length;
    if (total == 0) {
      return ToolResult.success('文件: $path (共 0 行，空文件)\nhasMore: false');
    }
    if (offset > total) {
      return ToolResult.failure(
          'offset 越界: 文件共 $total 行，offset=$offset 超出文件末尾。请用 1-$total 之间的 offset');
    }

    final start = offset;
    var end = start;
    var chars = 0;
    final buffer = StringBuffer();
    for (var i = start - 1; i < total && i < start - 1 + limit; i++) {
      var line = lines[i];
      if (line.length > maxLineChars) {
        line =
            '${line.substring(0, maxLineChars)}…(行过长，截断 ${line.length - maxLineChars} 字符)';
      }
      final entry = 'L${i + 1}: $line\n';
      // R8 边界：恰好等于上限时仍收录；首行永远收录（单行上限 < 总上限）
      if (chars + entry.length > maxSliceChars && buffer.isNotEmpty) break;
      buffer.write(entry);
      chars += entry.length;
      end = i + 1;
    }

    final hasMore = end < total;
    final out = StringBuffer()
      ..writeln('文件: $path (共 $total 行)')
      ..writeln('本次范围: L$start-L$end (${end - start + 1} 行)')
      ..write(buffer)
      ..write(hasMore
          ? 'hasMore: true，继续读取请用 offset: ${end + 1}'
          : 'hasMore: false（已到文件末尾）');
    return ToolResult.success(out.toString());
  }
}

/// 文件同步工具
/// 启动/停止本地↔远端双向同步
/// 参数：
///   - action: start | stop | status (必填)
///   - localDir: 本地目录绝对路径（start 时必填）
///   - remoteDir: 远程目录绝对路径（start 时必填）
///   - direction: localToRemote | bidirectional (可选，默认 localToRemote)
///   - exclude: 排除项（可选）
class FileSyncTool extends AgentTool {
  final FileSyncService _service;

  FileSyncTool(this._service);

  @override
  String get name => 'file_sync';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description =>
      '启动或停止本地目录与远程服务器目录的自动同步。本地文件修改自动上传到远程；bidirectional 模式下还会轮询远程变化下载到本地。'
      '注意：localDir 和 remoteDir 是一一对应的完整路径，remoteDir 应包含目标子目录名（如 localDir=/path/story、remoteDir=/tmp/story），'
      '否则 story 内的文件会被平铺到 remoteDir 根下。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  action: start|stop|status（必填）\n  localDir: 本地目录完整路径（start 必填）\n  remoteDir: 远程目录完整路径（start 必填，应含目标子目录名，如 /tmp/story 而非 /tmp）\n  direction: localToRemote|bidirectional（默认 localToRemote）\n  exclude: 排除项（可选，逗号分隔）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final action = args.getString('action');

    if (action == 'status') {
      final running = _service.isRunning;
      final config = _service.config;
      return ToolResult.success(
        running
            ? '同步运行中: ${config?.localDir} → ${config?.remoteDir} (${config?.direction.name})'
            : '同步未运行',
      );
    }

    if (action == 'stop') {
      await _service.stop();
      onProgress?.call(UiText.t('已停止文件同步', 'File sync stopped'));
      return ToolResult.success(UiText.t('文件同步已停止', 'File sync stopped'));
    }

    if (action == 'start') {
      final taskLocalAccess = localAccess;
      final taskActive = isTaskActive;
      bool taskAuthorizationValid() =>
          taskActive?.call() != false && (taskLocalAccess?.isCurrent ?? true);
      final localDir = args.getString('localDir');
      final remoteDir = args.getString('remoteDir');
      final directionStr =
          args.getString('direction', defaultValue: 'localToRemote');
      final excludeArg = args.getStringList('exclude');

      if (localDir.isEmpty || remoteDir.isEmpty) {
        return ToolResult.failure('start 需要 localDir 和 remoteDir 参数');
      }

      final direction = directionStr == 'bidirectional'
          ? SyncDirection.bidirectional
          : SyncDirection.localToRemote;
      final policy = LocalFilePolicy.load();
      final localDecision = await authorizeLocalPath(
        rawPath: localDir,
        mode: LocalAccessMode.read,
        access: taskLocalAccess,
        policy: policy,
        reason: 'file_sync 需要持续读取本地目录以同步到远程服务器：$localDir',
      );
      if (!localDecision.isAllowed) {
        return ToolResult.failure(
            _localPathDeniedMessage(localDir, localDecision));
      }
      final resolvedLocalDir = localDecision.resolved;
      if (direction == SyncDirection.bidirectional) {
        final writeDecision = await authorizeLocalPath(
          rawPath: localDir,
          mode: LocalAccessMode.write,
          access: taskLocalAccess,
          policy: policy,
          reason: '双向 file_sync 还需要把远程变化写入本地目录：$localDir',
        );
        if (!writeDecision.isAllowed ||
            writeDecision.resolved != resolvedLocalDir) {
          return ToolResult.failure(
              _localPathDeniedMessage(localDir, writeDecision));
        }
      }

      if (!taskAuthorizationValid()) {
        return ToolResult.failure('任务已结束、暂停或取消，本地授权失效');
      }
      if (executor is! SSHService) {
        return ToolResult.failure('file_sync 仅支持 SSH 远程会话');
      }
      if (executor.client == null) {
        return ToolResult.failure('SSH 连接未建立');
      }
      final sshService = executor;

      List<String> excludeNames = excludeArg.isEmpty
          ? ['node_modules', '.git', '.DS_Store']
          : excludeArg;

      final config = SyncConfig(
        localDir: resolvedLocalDir,
        remoteDir: remoteDir,
        direction: direction,
        excludeNames: excludeNames,
      );

      onProgress?.call(UiText.t('正在启动文件同步...', 'Starting file sync...'));
      String? validateSyncPath(String rawPath, String expectedResolved) {
        if (!taskAuthorizationValid()) {
          return '任务已结束、暂停或取消，本地授权失效';
        }
        final readDenial = _freshLocalPathDenial(
          rawPath,
          expectedResolved,
          access: taskLocalAccess,
          mode: LocalAccessMode.read,
        );
        if (readDenial != null) return readDenial;
        if (direction == SyncDirection.localToRemote) return null;
        return _freshLocalPathDenial(
          rawPath,
          expectedResolved,
          access: taskLocalAccess,
          mode: LocalAccessMode.write,
        );
      }

      // 传 getter 而非 client 引用：SSHService 重连后 getter 返回新 client
      final ok = await _service.start(
        clientGetter: () => sshService.client,
        config: config,
        // watcher/轮询期间持续复验；任务结束或暂停后所有 I/O 立即失效。
        validateLocalPath: (rawPath, expectedResolved) async =>
            validateSyncPath(rawPath, expectedResolved),
        authorizationCheck: () =>
            validateSyncPath(resolvedLocalDir, resolvedLocalDir) == null,
      );
      if (ok) {
        return ToolResult.success(
          '文件同步已启动: $resolvedLocalDir ↔ $remoteDir (方向: ${direction.name})\n'
          '本地文件修改将自动上传到远程${direction == SyncDirection.bidirectional ? '，远程变化也会同步到本地' : ''}',
        );
      } else {
        return ToolResult.failure('启动同步失败，请检查路径和连接');
      }
    }

    return ToolResult.failure('未知 action: $action (支持 start/stop/status)');
  }
}

/// 多机编排：在指定 host 上执行命令
/// 仅在编排模式下可用
class ExecOnTool extends AgentTool {
  final MultiHostExecutor _executor;

  ExecOnTool(this._executor);

  @override
  String get name => 'exec_on';

  @override
  ToolKind get kind => ToolKind.destructive;

  @override
  String get description => '【多机编排】在指定主机上执行命令。用于跨主机调度操作。'
      '仅在编排模式下可用；非编排模式请用普通 execute。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostId: 目标主机 ID（必填）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = args.getString('hostId');
    final command = args.getString('command');
    final timeoutSec = MultiHostExecutor.clampTimeoutSeconds(
        args.getInt('timeout', defaultValue: 60));

    if (hostId.isEmpty || command.isEmpty) {
      return ToolResult.failure(
          L10n.str.orchToolParamMissing('hostId 和 command'));
    }

    onProgress?.call(L10n.str.orchToolExecProgress(hostId, command));
    final result = await _executor.executeOn(
      hostId,
      command,
      timeout: Duration(seconds: timeoutSec),
    );

    if (result == null) {
      return ToolResult.failure(L10n.str.orchToolHostNotConnected(hostId));
    }

    final mark = result.success ? '✓' : '✗';
    // R8: 截断输出，避免 MB 级日志注入对话历史
    final output = _truncate(result.stdout, 2000);
    final err = _truncate(result.stderr, 1000);
    // failureKind 让 AI 区分"命令失败"vs"环境问题"，避免盲目重试：
    // - syntaxError → 修正命令（不要重试原命令）
    // - interactivePrompt → 提示用户需要交互凭据
    // - disconnected → 重连而非重试命令
    // - timeout → 可能需要更长超时或拆分命令
    final kindLabel = result.failureKind != CommandFailureKind.none
        ? ' [${result.failureKind.name.toUpperCase()}]'
        : (result.timedOut ? ' [TIMEOUT]' : '');
    final summary = '[$hostId] $mark (exit=${result.exitCode})$kindLabel';
    // 失败时必须同时回传 stdout 和 stderr：
    // PTY 模式下 stderr 已合并进 stdout（result.stderr 恒为空），
    // bash 的 "syntax error"、"command not found" 等关键诊断信息都在 stdout 里。
    // 旧实现只回传 'stderr: $err'，导致 AI 看不到任何错误文本，
    // 只能根据命令结构（如 nohup ... &）臆测"后台启动成功"。
    final detail = result.success
        ? (output.isNotEmpty ? output : L10n.str.orchToolNoOutput)
        : (output.isNotEmpty
            ? (err.isNotEmpty
                ? 'stdout: $output\nstderr: $err'
                : 'output: $output')
            : (err.isNotEmpty ? 'stderr: $err' : L10n.str.orchToolNoOutput));
    // 失败原因（人类可读诊断，指导 AI 修正命令而非盲目重试）
    final reasonLine =
        (result.failureReason != null && result.failureReason!.isNotEmpty)
            ? '\nreason: ${result.failureReason}'
            : '';

    if (result.success) {
      return ToolResult.success('$summary\n$detail');
    } else {
      return ToolResult(
        success: false,
        output: '$summary\n$detail$reasonLine',
        error: '主机 $hostId 命令失败 (exit=${result.exitCode})'
            '${result.failureKind != CommandFailureKind.none ? ' kind=${result.failureKind.name}' : ''}',
      );
    }
  }

  String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...(${s.length} chars)';
  }
}

/// 多机编排：批量执行同一命令到多台主机
class ExecBatchTool extends AgentTool {
  final MultiHostExecutor _executor;

  ExecBatchTool(this._executor);

  @override
  String get name => 'exec_batch';

  @override
  ToolKind get kind => ToolKind.destructive;

  @override
  String get description => '【多机编排】批量执行同一命令到多台主机（只读命令并行执行，修改性命令串行执行）。'
      '适用于时间同步、日志清理、配置检查等批量运维场景。'
      '一台失败不影响其他主机（除非 stopOnFailure=true）。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔，如 web1,web2,db1）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）\n  stopOnFailure: 某台失败是否停止后续（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final command = args.getString('command');
    final timeoutSec = MultiHostExecutor.clampTimeoutSeconds(
        args.getInt('timeout', defaultValue: 60));
    final stopOnFailure = args.getBool('stopOnFailure');
    final hostIds = args.getStringList('hostIds');

    if (hostIds.isEmpty || command.isEmpty) {
      return ToolResult.failure(
          L10n.str.orchToolParamMissing('hostIds 和 command'));
    }

    onProgress?.call(L10n.str.orchToolBatchProgress(command, hostIds.length));
    final results = await _executor.executeBatch(
      hostIds,
      command,
      timeout: Duration(seconds: timeoutSec),
      stopOnFailure: stopOnFailure,
    );

    final summary = MultiHostExecutor.formatBatchResult(command, results);
    final allSuccess = results.values.every((r) => r.success);
    final hostResults = <String, HostExecutionResult>{};
    results.forEach((hostId, r) {
      final out =
          r.stdout.length > 2000 ? '${r.stdout.substring(0, 2000)}…' : r.stdout;
      final failureDetail = MultiHostExecutor.failureDetail(r);
      final err = !r.success && failureDetail.length > 1000
          ? '${failureDetail.substring(0, 1000)}…'
          : (!r.success ? failureDetail : '');
      hostResults[hostId] = HostExecutionResult(
        hostId: hostId,
        success: r.success,
        output: out.isEmpty ? null : out,
        error: err.isEmpty ? null : err,
        exitCode: r.exitCode,
        durationMs: r.duration.inMilliseconds,
        failureKind: r.failureKind == CommandFailureKind.none
            ? null
            : r.failureKind.name,
      );
    });
    if (allSuccess) {
      return ToolResult.success(summary, hostResults: hostResults);
    } else {
      final notRunCount = results.values
          .where((r) =>
              !r.success &&
              (r.failureKind == CommandFailureKind.skipped ||
                  r.failureKind == CommandFailureKind.cancelled))
          .length;
      final failedCount = results.length -
          notRunCount -
          results.values.where((r) => r.success).length;
      return ToolResult(
        success: false,
        output: summary,
        error: failedCount > 0
            ? L10n.str.orchToolBatchFailed(failedCount, hostIds.length)
            : '${L10n.str.taskCancelled}（$notRunCount 台未执行）',
        hostResults: hostResults,
      );
    }
  }
}

/// 多机编排：跨机连通性测试
class CheckConnectivityTool extends AgentTool {
  final MultiHostExecutor _executor;

  CheckConnectivityTool(this._executor);

  @override
  String get name => 'check_connectivity';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '【多机编排】从一台主机测试到目标主机的端口连通性。'
      '用于部署前验证网络依赖（如 web→db:3306、web→redis:6379）。'
      '源主机必须是已连接的编排参与者。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  fromHostId: 源主机 ID（必填，命令从这台机执行）\n  targetHost: 目标主机 IP 或域名（必填）\n  port: 目标端口（必填）\n  timeout: 超时秒数（可选，默认 5）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final fromHostId = args.getString('fromHostId');
    final targetHost = args.getString('targetHost');
    final port = args.getInt('port');
    final timeoutSec = MultiHostExecutor.clampTimeoutSeconds(
        args.getInt('timeout', defaultValue: 5));

    if (fromHostId.isEmpty || targetHost.isEmpty || port <= 0) {
      return ToolResult.failure(L10n.str.orchToolConnParamMissing);
    }

    onProgress?.call(
        L10n.str.orchToolConnProgress(fromHostId, targetHost, port.toString()));
    final result = await _executor.checkConnectivity(
      fromHostId: fromHostId,
      targetHost: targetHost,
      port: port,
      timeout: Duration(seconds: timeoutSec),
    );

    if (result.reachable) {
      return ToolResult.success(result.summary);
    } else {
      return ToolResult(
        success: false,
        output: result.summary,
        error: result.detail ?? L10n.str.orchUnreachable,
      );
    }
  }
}

/// 多机编排：跨机上传文件/目录到指定主机
/// 复用 SftpService，但通过 hostId 路由到目标主机的 SSHClient
class UploadToTool extends AgentTool {
  final MultiHostExecutor _executor;

  UploadToTool(this._executor);

  @override
  String get name => 'upload_to';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '【多机编排】上传本地文件或目录到指定主机的远程目录。'
      '用于跨机部署（如把构建产物传到不同服务器）。'
      '目录上传语义同 sftp_upload：把 local 目录放到 remote 下，自动创建 basename(local) 子目录。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostId: 目标主机 ID（必填）\n  local: 本地文件/目录绝对路径（必填）\n  remote: 远程目标父目录（必填，目录上传时自动在其下创建 basename 子目录）\n  recursive: 是否递归上传目录（true/false，默认 false）\n  exclude: 排除项（可选，逗号分隔，如 node_modules,.git）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = args.getString('hostId');
    final local = args.getString('local');
    final remote = _normalizedRemotePath(args.getString('remote'));
    final recursive = args.getBool('recursive');
    final excludeArg = args.getStringList('exclude');

    if (hostId.isEmpty || local.isEmpty || remote == null) {
      return ToolResult.failure(
          '参数缺失或无效: hostId、local 必填，remote 必须是 POSIX 绝对路径');
    }
    if (cancelToken?.isCompleted == true || isTaskActive?.call() == false) {
      return ToolResult.failure('[$hostId] 上传已取消');
    }

    // 本地源路径必须在远程连接与文件读取前获得任务级读取授权。
    final localDecision = await authorizeLocalPath(
      rawPath: local,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: LocalFilePolicy.load(),
      reason: 'upload_to 需要读取本地文件并上传到主机 $hostId：$local',
    );
    if (!localDecision.isAllowed) {
      return ToolResult.failure(_localPathDeniedMessage(local, localDecision));
    }
    final localPath = localDecision.resolved;

    // 校验本地路径，并在连接远程前检查目录内每个实际上传文件。
    bool isDir;
    final dir = Directory(localPath);
    final file = File(localPath);
    if (await dir.exists()) {
      isDir = true;
    } else if (await file.exists()) {
      isDir = false;
    } else {
      return ToolResult.failure(L10n.str.orchToolLocalNotFound(localPath));
    }
    if (isDir && !recursive) {
      return ToolResult.failure(L10n.str.orchToolLocalIsDir);
    }

    List<String> excludeNames =
        excludeArg.isEmpty ? ['node_modules', '.git', '.DS_Store'] : excludeArg;
    if (isDir) {
      final policyError = await _preflightDirectoryUpload(
          localPath, excludeNames,
          access: localAccess);
      if (policyError != null) {
        return ToolResult.failure('[$hostId] $policyError');
      }
    }

    // 通过 hostId 获取目标主机的 executor（必须是 SSHService 才能开 SFTP）
    final targetExecutor = _executor.executorFor(hostId);
    if (targetExecutor == null) {
      return ToolResult.failure(L10n.str.orchToolHostNotConnected(hostId));
    }
    if (targetExecutor is! SSHService) {
      return ToolResult.failure(L10n.str.orchToolNotSshSession(hostId));
    }
    // R1: 捕获 client 到局部变量，避免 await 期间连接断开导致的 TOCTOU 空指针
    final client = targetExecutor.client;
    if (client == null) {
      return ToolResult.failure(L10n.str.orchToolSshNotEstablished(hostId));
    }

    onProgress?.call(L10n.str.orchToolSftpOpening(hostId));
    final sftp = SftpService();
    try {
      await sftp.attachToClient(client);
    } catch (e) {
      return ToolResult.failure(L10n.str.ut_6b85bbaf16(hostId, e));
    }

    try {
      if (!isDir) {
        final checked = _decideLocalPath(local,
            access: localAccess, mode: LocalAccessMode.read);
        if (!checked.isAllowed) {
          return ToolResult.failure(_localPathDeniedMessage(local, checked));
        }
        onProgress?.call(L10n.str.ut_2d44fe0c64(hostId, p.basename(localPath)));
        final remoteParent = p.posix.dirname(remote);
        if (remoteParent.isNotEmpty && remoteParent != '.') {
          await sftp.ensureDirectory(remoteParent);
        }
        final size = await sftp.uploadFile(
          localPath,
          remote,
          cancelToken: cancelToken,
          validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
              raw, expected,
              access: localAccess, mode: LocalAccessMode.read),
        );
        if (cancelToken?.isCompleted == true || isTaskActive?.call() == false) {
          return ToolResult.failure('上传已取消');
        }
        onProgress?.call(L10n.str.ut_7ef1cd9389(hostId));
        return ToolResult.success(
          L10n.str.ut_a465e8a3ee(hostId, localPath, remote, _formatSize(size)),
        );
      } else {
        final baseName = p.basename(localPath);
        String effectiveRemote = remote;
        if (p.posix.basename(remote) != baseName) {
          effectiveRemote = p.posix.join(remote, baseName);
        }
        onProgress
            ?.call(L10n.str.ut_699c3fa8dc(hostId, localPath, effectiveRemote));
        return await _runDirectoryUploadWithCancel(
          sftp: sftp,
          ssh: targetExecutor,
          local: localPath,
          effectiveRemote: effectiveRemote,
          excludeNames: excludeNames,
          onProgress: onProgress,
          cancelToken: cancelToken,
          isTaskActive: isTaskActive,
          access: localAccess,
          prefix: '[$hostId] ',
        );
      }
    } on SftpTransferCancelled {
      return ToolResult.failure('[$hostId] 上传已取消');
    } catch (e) {
      return ToolResult.failure('[$hostId] 上传失败: $e');
    } finally {
      // R2: 仅关闭 SFTP 子系统通道，不关闭借用的 SSHClient
      sftp.closeSftpOnly();
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 多机编排：广播上传 — 把本地文件/目录同时分发到多台主机
class BroadcastUploadTool extends AgentTool {
  final MultiHostExecutor _executor;
  BroadcastUploadTool(this._executor);

  @override
  String get name => 'broadcast_upload';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '【多机编排】把本地文件/目录广播分发到多台主机的相同远程目录。'
      '用于批量部署（如把配置文件/构建产物同步到一组服务器）。'
      '执行是串行的，每台主机的结果单独报告。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔，如 web1,web2）\n  local: 本地文件/目录绝对路径（必填）\n  remote: 远程目标父目录（必填）\n  recursive: 是否递归（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = args.getStringList('hostIds');
    final local = args.getString('local');
    final remote = _normalizedRemotePath(args.getString('remote'));
    final recursive = args.getBool('recursive');

    if (local.isEmpty || remote == null) {
      return ToolResult.failure('参数缺失或无效: local 必填，remote 必须是 POSIX 绝对路径');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项（数组或逗号分隔）');
    }
    if (hostIds.length > 64) {
      return ToolResult.failure('hostIds 超过 64 台，拒绝广播上传');
    }
    final taskToken = _executor.cancelToken;

    // remote 是目标目录：单文件必须拼上本地文件名，否则会把目录名当成文件名。
    // 目录上传由 UploadToTool 自己追加 basename(local)。
    final localDecision = await authorizeLocalPath(
      rawPath: local,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: LocalFilePolicy.load(),
      reason: 'broadcast_upload 需要读取本地文件并广播到多台主机：$local',
    );
    if (!localDecision.isAllowed) {
      return ToolResult.failure(_localPathDeniedMessage(local, localDecision));
    }
    final localPath = localDecision.resolved;
    final localIsDir = await Directory(localPath).exists();
    final effectiveRemote =
        localIsDir ? remote : p.posix.join(remote, p.basename(localPath));

    // 复用 UploadToTool 的逻辑：逐台上传
    final uploadTool = UploadToTool(_executor)
      ..cancelToken = cancelToken
      ..localAccess = localAccess
      ..isTaskActive = () =>
          !_executor.isTaskCancelled(taskToken) &&
          cancelToken?.isCompleted != true &&
          (isTaskActive?.call() ?? true);
    final results = <String>[];
    int successCount = 0;
    for (final hid in hostIds) {
      if (_executor.isTaskCancelled(taskToken)) {
        results.add('[$hid] 已取消，未上传');
        continue;
      }
      onProgress?.call(L10n.str.ut_2996de9000(hid));
      final r = await uploadTool.execute(
        executor: executor,
        args: ToolArgs({
          'hostId': hid,
          'local': localPath,
          'remote': effectiveRemote,
          'recursive': recursive,
        }),
        onProgress: onProgress,
      );
      if (r.success) {
        successCount++;
        results.add('[$hid] ✓ ${r.output}');
      } else {
        results.add('[$hid] ✗ ${r.error ?? r.output}');
      }
    }

    final summary =
        '广播分发完成: $successCount/${hostIds.length} 成功\n${results.join('\n')}';
    return successCount == hostIds.length
        ? ToolResult.success(summary)
        : ToolResult(
            success: false,
            output: summary,
            error: '${hostIds.length - successCount} 台失败');
  }
}

/// 多机编排：文件采集 — 从多台主机下载同名文件到本地（带 hostId 后缀）
class CollectFileTool extends AgentTool {
  final MultiHostExecutor _executor;
  CollectFileTool(this._executor);

  @override
  String get name => 'collect_file';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '【多机编排】从多台主机采集同名远程文件到本地目录，每个文件自动加 hostId 后缀。'
      '用于配置对比、日志收集等场景。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔）\n  remote: 远程文件绝对路径（必填）\n  localDir: 本地保存目录（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = args.getStringList('hostIds');
    final remote = _normalizedRemotePath(args.getString('remote'));
    final localDir = args.getString('localDir');

    if (remote == null || localDir.isEmpty) {
      return ToolResult.failure('参数缺失或无效: remote 必须是 POSIX 绝对路径，localDir 必填');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项');
    }
    if (hostIds.length > 64) {
      return ToolResult.failure('hostIds 超过 64 台，拒绝文件采集');
    }
    final taskToken = _executor.cancelToken;

    final rootDecision = await authorizeLocalPath(
      rawPath: localDir,
      mode: LocalAccessMode.write,
      access: localAccess,
      policy: LocalFilePolicy.load(),
      reason: 'collect_file 需要把多台主机的文件写入本地目录：$localDir',
    );
    if (!rootDecision.isAllowed) {
      return ToolResult.failure(
          _localPathDeniedMessage(localDir, rootDecision));
    }
    final rootPath = rootDecision.resolved;
    final remoteBasename = p.posix.basename(remote);
    if (!_isSafeRemoteEntryName(remoteBasename)) {
      return ToolResult.failure('remote 的文件名不安全: $remote');
    }

    // 先检查全部最终文件，再创建目录；hostId 也参与文件名，不能含路径分隔符。
    final targetPaths = <String, String>{};
    for (final hid in hostIds) {
      if (!_isSafeRemoteEntryName(hid)) {
        return ToolResult.failure('hostId 不能包含路径分隔符: $hid');
      }
      final rawTarget = p.join(rootPath, '${hid}_$remoteBasename');
      final targetDecision = _decideLocalPath(rawTarget,
          access: localAccess, mode: LocalAccessMode.write);
      if (!targetDecision.isAllowed) {
        return ToolResult.failure(
            _localPathDeniedMessage(rawTarget, targetDecision));
      }
      if (!p.isWithin(
          p.normalize(rootPath), p.normalize(targetDecision.resolved))) {
        return ToolResult.failure('采集目标越出本地根目录: $rawTarget');
      }
      targetPaths[hid] = targetDecision.resolved;
    }
    if (_executor.isTaskCancelled(taskToken)) {
      return ToolResult.failure('采集已取消');
    }

    final dir = Directory(rootPath);
    if (!await dir.exists()) {
      final beforeCreate = _decideLocalPath(localDir,
          access: localAccess, mode: LocalAccessMode.write);
      if (!beforeCreate.isAllowed) {
        return ToolResult.failure(
            _localPathDeniedMessage(localDir, beforeCreate));
      }
      final createError = await _createVerifiedLocalDirectory(
          rootPath, taskToken,
          access: localAccess);
      if (createError != null) return ToolResult.failure(createError);
    }

    final sftp = SftpService();
    final results = <String>[];
    int successCount = 0;

    for (final hid in hostIds) {
      if (_executor.isTaskCancelled(taskToken)) {
        results.add(L10n.str.ut_0f735fba75(hid));
        continue;
      }
      onProgress?.call(L10n.str.ut_5c021ae6b9(hid, remote));
      final targetExecutor = _executor.executorFor(hid);
      if (targetExecutor == null || targetExecutor is! SSHService) {
        results.add(L10n.str.ut_e31edc9171(hid));
        continue;
      }
      final client = targetExecutor.client;
      if (client == null) {
        results.add('[$hid] ✗ SSH 连接未建立');
        continue;
      }
      try {
        await sftp.attachToClient(client);
        final localPath = targetPaths[hid]!;
        final checked = _decideLocalPath(localPath,
            access: localAccess, mode: LocalAccessMode.write);
        if (!checked.isAllowed) {
          throw FileSystemException(
              _localPathDeniedMessage(localPath, checked));
        }
        await sftp.downloadFile(
          remote,
          localPath,
          cancelToken: taskToken,
          validateLocalPath: (raw, expected) async => _freshLocalPathDenial(
              raw, expected,
              access: localAccess, mode: LocalAccessMode.write),
        );
        if (_executor.isTaskCancelled(taskToken)) {
          throw const FileSystemException('采集已取消');
        }
        successCount++;
        results.add('[$hid] ✓ 已保存到 $localPath');
      } catch (e) {
        results.add('[$hid] ✗ 采集失败: $e');
      } finally {
        sftp.closeSftpOnly();
      }
    }

    final summary =
        '采集完成: $successCount/${hostIds.length} 成功\n${results.join('\n')}';
    return successCount == hostIds.length
        ? ToolResult.success(summary)
        : ToolResult(
            success: false,
            output: summary,
            error: '${hostIds.length - successCount} 台失败');
  }
}

/// 多机编排：日志聚合搜索 — 在多台主机上同时 grep 关键词，按主机分段返回
class MultiGrepTool extends AgentTool {
  final MultiHostExecutor _executor;
  MultiGrepTool(this._executor);

  @override
  String get name => 'multi_grep';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '【多机编排】在多台主机上同时 grep 搜索日志/文件，结果按主机分段聚合。'
      '用于跨机排障（如"在所有 web 机器 grep ERROR access.log 最近 100 行"）。'
      '注意：命令在远程执行，grep 语法须兼容目标 shell。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔）\n  pattern: 搜索关键词（必填，正则）\n  files: 要搜索的文件路径（必填，多个用逗号分隔）\n  tail: 仅搜索文件末尾 N 行（可选，如 1000）\n  ignoreCase: 是否忽略大小写（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = args.getStringList('hostIds');
    final pattern = args.getString('pattern');
    final files = args.getStringList('files');
    final tail = args.getString('tail');
    final ignoreCase = args.getBool('ignoreCase');

    if (pattern.isEmpty ||
        files.isEmpty ||
        files.any((file) => file.trim().isEmpty)) {
      return ToolResult.failure('参数缺失或无效: pattern、files 为必填项');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项');
    }
    if (hostIds.length > 64) {
      return ToolResult.failure('hostIds 超过 64 台，拒绝多机搜索');
    }
    if (pattern.length > 4096) {
      return ToolResult.failure('pattern 超过 4096 字符，拒绝多机搜索');
    }
    if (files.length > 64) {
      return ToolResult.failure('files 超过 64 个，拒绝多机搜索');
    }
    final normalizedFiles = <String>[];
    for (final file in files) {
      final normalized = _normalizedRemotePath(file.trim());
      if (normalized == null) {
        return ToolResult.failure('files 必须是 POSIX 绝对路径: $file');
      }
      normalizedFiles.add(normalized);
    }

    int? tailLines;
    if (tail.isNotEmpty) {
      if (!RegExp(r'^[1-9][0-9]*$').hasMatch(tail)) {
        return ToolResult.failure('tail 必须是正整数，实际值为 "$tail"');
      }
      tailLines = int.tryParse(tail);
      if (tailLines == null || tailLines <= 0 || tailLines > 1000000) {
        return ToolResult.failure('tail 必须是 1..1000000 的正整数，实际值为 "$tail"');
      }
    }

    // 每个文件独立执行：tail | grep 的管道退出码只反映 grep，
    // 任一输入不可读时不能因另一个文件命中而伪装成完整成功。
    final grepFlags = ignoreCase ? '-iE' : '-E';
    final grepPart = 'grep $grepFlags -- ${_quotePosixArgument(pattern)}';
    final taskToken = _executor.cancelToken;

    final results = <String>[];
    int hitCount = 0;
    int failureCount = 0;
    for (final hid in hostIds) {
      if (_executor.isTaskCancelled(taskToken)) {
        failureCount++;
        results.add('=== [$hid] 已取消 ===');
        continue;
      }
      onProgress?.call(L10n.str.ut_ffebfc53a6(hid));
      final target = _executor.executorFor(hid);
      if (target == null) {
        failureCount++;
        results.add(L10n.str.ut_38bc3dac85(hid));
        continue;
      }
      final shellReason = _unsupportedPosixShellReason(target);
      if (shellReason.isNotEmpty) {
        failureCount++;
        results.add('=== [$hid] 搜索失败 ===\n$shellReason');
        continue;
      }
      final hostBuffer = StringBuffer('=== [$hid] ===\n');
      var hostHit = false;
      var hostFailed = false;
      var hostOutputLength = 0;
      for (final file in normalizedFiles) {
        if (_executor.isTaskCancelled(taskToken)) {
          hostFailed = true;
          hostBuffer.writeln('已取消，未继续搜索剩余文件');
          break;
        }
        final quotedFile = _quotePosixArgument(file);
        final cmd = tailLines == null
            ? '$grepPart $quotedFile'
            : 'tail -n $tailLines -- $quotedFile | $grepPart';
        final r = await _executor.executeOn(hid, cmd,
            timeout: const Duration(seconds: 30));
        if (_executor.isTaskCancelled(taskToken)) {
          hostFailed = true;
          hostBuffer.writeln('已取消: $file');
          break;
        }
        final fileLabel =
            file.length > 500 ? '${file.substring(0, 500)}...' : file;
        final noMatch = r != null &&
            r.exitCode == 1 &&
            r.stdout.trim().isEmpty &&
            r.stderr.trim().isEmpty;
        if (r == null || (!r.success && !noMatch)) {
          hostFailed = true;
          hostBuffer.writeln('[失败] $fileLabel');
          final base = r == null
              ? L10n.str.ut_38bc3dac85(hid)
              : MultiHostExecutor.failureDetail(r);
          // 结构化 failureReason 可能只说明「读取失败」，真实诊断（如
          // Permission denied）只存在于 stderr；两者都要回传给模型。
          final stderrText = r?.stderr.trim() ?? '';
          final detail = stderrText.isNotEmpty && !base.contains(stderrText)
              ? '$base\n$stderrText'
              : base;
          hostBuffer.writeln(detail.length > 1000
              ? '${detail.substring(0, 1000)}...(已截断)'
              : detail);
        } else {
          final out = r.stdout.trim();
          if (out.isEmpty) {
            hostBuffer.writeln('[无匹配] $fileLabel');
          } else {
            hostHit = true;
            hostBuffer.writeln('[命中] $fileLabel');
            final remaining = 8000 - hostOutputLength;
            if (remaining > 0) {
              final truncated = out.length > remaining
                  ? '${out.substring(0, remaining)}\n...(已截断)'
                  : out;
              hostBuffer.writeln(truncated);
              hostOutputLength += truncated.length;
            } else {
              hostBuffer.writeln('...(该文件输出已达上限，仅保留搜索状态)');
            }
          }
        }
      }
      if (hostFailed) failureCount++;
      if (hostHit) hitCount++;
      results.add(hostBuffer.toString().trimRight());
    }

    final summary =
        '多机搜索完成: $hitCount/${hostIds.length} 台命中，$failureCount 台失败\n\n${results.join('\n\n')}';
    if (failureCount > 0) {
      return ToolResult.failure('$failureCount 台主机搜索失败或取消', output: summary);
    }
    return ToolResult.success(summary);
  }
}

/// 多机编排：文件 diff — 对比多台主机上同名文件的内容差异
class DiffFilesTool extends AgentTool {
  final MultiHostExecutor _executor;
  DiffFilesTool(this._executor);

  @override
  String get name => 'diff_files';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '【多机编排】对比多台主机上同名远程文件的内容差异。'
      '用于检查配置是否一致（如对比所有 nginx.conf）。'
      '返回每台主机文件的 md5 和两两 diff 摘要。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，至少 2 台，逗号分隔）\n  remote: 远程文件绝对路径（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = args.getStringList('hostIds');
    final remote = _normalizedRemotePath(args.getString('remote'));

    if (remote == null) {
      return ToolResult.failure('参数缺失或无效: remote 必须是 POSIX 绝对路径');
    }
    if (hostIds.length < 2) {
      return ToolResult.failure('diff 至少需要 2 台主机');
    }
    if (hostIds.length > 64) {
      return ToolResult.failure('hostIds 超过 64 台，拒绝多机 diff');
    }
    if (hostIds.toSet().length != hostIds.length) {
      return ToolResult.failure('hostIds 包含重复主机，拒绝 diff_files');
    }

    // 采集每台主机的 md5 和内容；remote 始终作为单个 POSIX 参数引用。
    final quotedRemote = _quotePosixArgument(remote);
    final command = "md5sum -- $quotedRemote && "
        "printf '%s\\n' '---CONTENT---' && "
        "head -n 200 -- $quotedRemote";
    final taskToken = _executor.cancelToken;
    final md5Results = <String, String>{};
    final contentResults = <String, String>{};
    int failureCount = 0;
    int successfulReads = 0;
    for (final hid in hostIds) {
      if (_executor.isTaskCancelled(taskToken)) {
        failureCount++;
        continue;
      }
      onProgress?.call(L10n.str.ut_8dc55e0134(hid, remote));
      final target = _executor.executorFor(hid);
      if (target == null) {
        failureCount++;
        continue;
      }
      final shellReason = _unsupportedPosixShellReason(target);
      if (shellReason.isNotEmpty) {
        failureCount++;
        continue;
      }
      final r = await _executor.executeOn(
        hid,
        command,
        timeout: const Duration(seconds: 15),
      );
      if (_executor.isTaskCancelled(taskToken)) {
        failureCount++;
      } else if (r == null) {
        failureCount++;
      } else if (!r.success) {
        failureCount++;
      } else {
        final out = r.stdout;
        final md5Match =
            RegExp(r'^([a-f0-9]{32})', multiLine: true).firstMatch(out);
        final contentStart = out.indexOf('---CONTENT---');
        if (md5Match == null || contentStart < 0) {
          // 命令退出 0 但缺少有效 MD5 或内容标记，仍不能作为一致性的证据。
          failureCount++;
        } else {
          md5Results[hid] = md5Match.group(1)!;
          contentResults[hid] = out.substring(contentStart + 13).trim();
          successfulReads++;
        }
      }
    }

    // 构建 md5 对比表
    final buffer = StringBuffer();
    buffer.writeln('文件: $remote');
    buffer.writeln('MD5 对比:');
    for (final hid in hostIds) {
      buffer.writeln('  [$hid] ${md5Results[hid] ?? '读取失败/取消/未连接'}');
    }
    if (failureCount > 0 || successfulReads != hostIds.length) {
      buffer.writeln('\n无法判断一致性：$failureCount 台主机读取失败、取消或未返回完整证据。');
      return ToolResult.failure(
        '$failureCount 台主机文件读取失败，无法比较',
        output: buffer.toString().trimRight(),
      );
    }

    // 检查是否全部一致
    final uniqueMd5 = md5Results.values.toSet();
    if (uniqueMd5.length == 1) {
      buffer.writeln('\n✅ 所有主机文件一致（MD5: ${uniqueMd5.first}）');
    } else {
      buffer.writeln('\n⚠️ 文件不一致，发现 ${uniqueMd5.length} 种版本');
      for (final hid in hostIds) {
        final content = contentResults[hid] ?? '';
        final lines = content.split('\n');
        final preview = lines.take(10).join('\n');
        buffer.writeln('\n--- [$hid] 前 10 行 ---');
        buffer.writeln(preview);
      }
    }

    return ToolResult.success(buffer.toString().trimRight());
  }
}

/// 证书到期监控工具
///
/// 支持 3 种检查：
/// 1. 远程 HTTPS 证书：通过 executor 在远程主机执行 openssl s_client -connect host:443
/// 2. 本地证书文件：通过 executor 读取 cert.pem 文件，用 openssl x509 解析
/// 3. SSH host key 指纹：通过 executor 读取 /etc/ssh/ 下的公钥指纹
class CertMonitorTool extends AgentTool {
  @override
  String get name => 'cert_check';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '检查 HTTPS/SSL 证书到期时间或 SSH host key 指纹。'
      '用于证书到期监控、安全审计。返回证书有效期剩余天数、到期日期、颁发者等。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  mode: remote|local_file|ssh_hostkey（必填）\n  host: 远程 HTTPS 主机名或 IP（mode=remote 时必填）\n  port: HTTPS 端口（默认 443）\n  certPath: 本地证书文件路径（mode=local_file 时必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final mode = args.getString('mode');
    if (mode.isEmpty) {
      return ToolResult.failure(UiText.t(
          '参数缺失: mode 必填（remote/local_file/ssh_hostkey）',
          'Missing parameter: mode is required (remote/local_file/ssh_hostkey)'));
    }

    if (mode == 'remote') {
      final host = args.getString('host');
      final port = args.getInt('port', defaultValue: 443);
      if (host.isEmpty) {
        return ToolResult.failure('mode=remote 需要 host 参数');
      }
      // R7: 校验 host 格式（防 shell 注入）
      if (!RegExp(r'^[a-zA-Z0-9.\-]+$').hasMatch(host)) {
        return ToolResult.failure('host 格式非法（仅允许字母、数字、点、连字符）');
      }
      if (port < 1 || port > 65535) {
        return ToolResult.failure(
            UiText.t('port 范围非法（1-65535）', 'Invalid port range (1-65535)'));
      }

      onProgress?.call(L10n.str.ut_475dcf3309(host, port));
      // 通过 executor 在已连接主机上执行 openssl 命令
      // 用 -servername 启用 SNI；用 2>/dev/null 屏蔽 s_client 的握手交互输出
      final cmd =
          "echo | openssl s_client -connect $host:$port -servername $host 2>/dev/null "
          "| openssl x509 -noout -dates -issuer -subject 2>/dev/null";
      try {
        final result = await executor.executeAndWait(cmd,
            timeout: const Duration(seconds: 15));
        if (!result.success) {
          return ToolResult.failure(L10n.str.ut_1e823bfa18(result.stderr),
              output: result.stdout);
        }
        final output = result.stdout.trim();
        if (output.isEmpty) {
          return ToolResult.failure('$host:$port 未返回证书（可能非 HTTPS 或端口不通）');
        }
        // 解析 notBefore/notAfter
        final parsed = _parseCertOutput(output, host, port);
        return ToolResult.success(parsed);
      } catch (e) {
        return ToolResult.failure('检查异常: $e');
      }
    }

    if (mode == 'local_file') {
      final certPath = args.getString('certPath');
      if (certPath.isEmpty) {
        return ToolResult.failure('mode=local_file 需要 certPath 参数');
      }
      // R7: 校验路径不含 shell 元字符（防注入；单引号防护可被单引号突破）
      if (RegExp(r"[';`$\\|&><\n\r]").hasMatch(certPath)) {
        return ToolResult.failure(UiText.t('certPath 含非法字符（禁止引号/分号/管道/反引号等）',
            'certPath contains illegal characters (quotes, semicolons, pipes, backticks, etc. are not allowed)'));
      }
      onProgress?.call(L10n.str.ut_bde384cf72(certPath));
      final cmd =
          "openssl x509 -in '$certPath' -noout -dates -issuer -subject 2>&1";
      try {
        final result = await executor.executeAndWait(cmd,
            timeout: const Duration(seconds: 10));
        if (!result.success) {
          return ToolResult.failure(L10n.str.ut_1e823bfa18(result.stderr),
              output: result.stdout);
        }
        final output = result.stdout.trim();
        if (output.isEmpty || output.contains('unable to load certificate')) {
          return ToolResult.failure('无法加载证书: $certPath', output: output);
        }
        final parsed = _parseCertOutput(output, certPath, null);
        return ToolResult.success(parsed);
      } catch (e) {
        return ToolResult.failure('检查异常: $e');
      }
    }

    if (mode == 'ssh_hostkey') {
      onProgress?.call(UiText.t(
          '正在读取 SSH host key 指纹...', 'Reading SSH host key fingerprints...'));
      // 列出 /etc/ssh/ 下所有 host key 的指纹
      const cmd = "for f in /etc/ssh/ssh_host_*_key.pub; do "
          "ssh-keygen -lf \"\$f\" 2>/dev/null; "
          "done";
      try {
        final result = await executor.executeAndWait(cmd,
            timeout: const Duration(seconds: 10));
        if (!result.success) {
          return ToolResult.failure('ssh-keygen 执行失败: ${result.stderr}',
              output: result.stdout);
        }
        final output = result.stdout.trim();
        if (output.isEmpty) {
          return ToolResult.failure('未找到 host key（可能权限不足或路径不存在）');
        }
        return ToolResult.success('SSH Host Key 指纹:\n$output');
      } catch (e) {
        return ToolResult.failure('检查异常: $e');
      }
    }

    return ToolResult.failure(
        '未知 mode: $mode（支持 remote/local_file/ssh_hostkey）');
  }

  /// 解析 openssl x509 -dates -issuer -subject 输出
  String _parseCertOutput(String output, String target, int? port) {
    String? notBefore;
    String? notAfter;
    String? issuer;
    String? subject;

    for (final line in output.split('\n')) {
      final l = line.trim();
      if (l.startsWith('notBefore=')) {
        notBefore = l.substring('notBefore='.length);
      }
      if (l.startsWith('notAfter=')) notAfter = l.substring('notAfter='.length);
      if (l.startsWith('issuer=')) issuer = l.substring('issuer='.length);
      if (l.startsWith('subject=')) subject = l.substring('subject='.length);
    }

    if (notAfter == null) {
      return '无法解析证书到期时间。原始输出:\n$output';
    }

    // 计算剩余天数
    int daysLeft = -1;
    try {
      // openssl 输出格式如: Aug 14 12:00:00 2025 GMT
      final dt = _parseOpenSslDate(notAfter);
      if (dt != null) {
        daysLeft = dt.difference(DateTime.now()).inDays;
      }
    } catch (_) {}

    final targetDesc = port != null ? '$target:$port' : target;
    final buffer = StringBuffer();
    buffer.writeln('证书目标: $targetDesc');
    buffer.writeln('主题: ${subject ?? "(未知)"}');
    buffer.writeln('颁发者: ${issuer ?? "(未知)"}');
    buffer.writeln('生效时间: ${notBefore ?? "(未知)"}');
    buffer.writeln('过期时间: $notAfter');
    if (daysLeft >= 0) {
      buffer.writeln('剩余天数: $daysLeft 天');
      if (daysLeft <= 0) {
        buffer.writeln('⚠️ 状态: 已过期');
      } else if (daysLeft <= 30) {
        buffer.writeln('⚠️ 状态: 即将到期（30 天内）');
      } else if (daysLeft <= 90) {
        buffer.writeln('状态: 注意（90 天内到期）');
      } else {
        buffer.writeln('状态: 正常');
      }
    }
    return buffer.toString().trimRight();
  }

  /// 解析 openssl 日期格式（如 "Aug 14 12:00:00 2025 GMT"）
  DateTime? _parseOpenSslDate(String s) {
    try {
      // 简单解析：用 Locale 不敏感的方式手动解析
      final months = {
        'Jan': 1,
        'Feb': 2,
        'Mar': 3,
        'Apr': 4,
        'May': 5,
        'Jun': 6,
        'Jul': 7,
        'Aug': 8,
        'Sep': 9,
        'Oct': 10,
        'Nov': 11,
        'Dec': 12,
      };
      final parts = s.split(RegExp(r'\s+'));
      if (parts.length < 5) return null;
      final mon = months[parts[0]];
      if (mon == null) return null;
      final day = int.parse(parts[1]);
      // parts[2] = HH:MM:SS
      final timeParts = parts[2].split(':');
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);
      final second = int.parse(timeParts[2]);
      final year = int.parse(parts[3]);
      return DateTime.utc(year, mon, day, hour, minute, second).toLocal();
    } catch (_) {
      return null;
    }
  }
}

/// 文件写入工具（绕过 shell 命令构造，从根本上避免转义/换行/EOF 问题）
///
/// **设计动机**：AI 用 `echo` / `cat <<EOF` / `sed` 写文件时，内容含 `$`、`\`、`"`、`'`、
/// 或 EOF 字符串都会导致写入失败或内容损坏。本工具让 AI 通过 SFTP 直接写入远程文件，
/// 完全绕过 shell，字符和换行符原样保留。
///
/// **使用方式**：
/// - 小文件（< 8KB）：一次调用，mode=write，提供完整 content_b64
/// - 大文件（>= 8KB）：分块调用，先 mode=write 写第一块，再 mode=append 追加后续块
///   每块保持 < 8KB 原文（base64 编码后约 11KB），AI 算 base64 不会出错
///
/// **鲁棒性设计**：
/// - H2: append 模式要求文件已存在，防止误用导致内容拼接到不期望的文件
/// - H3/H5: mode=write 覆盖已存在文件前自动备份到 .bak.{timestamp}，写入失败自动回滚
/// - 备份机制可通过 backup: false 关闭（如新建文件场景，避免无意义备份）
///
/// **大文件替代方案**：超过 8KB 的文件建议在本地编辑好（用本地编辑器/工具），
/// 然后用 sftp_upload 工具上传，避免 AI 输出大文本时丢字符。
class FileWriteTool extends AgentTool {
  @override
  String get name => 'file_write';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '直接写入文件内容（绕过 shell，避免转义/换行/EOF 问题）。'
      '支持 SSH 远程文件和本地文件。'
      '推荐用于：新建配置文件、整体重写文件、写入含特殊字符的脚本。'
      '普通文本优先用 content（单行写法，\\n 表示换行），避免自己计算 base64；'
      '二进制或需要逐字节精确（含首尾空格）时用 content_b64。'
      '大文件需分块：第一次 mode=write，后续 mode=append 追加。'
      '覆盖已存在文件时自动备份到 .bak.{timestamp}，失败自动回滚。'
      'append 模式要求文件已存在。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 文件绝对路径（必填。SSH 会话为远程路径，本地会话为本地路径）\n'
      '  content: 文本内容（与 content_b64 二选一，不能为空。整个值必须写在一行，'
      '用 \\n 表示换行、\\r 表示回车、\\t 表示制表符、\\\\ 表示反斜杠。'
      '适合中文/配置/脚本等普通文本）\n'
      '  content_b64: 文件内容的 base64 编码（与 content 二选一。用于二进制、'
      '需保留首尾空白或逐字节精确的内容。单次建议 < 8KB 原文；'
      '超限请分块：第一次 mode=write，后续 mode=append）\n'
      '  mode: write | append（可选，默认 write。append 用于分块写入场景追加到文件末尾）\n'
      '  backup: true | false（可选，默认 true。仅 mode=write 且文件已存在时生效，'
      '自动备份原文件到 {path}.bak.{timestamp}）';

  /// 单次写入大小上限（原文，未 base64）：8KB
  /// 超过此值的 content_b64 会被拒绝，强制 AI 分块写入
  static const int _maxChunkSize = 8 * 1024;

  /// base64 展开系数为 4/3；解码前先拒绝超限编码串，避免先分配超大字节数组。
  static const int _maxEncodedChunkSize = ((_maxChunkSize + 2) ~/ 3) * 4;

  /// 备份文件大小上限：10MB（更大的文件应该走 sftp_upload，不应整体重写）
  static const int _maxBackupSize = 10 * 1024 * 1024;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final path = args.getString('path');
    final contentB64 = args.getString('content_b64');
    final contentPlain = args.getString('content');
    final mode = args.getString('mode', defaultValue: 'write');
    final backup = args.getBool('backup', defaultValue: true);

    if (path.isEmpty) {
      return ToolResult.failure('参数缺失: path 为必填项');
    }
    if (contentB64.isEmpty && !args.containsKey('content')) {
      return ToolResult.failure(UiText.t('参数缺失: content 或 content_b64 必须提供一个',
          'Missing parameter: provide either content or content_b64'));
    }
    if (contentB64.isNotEmpty && args.containsKey('content')) {
      return ToolResult.failure('参数错误: content 与 content_b64 不能同时提供');
    }
    if (contentB64.isEmpty && contentPlain.isEmpty) {
      // 多行内容若直接写在 content: 后面，解析器只会得到空值，
      // 静默写入空文件会造成数据丢失；这里强制报错让 AI 改用 \n 转义。
      return ToolResult.failure(
        UiText.t(
          'content 为空。若内容是文本，请写成一行并用 \\n 表示换行；'
              '若需逐字节精确内容，请用 content_b64。已中止写入，文件未修改。',
          'content is empty. For text, write it on one line using \\n for newlines; '
              'for byte-exact content use content_b64. Write aborted, file unchanged.',
        ),
      );
    }
    if (mode != 'write' && mode != 'append') {
      return ToolResult.failure('参数错误: mode 只能是 write 或 append，实际值为 "$mode"');
    }

    final Uint8List contentBytes;
    if (contentB64.isNotEmpty) {
      if (contentB64.length > _maxEncodedChunkSize) {
        return ToolResult.failure(
          'content_b64 编码内容过大 (${contentB64.length} 字符 > $_maxEncodedChunkSize 字符)，'
          '已中止解码与写入；请将原文分成小于 8KB 的块。',
        );
      }
      try {
        contentBytes = base64Decode(contentB64);
      } catch (e) {
        return ToolResult.failure('content_b64 base64 解码失败: $e');
      }
    } else {
      if (contentPlain.length > _maxChunkSize) {
        return ToolResult.failure(
            'content 原文超过 8KB，已中止转义编码；请分块写入或使用 content_b64。');
      }
      // 纯文本：把单行参数里的 \n / \r / \t / \\ 还原为真实控制字符
      contentBytes =
          Uint8List.fromList(utf8.encode(decodeEscapedText(contentPlain)));
    }

    // 大小限制：避免 AI 一次输出过大 base64 出错
    if (contentBytes.length > _maxChunkSize) {
      return ToolResult.failure(
        UiText.t(
          '单次写入内容过大 (${contentBytes.length} 字节 > $_maxChunkSize 字节)。'
              '请分块写入：第一次 mode=write 写入前 8KB，后续 mode=append 追加剩余内容。'
              '提示：每次调用前在本地把内容切成 < 8KB 的块，分别 base64 编码后调用本工具。',
          'Single-write content too large (${contentBytes.length} bytes > $_maxChunkSize bytes). '
              'Write in chunks: first mode=write with the leading 8KB, then mode=append for the rest. '
              'Tip: split the content into blocks < 8KB locally, base64-encode each block, then call this tool per block.',
        ),
      );
    }

    onProgress?.call(UiText.t(
        '正在${mode == 'write' ? '写入' : '追加'} $path (${contentBytes.length} 字节)...',
        '${mode == 'write' ? 'Writing' : 'Appending'} $path (${contentBytes.length} bytes)...'));

    // SSH 远程会话：用 SFTP 直接写入
    if (executor is SSHService) {
      if (looksLikeWindowsLocalPath(path)) {
        // 设计稿 §4 就预见到这个混淆：AI 拿本机路径调远程工具时，SFTP 会把
        // "D:\deploy\app.conf" 当成一个文件名写到服务器上并回报成功 ——
        // 一次静默的错机器写入。宁可在这里停下。
        return ToolResult.failure(
          '当前是 SSH 远程会话，但 path 是本机路径格式：$path\n'
          'file_write 会把整串当成服务器上的文件名写入，不会碰到这台电脑。\n'
          '改本机文件请用 local_file_write；改服务器文件请给远程绝对路径（如 /etc/nginx/nginx.conf）。',
        );
      }
      if (_normalizedRemotePath(path) == null) {
        return ToolResult.failure('远程 path 必须是 POSIX 绝对路径: $path');
      }
      final client = executor.client;
      if (client == null) {
        return ToolResult.failure('SSH 连接未建立，无法打开 SFTP');
      }
      final sftp = SftpService();
      try {
        await sftp.attachToClient(client);
      } catch (e) {
        return ToolResult.failure('SFTP 连接失败: $e');
      }

      String? backupPath; // 用于失败时回滚
      String? sftpError; // SFTP 失败原因（非 null 时触发 PTY fallback）
      try {
        // 创建父目录（如 /etc/nginx/conf.d/ 不存在）
        final parentDir = p.posix.dirname(path);
        if (parentDir.isNotEmpty && parentDir != '/' && parentDir != '.') {
          await sftp.ensureDirectory(parentDir);
        }

        // H2: append 模式要求文件已存在
        if (mode == 'append') {
          final stat = await sftp.statFile(path);
          if (stat == null) {
            return ToolResult.failure(
              'append 模式要求文件已存在，但 $path 不存在。'
              '请先调用 file_write mode=write 创建文件，再用 mode=append 追加后续块。',
            );
          }
        }

        // H3/H5: write 模式覆盖前自动备份
        if (mode == 'write' && backup) {
          final existingStat = await sftp.statFile(path);
          if (existingStat != null) {
            final fileSize = existingStat.size ?? 0;
            if (fileSize > _maxBackupSize) {
              return ToolResult.failure(
                UiText.t(
                  '原文件过大 ($fileSize 字节 > $_maxBackupSize 字节)，无法自动备份。'
                      '请先手动备份（如 cp $path $path.manual.bak），再用 backup: false 调用本工具。',
                  'Original file too large ($fileSize bytes > $_maxBackupSize bytes), cannot back up automatically. '
                      'Back it up manually first (e.g. cp $path $path.manual.bak), then call this tool with backup: false.',
                ),
              );
            }
            backupPath = '$path.bak.${DateTime.now().millisecondsSinceEpoch}';
            onProgress?.call(L10n.str.ut_a2a80977d9(backupPath));
            try {
              await sftp.copyFile(
                path,
                backupPath,
                maxBytes: _maxBackupSize,
                cancelToken: cancelToken,
              );
            } catch (e) {
              return ToolResult.failure(L10n.str.ut_e39887dfed(e));
            }
          }
        }

        // 写入
        if (mode == 'write') {
          await sftp.writeFileBytes(path, contentBytes,
              cancelToken: cancelToken);
        } else {
          await sftp.appendFileBytes(path, contentBytes,
              cancelToken: cancelToken);
        }

        onProgress?.call(UiText.t('写入完成', 'Write complete'));
        final msg = StringBuffer()
          ..writeln(UiText.t(
              '文件${mode == 'write' ? '写入' : '追加'}成功: $path (${contentBytes.length} 字节)',
              '${mode == 'write' ? 'File written' : 'Content appended'}: $path (${contentBytes.length} bytes)'));
        if (backupPath != null) {
          msg.writeln(L10n.str.ut_fcda8e6588(backupPath));
          msg.writeln(L10n.str.ut_b9beeabb91(backupPath, path));
        }
        return ToolResult.success(msg.toString().trimRight());
      } catch (e) {
        sftpError = e.toString();
        // H3 失败回滚：恢复备份
        if (backupPath != null) {
          onProgress?.call(UiText.t('SFTP 写入失败，正在回滚备份 ...',
              'SFTP write failed, rolling back from backup ...'));
          try {
            await sftp.copyFile(backupPath, path);
            onProgress?.call(
                UiText.t('原文件已从备份恢复', 'Original file restored from backup'));
          } catch (rollbackErr) {
            // 回滚失败也继续走 PTY fallback（PTY 会覆盖原文件）
            onProgress?.call(L10n.str.ut_a7bd551b52(rollbackErr));
          }
        }
      } finally {
        sftp.closeSftpOnly();
      }

      // SFTP 失败 → PTY stdin fallback（绕过 SFTP 子系统，继承当前 shell 权限）
      // 适用于：SFTP 子系统被禁用 / 当前用户对目标路径无写权限 / 已 sudo -i 进 root
      // 走到这行说明 try 块抛了异常（catch 已执行，sftpError 已被赋值）
      if (mode == 'write') {
        onProgress?.call(UiText.t('SFTP 写入失败，尝试 PTY stdin 模式 (cat > file)...',
            'SFTP write failed, trying PTY stdin mode (cat > file)...'));
        final backupInfo =
            backupPath != null ? L10n.str.ut_f8d0ae7c3c(backupPath) : '';

        // 第一次：cat > /path（适用于 root shell 或用户有权限）
        var ptyResult = await executor.writeFileViaPty(
          path: path,
          content: contentBytes,
          useSudo: false,
          timeout: const Duration(seconds: 30),
          cancelToken: cancelToken,
        );
        if (ptyResult.success) {
          return ToolResult.success(
            L10n.str.ut_6820e10527(path, contentBytes.length, backupInfo),
          );
        }
        // cancelToken 触发时不再尝试 sudo tee，直接返回
        if (cancelToken != null && cancelToken!.isCompleted) {
          return ToolResult.failure(UiText.t(
              '用户取消任务，PTY 写入中止', 'Task cancelled by user, PTY write aborted'));
        }
        onProgress?.call(L10n.str.ut_caa84ab310(ptyResult.failureReason ?? ''));

        // 第二次：sudo tee /path > /dev/null（适用于非 root + sudo 可用）
        final ptyResult2 = await executor.writeFileViaPty(
          path: path,
          content: contentBytes,
          useSudo: true,
          timeout: const Duration(seconds: 30),
          cancelToken: cancelToken,
        );
        if (ptyResult2.success) {
          return ToolResult.success(
            L10n.str.ut_b0ea4177b4(path, contentBytes.length, backupInfo),
          );
        }

        // 两种 PTY 模式都失败
        return ToolResult.failure(
          'SFTP 与 PTY stdin 均失败。\n'
          'SFTP 错误: $sftpError\n'
          'PTY cat 错误: ${ptyResult.failureReason ?? ptyResult.stderr}\n'
          'PTY sudo tee 错误: ${ptyResult2.failureReason ?? ptyResult2.stderr}\n'
          '建议：检查 SSH 用户对 $path 的写权限，或确认 sudo 是否可用（NOPASSWD 或已缓存密码）。'
          '${backupPath != null ? "\n如需回滚: mv $backupPath $path" : ""}',
        );
      }

      // append 模式不走 PTY fallback（PTY stdin 无法精确追加）
      return ToolResult.failure(
          'SFTP 追加写入失败: $sftpError。append 模式不支持 PTY fallback，请检查 SFTP 子系统。');
    }

    // 本地终端：共享非截断打开、句柄身份校验与句柄回滚实现。
    if (executor is LocalTerminalService) {
      final policy = LocalFilePolicy.load();
      final initial = policy.decide(path);
      if (initial.verdict == LocalPathVerdict.sensitive ||
          initial.verdict == LocalPathVerdict.reserved ||
          initial.verdict == LocalPathVerdict.escape) {
        return ToolResult.failure(_localPathDeniedMessage(path, initial));
      }
      final decision = await authorizeLocalPath(
        rawPath: p.dirname(path),
        mode: LocalAccessMode.write,
        access: localAccess,
        policy: policy,
        reason: 'file_write 需要写入本地文件 $path（含父目录中的临时/备份文件）',
      );
      if (!decision.isAllowed) {
        return ToolResult.failure(_localPathDeniedMessage(path, decision));
      }
      final verified = _decideLocalPath(path,
          access: localAccess, mode: LocalAccessMode.write);
      if (!verified.isAllowed) {
        return ToolResult.failure(_localPathDeniedMessage(path, verified));
      }
      final localPath = verified.resolved;
      final outcome = await writeLocalFile(
        path: localPath,
        bytes: contentBytes,
        append: mode == 'append',
        backup: backup,
        authorizePath: (raw, expected) async => _freshLocalPathDenial(
            raw, expected,
            access: localAccess, mode: LocalAccessMode.write),
      );
      if (outcome.success) {
        onProgress?.call(UiText.t('写入完成', 'Write complete'));
        return _localWriteSuccess(
          path: localPath,
          byteCount: contentBytes.length,
          mode: mode,
          method: UiText.t('本地文件', 'Local file'),
          backupPath: outcome.backupPath,
        );
      }

      // 仅在没有备份、且直接写入尚未开始时才允许旧 PTY 权限回退。
      // 有备份而写入失败的路径必须由共享原语回滚，不能再用 shell 覆盖。
      if (!Platform.isWindows &&
          mode == 'write' &&
          outcome.backupPath == null &&
          !(outcome.error ?? '').contains('原子性校验') &&
          !(outcome.error ?? '').contains('授权') &&
          cancelToken?.isCompleted != true) {
        final fallbackCheck = _decideLocalPath(path,
            access: localAccess, mode: LocalAccessMode.write);
        if (!fallbackCheck.isAllowed) {
          return ToolResult.failure(
              _localPathDeniedMessage(path, fallbackCheck));
        }
        onProgress?.call(UiText.t('本地直接写入失败，尝试通过当前 shell 写入 ...',
            'Direct local write failed, writing via the current shell ...'));
        final ptyResult = await executor.writeFileViaPty(
          path: localPath,
          content: contentBytes,
          useSudo: false,
          timeout: const Duration(seconds: 30),
          cancelToken: cancelToken,
        );
        if (ptyResult.success) {
          return _localWriteSuccess(
            path: localPath,
            byteCount: contentBytes.length,
            mode: mode,
            method: UiText.t('本地 PTY stdin', 'local PTY stdin'),
          );
        }
        if (cancelToken?.isCompleted == true) {
          return ToolResult.failure(UiText.t(
              '用户取消任务，PTY 写入中止', 'Task cancelled by user, PTY write aborted'));
        }
        final sudoCheck = _decideLocalPath(path,
            access: localAccess, mode: LocalAccessMode.write);
        if (!sudoCheck.isAllowed) {
          return ToolResult.failure(_localPathDeniedMessage(path, sudoCheck));
        }
        final ptyResult2 = await executor.writeFileViaPty(
          path: localPath,
          content: contentBytes,
          useSudo: true,
          timeout: const Duration(seconds: 30),
          cancelToken: cancelToken,
        );
        if (ptyResult2.success) {
          return _localWriteSuccess(
            path: localPath,
            byteCount: contentBytes.length,
            mode: mode,
            method: UiText.t(
                '本地 PTY stdin + sudo tee', 'local PTY stdin + sudo tee'),
          );
        }
        return ToolResult.failure(
          '本地文件写入失败。\n'
          '直接写入: ${outcome.error}\n'
          'PTY cat: ${ptyResult.failureReason ?? ptyResult.stderr}\n'
          'PTY sudo tee: ${ptyResult2.failureReason ?? ptyResult2.stderr}',
        );
      }
      return ToolResult.failure('本地文件写入失败: ${outcome.error}');
    }

    return ToolResult.failure(
        'file_write 仅支持 SSHService / LocalTerminalService，当前 executor 类型不支持');
  }

  ToolResult _localWriteSuccess({
    required String path,
    required int byteCount,
    required String mode,
    required String method,
    String? backupPath,
    bool backupUnavailable = false,
  }) {
    final msg = StringBuffer()
      ..writeln(UiText.t(
          '文件${mode == 'write' ? '写入' : '追加'}成功（$method）: $path ($byteCount 字节)',
          '${mode == 'write' ? 'File written' : 'Content appended'} ($method): $path ($byteCount bytes)'));
    if (backupPath != null) {
      msg.writeln(L10n.str.ut_fcda8e6588(backupPath));
      msg.writeln(L10n.str.ut_c4acfd10f3(path));
    } else if (backupUnavailable) {
      msg.writeln(UiText.t('  注意：当前进程无权限读取原文件，未能生成备份。',
          '  Note: this process cannot read the original file, so no backup was created.'));
    }
    return ToolResult.success(msg.toString().trimRight());
  }
}

/// 文件补丁工具（基于字符串替换 + 唯一性校验 + 原子性保护）
///
/// **设计动机**：配置文件小改动（如改端口、改 server_name）用 file_write 整体重写
/// 浪费 token，且 AI 容易漏掉原文件其他部分。本工具让 AI 只提供 old/new 字符串，
/// Dart 层读取文件 → 替换 → 写回，完全绕过 shell。
///
/// **替换语义**：
/// - 读取原文件 → 统计 old 出现次数
/// - 若 != 1，报错：唯一性校验失败，让 AI 提供更长上下文
/// - 若 == 1，replace 后写回
///
/// **鲁棒性设计**：
/// - H1 原子性：read 时记录 (size, mtime)，write 前再 stat 校验，
///   若不一致说明文件被外部修改，拒绝写入避免覆盖外部更新
/// - 自动备份：写回前 copy 到 .bak.{timestamp}，写入失败自动回滚
/// - backup: false 可关闭备份（如修改临时文件）
///
/// **old/new 支持多行**：通过 base64 编码传递，避免单行参数无法承载换行符
class FilePatchTool extends AgentTool {
  @override
  String get name => 'file_patch';

  @override
  ToolKind get kind => ToolKind.write;

  @override
  String get description => '通过字符串替换修改文件（绕过 shell，避免 sed 转义问题）。'
      '支持 SSH 远程文件和本地文件。'
      '推荐用于：改一两行配置、替换变量值、修改 server_name 等小改动。'
      'old 必须在文件中唯一出现，否则报错让 AI 提供更长上下文。'
      '单行替换优先用 old/new 纯文本（无需 base64，中文更可靠）；'
      '多行、含首尾空白或特殊空白时用 old_b64/new_b64。'
      '按字节替换：文件中的其他内容（BOM/CRLF/非 UTF-8 字节）原样保留。'
      '原子性保护：若读取后文件被外部修改，拒绝写入。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 文件绝对路径（必填。SSH 会话为远程路径，本地会话为本地路径）\n'
      '  old: 要替换的单行原文（与 old_b64 二选一。无需 base64，推荐用于中文/单行替换）\n'
      '  new: 替换后的单行内容（与 new_b64 二选一。留空表示删除 old）\n'
      '  old_b64: 要替换原文的 base64（与 old 二选一。用于多行或需保留首尾空白的内容）\n'
      '  new_b64: 新内容的 base64（与 new 二选一。可为空字符串表示删除 old）\n'
      '  backup: true | false（可选，默认 true。自动备份原文件到 {path}.bak.{timestamp}，'
      '失败时自动回滚）';

  /// 文件大小上限：1MB（patch 仅适用于小配置文件，大文件请用 file_write 整体重写）
  static const int _maxFileSize = 1024 * 1024;
  static const int _maxPlainFieldLength = 64 * 1024;
  static const int _maxEncodedFieldSize = ((_maxFileSize + 2) ~/ 3) * 4;
  static const int _maxPatchedFileSize = 2 * _maxFileSize;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final path = args.getString('path');
    final oldB64 = args.getString('old_b64');
    final newB64 = args.getString('new_b64');
    final oldPlain = args.getString('old');
    final newPlain = args.getString('new');
    final backup = args.getBool('backup', defaultValue: true);

    if (path.isEmpty) {
      return ToolResult.failure('参数缺失: path 为必填项');
    }
    if (oldB64.isEmpty && oldPlain.isEmpty) {
      return ToolResult.failure('参数缺失: old 或 old_b64 必须提供一个');
    }
    if (oldB64.isNotEmpty && args.containsKey('old')) {
      return ToolResult.failure('参数错误: old 与 old_b64 不能同时提供');
    }
    if (newB64.isNotEmpty && args.containsKey('new')) {
      return ToolResult.failure('参数错误: new 与 new_b64 不能同时提供');
    }

    // 替换按原始字节进行，避免解码/重编码损坏 BOM、CRLF 或非 UTF-8 字节。
    // 文本视图仅用于错误提示和 diff 统计。
    Uint8List oldBytes;
    Uint8List newBytes;
    if (oldB64.isNotEmpty) {
      if (oldB64.length > _maxEncodedFieldSize) {
        return ToolResult.failure('old_b64 编码内容过大，已中止解码。');
      }
      try {
        oldBytes = base64Decode(oldB64);
      } catch (e) {
        return ToolResult.failure('old_b64 base64 解码失败: $e');
      }
    } else {
      if (oldPlain.length > _maxPlainFieldLength) {
        return ToolResult.failure('old 原文超过 64KB，已中止编码；更大内容请使用 old_b64。');
      }
      oldBytes = Uint8List.fromList(utf8.encode(oldPlain));
    }
    if (oldBytes.length > _maxFileSize) {
      return ToolResult.failure('old 内容超过 1MB，拒绝 patch。');
    }
    if (newB64.isNotEmpty) {
      if (newB64.length > _maxEncodedFieldSize) {
        return ToolResult.failure('new_b64 编码内容过大，已中止解码。');
      }
      try {
        newBytes = base64Decode(newB64);
      } catch (e) {
        return ToolResult.failure('new_b64 base64 解码失败: $e');
      }
    } else {
      if (newPlain.length > _maxPlainFieldLength) {
        return ToolResult.failure('new 原文超过 64KB，已中止编码；更大内容请使用 new_b64。');
      }
      // new 允许为空：表示删除 old
      newBytes = Uint8List.fromList(utf8.encode(newPlain));
    }
    if (newBytes.length > _maxFileSize) {
      return ToolResult.failure('new 内容超过 1MB，拒绝 patch。');
    }
    final oldStr = utf8.decode(oldBytes, allowMalformed: true);
    final newStr = utf8.decode(newBytes, allowMalformed: true);

    onProgress?.call(L10n.str.ut_f4856090f2(path));

    // SSH 远程会话
    if (executor is SSHService) {
      if (looksLikeWindowsLocalPath(path)) {
        return ToolResult.failure(
          '当前是 SSH 远程会话，但 path 是本机路径格式：$path\n'
          'file_patch 会把整串当成服务器上的文件名去改，不会碰到这台电脑。\n'
          '改本机文件请用 local_file_patch；改服务器文件请给远程绝对路径（如 /etc/nginx/nginx.conf）。',
        );
      }
      if (_normalizedRemotePath(path) == null) {
        return ToolResult.failure('远程 path 必须是 POSIX 绝对路径: $path');
      }
      final client = executor.client;
      if (client == null) {
        return ToolResult.failure('SSH 连接未建立，无法打开 SFTP');
      }
      final sftp = SftpService();
      try {
        await sftp.attachToClient(client);
      } catch (e) {
        return ToolResult.failure('SFTP 连接失败: $e');
      }

      String? backupPath; // 用于失败时回滚
      try {
        // H1 原子性：read 时记录文件 (size, mtime)
        final beforeStat = await sftp.statFile(path);
        if (beforeStat == null) {
          return ToolResult.failure(
            '文件不存在: $path。file_patch 仅能修改已存在的文件，'
            '如需新建文件请用 file_write。',
          );
        }
        final beforeSize = beforeStat.size ?? 0;
        if (beforeSize > _maxFileSize) {
          return ToolResult.failure(
            '文件过大 ($beforeSize 字节 > $_maxFileSize 字节)，已拒绝读取。'
            'patch 仅适用于 < 1MB 的配置文件，大文件请用 file_write 整体重写。',
          );
        }
        final beforeMtime = beforeStat.modifyTime ?? 0;

        // 读取原文件
        final bytes = await sftp.readFileBytes(path, maxSize: _maxFileSize + 1);
        if (bytes.length > _maxFileSize) {
          return ToolResult.failure(
            '文件过大 (${bytes.length} 字节 > $_maxFileSize 字节)。'
            'patch 仅适用于 < 1MB 的配置文件，大文件请用 file_write 整体重写。',
          );
        }
        // 唯一性校验：按字节统计 old 出现次数
        final occurrences = _countOccurrencesBytes(bytes, oldBytes);
        if (occurrences == 0) {
          return ToolResult.failure(
            'old 在文件中未找到。请检查 old 是否正确（包括前后空白、换行符）。',
            output: '提示：old 必须与文件内容完全匹配。'
                '建议先用 cat 命令查看文件内容，再选取要替换的精确字符串。',
          );
        }
        if (occurrences > 1) {
          return ToolResult.failure(
            'old 在文件中出现 $occurrences 次，无法确定替换哪个。'
            '请提供更长的上下文（包含前后行）使 old 唯一。',
            output:
                'old 内容预览: ${oldStr.length > 100 ? '${oldStr.substring(0, 100)}...' : oldStr}',
          );
        }

        // 字节级替换：文件其他部分（BOM/CRLF/非 UTF-8 字节）原样保留
        final newFileBytes = _replaceFirstBytes(bytes, oldBytes, newBytes);
        if (newFileBytes.length > _maxPatchedFileSize) {
          return ToolResult.failure('patch 后文件超过 2MB，拒绝写入。');
        }

        // H1 原子性：write 前再 stat 一次，若 size/mtime 变化则拒绝写入
        final afterStat = await sftp.statFile(path);
        if (afterStat == null) {
          return ToolResult.failure('原子性校验失败：文件在读取后已不存在，已中止写入。');
        }
        final afterSize = afterStat.size ?? 0;
        final afterMtime = afterStat.modifyTime ?? 0;
        if (afterSize != beforeSize || afterMtime != beforeMtime) {
          return ToolResult.failure(
            '原子性校验失败：文件在读取后被外部修改 '
            '(before: size=$beforeSize, mtime=$beforeMtime; '
            'after: size=$afterSize, mtime=$afterMtime)。'
            '已中止写入，请用 cat 重新查看文件内容后再次尝试 file_patch。',
          );
        }

        // 自动备份
        if (backup) {
          backupPath = '$path.bak.${DateTime.now().millisecondsSinceEpoch}';
          onProgress?.call(L10n.str.ut_a2a80977d9(backupPath));
          try {
            await sftp.copyFile(
              path,
              backupPath,
              maxBytes: _maxFileSize,
              cancelToken: cancelToken,
            );
          } catch (e) {
            return ToolResult.failure(L10n.str.ut_e39887dfed(e));
          }
        }

        // 写回
        await sftp.writeFileBytes(path, newFileBytes, cancelToken: cancelToken);

        onProgress?.call(UiText.t('替换完成', 'Replacement complete'));
        final msg = StringBuffer()
          ..writeln(L10n.str.ut_af40dec29f(path))
          ..writeln(L10n.str.ut_fb892c6b10(oldBytes.length, newBytes.length))
          ..writeln(L10n.str.ut_59e5f6620a(bytes.length, newFileBytes.length));
        if (backupPath != null) {
          msg.writeln(L10n.str.ut_fcda8e6588(backupPath));
          msg.writeln(L10n.str.ut_b9beeabb91(backupPath, path));
        }
        final diff = LineDiff.compute(oldStr, newStr);
        return ToolResult.success(
          msg.toString().trimRight(),
          diffAdditions: diff?.additions,
          diffDeletions: diff?.deletions,
        );
      } catch (e) {
        // 失败回滚：恢复备份
        if (backupPath != null) {
          onProgress?.call(
              UiText.t('写入失败，正在回滚 ...', 'Write failed, rolling back ...'));
          try {
            await sftp.copyFile(backupPath, path);
            return ToolResult.failure(
              UiText.t(
                'file_patch 写入失败: $e\n已自动回滚：原文件已从备份 $backupPath 恢复。',
                'file_patch write failed: $e\nAutomatically rolled back: the original file was restored from backup $backupPath.',
              ),
            );
          } catch (rollbackErr) {
            return ToolResult.failure(
              'file_patch 写入失败: $e\n回滚也失败: $rollbackErr。'
              '原文件可能已损坏，请手动从备份 $backupPath 恢复：mv $backupPath $path',
            );
          }
        }
        return ToolResult.failure('file_patch 失败: $e');
      } finally {
        sftp.closeSftpOnly();
      }
    }

    // 本地终端：字节级补丁走共享句柄实现，保留非 UTF-8 内容并绑定写时授权。
    if (executor is LocalTerminalService) {
      final policy = LocalFilePolicy.load();
      final initial = policy.decide(path);
      if (initial.verdict == LocalPathVerdict.sensitive ||
          initial.verdict == LocalPathVerdict.reserved ||
          initial.verdict == LocalPathVerdict.escape) {
        return ToolResult.failure(_localPathDeniedMessage(path, initial));
      }
      final decision = await authorizeLocalPath(
        rawPath: p.dirname(path),
        mode: LocalAccessMode.write,
        access: localAccess,
        policy: policy,
        reason: 'file_patch 需要读取并修改本地文件 $path（含父目录中的临时/备份文件）',
      );
      if (!decision.isAllowed) {
        return ToolResult.failure(_localPathDeniedMessage(path, decision));
      }
      final verified = _decideLocalPath(path,
          access: localAccess, mode: LocalAccessMode.write);
      if (!verified.isAllowed) {
        return ToolResult.failure(_localPathDeniedMessage(path, verified));
      }
      final localPath = verified.resolved;
      final file = File(localPath);
      if (!await file.exists()) {
        return ToolResult.failure(
          '文件不存在: $path。file_patch 仅能修改已存在的文件，'
          '如需新建文件请用 file_write。',
        );
      }
      final initialSize = await file.length();
      if (initialSize > _maxFileSize) {
        return ToolResult.failure(
          '文件过大 ($initialSize 字节 > $_maxFileSize 字节)，已拒绝读取。'
          'patch 仅适用于 < 1MB 的配置文件，大文件请用 file_write 整体重写。',
        );
      }
      final outcome = await patchLocalFileBytes(
        path: localPath,
        oldBytes: oldBytes,
        newBytes: newBytes,
        backup: backup,
        maxBytes: _maxFileSize,
        maxPatchedBytes: _maxPatchedFileSize,
        authorizePath: (raw, expected) async => _freshLocalPathDenial(
            raw, expected,
            access: localAccess, mode: LocalAccessMode.write),
      );
      if (!outcome.success) {
        return ToolResult.failure(outcome.error ?? 'file_patch 失败');
      }

      onProgress?.call(UiText.t('替换完成', 'Replacement complete'));
      final msg = StringBuffer()
        ..writeln(L10n.str.ut_af40dec29f(path))
        ..writeln(L10n.str.ut_fb892c6b10(oldBytes.length, newBytes.length))
        ..writeln(L10n.str
            .ut_59e5f6620a(outcome.originalBytes, outcome.patchedBytes));
      final backupPath = outcome.backupPath;
      if (backupPath != null) {
        msg.writeln(L10n.str.ut_fcda8e6588(backupPath));
        msg.writeln(L10n.str.ut_c4acfd10f3(path));
      }
      final diff = LineDiff.compute(oldStr, newStr);
      return ToolResult.success(
        msg.toString().trimRight(),
        diffAdditions: diff?.additions,
        diffDeletions: diff?.deletions,
      );
    }

    return ToolResult.failure(
      'file_patch 仅支持 SSHService / LocalTerminalService，当前 executor 类型不支持',
    );
  }

  /// 统计 needle 在 haystack 中（不重叠）的出现次数。
  /// 前缀表只构建一次并在每次搜索间复用，避免重复 O(m) 预处理。
  static int _countOccurrencesBytes(Uint8List haystack, Uint8List needle) {
    if (needle.isEmpty) return 0;
    final prefix = _kmpPrefix(needle);
    var count = 0;
    var idx = 0;
    while (idx <= haystack.length - needle.length) {
      final found = _indexOfBytesKmp(haystack, needle, idx, prefix);
      if (found < 0) break;
      count++;
      idx = found + needle.length;
    }
    return count;
  }

  /// KMP 前缀表（最长相等前后缀长度）。O(m)。
  static List<int> _kmpPrefix(Uint8List needle) {
    final prefix = List<int>.filled(needle.length, 0);
    for (var i = 1, len = 0; i < needle.length; i++) {
      while (len > 0 && needle[i] != needle[len]) {
        len = prefix[len - 1];
      }
      if (needle[i] == needle[len]) len++;
      prefix[i] = len;
    }
    return prefix;
  }

  /// 朴素字节搜索的 KMP 替代：O(n + m)，最坏情况也不退化到 O(n·m)。
  static int _indexOfBytes(Uint8List haystack, Uint8List needle,
      [int start = 0]) {
    if (needle.isEmpty ||
        start < 0 ||
        start > haystack.length - needle.length) {
      return -1;
    }
    return _indexOfBytesKmp(haystack, needle, start, _kmpPrefix(needle));
  }

  static int _indexOfBytesKmp(
    Uint8List haystack,
    Uint8List needle,
    int start,
    List<int> prefix,
  ) {
    final n = haystack.length;
    final m = needle.length;
    var j = 0; // 已匹配的 needle 前缀长度
    for (var i = start; i < n; i++) {
      while (j > 0 && haystack[i] != needle[j]) {
        j = prefix[j - 1];
      }
      if (haystack[i] == needle[j]) {
        j++;
        if (j == m) return i - m + 1;
      }
    }
    return -1;
  }

  static Uint8List _replaceFirstBytes(
    Uint8List source,
    Uint8List oldBytes,
    Uint8List newBytes,
  ) {
    final idx = _indexOfBytes(source, oldBytes);
    if (idx < 0) {
      throw StateError('old bytes not found');
    }
    final result = Uint8List(source.length - oldBytes.length + newBytes.length);
    result.setRange(0, idx, source);
    result.setRange(idx, idx + newBytes.length, newBytes);
    result.setRange(
      idx + newBytes.length,
      result.length,
      source,
      idx + oldBytes.length,
    );
    return result;
  }

  /// 统计 substring 在 string 中出现的次数（非重叠）
  static int _countOccurrences(String string, String sub) {
    if (sub.isEmpty) return 0;
    int count = 0;
    int idx = 0;
    while ((idx = string.indexOf(sub, idx)) != -1) {
      count++;
      idx += sub.length;
    }
    return count;
  }

  /// @visibleForTesting — 暴露 _countOccurrences 给单元测试
  /// 不在运行时代码中调用
  @visibleForTesting
  static int countOccurrencesForTest(String string, String sub) {
    return _countOccurrences(string, sub);
  }
}

/// 注册表条目：工具 + 它的作用域
class _RegisteredTool {
  final AgentTool tool;
  final ToolScope scope;
  const _RegisteredTool(this.tool, this.scope);
}

/// 收集特权（sudo）密码的工具
///
/// 场景：命令因卡在 `[sudo] … 的密码：` 而失败，且该主机还没配置 sudo 密码。
/// 以前只能让用户绕去「主机编辑」页补填，AI 只能 ask 一句「请先配置密码」然后失败。
/// 本工具把这条路收进 ReAct 循环：掩码弹窗 → 写入安全存储 → 立即启用自动应答，
/// AI 直接重试原命令即可。
///
/// 密码**不**进 ToolResult.output：output 会作为 observation 回给模型，
/// 明文一旦进对话历史就永久留在上下文与持久化里（AGENTS.md R7）。
class ProvidePasswordTool extends AgentTool {
  @override
  String get name => 'provide_password';

  @override
  ToolKind get kind => ToolKind.write;

  /// 特权密码是本机凭据，不是主机上的文件变更。进变更台账既没有回滚意义，
  /// 又会在审计列表里多出一条敏感记录。
  @override
  bool get recordsChanges => false;

  @override
  String get description => '请用户输入当前主机的 sudo（特权）密码，保存到本机凭据库并立即启用密码提示自动应答。'
      '仅在命令因「等待 sudo 密码」失败、且该主机尚未配置 sudo 密码时调用。'
      '调用成功后重试原命令即可；本工具不会把密码内容返回给你。';

  @override
  String get paramSpec =>
      '参数列表（多行 key:value 格式）：\n  reason: 向用户说明为什么需要这个密码（可选，会显示在输入框上方）';

  @override
  Map<String, dynamic>? toJsonSchema() => {
        'type': 'object',
        'properties': {
          'reason': {
            'type': 'string',
            'description': '向用户说明为什么需要这个密码（可选）',
          },
        },
        'additionalProperties': false,
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final request = sudoPasswordRequest;
    if (request == null) {
      return ToolResult.failure(UiText.t('当前会话未接入密码输入，请在主机设置中填写 sudo 密码',
          'This session has no password prompt wired up; set the sudo password in host settings'));
    }
    onProgress?.call(UiText.t(
        '等待用户输入 sudo 密码…', 'Waiting for user to enter sudo password…'));
    final accepted = await request(args.getString('reason'));
    if (!accepted) {
      return ToolResult.failure(UiText.t(
          '用户未提供密码（取消或输入为空）。'
              '请改用 动作: ask 与用户确认，或改以非特权方式执行。',
          'No password provided by the user (cancelled or empty). '
              'Use 动作: ask to confirm with the user, or run without privileges.'));
    }
    return ToolResult.success('已收到 sudo 密码并保存到本机凭据库。'
        '请重试原命令，遇到 sudo 密码提示时系统会自动应答。');
  }
}

/// Agent 工具注册表 — 管理所有可用的工具
class AgentToolRegistry {
  final Map<String, _RegisteredTool> _entries = {};

  /// 文件同步服务实例（由 registry 持有，工具共享）
  final FileSyncService fileSyncService = FileSyncService();

  /// 多机执行器实例（编排模式用）
  MultiHostExecutor? _multiHostExecutor;

  /// 编排命令权限档位提供者：由拥有本 registry 的引擎注入，锁定任务归属 tab。
  AgentPermissionMode? Function()? permissionModeProvider;

  AgentToolRegistry() {
    // 注册默认工具
    register(SftpUploadTool());
    register(SftpDownloadTool());
    register(SftpFileReadTool(), scope: ToolScope.sshSession);
    register(FileSyncTool(fileSyncService));
    register(CertMonitorTool());
    // 文件编辑工具：默认模式即可用，不依赖编排模式
    // 注册在默认层，保证任何 SSH 会话都能直接编辑文件
    register(FileWriteTool());
    register(FilePatchTool());
    // 特权密码：sudo 提示导致命令失败时的兜底入口，SSH 与本地终端都需要。
    register(ProvidePasswordTool());
    // 本地项目工作流：这三个工具要求 LocalTerminalService executor，
    // 在 SSH 会话里注册了也只会失败，所以限定 localSession 作用域。
    register(ProjectAnalyzeTool(), scope: ToolScope.localSession);
    register(BuildProjectTool(), scope: ToolScope.localSession);
    register(PackageProjectTool(), scope: ToolScope.localSession);
    // 本地文件工具：作用域不限（SSH 会话里也要能改本机的部署配置），
    // 但每个路径都要过 LocalFilePolicy 的白名单 + 黑名单判定。
    registerLocalFileTools(this);
    // 本机 shell：只在 SSH 会话暴露。本地会话的 execute 已经在本机，
    // 再暴露 local_exec 只会让模型在两个等价入口之间犹豫。
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      register(LocalExecTool(), scope: ToolScope.sshSession);
    }
  }

  /// 启用编排模式：注册多机编排工具
  /// [registry] 来自 AgentNotifier，可访问所有 host 的 executor
  void enableOrchestrator(AgentHostRegistry registry) {
    if (_multiHostExecutor != null) return; // 已启用
    _multiHostExecutor = MultiHostExecutor(registry,
        // 延迟取值：引擎在任务运行中切换权限档位时立即生效，
        // 但读的是本 registry 归属的引擎，不是当时的活跃 tab。
        permissionModeProvider: () => permissionModeProvider?.call());
    register(ExecOnTool(_multiHostExecutor!), scope: ToolScope.orchestrator);
    register(ExecBatchTool(_multiHostExecutor!), scope: ToolScope.orchestrator);
    register(CheckConnectivityTool(_multiHostExecutor!),
        scope: ToolScope.orchestrator);
    register(UploadToTool(_multiHostExecutor!), scope: ToolScope.orchestrator);
    register(BroadcastUploadTool(_multiHostExecutor!),
        scope: ToolScope.orchestrator);
    register(CollectFileTool(_multiHostExecutor!),
        scope: ToolScope.orchestrator);
    register(MultiGrepTool(_multiHostExecutor!), scope: ToolScope.orchestrator);
    register(DiffFilesTool(_multiHostExecutor!), scope: ToolScope.orchestrator);
  }

  /// 禁用编排模式：注销多机编排工具
  void disableOrchestrator() {
    _multiHostExecutor = null;
    permissionModeProvider = null;
    for (final name in const [
      'exec_on',
      'exec_batch',
      'check_connectivity',
      'upload_to',
      'broadcast_upload',
      'collect_file',
      'multi_grep',
      'diff_files',
    ]) {
      _entries.remove(name);
    }
  }

  /// 启用联网搜索工具：注册 web_search / fetch_url
  ///
  /// 调用时机：由 AgentEngine.startTask 根据"全局开关 + 会话级开关"合并后调用。
  /// 工具一旦注册，buildToolsPrompt / buildOpenAIToolsSchema 自动把它注入 system prompt
  /// 和 FC schema，AI 在下一轮 ReAct 中即可看到并调用。
  void enableWebTools() {
    if (!has('web_search')) {
      register(WebSearchTool(), scope: ToolScope.all);
    }
    if (!has('fetch_url')) {
      register(FetchUrlTool(), scope: ToolScope.all);
    }
  }

  /// 禁用联网搜索工具：注销 web_search / fetch_url
  void disableWebTools() {
    _entries.remove('web_search');
    _entries.remove('fetch_url');
  }

  /// 当前是否已注册联网工具
  bool get isWebToolsEnabled => has('web_search');

  bool get isOrchestratorEnabled => _multiHostExecutor != null;

  MultiHostExecutor? get multiHostExecutor => _multiHostExecutor;

  void register(AgentTool tool, {ToolScope scope = ToolScope.all}) {
    _entries[tool.name] = _RegisteredTool(tool, scope);
  }

  /// 注销工具（供后续 MCP server 断开时清理其提供的工具）
  void unregister(String name) => _entries.remove(name);

  /// 按前缀批量注销（MCP 工具刷新用，避免维护第二份工具名单）
  void unregisterPrefix(String prefix) {
    _entries.removeWhere((name, _) => name.startsWith(prefix));
  }

  AgentTool? get(String name) => _entries[name]?.tool;

  bool has(String name) => _entries.containsKey(name);

  /// 全部已注册工具（不做作用域过滤，仅用于诊断/日志）
  List<AgentTool> get all => _entries.values.map((e) => e.tool).toList();

  /// 当前会话可见的工具 — 提示词与 FC schema 的唯一来源
  ///
  /// 任何"告诉 AI 有哪些能力"的文本都必须走这里。历史上部署工作流提示词
  /// 手写了三个未注册的工具名，AI 照着调必然失败（设计稿 D1）。
  List<AgentTool> visibleFor({required bool isLocalSession}) {
    return _entries.values
        .where((e) {
          switch (e.scope) {
            case ToolScope.all:
            case ToolScope.orchestrator:
              return true;
            case ToolScope.localSession:
              return isLocalSession;
            case ToolScope.sshSession:
              return !isLocalSession;
          }
        })
        .map((e) => e.tool)
        .toList();
  }

  /// 是否会产生需要记入变更台账的改动
  ///
  /// 由 [AgentTool.kind] / [AgentTool.recordsChanges] 派生，不再维护工具名清单：
  /// 新增写类工具自动进台账，忘记登记导致的"变更不可追溯"不会再发生。
  bool isChangeRecordingTool(String toolName) =>
      get(toolName)?.recordsChanges ?? false;

  List<String> get changeRecordingToolNames => _entries.values
      .where((e) => e.tool.recordsChanges)
      .map((e) => e.tool.name)
      .toList();

  /// 构建工具说明文本，注入 system prompt。
  /// [fcMode] 为 true 时（O8 FC-first），工具已通过 Function Calling schema 暴露，
  /// 只保留清单与参数语义说明，不再注入文本协议的调用格式示例。
  String buildToolsPrompt({required bool isLocalSession, bool fcMode = false}) {
    final tools = visibleFor(isLocalSession: isLocalSession);
    if (tools.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('【可用工具】');
    if (fcMode) {
      buffer.writeln('以下工具已通过 Function Calling 暴露：直接按工具名发起工具调用，'
          '参数按各自的 JSON schema 填写。下面是每个工具的用途与参数语义说明。');
    } else {
      buffer.writeln('当需要执行非 shell 命令的操作时（如上传文件、跨机执行），使用 "动作: tool" 调用工具。');
    }
    buffer.writeln();
    for (final tool in tools) {
      buffer.writeln('工具: ${tool.name}');
      buffer.writeln('  说明: ${tool.description}');
      buffer.writeln('  ${tool.paramSpec}');
      buffer.writeln();
    }
    if (fcMode) return buffer.toString().trimRight();
    buffer.writeln('工具调用格式示例（参数必须用多行 key:value 格式，不要用 JSON）:');
    buffer.writeln('思考: 需要把本地 dist 目录上传到服务器');
    buffer.writeln('动作: tool');
    buffer.writeln('工具: sftp_upload');
    buffer.writeln('参数:');
    buffer.writeln('  local: /Users/x/proj/dist');
    buffer.writeln('  remote: /var/www/myapp');
    buffer.writeln('  recursive: true');
    buffer.writeln('  exclude: node_modules,.git');
    return buffer.toString().trimRight();
  }

  /// P2-6: 构建 OpenAI tools API 格式的工具 schema 列表。
  /// 用于在 _callAI 中传给支持 Function Calling 的模型。
  /// 返回的每个元素结构：{type:'function', function:{name, description, parameters}}
  /// toJsonSchema() 返回 null 的工具会被跳过（不参与 FC）。
  ///
  /// O8 FC-first：execute/finish/ask 三个核心动作也作为工具暴露，
  /// 让 FC 模型全程走结构化 tool_calls，不再依赖文本协议行。
  List<Map<String, dynamic>> buildOpenAIToolsSchema(
      {required bool isLocalSession}) {
    final result = <Map<String, dynamic>>[
      {
        'type': 'function',
        'function': {
          'name': 'execute',
          'description': '在当前主机执行一条 shell 命令并获取输出。'
              '只读查询可用管道/&&/|| 组合；会修改系统状态的命令每轮只发一条。'
              '需要用户确认或输入密码时不要自行猜测，改用 ask 或 provide_password。',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': '要执行的完整 shell 命令',
              },
              'description': {
                'type': 'string',
                'description': '一句话说明这条命令做什么、会带来什么影响，'
                    '用普通人能听懂的话，不要只复述命令本身',
              },
            },
            'required': ['command'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'finish',
          'description': '任务完成时调用，给出最终回答。'
              '只有任务目标真正达成（或确认无法继续）时才能调用；'
              '计划中仍有未完成步骤时不要调用。'
              '用户只是提问（问原因/原理/差异，非操作请求）时，'
              '直接基于已有上下文作答并调用本工具，无需执行命令，'
              '并在正文开头写明"纯问答，无需执行命令"。',
          'parameters': {
            'type': 'object',
            'properties': {
              'answer': {
                'type': 'string',
                'description': '给用户的最终回答正文（允许 Markdown）：'
                    '做成了什么、现在是什么状态、需要注意什么、下一步建议',
              },
              'conclusion': {
                'type': 'string',
                'description': '结论：一句话说明目标是否完成、现在是什么状态',
              },
              'status': {
                'type': 'string',
                'description': '现状：只写实际验证过的关键状态；没有验证就写"未独立验证"',
              },
              'changes': {
                'type': 'string',
                'description': '变更：实际修改了什么；没有修改写"无"',
              },
              'suggestion': {
                'type': 'string',
                'description': '建议：下一步可选项；没有写"无"',
              },
            },
            'required': ['answer'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'ask',
          'description': '需要用户做选择或补充信息时调用。'
              '涉及危险操作确认、多个可行方案取舍、缺少必要信息时必须先问，不要擅自决定。'
              'options 必须提供 2-4 个简洁明确的按钮选项；'
              '开放式问题也要给出可能的回答方向作为选项。',
          'parameters': {
            'type': 'object',
            'properties': {
              'question': {
                'type': 'string',
                'description': '向用户提出的问题',
              },
              'options': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '供用户选择的选项列表（用户可见的按钮文字，避免术语）',
              },
            },
            'required': ['question', 'options'],
          },
        },
      },
    ];
    for (final tool in visibleFor(isLocalSession: isLocalSession)) {
      final schema = tool.toJsonSchema();
      if (schema == null) continue;
      result.add({
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': schema,
        },
      });
    }
    return result;
  }
}
