import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'command_executor.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'file_sync_service.dart';
import 'multi_host_executor.dart';
import 'agent_host_registry.dart';
import '../core/l10n_holder.dart';
import '../utils/tool_args_parser.dart';

/// Agent 工具调用结果
class ToolResult {
  final bool success;
  final String output;
  final String? error;

  const ToolResult({
    required this.success,
    required this.output,
    this.error,
  });

  factory ToolResult.success(String output) =>
      ToolResult(success: true, output: output, error: null);

  factory ToolResult.failure(String error, {String? output}) =>
      ToolResult(success: false, output: output ?? '', error: error);
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

  /// P2-6: 返回 OpenAI tools API 格式的 JSON schema。
  /// 默认实现基于 paramSpec 生成一个宽松的 schema（type=object + 任意属性）。
  /// 子类可重写以提供精确的参数类型。
  /// 返回 null 表示该工具不参与 FC（仅文本协议可用）。
  Map<String, dynamic>? toJsonSchema() {
    // 默认实现：宽松 schema，让 AI 自由填参数，由 execute 内部校验
    return {
      'type': 'object',
      'properties': {
        'args': {
          'type': 'object',
          'description': paramSpec,
          'additionalProperties': true,
        },
      },
      'additionalProperties': true,
    };
  }

  /// 执行工具
  /// [executor] 当前命令执行器（可能是 SSHService 或本地终端）
  /// [args] AI 传入的参数（已解析的 Map）
  /// [onProgress] 进度回调（可选）
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
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
class SftpUploadTool extends AgentTool {
  @override
  String get name => 'sftp_upload';

  @override
  String get description => '上传本地文件或目录到 SSH 远程服务器。用于部署项目、传输文件等场景。仅适用于已连接 SSH 远程会话。'
      '目录上传语义：把 local 目录放到 remote 目录下，自动在 remote 内创建 basename(local) 子目录。'
      '例如 local=/path/story、remote=/tmp → 实际传到 /tmp/story；若 remote 已含同名末段（如 /tmp/story）则不重复追加。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  local: 本地路径（必填）\n  remote: 远程目标父目录（必填，目录上传时自动在其下创建 basename 子目录）\n  recursive: 是否递归上传目录（true/false，默认 false）\n  exclude: 排除项（可选，逗号分隔，如 node_modules,.git）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    // 参数校验
    final local = ToolArgsParser.getString(args, 'local');
    final remote = ToolArgsParser.getString(args, 'remote');
    final recursive = ToolArgsParser.getBool(args, 'recursive');
    final excludeArg = ToolArgsParser.getStringList(args, 'exclude');

    if (local.isEmpty || remote.isEmpty) {
      return ToolResult.failure('参数缺失: local 和 remote 为必填项');
    }

    // 仅支持 SSH 远程会话
    if (executor is! SSHService) {
      return ToolResult.failure('sftp_upload 仅支持 SSH 远程会话，当前为本地终端');
    }

    // 校验本地路径存在
    bool isDir;
    final dir = Directory(local);
    final file = File(local);
    if (await dir.exists()) {
      isDir = true;
    } else if (await file.exists()) {
      isDir = false;
    } else {
      return ToolResult.failure(L10n.str.orchToolLocalNotFound(local));
    }

    // 如果是目录但没指定 recursive，提示
    if (isDir && !recursive) {
      return ToolResult.failure(
        '本地路径是目录，请设置 recursive=true 以递归上传',
        output: '提示: 如需上传单文件，请指定文件路径而非目录路径',
      );
    }

    // 解析排除列表
    List<String> excludeNames = excludeArg.isEmpty
        ? ['node_modules', '.git', '.DS_Store']
        : excludeArg;

    onProgress?.call('正在打开 SFTP 子系统...');
    debugPrint('[SftpUploadTool] 开始上传: local=$local, remote=$remote, recursive=$recursive');

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
        // 单文件上传
        onProgress?.call('正在上传文件: ${p.basename(local)}');
        // R6: 远程路径用 posix
        final remoteParent = p.posix.dirname(remote);
        if (remoteParent.isNotEmpty && remoteParent != '.') {
          await sftp.createDirectory(remoteParent);
        }
        await sftp.uploadFile(local, remote);
        final size = await file.length();
        onProgress?.call('上传完成');
        return ToolResult.success(
          '文件上传成功: $local → $remote (${_formatSize(size)})',
        );
      } else {
        // 目录递归上传
        // 语义：把 local 目录传到 remote 下，期望 remote/basename(local) 存在
        // 如果 remote 路径不以 basename(local) 结尾，自动追加，避免目录内容被平铺到 remote 根下
        final baseName = p.basename(local);
        String effectiveRemote = remote;
        if (p.posix.basename(remote) != baseName) {
          effectiveRemote = p.posix.join(remote, baseName);
        }
        onProgress?.call('正在递归上传目录: $local → $effectiveRemote');
        final result = await sftp.uploadDirectory(
          local,
          effectiveRemote,
          excludeNames: excludeNames,
          onProgress: (uploaded, total) {
            onProgress?.call('上传进度: $uploaded/$total 文件');
          },
        );
        if (result.allSuccess) {
          return ToolResult.success(
            '${result.summary}\n目标路径: $effectiveRemote',
          );
        } else {
          return ToolResult(
            success: false,
            output: '${result.summary}\n目标路径: $effectiveRemote',
            error: '${result.failedFiles.length} 个文件上传失败',
          );
        }
      }
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
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
  String get description => '启动或停止本地目录与远程服务器目录的自动同步。本地文件修改自动上传到远程；bidirectional 模式下还会轮询远程变化下载到本地。'
      '注意：localDir 和 remoteDir 是一一对应的完整路径，remoteDir 应包含目标子目录名（如 localDir=/path/story、remoteDir=/tmp/story），'
      '否则 story 内的文件会被平铺到 remoteDir 根下。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  action: start|stop|status（必填）\n  localDir: 本地目录完整路径（start 必填）\n  remoteDir: 远程目录完整路径（start 必填，应含目标子目录名，如 /tmp/story 而非 /tmp）\n  direction: localToRemote|bidirectional（默认 localToRemote）\n  exclude: 排除项（可选，逗号分隔）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final action = ToolArgsParser.getString(args, 'action');

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
      onProgress?.call('已停止文件同步');
      return ToolResult.success('文件同步已停止');
    }

    if (action == 'start') {
      final localDir = ToolArgsParser.getString(args, 'localDir');
      final remoteDir = ToolArgsParser.getString(args, 'remoteDir');
      final directionStr = ToolArgsParser.getString(args, 'direction', defaultValue: 'localToRemote');
      final excludeArg = ToolArgsParser.getStringList(args, 'exclude');

      if (localDir.isEmpty || remoteDir.isEmpty) {
        return ToolResult.failure('start 需要 localDir 和 remoteDir 参数');
      }

      if (executor is! SSHService) {
        return ToolResult.failure('file_sync 仅支持 SSH 远程会话');
      }

      final sshService = executor;
      if (sshService.client == null) {
        return ToolResult.failure('SSH 连接未建立');
      }

      final direction = directionStr == 'bidirectional'
          ? SyncDirection.bidirectional
          : SyncDirection.localToRemote;

      List<String> excludeNames = excludeArg.isEmpty
          ? ['node_modules', '.git', '.DS_Store']
          : excludeArg;

      final config = SyncConfig(
        localDir: localDir,
        remoteDir: remoteDir,
        direction: direction,
        excludeNames: excludeNames,
      );

      onProgress?.call('正在启动文件同步...');
      // 传 getter 而非 client 引用：SSHService 重连后 getter 返回新 client
      final ok = await _service.start(
        clientGetter: () => sshService.client,
        config: config,
      );
      if (ok) {
        return ToolResult.success(
          '文件同步已启动: $localDir ↔ $remoteDir (方向: ${direction.name})\n'
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
  String get description => '【多机编排】在指定主机上执行命令。用于跨主机调度操作。'
      '仅在编排模式下可用；非编排模式请用普通 execute。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostId: 目标主机 ID（必填）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = ToolArgsParser.getString(args, 'hostId');
    final command = ToolArgsParser.getString(args, 'command');
    final timeoutSec = ToolArgsParser.getInt(args, 'timeout', defaultValue: 60);

    if (hostId.isEmpty || command.isEmpty) {
      return ToolResult.failure(L10n.str.orchToolParamMissing('hostId 和 command'));
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
            ? (err.isNotEmpty ? 'stdout: $output\nstderr: $err' : 'output: $output')
            : (err.isNotEmpty ? 'stderr: $err' : L10n.str.orchToolNoOutput));
    // 失败原因（人类可读诊断，指导 AI 修正命令而非盲目重试）
    final reasonLine = (result.failureReason != null && result.failureReason!.isNotEmpty)
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
  String get description => '【多机编排】批量执行同一命令到多台主机（只读命令并行执行，修改性命令串行执行）。'
      '适用于时间同步、日志清理、配置检查等批量运维场景。'
      '一台失败不影响其他主机（除非 stopOnFailure=true）。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔，如 web1,web2,db1）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）\n  stopOnFailure: 某台失败是否停止后续（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final command = ToolArgsParser.getString(args, 'command');
    final timeoutSec = ToolArgsParser.getInt(args, 'timeout', defaultValue: 60);
    final stopOnFailure = ToolArgsParser.getBool(args, 'stopOnFailure');
    final hostIds = ToolArgsParser.getStringList(args, 'hostIds');

    if (hostIds.isEmpty || command.isEmpty) {
      return ToolResult.failure(L10n.str.orchToolParamMissing('hostIds 和 command'));
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
    if (allSuccess) {
      return ToolResult.success(summary);
    } else {
      final failedCount = results.values.where((r) => !r.success).length;
      return ToolResult(
        success: false,
        output: summary,
        error: L10n.str.orchToolBatchFailed(failedCount, hostIds.length),
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
  String get description => '【多机编排】从一台主机测试到目标主机的端口连通性。'
      '用于部署前验证网络依赖（如 web→db:3306、web→redis:6379）。'
      '源主机必须是已连接的编排参与者。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  fromHostId: 源主机 ID（必填，命令从这台机执行）\n  targetHost: 目标主机 IP 或域名（必填）\n  port: 目标端口（必填）\n  timeout: 超时秒数（可选，默认 5）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final fromHostId = ToolArgsParser.getString(args, 'fromHostId');
    final targetHost = ToolArgsParser.getString(args, 'targetHost');
    final port = ToolArgsParser.getInt(args, 'port');
    final timeoutSec = ToolArgsParser.getInt(args, 'timeout', defaultValue: 5);

    if (fromHostId.isEmpty || targetHost.isEmpty || port <= 0) {
      return ToolResult.failure(L10n.str.orchToolConnParamMissing);
    }

    onProgress?.call(L10n.str.orchToolConnProgress(fromHostId, targetHost, port.toString()));
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
  String get description => '【多机编排】上传本地文件或目录到指定主机的远程目录。'
      '用于跨机部署（如把构建产物传到不同服务器）。'
      '目录上传语义同 sftp_upload：把 local 目录放到 remote 下，自动创建 basename(local) 子目录。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostId: 目标主机 ID（必填）\n  local: 本地文件/目录绝对路径（必填）\n  remote: 远程目标父目录（必填，目录上传时自动在其下创建 basename 子目录）\n  recursive: 是否递归上传目录（true/false，默认 false）\n  exclude: 排除项（可选，逗号分隔，如 node_modules,.git）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = ToolArgsParser.getString(args, 'hostId');
    final local = ToolArgsParser.getString(args, 'local');
    final remote = ToolArgsParser.getString(args, 'remote');
    final recursive = ToolArgsParser.getBool(args, 'recursive');
    final excludeArg = ToolArgsParser.getStringList(args, 'exclude');

    if (hostId.isEmpty || local.isEmpty || remote.isEmpty) {
      return ToolResult.failure(L10n.str.orchToolUploadParamMissing);
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

    // 校验本地路径
    bool isDir;
    final dir = Directory(local);
    final file = File(local);
    if (await dir.exists()) {
      isDir = true;
    } else if (await file.exists()) {
      isDir = false;
    } else {
      return ToolResult.failure(L10n.str.orchToolLocalNotFound(local));
    }
    if (isDir && !recursive) {
      return ToolResult.failure(L10n.str.orchToolLocalIsDir);
    }

    List<String> excludeNames = excludeArg.isEmpty
        ? ['node_modules', '.git', '.DS_Store']
        : excludeArg;

    onProgress?.call(L10n.str.orchToolSftpOpening(hostId));
    final sftp = SftpService();
    try {
      await sftp.attachToClient(client);
    } catch (e) {
      return ToolResult.failure('[$hostId] SFTP 连接失败: $e');
    }

    try {
      if (!isDir) {
        onProgress?.call('[$hostId] 正在上传文件: ${p.basename(local)}');
        final remoteParent = p.posix.dirname(remote);
        if (remoteParent.isNotEmpty && remoteParent != '.') {
          await sftp.createDirectory(remoteParent);
        }
        await sftp.uploadFile(local, remote);
        final size = await file.length();
        onProgress?.call('[$hostId] 上传完成');
        return ToolResult.success(
          '[$hostId] 文件上传成功: $local → $remote (${_formatSize(size)})',
        );
      } else {
        final baseName = p.basename(local);
        String effectiveRemote = remote;
        if (p.posix.basename(remote) != baseName) {
          effectiveRemote = p.posix.join(remote, baseName);
        }
        onProgress?.call('[$hostId] 正在递归上传目录: $local → $effectiveRemote');
        final result = await sftp.uploadDirectory(
          local,
          effectiveRemote,
          excludeNames: excludeNames,
          onProgress: (uploaded, total) {
            onProgress?.call('[$hostId] 上传进度: $uploaded/$total 文件');
          },
        );
        if (result.allSuccess) {
          return ToolResult.success(
            '[$hostId] ${result.summary}\n目标路径: $effectiveRemote',
          );
        } else {
          return ToolResult(
            success: false,
            output: '[$hostId] ${result.summary}\n目标路径: $effectiveRemote',
            error: '${result.failedFiles.length} 个文件上传失败',
          );
        }
      }
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
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
  String get description => '【多机编排】把本地文件/目录广播分发到多台主机的相同远程目录。'
      '用于批量部署（如把配置文件/构建产物同步到一组服务器）。'
      '执行是串行的，每台主机的结果单独报告。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔，如 web1,web2）\n  local: 本地文件/目录绝对路径（必填）\n  remote: 远程目标父目录（必填）\n  recursive: 是否递归（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = ToolArgsParser.getStringList(args, 'hostIds');
    final local = ToolArgsParser.getString(args, 'local');
    final remote = ToolArgsParser.getString(args, 'remote');
    final recursive = ToolArgsParser.getBool(args, 'recursive');

    if (local.isEmpty || remote.isEmpty) {
      return ToolResult.failure('参数缺失: local、remote 为必填项');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项（数组或逗号分隔）');
    }

    // 复用 UploadToTool 的逻辑：逐台上传
    final uploadTool = UploadToTool(_executor);
    final results = <String>[];
    int successCount = 0;
    for (final hid in hostIds) {
      onProgress?.call('[$hid] 正在分发...');
      final r = await uploadTool.execute(
        executor: executor,
        args: {
          'hostId': hid,
          'local': local,
          'remote': remote,
          'recursive': recursive,
        },
        onProgress: onProgress,
      );
      if (r.success) {
        successCount++;
        results.add('[$hid] ✓ ${r.output}');
      } else {
        results.add('[$hid] ✗ ${r.error ?? r.output}');
      }
    }

    final summary = '广播分发完成: $successCount/${hostIds.length} 成功\n${results.join('\n')}';
    return successCount == hostIds.length
        ? ToolResult.success(summary)
        : ToolResult(success: successCount > 0, output: summary, error: '${hostIds.length - successCount} 台失败');
  }
}

/// 多机编排：文件采集 — 从多台主机下载同名文件到本地（带 hostId 后缀）
class CollectFileTool extends AgentTool {
  final MultiHostExecutor _executor;
  CollectFileTool(this._executor);

  @override
  String get name => 'collect_file';

  @override
  String get description => '【多机编排】从多台主机采集同名远程文件到本地目录，每个文件自动加 hostId 后缀。'
      '用于配置对比、日志收集等场景。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔）\n  remote: 远程文件绝对路径（必填）\n  localDir: 本地保存目录（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = ToolArgsParser.getStringList(args, 'hostIds');
    final remote = ToolArgsParser.getString(args, 'remote');
    final localDir = ToolArgsParser.getString(args, 'localDir');

    if (remote.isEmpty || localDir.isEmpty) {
      return ToolResult.failure('参数缺失: remote、localDir 为必填项');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项');
    }

    // 确保本地目录存在
    final dir = Directory(localDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final remoteBasename = p.posix.basename(remote);
    final sftp = SftpService();
    final results = <String>[];
    int successCount = 0;

    for (final hid in hostIds) {
      if (_executor.isCancelled) {
        results.add('[$hid] ✗ 已取消，跳过');
        continue;
      }
      onProgress?.call('[$hid] 正在采集 $remote ...');
      final targetExecutor = _executor.executorFor(hid);
      if (targetExecutor == null || targetExecutor is! SSHService) {
        results.add('[$hid] ✗ 主机未连接或非 SSH 会话');
        continue;
      }
      final client = targetExecutor.client;
      if (client == null) {
        results.add('[$hid] ✗ SSH 连接未建立');
        continue;
      }
      try {
        await sftp.attachToClient(client);
        final localPath = p.join(localDir, '${hid}_$remoteBasename');
        await sftp.downloadFile(remote, localPath);
        successCount++;
        results.add('[$hid] ✓ 已保存到 $localPath');
      } catch (e) {
        results.add('[$hid] ✗ 采集失败: $e');
      } finally {
        sftp.closeSftpOnly();
      }
    }

    final summary = '采集完成: $successCount/${hostIds.length} 成功\n${results.join('\n')}';
    return successCount == hostIds.length
        ? ToolResult.success(summary)
        : ToolResult(success: successCount > 0, output: summary, error: '${hostIds.length - successCount} 台失败');
  }
}

/// 多机编排：日志聚合搜索 — 在多台主机上同时 grep 关键词，按主机分段返回
class MultiGrepTool extends AgentTool {
  final MultiHostExecutor _executor;
  MultiGrepTool(this._executor);

  @override
  String get name => 'multi_grep';

  @override
  String get description => '【多机编排】在多台主机上同时 grep 搜索日志/文件，结果按主机分段聚合。'
      '用于跨机排障（如"在所有 web 机器 grep ERROR access.log 最近 100 行"）。'
      '注意：命令在远程执行，grep 语法须兼容目标 shell。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔）\n  pattern: 搜索关键词（必填，正则）\n  files: 要搜索的文件路径（必填，多个用逗号分隔）\n  tail: 仅搜索文件末尾 N 行（可选，如 1000）\n  ignoreCase: 是否忽略大小写（true/false，默认 false）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = ToolArgsParser.getStringList(args, 'hostIds');
    final pattern = ToolArgsParser.getString(args, 'pattern');
    final files = ToolArgsParser.getString(args, 'files');
    final tail = ToolArgsParser.getString(args, 'tail');
    final ignoreCase = ToolArgsParser.getBool(args, 'ignoreCase');

    if (pattern.isEmpty || files.isEmpty) {
      return ToolResult.failure('参数缺失: pattern、files 为必填项');
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项');
    }

    // 构造 grep 命令：支持 tail + ignoreCase
    final safePattern = pattern.replaceAll("'", "'\\''");
    final grepFlags = ignoreCase ? '-iE' : '-E';
    final fileList = files.split(',').map((f) => f.trim()).where((f) => f.isNotEmpty).join(' ');
    String cmd;
    if (tail.isNotEmpty) {
      final n = int.tryParse(tail) ?? 1000;
      cmd = "tail -n $n $fileList | grep $grepFlags '$safePattern'";
    } else {
      cmd = "grep $grepFlags '$safePattern' $fileList";
    }

    final results = <String>[];
    int hitCount = 0;
    for (final hid in hostIds) {
      if (_executor.isCancelled) {
        results.add('=== [$hid] 已取消，跳过 ===');
        continue;
      }
      onProgress?.call('[$hid] 正在搜索...');
      final r = await _executor.executeOn(hid, cmd, timeout: const Duration(seconds: 30));
      if (r == null) {
        results.add('=== [$hid] 主机未连接 ===');
        continue;
      }
      final out = r.stdout.trim();
      if (out.isEmpty) {
        results.add('=== [$hid] 无匹配 ===');
      } else {
        hitCount++;
        final truncated = out.length > 2000 ? '${out.substring(0, 2000)}\n...(已截断)' : out;
        results.add('=== [$hid] 命中 ${out.split('\n').length} 行 ===\n$truncated');
      }
    }

    final summary = '多机搜索完成: $hitCount/${hostIds.length} 台命中\n\n${results.join('\n\n')}';
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
  String get description => '【多机编排】对比多台主机上同名远程文件的内容差异。'
      '用于检查配置是否一致（如对比所有 nginx.conf）。'
      '返回每台主机文件的 md5 和两两 diff 摘要。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，至少 2 台，逗号分隔）\n  remote: 远程文件绝对路径（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIds = ToolArgsParser.getStringList(args, 'hostIds');
    final remote = ToolArgsParser.getString(args, 'remote');

    if (remote.isEmpty) {
      return ToolResult.failure('参数缺失: remote 为必填项');
    }
    if (hostIds.length < 2) {
      return ToolResult.failure('diff 至少需要 2 台主机');
    }

    // 采集每台主机的 md5 和内容
    final md5Results = <String, String>{};
    final contentResults = <String, String>{};
    for (final hid in hostIds) {
      if (_executor.isCancelled) {
        md5Results[hid] = '已取消';
        contentResults[hid] = '';
        continue;
      }
      onProgress?.call('[$hid] 正在读取 $remote ...');
      final r = await _executor.executeOn(
        hid,
        "md5sum '$remote' 2>/dev/null; echo '---CONTENT---'; cat '$remote' 2>/dev/null | head -200",
        timeout: const Duration(seconds: 15),
      );
      if (r == null) {
        md5Results[hid] = '未连接';
        contentResults[hid] = '';
        continue;
      }
      final out = r.stdout;
      final md5Match = RegExp(r'^([a-f0-9]{32})').firstMatch(out);
      md5Results[hid] = md5Match?.group(1) ?? '读取失败';
      final contentStart = out.indexOf('---CONTENT---');
      contentResults[hid] = contentStart >= 0 ? out.substring(contentStart + 13).trim() : '';
    }

    // 构建 md5 对比表
    final buffer = StringBuffer();
    buffer.writeln('文件: $remote');
    buffer.writeln('MD5 对比:');
    for (final hid in hostIds) {
      buffer.writeln('  [$hid] ${md5Results[hid]}');
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
  String get description => '检查 HTTPS/SSL 证书到期时间或 SSH host key 指纹。'
      '用于证书到期监控、安全审计。返回证书有效期剩余天数、到期日期、颁发者等。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n  mode: remote|local_file|ssh_hostkey（必填）\n  host: 远程 HTTPS 主机名或 IP（mode=remote 时必填）\n  port: HTTPS 端口（默认 443）\n  certPath: 本地证书文件路径（mode=local_file 时必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final mode = ToolArgsParser.getString(args, 'mode');
    if (mode.isEmpty) {
      return ToolResult.failure('参数缺失: mode 必填（remote/local_file/ssh_hostkey）');
    }

    if (mode == 'remote') {
      final host = ToolArgsParser.getString(args, 'host');
      final port = ToolArgsParser.getInt(args, 'port', defaultValue: 443);
      if (host.isEmpty) {
        return ToolResult.failure('mode=remote 需要 host 参数');
      }
      // R7: 校验 host 格式（防 shell 注入）
      if (!RegExp(r'^[a-zA-Z0-9.\-]+$').hasMatch(host)) {
        return ToolResult.failure('host 格式非法（仅允许字母、数字、点、连字符）');
      }
      if (port < 1 || port > 65535) {
        return ToolResult.failure('port 范围非法（1-65535）');
      }

      onProgress?.call('正在检查 $host:$port 的 HTTPS 证书...');
      // 通过 executor 在已连接主机上执行 openssl 命令
      // 用 -servername 启用 SNI；用 2>/dev/null 屏蔽 s_client 的握手交互输出
      final cmd = "echo | openssl s_client -connect $host:$port -servername $host 2>/dev/null "
          "| openssl x509 -noout -dates -issuer -subject 2>/dev/null";
      try {
        final result = await executor.executeAndWait(cmd, timeout: const Duration(seconds: 15));
        if (!result.success) {
          return ToolResult.failure('openssl 执行失败: ${result.stderr}', output: result.stdout);
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
      final certPath = ToolArgsParser.getString(args, 'certPath');
      if (certPath.isEmpty) {
        return ToolResult.failure('mode=local_file 需要 certPath 参数');
      }
      // R7: 校验路径不含 shell 元字符（防注入；单引号防护可被单引号突破）
      if (RegExp(r"[';`$\\|&><\n\r]").hasMatch(certPath)) {
        return ToolResult.failure('certPath 含非法字符（禁止引号/分号/管道/反引号等）');
      }
      onProgress?.call('正在解析本地证书: $certPath');
      final cmd = "openssl x509 -in '$certPath' -noout -dates -issuer -subject 2>&1";
      try {
        final result = await executor.executeAndWait(cmd, timeout: const Duration(seconds: 10));
        if (!result.success) {
          return ToolResult.failure('openssl 执行失败: ${result.stderr}', output: result.stdout);
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
      onProgress?.call('正在读取 SSH host key 指纹...');
      // 列出 /etc/ssh/ 下所有 host key 的指纹
      const cmd = "for f in /etc/ssh/ssh_host_*_key.pub; do "
          "ssh-keygen -lf \"\$f\" 2>/dev/null; "
          "done";
      try {
        final result = await executor.executeAndWait(cmd, timeout: const Duration(seconds: 10));
        if (!result.success) {
          return ToolResult.failure('ssh-keygen 执行失败: ${result.stderr}', output: result.stdout);
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

    return ToolResult.failure('未知 mode: $mode（支持 remote/local_file/ssh_hostkey）');
  }

  /// 解析 openssl x509 -dates -issuer -subject 输出
  String _parseCertOutput(String output, String target, int? port) {
    String? notBefore;
    String? notAfter;
    String? issuer;
    String? subject;

    for (final line in output.split('\n')) {
      final l = line.trim();
      if (l.startsWith('notBefore=')) notBefore = l.substring('notBefore='.length);
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
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
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
  String get description => '直接写入远程文件内容（绕过 shell，避免转义/换行/EOF 问题）。'
      '推荐用于：新建配置文件、整体重写文件、写入含特殊字符的脚本。'
      '大文件需分块：第一次 mode=write，后续 mode=append 追加。'
      '覆盖已存在文件时自动备份到 .bak.{timestamp}，失败自动回滚。'
      'append 模式要求文件已存在。仅适用于 SSH 远程会话。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 远程文件绝对路径（必填，如 /etc/nginx/conf.d/default.conf）\n'
      '  content_b64: 文件内容的 base64 编码（必填。AI 自己生成 base64，工具解码后写入。'
      '单次建议 < 8KB 原文；超限请分块：第一次 mode=write，后续 mode=append）\n'
      '  mode: write | append（可选，默认 write。append 用于分块写入场景追加到文件末尾）\n'
      '  backup: true | false（可选，默认 true。仅 mode=write 且文件已存在时生效，'
      '自动备份原文件到 {path}.bak.{timestamp}）';

  /// 单次写入大小上限（原文，未 base64）：8KB
  /// 超过此值的 content_b64 会被拒绝，强制 AI 分块写入
  static const int _maxChunkSize = 8 * 1024;

  /// 备份文件大小上限：10MB（更大的文件应该走 sftp_upload，不应整体重写）
  static const int _maxBackupSize = 10 * 1024 * 1024;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final path = ToolArgsParser.getString(args, 'path');
    final contentB64 = ToolArgsParser.getString(args, 'content_b64');
    final mode = ToolArgsParser.getString(args, 'mode', defaultValue: 'write');
    final backup = ToolArgsParser.getBool(args, 'backup', defaultValue: true);

    if (path.isEmpty) {
      return ToolResult.failure('参数缺失: path 为必填项');
    }
    if (contentB64.isEmpty) {
      return ToolResult.failure('参数缺失: content_b64 为必填项');
    }
    if (mode != 'write' && mode != 'append') {
      return ToolResult.failure('参数错误: mode 只能是 write 或 append，实际值为 "$mode"');
    }

    // base64 解码
    final Uint8List contentBytes;
    try {
      contentBytes = base64Decode(contentB64);
    } catch (e) {
      return ToolResult.failure('content_b64 base64 解码失败: $e');
    }

    // 大小限制：避免 AI 一次输出过大 base64 出错
    if (contentBytes.length > _maxChunkSize) {
      return ToolResult.failure(
        '单次写入内容过大 (${contentBytes.length} 字节 > $_maxChunkSize 字节)。'
        '请分块写入：第一次 mode=write 写入前 8KB，后续 mode=append 追加剩余内容。'
        '提示：每次调用前在本地把内容切成 < 8KB 的块，分别 base64 编码后调用本工具。',
      );
    }

    onProgress?.call('正在${mode == 'write' ? '写入' : '追加'} $path (${contentBytes.length} 字节)...');

    // SSH 远程会话：用 SFTP 直接写入
    if (executor is SSHService) {
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
        // 创建父目录（如 /etc/nginx/conf.d/ 不存在）
        final parentDir = p.posix.dirname(path);
        if (parentDir.isNotEmpty && parentDir != '/' && parentDir != '.') {
          await sftp.createDirectory(parentDir);
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
                '原文件过大 ($fileSize 字节 > $_maxBackupSize 字节)，无法自动备份。'
                '请先手动备份（如 cp $path $path.manual.bak），再用 backup: false 调用本工具。',
              );
            }
            backupPath = '$path.bak.${DateTime.now().millisecondsSinceEpoch}';
            onProgress?.call('正在备份原文件到 $backupPath ...');
            try {
              await sftp.copyFile(path, backupPath!);
            } catch (e) {
              return ToolResult.failure('备份原文件失败: $e。已中止写入，原文件未被修改。');
            }
          }
        }

        // 写入
        if (mode == 'write') {
          await sftp.writeFileBytes(path, contentBytes);
        } else {
          await sftp.appendFileBytes(path, contentBytes);
        }

        onProgress?.call('写入完成');
        final msg = StringBuffer()
          ..writeln('文件${mode == 'write' ? '写入' : '追加'}成功: $path (${contentBytes.length} 字节)');
        if (backupPath != null) {
          msg.writeln('  原文件已备份: $backupPath');
          msg.writeln('  如需回滚: mv $backupPath $path');
        }
        return ToolResult.success(msg.toString().trimRight());
      } catch (e) {
        // H3 失败回滚：恢复备份
        if (backupPath != null) {
          onProgress?.call('写入失败，正在回滚 ...');
          try {
            await sftp.copyFile(backupPath!, path);
            return ToolResult.failure(
              'SFTP 写入失败: $e\n已自动回滚：原文件已从备份 $backupPath 恢复。',
            );
          } catch (rollbackErr) {
            return ToolResult.failure(
              'SFTP 写入失败: $e\n回滚也失败: $rollbackErr。'
              '原文件可能已损坏，请手动从备份 $backupPath 恢复：mv $backupPath $path',
            );
          }
        }
        return ToolResult.failure('SFTP 写入失败: $e');
      } finally {
        sftp.closeSftpOnly();
      }
    }

    return ToolResult.failure('file_write 仅支持 SSH 远程会话，当前为本地终端');
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
  String get description => '通过字符串替换修改远程文件（绕过 shell，避免 sed 转义问题）。'
      '推荐用于：改一两行配置、替换变量值、修改 server_name 等小改动。'
      'old 必须在文件中唯一出现，否则报错让 AI 提供更长上下文。'
      'old 和 new 用 base64 编码传递，支持多行内容。'
      '原子性保护：若读取后文件被外部修改，拒绝写入。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 远程文件绝对路径（必填）\n'
      '  old_b64: 要替换的原文的 base64 编码（必填。必须在文件中唯一出现，否则报错）\n'
      '  new_b64: 新内容的 base64 编码（必填。可为空字符串表示删除 old）\n'
      '  backup: true | false（可选，默认 true。自动备份原文件到 {path}.bak.{timestamp}，'
      '失败时自动回滚）';

  /// 文件大小上限：1MB（patch 仅适用于小配置文件，大文件请用 file_write 整体重写）
  static const int _maxFileSize = 1024 * 1024;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final path = ToolArgsParser.getString(args, 'path');
    final oldB64 = ToolArgsParser.getString(args, 'old_b64');
    final newB64 = ToolArgsParser.getString(args, 'new_b64');
    final backup = ToolArgsParser.getBool(args, 'backup', defaultValue: true);

    if (path.isEmpty) {
      return ToolResult.failure('参数缺失: path 为必填项');
    }
    if (oldB64.isEmpty) {
      return ToolResult.failure('参数缺失: old_b64 为必填项');
    }
    // new_b64 允许为空（表示删除 old）

    // base64 解码
    String oldStr;
    String newStr;
    try {
      oldStr = utf8.decode(base64Decode(oldB64));
    } catch (e) {
      return ToolResult.failure('old_b64 base64 解码失败: $e');
    }
    try {
      // new_b64 可空 → 解码为空字符串
      newStr = newB64.isEmpty ? '' : utf8.decode(base64Decode(newB64));
    } catch (e) {
      return ToolResult.failure('new_b64 base64 解码失败: $e');
    }

    onProgress?.call('正在读取 $path ...');

    // SSH 远程会话
    if (executor is SSHService) {
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
        final beforeMtime = beforeStat.modifyTime ?? 0;

        // 读取原文件
        final bytes = await sftp.readFileBytes(path, maxSize: _maxFileSize + 1);
        if (bytes.length > _maxFileSize) {
          return ToolResult.failure(
            '文件过大 (${bytes.length} 字节 > $_maxFileSize 字节)。'
            'patch 仅适用于 < 1MB 的配置文件，大文件请用 file_write 整体重写。',
          );
        }
        final content = utf8.decode(bytes, allowMalformed: true);

        // 唯一性校验：统计 old 出现次数
        final occurrences = _countOccurrences(content, oldStr);
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
            output: 'old 内容预览: ${oldStr.length > 100 ? '${oldStr.substring(0, 100)}...' : oldStr}',
          );
        }

        // 替换
        final newContent = content.replaceFirst(oldStr, newStr);

        // H1 原子性：write 前再 stat 一次，若 size/mtime 变化则拒绝写入
        final afterStat = await sftp.statFile(path);
        if (afterStat != null) {
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
        }

        // 自动备份
        if (backup) {
          backupPath = '$path.bak.${DateTime.now().millisecondsSinceEpoch}';
          onProgress?.call('正在备份原文件到 $backupPath ...');
          try {
            await sftp.copyFile(path, backupPath!);
          } catch (e) {
            return ToolResult.failure('备份原文件失败: $e。已中止写入，原文件未被修改。');
          }
        }

        // 写回
        await sftp.writeFileBytes(path, Uint8List.fromList(utf8.encode(newContent)));

        onProgress?.call('替换完成');
        final msg = StringBuffer()
          ..writeln('文件已修改: $path')
          ..writeln('  替换: ${oldStr.length} 字节 → ${newStr.length} 字节')
          ..writeln('  文件大小: ${bytes.length} → ${newContent.length} 字节');
        if (backupPath != null) {
          msg.writeln('  原文件已备份: $backupPath');
          msg.writeln('  如需回滚: mv $backupPath $path');
        }
        return ToolResult.success(msg.toString().trimRight());
      } catch (e) {
        // 失败回滚：恢复备份
        if (backupPath != null) {
          onProgress?.call('写入失败，正在回滚 ...');
          try {
            await sftp.copyFile(backupPath!, path);
            return ToolResult.failure(
              'file_patch 写入失败: $e\n已自动回滚：原文件已从备份 $backupPath 恢复。',
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

    return ToolResult.failure('file_patch 仅支持 SSH 远程会话，当前为本地终端');
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

/// Agent 工具注册表 — 管理所有可用的工具
class AgentToolRegistry {
  final Map<String, AgentTool> _tools = {};
  /// 文件同步服务实例（由 registry 持有，工具共享）
  final FileSyncService fileSyncService = FileSyncService();
  /// 多机执行器实例（编排模式用）
  MultiHostExecutor? _multiHostExecutor;

  AgentToolRegistry() {
    // 注册默认工具
    register(SftpUploadTool());
    register(FileSyncTool(fileSyncService));
    register(CertMonitorTool());
    // 文件编辑工具：默认模式即可用，不依赖编排模式
    // 注册在默认层，保证任何 SSH 会话都能直接编辑文件
    register(FileWriteTool());
    register(FilePatchTool());
  }

  /// 启用编排模式：注册多机编排工具
  /// [registry] 来自 AgentNotifier，可访问所有 host 的 executor
  void enableOrchestrator(AgentHostRegistry registry) {
    if (_multiHostExecutor != null) return; // 已启用
    _multiHostExecutor = MultiHostExecutor(registry);
    register(ExecOnTool(_multiHostExecutor!));
    register(ExecBatchTool(_multiHostExecutor!));
    register(CheckConnectivityTool(_multiHostExecutor!));
    register(UploadToTool(_multiHostExecutor!));
    register(BroadcastUploadTool(_multiHostExecutor!));
    register(CollectFileTool(_multiHostExecutor!));
    register(MultiGrepTool(_multiHostExecutor!));
    register(DiffFilesTool(_multiHostExecutor!));
  }

  /// 禁用编排模式：注销多机编排工具
  void disableOrchestrator() {
    _multiHostExecutor = null;
    _tools.remove('exec_on');
    _tools.remove('exec_batch');
    _tools.remove('check_connectivity');
    _tools.remove('upload_to');
    _tools.remove('broadcast_upload');
    _tools.remove('collect_file');
    _tools.remove('multi_grep');
    _tools.remove('diff_files');
  }

  bool get isOrchestratorEnabled => _multiHostExecutor != null;

  MultiHostExecutor? get multiHostExecutor => _multiHostExecutor;

  void register(AgentTool tool) {
    _tools[tool.name] = tool;
  }

  AgentTool? get(String name) => _tools[name];

  bool has(String name) => _tools.containsKey(name);

  List<AgentTool> get all => _tools.values.toList();

  /// 构建工具说明文本，注入 system prompt
  String buildToolsPrompt() {
    if (_tools.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('【可用工具】');
    buffer.writeln('当需要执行非 shell 命令的操作时（如上传文件、跨机执行），使用 "动作: tool" 调用工具。');
    buffer.writeln();
    for (final tool in _tools.values) {
      buffer.writeln('工具: ${tool.name}');
      buffer.writeln('  说明: ${tool.description}');
      buffer.writeln('  $tool.paramSpec');
      buffer.writeln();
    }
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
  List<Map<String, dynamic>> buildOpenAIToolsSchema() {
    final result = <Map<String, dynamic>>[];
    for (final tool in _tools.values) {
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
