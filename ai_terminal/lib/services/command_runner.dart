import 'dart:io';

import '../core/l10n_holder.dart';
import '../core/permission_policy.dart';
import '../core/safety_guard.dart';
import '../core/ui_text.dart';
import '../models/agent_event.dart';
import '../models/agent_model.dart';
import '../models/agent_permission_mode.dart';
import '../utils/command_heuristics.dart';
import '../utils/local_command_detector.dart';
import 'change_window_service.dart';
import 'command_executor.dart';
import 'local_terminal_service.dart';
import 'ssh_service.dart';

/// 命令执行层的**无状态**部分。
///
/// 从 `AgentEngine` 抽出的第 5 个叶子模块（Step 5）。这里只放不依赖引擎
/// 实例状态的逻辑：日志格式化、审计截断、命令事件元数据补全、展示阶段派生，
/// 以及执行前的五道守卫。
///
/// 为什么真正的执行逻辑没搬过来：`_runCommandWithSafetyInner` 会写
/// `_currentTask.status`（waitingConfirm/executing）、操作确认握手
/// （`_confirmCompleter` 与 `cancelTask` 共享）、成功/失败计数与报告账本。
/// 这些字段都是引擎生命周期的一部分，搬走会让取消路径只 complete 引擎的
/// completer，而 runner 侧的 await 永久挂起（违反 R1）。因此执行状态机留在
/// `AgentEngine`，这里只做"判定"和"格式化"。
class CommandRunner {
  const CommandRunner._();

  /// 日志里只放命令首行并限长：整条命令可能是多行脚本，原样打会把日志撑爆
  static String logCommand(String command) {
    final firstLine = command.split('\n').first.trim();
    if (firstLine.isEmpty) return '(空命令)';
    return firstLine.length <= 80
        ? firstLine
        : '${firstLine.substring(0, 80)}…';
  }

  /// 审计日志输出截断（避免 MB 级日志膨胀审计 box）
  static String truncateForAudit(String s) {
    if (s.length <= 500) return s;
    return '${s.substring(0, 500)}...(${s.length} chars)';
  }

  /// 当前响应中除第一条之外、已作为 command 事件发出的其余命令（带事件 id）。
  ///
  /// 这些命令事件在流式/收尾阶段已发出且 id 已是 finalId，结果事件用同一 id
  /// 关联即可；调用后由调用方清空 `_announcedFollowUps`。
  static List<({String eventId, String command})> remainingAnnouncedCommands(
      List<AgentEvent>? events) {
    if (events == null) return const [];
    var skippedFirst = false;
    final out = <({String eventId, String command})>[];
    for (final e in events) {
      if (!e.isCommand) continue;
      final cmd = (e.command ?? '').trim();
      if (cmd.isEmpty) continue;
      if (!skippedFirst) {
        skippedFirst = true; // 第一条命令由 _handleExecuteAction 主流程执行
        continue;
      }
      out.add((eventId: e.id, command: cmd));
    }
    return out;
  }

  /// 按命令类型派生展示阶段（不参与状态机）
  static String phaseForCommand(String command, SafetyLevel level) {
    if (isQueryCommand(command)) return '检查环境';
    if (level == SafetyLevel.warn || level == SafetyLevel.blocked) {
      return '执行变更';
    }
    return '执行命令';
  }

  /// 为 shell command 事件补主机/工具/风险元数据（供操作单证据层使用）
  static void enrichCommandEvent(
    AgentEvent e, {
    required String? hostId,
    required AgentPermissionMode permissionMode,
  }) {
    if (!e.isCommand) return;
    e.hostId ??= hostId;
    e.toolName ??= 'exec_command';
    final cmd = (e.command ?? '').trim();
    if (cmd.isNotEmpty) {
      final level = SafetyGuard.check(cmd);
      e.riskLevel ??= level.name;
      e.permissionDecision ??= decideCommand(level, permissionMode).name;
    }
  }

  /// 这些 reason 表示命令被策略/权限/用户拦下，从未真正执行。
  /// 「步」的口径要求把"尝试过但没执行"也算进去，所以按 reason 统一识别，
  /// 而不是在每个 return 分支各加一次——分支会继续增加，集合不会漏。
  static const Set<String> blockedCommandReasons = {
    'window_blocked',
    'read_only_blocked',
    'safety_blocked',
    'chained_modification_blocked',
    'user_rejected',
    'confirm_timeout',
    'permission_changed_during_confirm',
  };
}

/// 预检拦截的结果。
///
/// [reasonCode] 必须落在 [CommandRunner.blockedCommandReasons] 内，调用方据此
/// 计入「被拦下的步」。审计写入留在调用方：它需要 `hostId` 与 `await`，
/// 放进纯判定层会把 IO 和日志失败处理一并拖进来。
class CommandBlock {
  const CommandBlock({
    required this.reasonCode,
    required this.observation,
    this.auditOutput,
    this.auditTag,
  });

  /// 拦截原因码（`onSuccess` 的第二参）
  final String reasonCode;

  /// 回传给模型的观测正文（已格式化）
  final String observation;

  /// 非空表示还需追加一条 blocked 级审计记录（执行前已写过 executed=false）
  final String? auditOutput;

  /// 审计失败日志里的分支标记，便于定位
  final String? auditTag;
}

/// 执行前的五道守卫，**顺序不可变**。
///
/// 顺序本身就是语义：远程误发必须排在封网期之前（本机命令不该被远程的
/// 安全时段规则拦成"封网期"）；链式修改必须排在最前（否则一条链式命令
/// 里夹带的修改会绕过单命令检查）。
class CommandPreflight {
  const CommandPreflight._();

  /// 返回 null 表示放行；否则调用方应直接回传观察并结束本轮命令。
  ///
  /// [decision] 由调用方用 `decideCommand(safetyLevel, permissionMode)` 预先
  /// 算好传入——这样引擎侧那条带步数的 debug 日志可以原样保留。
  static CommandBlock? evaluate({
    required String command,
    required SafetyLevel safetyLevel,
    required CommandExecutor executor,
    required AgentPermissionMode permissionMode,
    required CommandGateDecision decision,
    required void Function(AgentEvent) emitInfo,
  }) {
    // ── 1. O1 硬保证：只读管道/链式允许，但修改类命令必须每轮一条 ──
    // 不依赖模型自觉：任一子命令 ≥ warn 即拦截，回传观测让模型拆分重试。
    final subCommands = SafetyGuard.splitSubCommands(command)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (subCommands.length > 1 &&
        subCommands
            .any((s) => SafetyGuard.check(s).index >= SafetyLevel.warn.index)) {
      const reason = '链式命令包含修改类操作，请拆分为多轮逐条执行';
      emitInfo(AgentEvent.info(
          '⛓ ${UiText.t(reason, 'Chained commands contain modifying operations; split them into separate single commands across rounds')}\n${UiText.t('命令', 'Command')}: `$command`'));
      return CommandBlock(
        reasonCode: 'chained_modification_blocked',
        observation: ReActObservation(
          command: command,
          output: reason,
          success: false,
          error: reason,
        ).format(),
        // 与权限拦截分支一致：blocked 级追加一条带原因的审计记录
        auditOutput: safetyLevel == SafetyLevel.blocked ? reason : null,
        auditTag: '链式拦截分支',
      );
    }

    // ── 2. Windows 本地终端固定启动 PowerShell 5.1，不支持 && ──
    // 提前回传语法纠错观测，避免语法错误导致 marker 永不出现、干等超时。
    if (executor is LocalTerminalService &&
        Platform.isWindows &&
        SafetyGuard.containsUnquotedOperator(command, '&&')) {
      const reason =
          'Windows PowerShell 5.1 不支持 && 运算符，请改用 ; 分隔只读命令（如 a ; b），或拆分为多轮逐条执行';
      emitInfo(AgentEvent.info(
          '🪟 ${UiText.t(reason, 'Windows PowerShell 5.1 does not support the && operator; separate read-only commands with ; (e.g. a ; b), or split them into separate single commands across rounds')}\n${UiText.t('命令', 'Command')}: `$command`'));
      return CommandBlock(
        reasonCode: 'ps5_and_operator_unsupported',
        observation: ReActObservation(
          command: command,
          output: reason,
          success: false,
          error: reason,
        ).format(),
      );
    }

    // ── 3. 远程误发拦截 ──
    // SSH 到非 Windows 主机时，明显是本机 Windows/PowerShell 的命令先给一条
    // 可读观测，避免把 PowerShell 原样发给 bash。
    // 放在安全时段检查之前：这是本机命令，不应被远程的安全时段规则拦成"封网期"。
    final remoteOs =
        executor is SSHService ? executor.osInfo.toLowerCase() : '';
    final remoteLooksWindows = remoteOs.contains('windows') ||
        remoteOs.contains('mingw') ||
        remoteOs.contains('cygwin');
    if (executor is SSHService &&
        !remoteLooksWindows &&
        looksLikeLocalWindowsCommand(command)) {
      const reason = '检测到 Windows 盘符或 PowerShell 语法，但当前 execute 运行在远程服务器。';
      emitInfo(AgentEvent.info(
          '🖥 ${UiText.t(reason, 'Windows drive letters or PowerShell syntax detected, but this execute runs on the remote server.')}\n${UiText.t('本机命令请改用 local_exec 工具', 'For local commands use the local_exec tool')}: `$command`'));
      return CommandBlock(
        reasonCode: 'local_command_on_remote',
        observation: ReActObservation(
          command: command,
          output: '$reason\n'
              '如果目标在运行 App 的本机，请改用 local_exec 工具（参数 command/cwd）；'
              '如果目标确实是远程服务器，请改用服务器支持的 shell 语法。',
          success: false,
          error: '本机命令误发到远程',
        ).format(),
      );
    }

    // ── 4. 安全时段检查：非 safe 级命令在时段外被拒绝 ──
    final (windowAllowed, windowReason) =
        ChangeWindowService.checkCommand(command);
    if (!windowAllowed) {
      emitInfo(AgentEvent.info(
          '🚫 ${UiText.t('封网期拦截', 'Blocked during change window')}\n${UiText.t('命令', 'Command')}: `$command`\n$windowReason'));
      return CommandBlock(
        reasonCode: 'window_blocked',
        observation: ReActObservation(
          command: command,
          output: '封网期内禁止执行修改性命令（仅允许只读命令）',
          success: false,
          error: windowReason ?? '封网期拦截',
        ).format(),
      );
    }

    // ── 5. 权限档位：只读拒绝、询问/自动确认、全自动放行 ──
    if (decision == CommandGateDecision.reject) {
      // UI 事件按当前语言；observation/审计走规范中文串——reason 会原样
      // 喂回模型，模型上下文里的规范串不随 UI 语言漂移
      final reason =
          SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      final reasonZh =
          SafetyGuard.getReasonZh(command) ?? SafetyGuard.getTipZh(safetyLevel);
      final readOnly = permissionMode == AgentPermissionMode.readOnly;
      emitInfo(AgentEvent.info(
          '🔒 ${readOnly ? UiText.t('只读模式已开启，此命令被拒绝执行', 'Read-only mode is on; this command was not allowed to run') : UiText.t('当前权限模式，此命令被拒绝执行', 'Blocked by the current permission mode; this command was not allowed to run')}: `$command`\n'
          '${L10n.str.ut_cb255683ce(safetyLevel)}\n${L10n.str.ut_ee0b938b2c(reason)}'));
      return CommandBlock(
        reasonCode: readOnly ? 'read_only_blocked' : 'safety_blocked',
        observation: ReActObservation(
          command: command,
          output: readOnly
              ? '只读模式下禁止执行非只读命令（当前等级: $safetyLevel）\n原因: $reasonZh'
              : '当前权限模式禁止执行该命令（当前等级: $safetyLevel）\n原因: $reasonZh',
          success: false,
          error: readOnly ? '只读模式拦截' : reasonZh,
        ).format(),
        // 审计日志：被拦截的 blocked 命令追加记录（执行前已写一条 executed=false）
        auditOutput: safetyLevel == SafetyLevel.blocked ? reasonZh : null,
        auditTag: '拦截分支',
      );
    }

    return null;
  }
}
