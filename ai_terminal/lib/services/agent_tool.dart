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
      return ToolResult.failure('本地路径不存在: $local');
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
      return ToolResult.failure('参数缺失: hostId 和 command 为必填项');
    }

    onProgress?.call('[$hostId] 执行: $command');
    final result = await _executor.executeOn(
      hostId,
      command,
      timeout: Duration(seconds: timeoutSec),
    );

    if (result == null) {
      return ToolResult.failure('主机 $hostId 未连接或不存在');
    }

    final mark = result.success ? '✓' : '✗';
    // R8: 截断输出，避免 MB 级日志注入对话历史
    final output = _truncate(result.stdout, 2000);
    final err = _truncate(result.stderr, 1000);
    final summary = '[$hostId] $mark (exit=${result.exitCode})';
    final detail = result.success
        ? (output.isNotEmpty ? output : '(无输出)')
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
  String get description => '【多机编排】批量执行同一命令到多台主机（串行）。'
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
      return ToolResult.failure('参数缺失: hostIds 和 command 为必填项');
    }

    final hostIds = hostIdsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (hostIds.isEmpty) {
      return ToolResult.failure('hostIds 解析后为空');
    }

    onProgress?.call('批量执行: $command → ${hostIds.length} 台主机');
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
        error: '$failedCount/${hostIds.length} 台主机执行失败',
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
      return ToolResult.failure('参数缺失或无效: fromHostId、targetHost、port(正整数) 为必填项');
    }

    onProgress?.call('[$fromHostId → $targetHost:$port] 测试连通性...');
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
        error: result.detail ?? '不可达',
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
      return ToolResult.failure('参数缺失: hostId、local、remote 为必填项');
    }

    // 通过 hostId 获取目标主机的 executor（必须是 SSHService 才能开 SFTP）
    final targetExecutor = _executor.executorFor(hostId);
    if (targetExecutor == null) {
      return ToolResult.failure('主机 $hostId 未连接或不存在');
    }
    if (targetExecutor is! SSHService) {
      return ToolResult.failure('主机 $hostId 不是 SSH 远程会话，无法 SFTP 上传');
    }
    // R1: 捕获 client 到局部变量，避免 await 期间连接断开导致的 TOCTOU 空指针
    final client = targetExecutor.client;
    if (client == null) {
      return ToolResult.failure('主机 $hostId 的 SSH 连接未建立');
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
      return ToolResult.failure('本地路径不存在: $local');
    }
    if (isDir && !recursive) {
      return ToolResult.failure('本地路径是目录，请设置 recursive=true 以递归上传');
    }

    List<String> excludeNames = ['node_modules', '.git', '.DS_Store'];
    if (excludeRaw != null) {
      if (excludeRaw is List) {
        excludeNames = excludeRaw.map((e) => e.toString()).toList();
      } else if (excludeRaw is String) {
        excludeNames = excludeRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    }

    onProgress?.call('[$hostId] 正在打开 SFTP 子系统...');
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
  }

  /// 禁用编排模式：注销多机编排工具
  void disableOrchestrator() {
    _multiHostExecutor = null;
    _tools.remove('exec_on');
    _tools.remove('exec_batch');
    _tools.remove('check_connectivity');
    _tools.remove('upload_to');
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
