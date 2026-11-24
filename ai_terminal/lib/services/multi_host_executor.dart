import 'dart:async';
import 'dart:io';

import '../core/l10n_holder.dart';
import '../core/permission_policy.dart';
import '../core/safety_guard.dart';
import '../models/agent_permission_mode.dart';
import '../models/host_config.dart';
import '../models/orchestrator_state.dart';
import '../utils/command_heuristics.dart';
import '../utils/shell_syntax.dart';
import 'agent_host_registry.dart';
import 'command_executor.dart';
import 'command_runner.dart';
import 'daos.dart';
import 'local_terminal_service.dart';
import 'ssh_service.dart';

/// 多机执行器：在单个 AgentEngine 内部按 hostId 路由命令
///
/// 关键设计（R3 兼容）：
/// - 不切换 _registry.activeHostId，避免 UI 串台
/// - 每次执行都从 registry 取最新的 executor，不持有引用
/// - 批量执行按命令安全等级分流：只读命令并行，修改性命令串行
class MultiHostExecutor {
  final AgentHostRegistry _registry;

  /// 归属任务的权限档位提供者：由启用编排的 AgentEngine 注入。
  ///
  /// 不能只读 [_registry.activeScopeId]：任务运行期间用户可能切到另一个
  /// 同主机 tab，那里也有引擎；权限档位会跟着活跃 tab 漂移，导致原任务
  /// 在不该拦截的命令上被拦、或在不该放行的命令上被放行。
  AgentPermissionMode? Function()? permissionModeProvider;

  MultiHostExecutor(this._registry, {this.permissionModeProvider});

  /// 模型给的 timeout 可能为 0/负数（命令必然立刻超时）或极大值（任务
  /// 长时间无法结束、停止按钮生效慢）。统一夹到 [1, 600] 秒。
  static int clampTimeoutSeconds(int seconds) => seconds.clamp(1, 600);

  /// 当前任务的取消令牌（由 AgentEngine 在任务开始时注入）。
  /// 所有 executeAndWait 调用都会带上这个 token，用户点停止按钮时
  /// cancelTask() complete 它，编排里正在执行的远程命令立即中断。
  /// 串行模式的 for 循环也会每轮检查它提前 break。
  Completer<void>? _cancelToken;

  /// 由 AgentEngine 调用：注入当前任务的取消令牌
  set cancelToken(Completer<void>? token) => _cancelToken = token;

  /// 工具在异步循环入口捕获令牌，后续不得借用新任务的令牌继续派发。
  Completer<void>? get cancelToken => _cancelToken;

  bool isTaskCancelled(Completer<void>? taskToken) =>
      taskToken?.isCompleted == true || !identical(_cancelToken, taskToken);

  /// 公开版取消检查：供 agent_tool 里的逐台循环每轮检查用。
  /// 当 cancelTask 触发后，工具的 for 循环应立即 break，不再派发新主机。
  bool get isCancelled => _cancelToken?.isCompleted ?? false;

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
    AgentPermissionMode? permissionMode,
  }) =>
      _executeOnWithToken(
        hostId,
        command,
        timeout: timeout,
        permissionMode: permissionMode,
        taskToken: _cancelToken,
      );

  Future<CommandResult?> _executeOnWithToken(
    String hostId,
    String command, {
    required Duration timeout,
    AgentPermissionMode? permissionMode,
    required Completer<void>? taskToken,
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
        failureKind: CommandFailureKind.disconnected,
        failureReason: L10n.str.orchHostNotConnected(hostId),
      );
    }
    if (isTaskCancelled(taskToken)) {
      return _blockedResult('任务已取消，命令未执行', CommandFailureKind.cancelled);
    }

    // 每条真正派发给 executor 的命令都走同一套预检；工具描述/模型自报不是证据。
    final block = _preflight(
        command, executor, permissionMode ?? _currentPermissionMode());
    if (block != null) return block;

    try {
      final result = await executor.executeAndWait(command,
          timeout: timeout, cancelToken: taskToken);
      // 共享令牌可能在 await 期间被新任务替换；旧任务结果不得冒充新任务成功。
      if (isTaskCancelled(taskToken)) {
        return CommandResult(
          stdout: result.stdout,
          stderr: result.stderr,
          exitCode: result.exitCode,
          duration: result.duration,
          failureKind: CommandFailureKind.cancelled,
          failureReason: '任务已取消或取消令牌已替换',
        );
      }
      return result;
    } catch (e) {
      if (isTaskCancelled(taskToken)) {
        return _blockedResult('任务已取消或取消令牌已替换', CommandFailureKind.cancelled);
      }
      return CommandResult(
        stdout: '',
        stderr: L10n.str.orchExecException(e.toString()),
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.unknown,
        failureReason: e.toString(),
      );
    }
  }

  AgentPermissionMode _currentPermissionMode() {
    // 优先用任务归属引擎的实时档位；registry 活跃 scope 仅作未注入时的回退。
    final bound = permissionModeProvider?.call();
    if (bound != null) return bound;
    final scopeId = _registry.activeScopeId;
    if (scopeId == null) return AgentPermissionMode.ask;
    // 引擎是权限设置的实时来源；registry state 作为尚未创建引擎时的回退。
    return _registry.getEngine(scopeId)?.permissionMode ??
        _registry.getState(scopeId)?.permissionMode ??
        AgentPermissionMode.ask;
  }

  CommandResult? _preflight(
    String command,
    CommandExecutor executor,
    AgentPermissionMode permissionMode,
  ) {
    final level = SafetyGuard.check(command);
    final decision = decideCommand(level, permissionMode);
    final block = CommandPreflight.evaluate(
      command: command,
      safetyLevel: level,
      executor: executor,
      permissionMode: permissionMode,
      decision: decision,
      emitInfo: (_) {},
    );
    if (block != null) {
      return _blockedResult(
          block.observation, CommandFailureKind.permissionDenied);
    }
    // fullAuto 在通用权限策略里会放行 blocked；多机入口按要求仍硬拒绝高危命令。
    if (level == SafetyLevel.blocked) {
      final reason = SafetyGuard.getReasonZh(command) ?? '高危命令禁止通过多机工具执行';
      return _blockedResult(reason, CommandFailureKind.permissionDenied);
    }

    final remoteOs =
        executor is SSHService ? executor.osInfo.toLowerCase() : '';
    final isWindows = executor is LocalTerminalService
        ? Platform.isWindows
        : (executor is SSHService &&
            (remoteOs.contains('windows') ||
                remoteOs.contains('mingw') ||
                remoteOs.contains('cygwin')));
    final unclosed = ShellSyntax.unclosedReason(command, isWindows: isWindows);
    if (unclosed != null) {
      return _blockedResult('命令未闭合: $unclosed', CommandFailureKind.syntaxError);
    }
    if (!isWindows) {
      final reliability =
          ShellSyntax.scanPosixCommand(command).reliabilityReason;
      if (reliability != null) {
        return _blockedResult(
            '命令无法可靠执行: $reliability', CommandFailureKind.syntaxError);
      }
    }
    if (isBlockingInteractiveCommand(command)) {
      return _blockedResult('交互阻塞命令禁止通过多机工具执行，请改用非交互参数或后台服务',
          CommandFailureKind.interactivePrompt);
    }
    return null;
  }

  static CommandResult _blockedResult(String reason, CommandFailureKind kind) =>
      CommandResult(
        stdout: '',
        stderr: reason,
        exitCode: -1,
        duration: Duration.zero,
        failureKind: kind,
        failureReason: reason,
      );

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
    // 批次入口锁定权限档位和取消令牌，避免执行中途切换会话导致权限/取消漂移。
    final batchPermissionMode = _currentPermissionMode();
    final batchToken = _cancelToken;

    // 取消提前检查：若进入 executeBatch 时已取消，直接全部标记 skipped
    if (isTaskCancelled(batchToken)) {
      for (final hostId in hostIds) {
        results[hostId] =
            _blockedResult('任务已取消，命令未执行', CommandFailureKind.cancelled);
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
          _executeOneAndStore(
            hostId,
            command,
            timeout: timeout,
            results: results,
            permissionMode: batchPermissionMode,
            taskToken: batchToken,
          ),
        );
      }
      await Future.wait(futures);
      return results;
    }

    // 串行执行：修改性命令逐台执行，支持 stopOnFailure
    for (int i = 0; i < hostIds.length; i++) {
      // 每轮开始前检查取消：cancelTask 触发后立即停止派发新命令
      if (isTaskCancelled(batchToken)) {
        for (int j = i; j < hostIds.length; j++) {
          results[hostIds[j]] =
              _blockedResult('任务已取消，命令未执行', CommandFailureKind.cancelled);
        }
        break;
      }
      final hostId = hostIds[i];
      final result = await _executeOnWithToken(
        hostId,
        command,
        timeout: timeout,
        permissionMode: batchPermissionMode,
        taskToken: batchToken,
      );
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
      if (isTaskCancelled(batchToken)) {
        for (int j = i + 1; j < hostIds.length; j++) {
          results[hostIds[j]] =
              _blockedResult('任务已取消，命令未执行', CommandFailureKind.cancelled);
        }
        break;
      }
      // R5: 用合成后的 results[hostId] 判断失败，确保 null（未连接）也触发 stopOnFailure
      if (stopOnFailure && !results[hostId]!.success) {
        // 未派发 ≠ 被取消：单独标记 skipped，UI/模型才能区分“执行中断”和“根本没跑”。
        for (int j = i + 1; j < hostIds.length; j++) {
          results[hostIds[j]] =
              _blockedResult('前序主机失败，命令未执行', CommandFailureKind.skipped);
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
    required AgentPermissionMode permissionMode,
    required Completer<void>? taskToken,
  }) async {
    try {
      final result = await _executeOnWithToken(
        hostId,
        command,
        timeout: timeout,
        permissionMode: permissionMode,
        taskToken: taskToken,
      );
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
    final taskToken = _cancelToken;
    try {
      final result = await executor.executeAndWait(probeCmd,
          timeout: timeout, cancelToken: taskToken);
      if (isTaskCancelled(taskToken)) {
        return ConnectivityResult(
          fromHostId: fromHostId,
          targetHost: targetHost,
          port: port,
          reachable: false,
          detail: L10n.str.taskCancelled,
          elapsed: DateTime.now().difference(start),
        );
      }
      if (!result.success) {
        // 探测本身没跑完（超时/断连/语法错误）：把真实原因带给 AI，
        // 固定文案会让它误以为目标端口不通而做出错误路由决定。
        final reason = (result.failureReason ?? '').trim();
        final stderr = result.stderr.trim();
        return ConnectivityResult(
          fromHostId: fromHostId,
          targetHost: targetHost,
          port: port,
          reachable: false,
          detail: reason.isNotEmpty
              ? reason
              : (stderr.isNotEmpty ? stderr : L10n.str.orchConnectTimeout),
          elapsed: DateTime.now().difference(start),
        );
      }
      final elapsed = DateTime.now().difference(start);
      final output = result.stdout;
      final reachable = output.contains('CONNECT_OK');
      return ConnectivityResult(
        fromHostId: fromHostId,
        targetHost: targetHost,
        port: port,
        reachable: reachable,
        detail: reachable
            ? null
            : (result.stderr.isNotEmpty
                ? result.stderr
                : L10n.str.orchConnectTimeout),
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
      final status = connected
          ? L10n.str.orchHostConnected
          : L10n.str.orchHostDisconnected;
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
    final skippedCount = results.values
        .where((r) => !r.success && r.failureKind == CommandFailureKind.skipped)
        .length;
    final cancelledCount = results.values
        .where(
            (r) => !r.success && r.failureKind == CommandFailureKind.cancelled)
        .length;
    buffer.writeln(L10n.str.orchBatchResult(successCount, results.length));
    if (skippedCount > 0 || cancelledCount > 0) {
      buffer.writeln('未执行 $skippedCount 台，已取消 $cancelledCount 台（不计入失败）');
    }
    for (final entry in results.entries) {
      final hostId = entry.key;
      final r = entry.value;
      final notRun = !r.success &&
          (r.failureKind == CommandFailureKind.skipped ||
              r.failureKind == CommandFailureKind.cancelled);
      final mark = r.success ? '✓' : (notRun ? '⊘' : '✗');
      final detail = r.success
          ? (r.stdout.isNotEmpty
              ? _truncate(r.stdout, 200)
              : L10n.str.orchNoOutput)
          : L10n.str.orchErrorPrefix(_truncate(failureDetail(r), 200));
      buffer.writeln('[$hostId] $mark $detail');
    }
    return buffer.toString().trimRight();
  }

  /// 失败诊断优先级：结构化 failureReason → stderr → stdout。
  /// PTY 常把诊断合并进 stdout，不能只回传 stderr。
  static String failureDetail(CommandResult result) {
    final reason = result.failureReason?.trim() ?? '';
    if (reason.isNotEmpty) return reason;
    if (result.stderr.trim().isNotEmpty) return result.stderr;
    if (result.stdout.trim().isNotEmpty) return result.stdout;
    return L10n.str.orchUnknown;
  }

  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}
