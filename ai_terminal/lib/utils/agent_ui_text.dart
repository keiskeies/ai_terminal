import 'package:flutter/widgets.dart';
import '../models/agent_permission_mode.dart';

/// Agent 操作单/计划面板的轻量文案。
///
/// 这些标签是 v1.3.7 新增界面，尚未进入 14 语言 ARB；先覆盖中文/英文，
/// 其它语言回退英文，避免英文界面出现中英混排。
class AgentUiText {
  final bool zh;

  const AgentUiText(this.zh);

  factory AgentUiText.of(BuildContext context) {
    return AgentUiText(
      Localizations.localeOf(context).languageCode == 'zh',
    );
  }

  String get taskRecord => zh ? '任务记录' : 'Task record';
  String get completed => zh ? '完成' : 'Completed';
  String get failed => zh ? '失败' : 'Failed';
  String get cancelled => zh ? '已取消' : 'Cancelled';
  String get interrupted => zh ? '已中断' : 'Interrupted';

  String get planTitle => zh ? '执行清单' : 'Execution Plan';
  String get planByAi => zh ? 'AI 计划' : 'AI plan';
  String get planWarning => zh
      ? '计划仍有未收尾步骤，请核对是否全部完成'
      : 'Some plan steps are still open. Please verify the task is complete.';

  String get conclusion => zh ? '结论' : 'Conclusion';
  String get verifiedEvidence => zh ? '有验证证据' : 'Verified evidence';
  String get aiConclusion => zh ? 'AI 结论' : 'AI conclusion';
  String get continueTask => zh ? '继续任务' : 'Continue task';
  String get operationCopied => zh ? '操作单已复制' : 'Operation sheet copied';
  String get copyAnswer => zh ? '复制回答' : 'Copy answer';
  String get answerCopied => zh ? '回答已复制到剪贴板' : 'Answer copied';

  String get changesAndRollback => zh ? '变更与回滚' : 'Changes & rollback';
  String get auditLog => zh ? '审计记录' : 'Audit log';
  String itemsCount(int n) => zh ? '$n 项' : '$n items';
  String changesCount(int n) => zh ? '$n 项变更' : '$n changes';
  String moreChanges(int n) =>
      zh ? '还有 $n 项变更，详见审计记录' : '$n more changes — see audit log';

  String get processAndEvidence => zh ? '过程与证据' : 'Process & evidence';
  String get fullSummary => zh ? '完整总结' : 'Full summary';
  String get noEvidence =>
      zh ? '没有可展开的执行记录' : 'No execution records to expand';

  String step(int n) => zh ? '第 $n 步' : 'Step $n';

  // ── 底部指标带 ──
  String roundsCount(int n) => zh ? '$n 轮' : '$n rounds';
  String stepsCount(int n) => zh ? '$n 步' : '$n steps';

  /// 含估算成分时必须带 `≈`：provider 没给 usage 的那些轮是估出来的，
  /// 把估算说成实测属于失准文案。
  String tokensCount(String n, {required bool estimated}) =>
      zh ? '${estimated ? '≈' : ''}$n tok' : '${estimated ? '≈' : ''}$n tok';
  String tokPerSec(int n) => zh ? '$n tok/s' : '$n tok/s';
  String cacheHit(int percent) =>
      zh ? '缓存命中 $percent%' : 'cache hit $percent%';
  String contextUsed(int percent) => zh ? '上下文 $percent%' : 'ctx $percent%';
  String get contextHint => zh
      ? '上下文占用；超过 70% 后引擎会开始丢弃最早的消息'
      : 'Context usage. Above 70% the engine starts dropping the earliest messages.';

  // ── 目标模式 ──
  String get goalRunning => zh ? '进行中的目标' : 'Active goal';
  String get goalPaused => zh ? '已暂停的目标' : 'Paused goal';
  String get goalFinished => zh ? '已结束的目标' : 'Finished goal';
  String goalRounds(int used, int max) => zh ? '轮次 $used/$max' : 'rounds $used/$max';
  String goalRoundsLeft(int n) => zh ? '剩 $n 轮' : '$n left';
  String get goalEditAction => zh ? '编辑目标' : 'Edit goal';
  String get goalFinishAction => zh ? '结束目标' : 'Finish goal';
  String get goalClearAction => zh ? '清除记录' : 'Clear record';
  String get goalEditTitle => zh ? '编辑目标' : 'Edit goal';
  String get goalFinishTitle => zh ? '结束这个目标？' : 'Finish this goal?';
  String get goalFinishBody => zh
      ? '目标会被标记为结束，正在运行的任务不受影响。'
      : 'The goal is marked finished. A running task is not affected.';
  String get goalBudgetExhausted => zh ? '轮次已用尽' : 'Round budget used up';
  String commandCount(int n) =>
      zh ? '$n 条命令' : (n == 1 ? '1 command' : '$n commands');
  String get thinkingAndExecution =>
      zh ? '思考与执行记录' : 'Thinking & execution log';
  String get lessThanOneSecond => zh ? '不足 1s' : '<1s';
  String get agentTask => zh ? 'Agent 任务' : 'Agent task';
  String get openInTerminal => zh ? '在终端查看' : 'Open in terminal';
  String get resume => zh ? '恢复' : 'Resume';
  String get pause => zh ? '暂停' : 'Pause';
  String get stop => zh ? '停止' : 'Stop';
  String get thinking => zh ? '思考中' : 'Thinking';
  String get executing => zh ? '执行中' : 'Executing';
  String get waitingConfirm => zh ? '等待确认' : 'Waiting for confirmation';
  String get paused => zh ? '已暂停' : 'Paused';
  String get idle => zh ? '就绪' : 'Idle';
  String successCount(int n) => zh ? '$n 成功' : '$n succeeded';
  String planProgress(int done, int total) =>
      zh ? '计划 $done/$total' : 'Plan $done/$total';

  String get toolCall => zh ? '工具调用' : 'Tool call';
  String get blocked => zh ? '已拦截' : 'Blocked';
  String get needsConfirm => zh ? '需确认' : 'Needs confirmation';
  String get executedLabel => zh ? '已运行' : 'Executed';
  String get executable => zh ? '可执行' : 'Ready';
  String get riskBlocked =>
      zh ? '该命令已被安全策略拦截' : 'Blocked by the safety policy';
  String get changeImpact => zh ? '变更影响' : 'Change impact';
  String get confirmImpact => zh ? '执行前请确认影响' : 'Review impact before running';
  String riskPrefix(String reason) => zh ? '风险：$reason' : 'Risk: $reason';
  String rollbackPrefix(String command) =>
      zh ? '回滚：$command' : 'Rollback: $command';
  String get noRollbackSnapshot =>
      zh ? '回滚：无自动回滚，建议先快照' : 'Rollback: no automatic rollback; snapshot first';
  String get cancel => zh ? '取消' : 'Cancel';
  String get confirmExecute => zh ? '确认执行' : 'Run';

  /// 引擎阶段是中文常量；英文环境映射到对应英文。
  String phase(String? raw) {
    if (zh) return raw ?? thinking;
    const map = {
      '理解需求': 'Understanding request',
      '思考中': 'Thinking',
      '执行命令': 'Executing command',
      '等待确认': 'Waiting for confirmation',
      '验证结果': 'Verifying result',
      '等待选择': 'Waiting for choice',
      '执行工具': 'Running tool',
      '整理结论': 'Summarizing',
      '执行失败': 'Failed',
      '已取消': 'Cancelled',
      '已暂停': 'Paused',
      '继续执行': 'Resuming',
    };
    return map[raw] ?? raw ?? thinking;
  }

  String failureLabel(String? kind) {
    if (zh) {
      switch (kind) {
        case 'disconnected': return '连接已断开';
        case 'timeout': return '执行超时';
        case 'permissionDenied': return '权限不足';
        case 'interactivePrompt': return '等待输入';
        case 'syntaxError': return '命令语法错误';
        case 'cancelled': return '已取消';
        default: return failed;
      }
    }
    switch (kind) {
      case 'disconnected': return 'Disconnected';
      case 'timeout': return 'Timed out';
      case 'permissionDenied': return 'Permission denied';
      case 'interactivePrompt': return 'Waiting for input';
      case 'syntaxError': return 'Syntax error';
      case 'cancelled': return 'Cancelled';
      default: return failed;
    }
  }

  String? failureHint(String? kind) {
    if (zh) {
      switch (kind) {
        case 'disconnected': return '连接已断开。建议先重连服务器，再重试本步。';
        case 'timeout': return '执行超时。建议延长超时，或把命令拆小后重试。';
        case 'permissionDenied': return '权限不足。建议使用 sudo 重试，或更换有权限的用户。';
        case 'interactivePrompt': return '命令在等待输入。建议改用非交互参数（如 -y / --batch）后重试。';
        case 'syntaxError': return '命令语法错误，未执行。建议修正命令后重试。';
        case 'cancelled': return '执行已取消。可以重新发起本步。';
        case 'unknown': return '执行失败。建议查看输出后修正并重试。';
        default: return null;
      }
    }
    switch (kind) {
      case 'disconnected':
        return 'Connection lost. Reconnect the server, then retry this step.';
      case 'timeout':
        return 'Command timed out. Increase the timeout or split it into smaller steps.';
      case 'permissionDenied':
        return 'Permission denied. Retry with sudo or use an account with the required access.';
      case 'interactivePrompt':
        return 'The command is waiting for input. Use non-interactive flags such as -y or --batch.';
      case 'syntaxError':
        return 'The command was not executed due to a syntax error. Fix it and retry.';
      case 'cancelled':
        return 'Execution was cancelled. You can start this step again.';
      case 'unknown':
        return 'Execution failed. Review the output, fix the command and retry.';
      default:
        return null;
    }
  }

  String get resultSuccess => zh ? '执行成功' : 'Succeeded';
  String exitCode(int n) => zh ? '退出码 $n' : 'Exit $n';
  String outputLines(int n) => zh ? '$n 行' : '$n lines';
  String truncated([int? chars]) => chars == null
      ? (zh ? '已截断' : 'Truncated')
      : (zh ? '已截断 $chars 字符' : 'Truncated · $chars chars');
  String failureCount(int n) => zh ? '$n 失败' : '$n failed';

  String planCounts({
    required int total,
    required int completed,
    required int inProgress,
    required int failed,
    required int skipped,
    required int pending,
  }) {
    final parts = <String>[
      zh ? '$total 项' : '$total items',
      zh ? '$completed 完成' : '$completed done',
    ];
    if (inProgress > 0) {
      parts.add(zh ? '$inProgress 进行中' : '$inProgress in progress');
    }
    if (failed > 0) parts.add(zh ? '$failed 失败' : '$failed failed');
    if (skipped > 0) parts.add(zh ? '$skipped 跳过' : '$skipped skipped');
    if (pending > 0) parts.add(zh ? '$pending 待处理' : '$pending pending');
    return parts.join(' · ');
  }

  String expandAll(int n) => zh ? '展开全部 $n 项' : 'Show all $n';

  // ── 本地文件访问授权（设置 → Agent） ──
  String get localFileSection =>
      zh ? '本地文件访问' : 'Local file access';
  String get localFileEnable =>
      zh ? '允许 Agent 读写本机文件' : 'Let the agent read and write local files';
  String get localFileEnableDesc => zh
      ? '开启后，Agent 可使用 local_file_read / local_file_write 等工具操作这台电脑上的文件。'
          'SSH 会话里的 local_exec 也使用这份目录授权。'
          '未添加授权目录时，任何本机文件或本机命令操作都会被拒绝。'
      : 'When enabled, the agent can use local_file_read / local_file_write and friends on this computer. '
          'local_exec in SSH sessions also uses this folder authorization. '
          'With no authorized folders, every local file or local command operation is refused.';
  String get localFileDirs => zh ? '授权目录' : 'Authorized folders';
  String get localFileAddDir => zh ? '添加目录' : 'Add folder';
  String get localFileRemoveDir => zh ? '移除该目录' : 'Remove this folder';
  String get localFilePickTitle =>
      zh ? '选择允许 Agent 访问的目录' : 'Choose a folder the agent may access';
  String get localFileNoDirs =>
      zh ? '尚未授权任何目录' : 'No folders authorized yet';
  String get localFileBlacklistHint => zh
      ? '注意：即使目录已授权，密钥与凭据类文件（~/.ssh、*.key、*.pem、.env 等）仍被禁止访问。'
      : 'Note: even inside an authorized folder, key and credential files '
          '(~/.ssh, *.key, *.pem, .env, …) stay off limits.';

  // ── 回收区（local_file_delete 的副本）──
  String localFileTrashLabel(int count, String size) => zh
      ? '回收区：$count 项 · 约 $size'
      : 'Trash: $count items · ~$size';
  String get localFileTrashEmpty => zh ? '回收区为空' : 'Trash is empty';
  String get localFileTrashClear => zh ? '清空回收区' : 'Empty trash';
  String localFileTrashClearBody(int count, String size, int records) => zh
      ? '清空会永久删除这 $count 项副本（约 $size）。'
          '之后 $records 条改动记录将无法再还原（记录本身保留，只是捞不回文件）。'
      : 'This permanently deletes $count saved copies (~$size). '
          '$records change records will no longer be restorable '
          '(the records stay, the files do not).';
  String localFileTrashCleared(int count, String size) => zh
      ? '已清空回收区：删除 $count 项，释放约 $size'
      : 'Trash emptied: $count items removed, ~$size freed';
  String get localFileTrashClearRefused => zh
      ? '有路径不在回收区内，已跳过未删除'
      : 'Some paths are outside the trash and were skipped';
  String localFileTrashClearFailed(int count) => zh
      ? '$count 项删除失败（可能被其它程序占用）'
      : '$count items could not be deleted (maybe locked by another app)';

  // ── local_exec 目录授权 ──
  String get localExecAuthTitle =>
      zh ? '允许本机目录访问？' : 'Allow local folder access?';
  String localExecAuthBody(String path, String reason, bool willCreate) => zh
      ? 'Agent 需要在本机目录执行命令：\n$path\n\n'
          '原因：$reason\n\n'
          '${willCreate ? '该目录不存在，允许后将创建。\n' : ''}'
          '允许后会开启本地文件访问并授权该目录。'
      : 'The agent needs to run a command in this local folder:\n$path\n\n'
          'Reason: $reason\n\n'
          '${willCreate ? 'The folder does not exist and will be created.\n' : ''}'
          'Allowing this enables local file access and authorizes the folder.';
  String get localExecAuthNote => zh
      ? '敏感路径（~/.ssh、.env、密钥等）仍然禁止访问。'
      : 'Sensitive paths (~/.ssh, .env, keys) remain blocked.';
  String get localExecAuthAllow => zh ? '允许并继续' : 'Allow and continue';
  String localExecAuthorized(String path) =>
      zh ? '已授权本机目录：$path' : 'Local folder authorized: $path';

  // ── 过程时间线 ──
  String get commandLabel => zh ? '终端命令' : 'Command';
  String get pendingLabel => zh ? '待执行' : 'Pending';
  String get toolDoneLabel => zh ? '已调用' : 'Called';
  String get failedLabel => zh ? '失败' : 'Failed';
  String get processFolded => zh ? '过程已折叠' : 'Process folded';
  String get collapseProcess => zh ? '展开过程' : 'Show process';
  String get expandProcess => zh ? '展开' : 'Expand';
  String get collapse => zh ? '收起' : 'Collapse';
  String get viewFullOutput => zh ? '查看完整输出' : 'View full output';
  String toolCallsCount(int n) => zh ? '已调用工具 $n 次' : '$n tool calls';
  String commandCallsCount(int n) => zh ? '$n 条命令' : '$n commands';
  String moreSteps(int n) => zh ? '更早 $n 步' : '$n earlier steps';
  String moreOutputLines(int n) => zh ? '还有 $n 行' : '$n more lines';

  // ── 执行权限档位 ──
  String get permissionModeTitle => zh ? '执行权限' : 'Execution permission';

  String permissionModeLabel(AgentPermissionMode mode) {
    switch (mode) {
      case AgentPermissionMode.readOnly:
        return zh ? '只读' : 'Read-only';
      case AgentPermissionMode.ask:
        return zh ? '询问' : 'Ask';
      case AgentPermissionMode.auto:
        return zh ? '自动' : 'Auto';
      case AgentPermissionMode.fullAuto:
        return zh ? '全自动' : 'Full auto';
    }
  }

  String permissionModeDescription(AgentPermissionMode mode) {
    switch (mode) {
      case AgentPermissionMode.readOnly:
        return zh ? '只允许只读命令，任何修改都会被拒绝' : 'Only read-only commands; changes are refused';
      case AgentPermissionMode.ask:
        return zh ? '修改类与高危命令都先询问你' : 'Ask before changes and high-risk commands';
      case AgentPermissionMode.auto:
        return zh ? '普通修改自动执行，高危命令仍会询问' : 'Run normal changes automatically; ask for high-risk ones';
      case AgentPermissionMode.fullAuto:
        return zh
            ? '高危命令也自动执行；封网期与敏感文件限制仍生效'
            : 'High-risk commands run automatically; change windows and sensitive-file guards still apply';
    }
  }

  String get permissionAllowed => zh ? '已放行' : 'Allowed';
  String get permissionNotExecuted => zh ? '未执行' : 'Not run';
  String get permissionModeFullAutoWarningTitle =>
      zh ? '启用全自动模式？' : 'Enable full-auto mode?';
  String get permissionModeFullAutoWarningBody => zh
      ? 'Agent 将不再逐条确认，直接执行包括删除系统配置、格式化磁盘在内的所有命令。'
          '部分操作不可恢复；封网期与敏感文件限制仍会生效，请确认你了解影响范围。'
      : 'The agent will stop asking and run every command, including deleting system '
          'configuration and formatting disks. Some operations cannot be undone. '
          'Change windows and sensitive-file guards still apply.';
  String get permissionModeEnable => zh ? '启用' : 'Enable';

  String permissionModeCurrent(String mode) =>
      zh ? '当前权限模式：$mode' : 'Current permission mode: $mode';
  String get permissionModeUsage =>
      zh ? '用法：/permission <只读|询问|自动|全自动>' : 'Usage: /permission <read|ask|auto|full>';
  String permissionModeSwitched(String mode, String desc) =>
      zh ? '已切换到「$mode」：$desc' : 'Switched to $mode: $desc';

}
