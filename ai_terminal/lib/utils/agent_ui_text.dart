import 'package:flutter/widgets.dart';

import '../core/l10n_holder.dart';
import '../l10n/app_localizations.dart';
import '../models/agent_permission_mode.dart';

/// Agent 操作单/计划面板的轻量文案。
///
/// 全部成员走 14 语言 ARB（agentUi* 键）。[zh] 仅供调用点选择全角/半角
/// 标点等排版细节，不再参与文案取值。
class AgentUiText {
  final bool zh;

  const AgentUiText(this.zh);

  factory AgentUiText.of(BuildContext context) {
    return AgentUiText(
      Localizations.localeOf(context).languageCode == 'zh',
    );
  }

  AppLocalizations get _l => L10n.str;

  String get taskRecord => _l.agentUiTaskRecord;
  String get completed => _l.agentUiCompleted;
  String get failed => _l.agentUiFailed;
  String get cancelled => _l.agentUiCancelled;
  String get interrupted => _l.agentUiInterrupted;
  String get planTitle => _l.agentUiPlanTitle;
  String get planByAi => _l.agentUiPlanByAi;
  String get planWarning => _l.agentUiPlanWarning;
  String get conclusion => _l.agentUiConclusion;
  String get verifiedEvidence => _l.agentUiVerifiedEvidence;
  String get aiConclusion => _l.agentUiAiConclusion;
  String get continueTask => _l.agentUiContinueTask;
  String get operationCopied => _l.agentUiOperationCopied;
  String get copyAnswer => _l.agentUiCopyAnswer;
  String get copied => _l.agentUiCopied;
  String get answerCopied => _l.agentUiAnswerCopied;
  String get changesAndRollback => _l.agentUiChangesAndRollback;
  String get auditLog => _l.agentUiAuditLog;
  String itemsCount(int n) => _l.agentUiItemsCount(n);
  String changesCount(int n) => _l.agentUiChangesCount(n);
  String moreChanges(int n) => _l.agentUiMoreChanges(n);
  String get processAndEvidence => _l.agentUiProcessAndEvidence;
  String get fullSummary => _l.agentUiFullSummary;
  String get noEvidence => _l.agentUiNoEvidence;
  String step(int n) => _l.agentUiStep(n);
  // ── 底部指标带 ──
  String roundsCount(int n) => _l.agentUiRoundsCount(n);
  String stepsCount(int n) => _l.agentUiStepsCount(n);
  /// 含估算成分时必须带 `≈`：provider 没给 usage 的那些轮是估出来的，
  /// 把估算说成实测属于失准文案。
  String tokensCount(String n, {required bool estimated}) =>
      _l.agentUiTokensCount(estimated ? '≈' : '', n);
  String tokPerSec(int n) => _l.agentUiTokPerSec(n);
  String cacheHit(int percent) => _l.agentUiCacheHit(percent);
  String contextUsed(int percent) => _l.agentUiContextUsed(percent);
  String get contextHint => _l.agentUiContextHint;
  // ── 目标模式 ──
  String get goalRunning => _l.agentUiGoalRunning;
  String get goalPaused => _l.agentUiGoalPaused;
  String get goalFinished => _l.agentUiGoalFinished;
  String goalRounds(int used, int max) => _l.agentUiGoalRounds(used, max);
  String goalRoundsLeft(int n) => _l.agentUiGoalRoundsLeft(n);
  String get goalEditAction => _l.agentUiGoalEditAction;
  String get goalFinishAction => _l.agentUiGoalFinishAction;
  String get goalClearAction => _l.agentUiGoalClearAction;
  String get goalEditTitle => _l.agentUiGoalEditTitle;
  String get goalFinishTitle => _l.agentUiGoalFinishTitle;
  String get goalFinishBody => _l.agentUiGoalFinishBody;
  String get goalBudgetExhausted => _l.agentUiGoalBudgetExhausted;
  String commandCount(int n) =>
      n == 1 ? _l.agentUiCommandCountOne : _l.agentUiCommandCount(n);
  String get thinkingAndExecution => _l.agentUiThinkingAndExecution;
  String get lessThanOneSecond => _l.agentUiLessThanOneSecond;
  String get agentTask => _l.agentUiAgentTask;
  String get openInTerminal => _l.agentUiOpenInTerminal;
  String get resume => _l.agentUiResume;
  String get pause => _l.agentUiPause;
  String get stop => _l.agentUiStop;
  String get thinking => _l.agentUiThinking;
  String get executing => _l.agentUiExecuting;
  String get waitingConfirm => _l.agentUiWaitingConfirm;
  String get paused => _l.agentUiPaused;
  String get idle => _l.agentUiIdle;
  String successCount(int n) => _l.agentUiSuccessCount(n);
  String planProgress(int done, int total) => _l.agentUiPlanProgress(done, total);
  String get toolCall => _l.agentUiToolCall;
  String get blocked => _l.agentUiBlocked;
  String get needsConfirm => _l.agentUiNeedsConfirm;
  String get executedLabel => _l.agentUiExecutedLabel;
  String get executable => _l.agentUiExecutable;
  String get riskBlocked => _l.agentUiRiskBlocked;
  String get changeImpact => _l.agentUiChangeImpact;
  String get confirmImpact => _l.agentUiConfirmImpact;
  String riskPrefix(String reason) => _l.agentUiRiskPrefix(reason);
  String rollbackPrefix(String command) => _l.agentUiRollbackPrefix(command);
  String get noRollbackSnapshot => _l.agentUiNoRollbackSnapshot;
  String get cancel => _l.agentUiCancel;
  String get confirmExecute => _l.agentUiConfirmExecute;
  String get confirmedLabel => _l.agentUiConfirmedLabel;
  String get confirmedRecord => _l.agentUiConfirmedRecord;
  /// 引擎阶段是中文常量；ARB 里 zh 存原常量、其余语言存译文，
  /// 未知阶段原样透传，null 回退到「思考中」。
  String phase(String? raw) {
    switch (raw) {
      case '理解需求':
        return _l.agentUiPhaseUnderstand;
      case '思考中':
        return _l.agentUiPhaseThink;
      case '执行命令':
        return _l.agentUiPhaseExec;
      case '等待确认':
        return _l.agentUiPhaseWaitConfirm;
      case '验证结果':
        return _l.agentUiPhaseVerify;
      case '等待选择':
        return _l.agentUiPhaseWaitChoice;
      case '执行工具':
        return _l.agentUiPhaseTool;
      case '整理结论':
        return _l.agentUiPhaseSummarize;
      case '执行失败':
        return _l.agentUiPhaseFail;
      case '已取消':
        return _l.agentUiPhaseCancel;
      case '已暂停':
        return _l.agentUiPhasePause;
      case '继续执行':
        return _l.agentUiPhaseResume;
      case null:
        return _l.agentUiThinking;
      default:
        return raw;
    }
  }

  String failureLabel(String? kind) {
    switch (kind) {
      case 'disconnected':
        return _l.agentUiFailureLabelDisconnected;
      case 'timeout':
        return _l.agentUiFailureLabelTimeout;
      case 'permissionDenied':
        return _l.agentUiFailureLabelPermissionDenied;
      case 'interactivePrompt':
        return _l.agentUiFailureLabelInteractivePrompt;
      case 'syntaxError':
        return _l.agentUiFailureLabelSyntaxError;
      case 'cancelled':
        return _l.agentUiFailureLabelCancelled;
      default:
        return _l.agentUiFailed;
    }
  }

  String? failureHint(String? kind) {
    switch (kind) {
      case 'disconnected':
        return _l.agentUiFailureHintDisconnected;
      case 'timeout':
        return _l.agentUiFailureHintTimeout;
      case 'permissionDenied':
        return _l.agentUiFailureHintPermissionDenied;
      case 'interactivePrompt':
        return _l.agentUiFailureHintInteractivePrompt;
      case 'syntaxError':
        return _l.agentUiFailureHintSyntaxError;
      case 'cancelled':
        return _l.agentUiFailureHintCancelled;
      case 'unknown':
        return _l.agentUiFailureHintUnknown;
      default:
        return null;
    }
  }

  String get resultSuccess => _l.agentUiResultSuccess;
  String exitCode(int n) => _l.agentUiExitCode(n);
  String outputLines(int n) => _l.agentUiOutputLines(n);
  String truncated([int? chars]) =>
      chars == null ? _l.agentUiTruncated : _l.agentUiTruncatedChars(chars);
  String failureCount(int n) => _l.agentUiFailureCount(n);
  String planCounts({
    required int total,
    required int completed,
    required int inProgress,
    required int failed,
    required int skipped,
    required int pending,
  }) {
    final parts = <String>[
      _l.agentUiPlanItems(total),
      _l.agentUiPlanDone(completed),
    ];
    if (inProgress > 0) parts.add(_l.agentUiPlanInProgress(inProgress));
    if (failed > 0) parts.add(_l.agentUiPlanFailed(failed));
    if (skipped > 0) parts.add(_l.agentUiPlanSkipped(skipped));
    if (pending > 0) parts.add(_l.agentUiPlanPending(pending));
    return parts.join(' · ');
  }

  String expandAll(int n) => _l.agentUiExpandAll(n);
  // ── 本地文件访问授权（设置 → Agent） ──
  String get localFileSection => _l.agentUiLocalFileSection;
  String get localFileEnable => _l.agentUiLocalFileEnable;
  String get localFileDirs => _l.agentUiLocalFileDirs;
  String get localFileAddDir => _l.agentUiLocalFileAddDir;
  String get localFileRemoveDir => _l.agentUiLocalFileRemoveDir;
  String get localFilePickTitle => _l.agentUiLocalFilePickTitle;
  String get localFileNoDirs => _l.agentUiLocalFileNoDirs;
  String get localFileBlacklistHint => _l.agentUiLocalFileBlacklistHint;
  // ── 回收区（local_file_delete 的副本）──
  String localFileTrashLabel(int count, String size) =>
      _l.agentUiLocalFileTrashLabel(count, size);
  String get localFileTrashEmpty => _l.agentUiLocalFileTrashEmpty;
  String get localFileTrashClear => _l.agentUiLocalFileTrashClear;
  String localFileTrashClearBody(int count, String size, int records) =>
      _l.agentUiLocalFileTrashClearBody(count, size, records);
  String localFileTrashCleared(int count, String size) =>
      _l.agentUiLocalFileTrashCleared(count, size);
  String get localFileTrashClearRefused => _l.agentUiLocalFileTrashClearRefused;
  String localFileTrashClearFailed(int count) => _l.agentUiLocalFileTrashClearFailed(count);
  // ── local_exec 目录授权 ──
  String get localExecAuthTitle => _l.agentUiLocalExecAuthTitle;
  String localExecAuthBody(String path, String reason, bool willCreate) =>
      _l.agentUiLocalExecAuthHead(path) +
      _l.agentUiLocalExecAuthReason(reason) +
      (willCreate ? _l.agentUiLocalExecAuthCreateLine : '') +
      _l.agentUiLocalExecAuthGrant;

  String get localExecAuthNote => _l.agentUiLocalExecAuthNote;
  String get localExecAuthAllow => _l.agentUiLocalExecAuthAllow;
  String localExecAuthorized(String path) => _l.agentUiLocalExecAuthorized(path);
  // ── 过程时间线 ──
  String get commandLabel => _l.agentUiCommandLabel;
  String get pendingLabel => _l.agentUiPendingLabel;
  String get toolDoneLabel => _l.agentUiToolDoneLabel;
  String get failedLabel => _l.agentUiFailedLabel;
  String get processFolded => _l.agentUiProcessFolded;
  String get collapseProcess => _l.agentUiCollapseProcess;
  String get expandProcess => _l.agentUiExpandProcess;
  String get collapse => _l.agentUiCollapse;
  String get expandText => _l.agentUiExpandText;
  String get viewFullOutput => _l.agentUiViewFullOutput;
  String toolCallsCount(int n) => _l.agentUiToolCallsCount(n);
  String commandCallsCount(int n) => _l.agentUiCommandCallsCount(n);
  String moreSteps(int n) => _l.agentUiMoreSteps(n);
  /// 折叠头要写清"藏了什么"：只报命令数时，用户不知道点开是 3 行还是 1 万行。
  String thoughtCount(int n) =>
      n == 1 ? _l.agentUiThoughtCountOne : _l.agentUiThoughtCount(n);
  String logCount(int n) => n == 1 ? _l.agentUiLogCountOne : _l.agentUiLogCount(n);
  String progressLines(int n) => _l.agentUiProgressLines(n);
  String get expandEach => _l.agentUiExpandEach;
  String turnLabel(int n) => _l.agentUiTurnLabel(n);
  String moreActions(int n) => _l.agentUiMoreActions(n);
  String failedCommands(int n) => _l.agentUiFailedCommands(n);
  String moreOutputLines(int n) => _l.agentUiMoreOutputLines(n);
  // ── 执行权限档位 ──
  String get permissionModeTitle => _l.agentUiPermissionModeTitle;
  String permissionModeLabel(AgentPermissionMode mode) =>
      switch (mode) {
        AgentPermissionMode.readOnly => _l.agentUiPermLabelReadOnly,
        AgentPermissionMode.ask => _l.agentUiPermLabelAsk,
        AgentPermissionMode.auto => _l.agentUiPermLabelAuto,
        AgentPermissionMode.fullAuto => _l.agentUiPermLabelFullAuto,
      };

  String permissionModeDescription(AgentPermissionMode mode) =>
      switch (mode) {
        AgentPermissionMode.readOnly => _l.agentUiPermDescReadOnly,
        AgentPermissionMode.ask => _l.agentUiPermDescAsk,
        AgentPermissionMode.auto => _l.agentUiPermDescAuto,
        AgentPermissionMode.fullAuto => _l.agentUiPermDescFullAuto,
      };

  String get permissionAllowed => _l.agentUiPermissionAllowed;
  String get permissionNotExecuted => _l.agentUiPermissionNotExecuted;
  String get permissionModeFullAutoWarningTitle => _l.agentUiPermFullAutoWarningTitle;
  String get permissionModeFullAutoWarningBody => _l.agentUiPermFullAutoWarningBody;
  String get permissionModeEnable => _l.agentUiPermissionEnable;
  String permissionModeCurrent(String mode) => _l.agentUiPermissionModeCurrent(mode);
  String get permissionModeUsage => _l.agentUiPermissionModeUsage;
  String permissionModeSwitched(String mode, String desc) =>
      _l.agentUiPermissionModeSwitched(mode, desc);
}
