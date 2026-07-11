import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'command_executor.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'file_sync_service.dart';
import 'multi_host_executor.dart';
import 'agent_host_registry.dart';
import '../core/l10n_holder.dart';

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
/// AI 通过 "动作: tool" + "工具: xxx" + "参数: {json}" 协议调用。
/// 引擎拦截后路由到对应工具的 execute 方法。
abstract class AgentTool {
  /// 工具名（AI 调用时使用，如 sftp_upload）
  String get name;

  /// 工具描述（注入 system prompt，告诉 AI 何时用）
  String get description;

  /// 参数说明（注入 system prompt，告诉 AI 怎么填参数）
  /// 返回 JSON schema 描述字符串
  String get paramSpec;

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
  String get paramSpec => '''{"local":"本地路径(必填)","remote":"远程目标父目录(必填,目录上传时会自动在其下创建basename子目录)","recursive":"是否递归上传目录(true/false,默认false)","exclude":"排除项(可选,如node_modules,.git)"}''';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    // 参数校验
    final local = args['local']?.toString() ?? '';
    final remote = args['remote']?.toString() ?? '';
    final recursive = args['recursive'] == true || args['recursive'] == 'true';
    final excludeRaw = args['exclude'];

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
    List<String> excludeNames = ['node_modules', '.git', '.DS_Store'];
    if (excludeRaw != null) {
      if (excludeRaw is List) {
        excludeNames = excludeRaw.map((e) => e.toString()).toList();
      } else if (excludeRaw is String) {
        excludeNames = excludeRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    }

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
  String get paramSpec => '''{"action":"start|stop|status","localDir":"本地目录完整路径(start必填)","remoteDir":"远程目录完整路径(start必填,应含目标子目录名,如/tmp/story而非/tmp)","direction":"localToRemote|bidirectional(默认)","exclude":"排除项(可选)"}''';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final action = args['action']?.toString() ?? '';

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
      final localDir = args['localDir']?.toString() ?? '';
      final remoteDir = args['remoteDir']?.toString() ?? '';
      final directionStr = args['direction']?.toString() ?? 'localToRemote';
      final excludeRaw = args['exclude'];

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

      List<String> excludeNames = ['node_modules', '.git', '.DS_Store'];
      if (excludeRaw is List) {
        excludeNames = excludeRaw.map((e) => e.toString()).toList();
      } else if (excludeRaw is String) {
        excludeNames = excludeRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }

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
  String get paramSpec => '{"hostId":"目标主机ID(必填)","command":"要执行的命令(必填)","timeout":"超时秒数(可选,默认60)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = args['hostId']?.toString() ?? '';
    final command = args['command']?.toString() ?? '';
    final timeoutSec = int.tryParse(args['timeout']?.toString() ?? '') ?? 60;

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
    final summary = '[$hostId] $mark (exit=${result.exitCode})';
    final detail = result.success
        ? (output.isNotEmpty ? output : L10n.str.orchToolNoOutput)
        : 'stderr: $err';

    if (result.success) {
      return ToolResult.success('$summary\n$detail');
    } else {
      return ToolResult(
        success: false,
        output: '$summary\n$detail',
        error: '主机 $hostId 命令失败 (exit=${result.exitCode})',
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
  String get paramSpec => '{"hostIds":"主机ID列表(必填,逗号分隔,如web1,web2,db1)","command":"要执行的命令(必填)","timeout":"超时秒数(可选,默认60)","stopOnFailure":"某台失败是否停止后续(true/false,默认false)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIdsStr = args['hostIds']?.toString() ?? '';
    final command = args['command']?.toString() ?? '';
    final timeoutSec = int.tryParse(args['timeout']?.toString() ?? '') ?? 60;
    final stopOnFailure = args['stopOnFailure'] == true || args['stopOnFailure'] == 'true';

    if (hostIdsStr.isEmpty || command.isEmpty) {
      return ToolResult.failure(L10n.str.orchToolParamMissing('hostIds 和 command'));
    }

    final hostIds = hostIdsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (hostIds.isEmpty) {
      return ToolResult.failure(L10n.str.orchToolHostIdsEmpty);
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
  String get paramSpec => '{"fromHostId":"源主机ID(必填,命令从这台机执行)","targetHost":"目标主机IP或域名(必填)","port":"目标端口(必填)","timeout":"超时秒数(可选,默认5)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final fromHostId = args['fromHostId']?.toString() ?? '';
    final targetHost = args['targetHost']?.toString() ?? '';
    final port = int.tryParse(args['port']?.toString() ?? '') ?? 0;
    final timeoutSec = int.tryParse(args['timeout']?.toString() ?? '') ?? 5;

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
  String get paramSpec => '{"hostId":"目标主机ID(必填)","local":"本地文件/目录绝对路径(必填)","remote":"远程目标父目录(必填,目录上传时自动在其下创建basename子目录)","recursive":"是否递归上传目录(true/false,默认false)","exclude":"排除项(可选,如node_modules,.git)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostId = args['hostId']?.toString() ?? '';
    final local = args['local']?.toString() ?? '';
    final remote = args['remote']?.toString() ?? '';
    final recursive = args['recursive'] == true || args['recursive'] == 'true';
    final excludeRaw = args['exclude'];

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

    List<String> excludeNames = ['node_modules', '.git', '.DS_Store'];
    if (excludeRaw != null) {
      if (excludeRaw is List) {
        excludeNames = excludeRaw.map((e) => e.toString()).toList();
      } else if (excludeRaw is String) {
        excludeNames = excludeRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    }

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
  String get paramSpec => '{"hostIds":["hostId1","hostId2"],"local":"本地文件/目录绝对路径(必填)","remote":"远程目标父目录(必填)","recursive":"是否递归(true/false,默认false)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIdsRaw = args['hostIds'];
    final local = args['local']?.toString() ?? '';
    final remote = args['remote']?.toString() ?? '';
    final recursive = args['recursive'] == true || args['recursive'] == 'true';

    if (local.isEmpty || remote.isEmpty) {
      return ToolResult.failure('参数缺失: local、remote 为必填项');
    }
    List<String> hostIds = [];
    if (hostIdsRaw is List) {
      hostIds = hostIdsRaw.map((e) => e.toString()).toList();
    } else if (hostIdsRaw is String) {
      hostIds = hostIdsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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
  String get paramSpec => '{"hostIds":["hostId1","hostId2"],"remote":"远程文件绝对路径(必填)","localDir":"本地保存目录(必填)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIdsRaw = args['hostIds'];
    final remote = args['remote']?.toString() ?? '';
    final localDir = args['localDir']?.toString() ?? '';

    if (remote.isEmpty || localDir.isEmpty) {
      return ToolResult.failure('参数缺失: remote、localDir 为必填项');
    }
    List<String> hostIds = [];
    if (hostIdsRaw is List) {
      hostIds = hostIdsRaw.map((e) => e.toString()).toList();
    } else if (hostIdsRaw is String) {
      hostIds = hostIdsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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
  String get paramSpec => '{"hostIds":["hostId1","hostId2"],"pattern":"搜索关键词(必填,正则)","files":"要搜索的文件路径(必填,多个用逗号分隔)","tail":"仅搜索文件末尾N行(可选,如1000)","ignoreCase":"是否忽略大小写(true/false,默认false)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIdsRaw = args['hostIds'];
    final pattern = args['pattern']?.toString() ?? '';
    final files = args['files']?.toString() ?? '';
    final tail = args['tail']?.toString();
    final ignoreCase = args['ignoreCase'] == true || args['ignoreCase'] == 'true';

    if (pattern.isEmpty || files.isEmpty) {
      return ToolResult.failure('参数缺失: pattern、files 为必填项');
    }
    List<String> hostIds = [];
    if (hostIdsRaw is List) {
      hostIds = hostIdsRaw.map((e) => e.toString()).toList();
    } else if (hostIdsRaw is String) {
      hostIds = hostIdsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    if (hostIds.isEmpty) {
      return ToolResult.failure('参数缺失: hostIds 为必填项');
    }

    // 构造 grep 命令：支持 tail + ignoreCase
    final safePattern = pattern.replaceAll("'", "'\\''");
    final grepFlags = ignoreCase ? '-iE' : '-E';
    final fileList = files.split(',').map((f) => f.trim()).where((f) => f.isNotEmpty).join(' ');
    String cmd;
    if (tail != null && tail.isNotEmpty) {
      final n = int.tryParse(tail) ?? 1000;
      cmd = "tail -n $n $fileList | grep $grepFlags '$safePattern'";
    } else {
      cmd = "grep $grepFlags '$safePattern' $fileList";
    }

    final results = <String>[];
    int hitCount = 0;
    for (final hid in hostIds) {
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
  String get paramSpec => '{"hostIds":["hostId1","hostId2"],"remote":"远程文件绝对路径(必填)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final hostIdsRaw = args['hostIds'];
    final remote = args['remote']?.toString() ?? '';

    if (remote.isEmpty) {
      return ToolResult.failure('参数缺失: remote 为必填项');
    }
    List<String> hostIds = [];
    if (hostIdsRaw is List) {
      hostIds = hostIdsRaw.map((e) => e.toString()).toList();
    } else if (hostIdsRaw is String) {
      hostIds = hostIdsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    if (hostIds.length < 2) {
      return ToolResult.failure('diff 至少需要 2 台主机');
    }

    // 采集每台主机的 md5 和内容
    final md5Results = <String, String>{};
    final contentResults = <String, String>{};
    for (final hid in hostIds) {
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
  String get paramSpec => '{"mode":"remote|local_file|ssh_hostkey(必填)","host":"远程HTTPS主机名或IP(mode=remote时必填)","port":"HTTPS端口(默认443)","certPath":"本地证书文件路径(mode=local_file时必填)"}';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final mode = args['mode']?.toString() ?? '';
    if (mode.isEmpty) {
      return ToolResult.failure('参数缺失: mode 必填（remote/local_file/ssh_hostkey）');
    }

    if (mode == 'remote') {
      final host = args['host']?.toString() ?? '';
      final port = int.tryParse(args['port']?.toString() ?? '') ?? 443;
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
      final certPath = args['certPath']?.toString() ?? '';
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
    buffer.writeln('当需要执行非 shell 命令的操作时（如上传文件），使用 "动作: tool" 调用工具。');
    buffer.writeln();
    for (final tool in _tools.values) {
      buffer.writeln('工具: ${tool.name}');
      buffer.writeln('  说明: ${tool.description}');
      buffer.writeln('  参数: ${tool.paramSpec}');
      buffer.writeln();
    }
    buffer.writeln('工具调用格式示例:');
    buffer.writeln('思考: 需要把本地 dist 目录上传到服务器');
    buffer.writeln('动作: tool');
    buffer.writeln('工具: sftp_upload');
    buffer.writeln('参数: {"local":"/Users/x/proj/dist","remote":"/var/www/myapp","recursive":true}');
    return buffer.toString().trimRight();
  }
}
