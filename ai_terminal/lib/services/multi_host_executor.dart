import '../models/host_config.dart';
import '../core/hive_init.dart';
import 'agent_host_registry.dart';
import 'command_executor.dart';
import '../models/orchestrator_state.dart';

/// 多机执行器：在单个 AgentEngine 内部按 hostId 路由命令
///
/// 关键设计（R3 兼容）：
/// - 不切换 _registry.activeHostId，避免 UI 串台
/// - 每次执行都从 registry 取最新的 executor，不持有引用
/// - 批量执行是串行的（for 循环），不是并发
class MultiHostExecutor {
  final AgentHostRegistry _registry;

  MultiHostExecutor(this._registry);

  /// 获取指定 host 的 executor
  /// 返回 null 表示该 host 未连接或不存在
  CommandExecutor? executorFor(String hostId) {
    return _registry.getExecutor(hostId);
  }

  /// 获取指定 host 的 HostConfig（用于显示名、IP 等）
  HostConfig? hostConfigFor(String hostId) {
    return HiveInit.hostsBox.get(hostId);
  }

  /// 获取所有已连接的主机 id 列表
  List<String> get connectedHostIds {
    final ids = <String>[];
    for (final host in HiveInit.hostsBox.values) {
      final executor = _registry.getExecutor(host.id);
      if (executor != null && executor.isConnected) {
        ids.add(host.id);
      }
    }
    return ids;
  }

  /// 在指定 host 上执行命令
  /// 返回 null 表示该 host 未连接
  Future<CommandResult?> executeOn(
    String hostId,
    String command, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final executor = _registry.getExecutor(hostId);
    if (executor == null) {
      return null;
    }
    if (!executor.isConnected) {
      return CommandResult(
        stdout: '',
        stderr: '主机 $hostId 未连接',
        exitCode: -1,
        duration: Duration.zero,
      );
    }
    try {
      return await executor.executeAndWait(command, timeout: timeout);
    } catch (e) {
      return CommandResult(
        stdout: '',
        stderr: '执行异常: $e',
        exitCode: -1,
        duration: Duration.zero,
      );
    }
  }

  /// 批量执行：同一命令在多台机上串行执行
  /// [stopOnFailure] 为 true 时，某台失败则停止后续；为 false 时继续执行其他
  Future<Map<String, CommandResult>> executeBatch(
    List<String> hostIds,
    String command, {
    Duration timeout = const Duration(seconds: 60),
    bool stopOnFailure = false,
  }) async {
    final results = <String, CommandResult>{};
    for (int i = 0; i < hostIds.length; i++) {
      final hostId = hostIds[i];
      final result = await executeOn(hostId, command, timeout: timeout);
      if (result == null) {
        results[hostId] = CommandResult(
          stdout: '',
          stderr: '主机 $hostId 未连接',
          exitCode: -1,
          duration: Duration.zero,
        );
      } else {
        results[hostId] = result;
      }
      // R5: 用合成后的 results[hostId] 判断失败，确保 null（未连接）也触发 stopOnFailure
      if (stopOnFailure && !results[hostId]!.success) {
        // 基于索引标记后续主机为 skipped（避免重复 hostId 时 skipWhile 错乱）
        for (int j = i + 1; j < hostIds.length; j++) {
          results[hostIds[j]] = CommandResult(
            stdout: '',
            stderr: '已跳过（前序主机失败）',
            exitCode: -1,
            duration: Duration.zero,
          );
        }
        break;
      }
    }
    return results;
  }

  /// 跨机连通性测试：从 fromHostId 的 executor 上执行网络探测命令
  Future<ConnectivityResult> checkConnectivity({
    required String fromHostId,
    required String targetHost,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final start = DateTime.now();
    final executor = _registry.getExecutor(fromHostId);
    if (executor == null || !executor.isConnected) {
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: false,
        detail: '源主机 $fromHostId 未连接',
        elapsed: DateTime.now().difference(start),
      );
    }

    // R7: 校验 targetHost 格式（IP 或域名），防止 shell 注入
    if (!_isValidHost(targetHost)) {
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: false,
        detail: 'targetHost 格式非法（仅允许 IP 或域名字符）',
        elapsed: DateTime.now().difference(start),
      );
    }

    // 用 timeout 3 + bash /dev/tcp 探测，兼容性最好（不需要 nc）
    // R6: 不同 shell 都支持 bash -c，且 /dev/tcp 是 bash 内建
    final probeCmd = "timeout 3 bash -c 'cat < /dev/tcp/$targetHost/$port' "
        "&& echo 'CONNECT_OK' || echo 'CONNECT_FAIL'";
    try {
      final result = await executor.executeAndWait(probeCmd, timeout: timeout);
      final elapsed = DateTime.now().difference(start);
      final output = result.stdout;
      final reachable = output.contains('CONNECT_OK');
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: reachable,
        detail: reachable ? null : (result.stderr.isNotEmpty ? result.stderr : '连接超时或被拒绝'),
        elapsed: elapsed,
      );
    } catch (e) {
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: false,
        detail: '探测异常: $e',
        elapsed: DateTime.now().difference(start),
      );
    }
  }

  /// 校验主机名/IP格式：仅允许字母、数字、点、连字符（防 shell 注入）
  static final RegExp _hostRegex = RegExp(r'^[a-zA-Z0-9.\-]+$');
  static bool _isValidHost(String host) {
    if (host.isEmpty || host.length > 255) return false;
    return _hostRegex.hasMatch(host);
  }

  /// 构建主机清单文本（用于 system prompt 注入）
  String buildHostListText() {
    final hosts = HiveInit.hostsBox.values.toList();
    if (hosts.isEmpty) return '（暂无已配置的主机）';

    final buffer = StringBuffer();
    for (final host in hosts) {
      final executor = _registry.getExecutor(host.id);
      final connected = executor?.isConnected ?? false;
      final status = connected ? '已连接' : '未连接';
      buffer.writeln('- ${host.id} (${host.name}, ${host.host}): $status');
    }
    return buffer.toString().trimRight();
  }

  /// 把批量结果格式化为紧凑的观测文本（避免 AI 上下文爆炸）
  static String formatBatchResult(
    String command,
    Map<String, CommandResult> results,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('批量执行: $command');
    final successCount = results.values.where((r) => r.success).length;
    buffer.writeln('结果: $successCount/${results.length} 成功');
    for (final entry in results.entries) {
      final hostId = entry.key;
      final r = entry.value;
      final mark = r.success ? '✓' : '✗';
      final detail = r.success
          ? (r.stdout.isNotEmpty ? _truncate(r.stdout, 200) : '(无输出)')
          : '错误: ${_truncate(r.stderr.isNotEmpty ? r.stderr : '未知', 200)}';
      buffer.writeln('[$hostId] $mark $detail');
    }
    return buffer.toString().trimRight();
  }

  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}
