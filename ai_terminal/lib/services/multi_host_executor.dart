import 'dart:async';
import '../models/host_config.dart';
import '../core/safety_guard.dart';
import 'agent_host_registry.dart';
import 'command_executor.dart';
import 'daos.dart';
import '../models/orchestrator_state.dart';
import '../core/l10n_holder.dart';

/// 多机执行器：在单个 AgentEngine 内部按 hostId 路由命令
///
/// 关键设计（R3 兼容）：
/// - 不切换 _registry.activeHostId，避免 UI 串台
/// - 每次执行都从 registry 取最新的 executor，不持有引用
/// - 批量执行按命令安全等级分流：只读命令并行，修改性命令串行
class MultiHostExecutor {
  final AgentHostRegistry _registry;

  MultiHostExecutor(this._registry);

  /// 当前任务的取消令牌（由 AgentEngine 在任务开始时注入）。
  /// 所有 executeAndWait 调用都会带上这个 token，用户点停止按钮时
  /// cancelTask() complete 它，编排里正在执行的远程命令立即中断。
  /// 串行模式的 for 循环也会每轮检查它提前 break。
  Completer<void>? _cancelToken;

  /// 由 AgentEngine 调用：注入当前任务的取消令牌
  set cancelToken(Completer<void>? token) => _cancelToken = token;

  /// 当前是否已取消（供串行循环每轮检查用）
  bool get _isCancelled => _cancelToken?.isCompleted ?? false;

  /// 公开版取消检查：供 agent_tool 里的逐台循环每轮检查用。
  /// 当 cancelTask 触发后，工具的 for 循环应立即 break，不再派发新主机。
  bool get isCancelled => _isCancelled;

  /// 获取指定 host 的 executor
  /// 返回 null 表示该 host 未连接或不存在
  CommandExecutor? executorFor(String hostId) {
    return _registry.getExecutor(hostId);
  }

  /// 获取指定 host 的 HostConfig（用于显示名、IP 等）
  HostConfig? hostConfigFor(String hostId) {
    return HostsDao.getCachedById(hostId);
  }

  /// 获取所有已连接的主机 id 列表
  List<String> get connectedHostIds {
    final ids = <String>[];
    for (final host in HostsDao.cached) {
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
        stderr: L10n.str.orchHostNotConnected(hostId),
        exitCode: -1,
        duration: Duration.zero,
      );
    }
    try {
      return await executor.executeAndWait(command, timeout: timeout, cancelToken: _cancelToken);
    } catch (e) {
      return CommandResult(
        stdout: '',
        stderr: L10n.str.orchExecException(e.toString()),
        exitCode: -1,
        duration: Duration.zero,
      );
    }
  }

  /// 批量执行：同一命令在多台机上执行
  ///
  /// - 只读命令（SafetyLevel.safe）并行执行，提升多机查询效率
  /// - 修改性命令（非 safe 级）串行执行，便于逐台确认与失败即止
  ///
  /// [stopOnFailure] 语义：
  /// - 串行模式：某台失败则停止后续主机，未执行的主机标记为 skipped
  /// - 并行模式：所有主机都会执行完，stopOnFailure 仅影响后续批次
  Future<Map<String, CommandResult>> executeBatch(
    List<String> hostIds,
    String command, {
    Duration timeout = const Duration(seconds: 60),
    bool stopOnFailure = false,
  }) async {
    final results = <String, CommandResult>{};

    // 取消提前检查：若进入 executeBatch 时已取消，直接全部标记 skipped
    if (_isCancelled) {
      for (final hostId in hostIds) {
        results[hostId] = CommandResult(
          stdout: '',
          stderr: L10n.str.orchSkippedPreviousFailed,
          exitCode: -1,
          duration: Duration.zero,
        );
      }
      return results;
    }

    // R4/R8：用 SafetyGuard 判定安全等级，只读命令并行
    final level = SafetyGuard.check(command);
    if (level == SafetyLevel.safe) {
      // 并行执行：单台异常/失败不影响其他主机
      final futures = <Future<void>>[];
      for (final hostId in hostIds) {
        futures.add(
          _executeOneAndStore(hostId, command, timeout: timeout, results: results),
        );
      }
      await Future.wait(futures);
      return results;
    }

    // 串行执行：修改性命令逐台执行，支持 stopOnFailure
    for (int i = 0; i < hostIds.length; i++) {
      // 每轮开始前检查取消：cancelTask 触发后立即停止派发新命令
      if (_isCancelled) {
        for (int j = i; j < hostIds.length; j++) {
          results[hostIds[j]] = CommandResult(
            stdout: '',
            stderr: L10n.str.orchSkippedPreviousFailed,
            exitCode: -1,
            duration: Duration.zero,
          );
        }
        break;
      }
      final hostId = hostIds[i];
      final result = await executeOn(hostId, command, timeout: timeout);
      if (result == null) {
        results[hostId] = CommandResult(
          stdout: '',
          stderr: L10n.str.orchHostNotConnected(hostId),
          exitCode: -1,
          duration: Duration.zero,
        );
      } else {
        results[hostId] = result;
      }
      // 取消后停止后续派发（执行中的命令已由 executeAndWait 内部提前返回）
      if (_isCancelled) {
        for (int j = i + 1; j < hostIds.length; j++) {
          results[hostIds[j]] = CommandResult(
            stdout: '',
            stderr: L10n.str.orchSkippedPreviousFailed,
            exitCode: -1,
            duration: Duration.zero,
          );
        }
        break;
      }
      // R5: 用合成后的 results[hostId] 判断失败，确保 null（未连接）也触发 stopOnFailure
      if (stopOnFailure && !results[hostId]!.success) {
        // 基于索引标记后续主机为 skipped（避免重复 hostId 时 skipWhile 错乱）
        for (int j = i + 1; j < hostIds.length; j++) {
          results[hostIds[j]] = CommandResult(
            stdout: '',
            stderr: L10n.str.orchSkippedPreviousFailed,
            exitCode: -1,
            duration: Duration.zero,
          );
        }
        break;
      }
    }
    return results;
  }

  /// 在单台主机执行命令并把结果写入共享 map（并行模式下使用）
  /// 单台异常被捕获并转为失败结果，不影响其他主机的 Future
  Future<void> _executeOneAndStore(
    String hostId,
    String command, {
    required Duration timeout,
    required Map<String, CommandResult> results,
  }) async {
    try {
      final result = await executeOn(hostId, command, timeout: timeout);
      if (result == null) {
        results[hostId] = CommandResult(
          stdout: '',
          stderr: L10n.str.orchHostNotConnected(hostId),
          exitCode: -1,
          duration: Duration.zero,
        );
      } else {
        results[hostId] = result;
      }
    } catch (e) {
      // R2/R8：单台异常不传播，避免 Future.wait 因一个失败而丢失其他结果
      results[hostId] = CommandResult(
        stdout: '',
        stderr: L10n.str.orchExecException(e.toString()),
        exitCode: -1,
        duration: Duration.zero,
      );
    }
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
        detail: L10n.str.orchSourceNotConnected(fromHostId),
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
        detail: L10n.str.orchInvalidTarget,
        elapsed: DateTime.now().difference(start),
      );
    }

    // 用 timeout 3 + bash /dev/tcp 探测，兼容性最好（不需要 nc）
    // R6: 不同 shell 都支持 bash -c，且 /dev/tcp 是 bash 内建
    final probeCmd = "timeout 3 bash -c 'cat < /dev/tcp/$targetHost/$port' "
        "&& echo 'CONNECT_OK' || echo 'CONNECT_FAIL'";
    try {
      final result = await executor.executeAndWait(probeCmd, timeout: timeout, cancelToken: _cancelToken);
      final elapsed = DateTime.now().difference(start);
      final output = result.stdout;
      final reachable = output.contains('CONNECT_OK');
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: reachable,
        detail: reachable ? null : (result.stderr.isNotEmpty ? result.stderr : L10n.str.orchConnectTimeout),
        elapsed: elapsed,
      );
    } catch (e) {
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: false,
        detail: L10n.str.orchProbeException(e.toString()),
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
    final hosts = HostsDao.cached;
    if (hosts.isEmpty) return L10n.str.orchNoHostsConfigured;

    final buffer = StringBuffer();
    for (final host in hosts) {
      final executor = _registry.getExecutor(host.id);
      final connected = executor?.isConnected ?? false;
      final status = connected ? L10n.str.orchHostConnected : L10n.str.orchHostDisconnected;
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
    buffer.writeln(L10n.str.orchBatchExec(command));
    final successCount = results.values.where((r) => r.success).length;
    buffer.writeln(L10n.str.orchBatchResult(successCount, results.length));
    for (final entry in results.entries) {
      final hostId = entry.key;
      final r = entry.value;
      final mark = r.success ? '✓' : '✗';
      final detail = r.success
          ? (r.stdout.isNotEmpty ? _truncate(r.stdout, 200) : L10n.str.orchNoOutput)
          : L10n.str.orchErrorPrefix(_truncate(r.stderr.isNotEmpty ? r.stderr : L10n.str.orchUnknown, 200));
      buffer.writeln('[$hostId] $mark $detail');
    }
    return buffer.toString().trimRight();
  }

  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}
