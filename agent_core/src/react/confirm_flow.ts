// confirm_flow.ts - port of the dangerous-command / destructive-tool confirmation
// state machine embedded in ai_terminal/lib/services/agent_engine.dart.
//
// Dart keeps this logic inline in the engine (fields at 82-94/132, the shared tool
// gate at 408-444, the command gate at 2631-2725, the tool rejection texts at
// 3412-3439, the wake paths at 699-707 / 931-939 / 1046-1055 and the finish cleanup
// at 3809-3811). It is extracted here into one owner because Node needs the same
// machine reachable from rpc:confirm (src/index.ts), and a second copy of the wake
// rules is exactly how the awaiter gets dropped instead of woken (R1).
//
// The invariants this module exists to keep, quoted from Dart:
//   - "cancelTask / confirmChoice 已经知道怎么处理这个 Completer（R1：从外部取消
//     订阅时必须手动 complete，否则等待方永久挂起）" (405-407). A transient field
//     must be COMPLETED before it is nulled: hasPendingConfirm going false cannot
//     tell "woken" from "dropped", and dropped is the permanent hang.
//   - "超时不是用户拒绝" (2688-2689). Ten minutes of silence is system behaviour;
//     writing it as a user refusal records something the user never did and teaches
//     the model to stop retrying.
//   - generation++ happens in the same frame as the reset, while the await
//     continuation runs later, so the old loop exits at the generation check before
//     it could label the reset a user rejection. That order is load-bearing.
//   - "等确认的墙钟要单独记账：它是人的反应时间，不该进 tok/s 的分母" (430), and it
//     is only credited while the generation is unchanged (434-438).

import {CompleterLike} from "../utils/pending_registry.js";
import {decideCommand, type CommandGateDecision, type SafetyLevel} from "../utils/permission_policy.js";
import {getSafetyReason, getSafetyTip} from "../utils/safety_guard.js";
import type {PermissionMode} from "../rpc/schema.js";

/** Dart: Timer(const Duration(minutes: 10), ...) - 413 and 2642. */
export const CONFIRM_TIMEOUT_MS = 10 * 60 * 1000;

/**
 * Dart 2367-2377. These reasons mean the command was stopped by policy / permission /
 * the user and never actually ran. "步" counting still counts them, which is why they
 * live in one set instead of being incremented per return branch - branches keep
 * getting added, the set does not drift. generation_invalid_during_confirm is
 * deliberately NOT here: that attempt belongs to a superseded task, not to this one.
 */
export const BLOCKED_COMMAND_REASONS = [
  "window_blocked",
  "read_only_blocked",
  "safety_blocked",
  "user_rejected",
  "confirm_timeout",
  "permission_changed_during_confirm",
] as const;
export type BlockedCommandReason = (typeof BLOCKED_COMMAND_REASONS)[number];

export function isBlockedCommandReason(reason: string): boolean {
  return (BLOCKED_COMMAND_REASONS as readonly string[]).includes(reason);
}

/** Reason codes emitted through onSuccess(false, code, 0) - Dart 2678-2718. */
export const CONFIRM_REASON_GENERATION_INVALID = "generation_invalid_during_confirm";
export const CONFIRM_REASON_CANCELLED = "cancelled_during_confirm";
export const CONFIRM_REASON_TIMEOUT = "confirm_timeout";
export const CONFIRM_REASON_USER_REJECTED = "user_rejected";
export const CONFIRM_REASON_PERMISSION_CHANGED = "permission_changed_during_confirm";

/** Wire ids for the confirm round-trip. Dart's UI calls the engine directly, so it has
 * no confirmId; the Node wire (schema/request.schema.json rpc:confirm) requires one, so
 * the flow mints one per wait and the parent must echo it back. */
export type ConfirmOutcomeKind = "generation_invalid" | "cancelled" | "rejected" | "permission_changed" | "proceed";

export interface CommandConfirmOutcome {
  kind: ConfirmOutcomeKind;
  /** Reason code for onSuccess(false, code, 0); absent when the command proceeds. */
  reasonCode: string | null;
  /** Whether the ReAct loop keeps going. False = this task is done (superseded / cancelled). */
  shouldContinue: boolean;
  /** Info-event text, when Dart emits one. */
  info: string | null;
  /** result-event error, when Dart emits a failed result. */
  error: string | null;
  /** Observation text appended to the conversation, when Dart builds one. */
  observation: string | null;
  timedOut: boolean;
}

export interface ConfirmRequestShape {
  confirmId: string;
  prompt: string;
  timeoutMs: number;
  riskLevel?: SafetyLevel;
}

export interface ConfirmFlowContext {
  /** Dart _currentTaskGeneration. */
  currentGeneration(): number;
  /** Dart _permissionMode, re-read after the wait so a mode switch mid-wait is seen. */
  permissionMode(): PermissionMode;
  /** Dart _currentTask?.status == AgentStatus.cancelled. */
  isCancelled(): boolean;
  /** Dart _currentTaskGeneration++ on the cancel/pause wake paths. */
  bumpGeneration(): void;
}

export interface ConfirmFlowEvents {
  onInfo?: (text: string) => void;
  onWaitingConfirm?: (step: string) => void;
  onConfirmRequest?: (req: ConfirmRequestShape) => void;
  onLog?: (level: "info" | "warn", message: string) => void;
}

/** Injectable so tests can prove the timer is cancelled on every path (R2) without
 * waiting ten minutes, and so the timeout path is reachable at all. */
export interface ConfirmTimerHandle {
  cancel(): void;
  readonly hasFired: boolean;
}
export interface ConfirmFlowOptions {
  context: ConfirmFlowContext;
  events?: ConfirmFlowEvents;
  setTimer?: (fn: () => void, ms: number) => ConfirmTimerHandle;
  now?: () => number;
  newConfirmId?: () => string;
}

let confirmIdCounter = 0;
function defaultConfirmId(): string {
  return "confirm_" + ++confirmIdCounter;
}

function realTimer(fn: () => void, ms: number): ConfirmTimerHandle {
  let fired = false;
  let cleared = false;
  const id = setTimeout(() => {
    if (cleared) return;
    fired = true;
    fn();
  }, ms);
  return {
    get hasFired(): boolean {
      return fired;
    },
    cancel(): void {
      cleared = true;
      clearTimeout(id);
    },
  };
}

/** Dart ReActObservation.format() failure branch (agent_model.dart 161-177). A command
 * containing a newline is not backtick-wrapped, so a multi-line tool call cannot make a
 * single-line code span ambiguous. */
export function formatObservationFailure(command: string, error: string): string {
  const BT = String.fromCharCode(96);
  const isMultiline = command.includes("\n");
  const cmdRef = isMultiline ? command : BT + command + BT;
  const NL = "\n";
  return "观测: 命令 " + cmdRef + " 执行失败" + NL + "错误:" + NL + error + NL;
}

/**
 * The confirmation state machine. Exactly one completer at a time, woken by exactly
 * four paths - accept, reject, timeout, and cancel/pause - each of which also cancels
 * the timer (R2: whoever creates the resource owns its cleanup, on every path).
 */
export class ConfirmFlow {
  private readonly ctx: ConfirmFlowContext;
  private readonly ev: ConfirmFlowEvents;
  private readonly setTimer: (fn: () => void, ms: number) => ConfirmTimerHandle;
  private readonly now: () => number;
  private readonly makeConfirmId: () => string;

  private _confirmCompleter: CompleterLike<boolean> | null = null;
  private _confirmTimeoutTimer: ConfirmTimerHandle | null = null;
  private _confirmTimedOut = false;
  private _taskHadConfirmTimeout = false;
  private _pendingConfirmCommand: string | null = null;
  private _pendingConfirmId: string | null = null;
  private _confirmWaitSeconds = 0;
  /** Label captured before the wait is torn down: refusal texts, observations and
   * logs are all produced after _pendingConfirmCommand has been reset. */
  private pendingConfirmLabel: string | null = null;

  constructor(opts: ConfirmFlowOptions) {
    this.ctx = opts.context;
    this.ev = opts.events ?? {};
    this.setTimer = opts.setTimer ?? realTimer;
    this.now = opts.now ?? ((): number => Date.now());
    this.makeConfirmId = opts.newConfirmId ?? defaultConfirmId;
  }

  /** Dart 475-476 hasPendingConfirm. */
  get hasPendingConfirm(): boolean {
    return this._confirmCompleter !== null && !this._confirmCompleter.isDone;
  }

  /** Dart 478-483 pendingConfirmForTesting: the awaiter itself, not just a boolean,
   * because "hasPendingConfirm == false" cannot distinguish woken from dropped. */
  get pendingConfirmForTesting(): CompleterLike<boolean> | null {
    return this._confirmCompleter;
  }

  /** Dart 535 pendingConfirmCommand. */
  get pendingConfirmCommand(): string | null {
    return this._pendingConfirmCommand;
  }

  get pendingConfirmId(): string | null {
    return this._pendingConfirmId;
  }

  /** Dart 132 / 511-514: human reaction time, kept out of the tok/s denominator. */
  get confirmWaitSeconds(): number {
    return this._confirmWaitSeconds;
  }

  resetConfirmWaitSeconds(): void {
    this._confirmWaitSeconds = 0;
  }

  /** Dart 90 / 789: sticky for the whole task, reset only when a task starts. */
  get taskHadConfirmTimeout(): boolean {
    return this._taskHadConfirmTimeout;
  }

  resetTaskHadConfirmTimeout(): void {
    this._taskHadConfirmTimeout = false;
  }

  /** Dart 86 / 2637-2639: the per-wait verdict, cleared at every new wait so a stale
   * true cannot mislabel the next real user refusal as a timeout. */
  get confirmTimedOut(): boolean {
    return this._confirmTimedOut;
  }

  private arm(label: string): string {
    this._pendingConfirmCommand = label;
    // The refusal texts and observations are built after the wait fields have been
    // reset, so the label outlives them by design (Dart reads _pendingConfirmCommand
    // before clearing it; here it is captured instead).
    this.pendingConfirmLabel = label;
    this._confirmCompleter = new CompleterLike<boolean>();
    this._confirmTimedOut = false;
    this._pendingConfirmId = this.makeConfirmId();
    const target = this._confirmCompleter;
    this._confirmTimeoutTimer = this.setTimer(() => {
      if (this._confirmCompleter === target && this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
        this.ev.onLog?.("warn", "确认超时(10min)，自动拒绝: " + label);
        this._confirmTimedOut = true;
        this._taskHadConfirmTimeout = true;
        this._confirmCompleter.resolve(false);
      }
    }, CONFIRM_TIMEOUT_MS);
    return this._pendingConfirmId;
  }

  /** Dart 2633-2665: prepare the dangerous-command wait and announce it. */
  beginDangerousCommand(command: string, safetyLevel: SafetyLevel): {confirmId: string; prompt: string} {
    const mode = this.ctx.permissionMode();
    this.ev.onLog?.("warn", "命令需要确认: " + command + " (模式: " + mode + ")");
    const confirmId = this.arm(command);

    // 显示具体的风险说明，而非泛泛的"危险操作"
    const reason = getSafetyReason(command) ?? getSafetyTip(safetyLevel);
    const highRisk = safetyLevel === "blocked";
    const modeLabel = mode === "ask" ? "询问" : "自动";
    const BT = String.fromCharCode(96);
    const prompt =
      (highRisk ? "\u26d4" : "\u26a0\ufe0f") + " " + (highRisk ? "高危命令" : "高风险命令") +
      "需要确认（" + modeLabel + "模式）: " + BT + command + BT + "\n风险说明: " + reason;
    this.ev.onInfo?.(prompt);
    this.ev.onWaitingConfirm?.("等待确认: " + command);
    this.ev.onConfirmRequest?.({confirmId, prompt, timeoutMs: CONFIRM_TIMEOUT_MS, riskLevel: safetyLevel});
    return {confirmId, prompt};
  }

  /**
   * Dart 2667-2725. Post-wait order is fixed by Dart and must not be reordered:
   * cancel timer -> null timer -> null completer -> null pending -> generation-gated
   * wait accounting -> generation check -> cancelled check -> refusal -> re-validate
   * the permission gate -> proceed.
   */
  async waitForCommandConfirm(myGeneration: number | null, safetyLevel: SafetyLevel): Promise<CommandConfirmOutcome> {
    if (this._confirmCompleter === null) {
      throw new Error("waitForCommandConfirm called with no pending confirm");
    }
    const waitStart = this.now();
    const confirmed = await this._confirmCompleter.promise;
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
    this._confirmCompleter = null;
    this._pendingConfirmCommand = null;
    this._pendingConfirmId = null;
    if (myGeneration === null || myGeneration === this.ctx.currentGeneration()) {
      this._confirmWaitSeconds += Math.trunc((this.now() - waitStart) / 1000);
    }

    if (myGeneration !== null && myGeneration !== this.ctx.currentGeneration()) {
      return {
        kind: "generation_invalid",
        reasonCode: CONFIRM_REASON_GENERATION_INVALID,
        shouldContinue: false,
        info: null,
        error: null,
        observation: null,
        timedOut: false,
      };
    }
    if (this.ctx.isCancelled()) {
      this.ev.onLog?.("info", "任务在等待确认期间被取消");
      return {
        kind: "cancelled",
        reasonCode: CONFIRM_REASON_CANCELLED,
        shouldContinue: false,
        info: null,
        error: null,
        observation: null,
        timedOut: false,
      };
    }

    if (!confirmed) {
      // 超时不是用户拒绝：写成"用户拒绝"会在历史里留下一件用户没做过的事，
      // 也会让模型以为被否决而不再重试。
      const timedOut = this._confirmTimedOut;
      const reason = timedOut ? "确认超时（10 分钟无响应），已自动拒绝" : "用户拒绝执行此命令";
      this.ev.onLog?.("info", reason + ": " + (this.pendingConfirmLabel ?? ""));
      const info = timedOut ? "⏱ " + reason : "\u274c " + reason;
      this.ev.onInfo?.(info);
      const error = timedOut ? "确认超时" : "用户拒绝";
      return {
        kind: "rejected",
        reasonCode: timedOut ? CONFIRM_REASON_TIMEOUT : CONFIRM_REASON_USER_REJECTED,
        shouldContinue: true,
        info,
        error,
        observation: formatObservationFailure(this.pendingConfirmLabel ?? "", reason),
        timedOut,
      };
    }

    // 等待期间用户可能把档位切到只读：重新校验，不能让切换前弹出的确认框
    // 绕过新的安全边界（全自动则本来就无需确认，重新校验仍是 execute）。
    const decision: CommandGateDecision = decideCommand(safetyLevel, this.ctx.permissionMode());
    if (decision === "reject") {
      const reason = "等待确认期间权限档位已切换为只读，命令未执行";
      this.ev.onLog?.("warn", reason);
      const info = "\ud83d\udd12 " + reason;
      this.ev.onInfo?.(info);
      return {
        kind: "permission_changed",
        reasonCode: CONFIRM_REASON_PERMISSION_CHANGED,
        shouldContinue: true,
        info,
        error: "权限档位切换",
        observation: formatObservationFailure(this.pendingConfirmLabel ?? "", reason),
        timedOut: false,
      };
    }

    this.ev.onLog?.("info", "用户确认执行危险命令: " + (this.pendingConfirmLabel ?? ""));
    const info = "\u2705 用户已确认，开始执行...";
    this.ev.onInfo?.(info);
    return {kind: "proceed", reasonCode: null, shouldContinue: true, info, error: null, observation: null, timedOut: false};
  }

  /** Dart 408-444: the destructive-tool wait. Same completer, same 10-minute policy,
   * same wake paths - one waiting mechanism, not two. */
  async confirmToolExecution(toolName: string, display: string): Promise<boolean> {
    this.ev.onLog?.("info", "破坏性工具需要确认: " + toolName);
    const confirmId = this.arm(display);

    this.ev.onInfo?.("⚠\ufe0f 该操作会改动本机文件，需要确认:\n" + display);
    this.ev.onWaitingConfirm?.("等待确认: " + toolName);
    this.ev.onConfirmRequest?.({
      confirmId,
      prompt: "⚠\ufe0f 该操作会改动本机文件，需要确认:\n" + display,
      timeoutMs: CONFIRM_TIMEOUT_MS,
    });

    // 等确认的墙钟要单独记账：它是人的反应时间，不该进 tok/s 的分母。
    const waitStart = this.now();
    const generationAtWait = this.ctx.currentGeneration();
    const confirmed = await this.confirmCompleterOrThrow().promise;
    // 只在仍是同一个任务时计入：切会话时 cancelTask 会补完成这个 future，
    // 把旧任务的等待挂到新任务的计量上是错的。
    if (generationAtWait === this.ctx.currentGeneration()) {
      this._confirmWaitSeconds += Math.trunc((this.now() - waitStart) / 1000);
    }
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
    this._confirmCompleter = null;
    this._pendingConfirmCommand = null;
    this._pendingConfirmId = null;
    this.pendingConfirmLabel = null;
    return confirmed;
  }

  /** Dart 3420-3439: the tool refusal text. Differs from the command refusal by exactly
   * one word (该操作 vs 此命令) - Dart's own test asserts both spellings separately, so
   * neither may be "tidied" into a shared string. */
  toolRefusal(timedOut: boolean): {reason: string; info: string; observation: string} {
    const reason = timedOut ? "确认超时（10 分钟无响应），已自动拒绝" : "用户拒绝执行该操作";
    const info = timedOut ? "⏱ " + reason : "\u274c " + reason;
    const observation =
      "观测: " + reason + "。" +
      (timedOut
        ? "用户可能只是暂时离开，可以重申一次或改用更保守的方案。"
        : "请用 ask 询问用户希望如何进行，或用 finish 结束任务，不要重复尝试。");
    return {reason, info, observation};
  }

  private confirmCompleterOrThrow(): CompleterLike<boolean> {
    if (this._confirmCompleter === null) {
      throw new Error("no pending confirm to await");
    }
    return this._confirmCompleter;
  }

  /** Dart 446-459: collapse a live wait as a timeout. Both timers share this closing
   * logic so "timeout is not a refusal" can actually be verified. */
  expireConfirmTimeoutForTesting(label: string): void {
    if (this._confirmCompleter === null || this._confirmCompleter.isDone) return;
    this.ev.onLog?.("warn", "确认超时(10min)，自动拒绝: " + label);
    this._confirmTimedOut = true;
    this._taskHadConfirmTimeout = true;
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
    this._confirmCompleter.resolve(false);
  }

  /** Dart 1152-1158 confirmDangerousCommand. */
  confirmDangerousCommand(): void {
    if (this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
      this._confirmCompleter.resolve(true);
    }
    this._pendingConfirmCommand = null;
  }

  /** Dart 1160-1166 rejectDangerousCommand. */
  rejectDangerousCommand(): void {
    if (this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
      this._confirmCompleter.resolve(false);
    }
    this._pendingConfirmCommand = null;
  }

  /** Dart 701-707 (cancelTask): complete before nulling; no generation bump here. */
  wakeForCancelTask(): void {
    if (this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
      this._confirmCompleter.resolve(false);
    }
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
    this._confirmCompleter = null;
    this._pendingConfirmCommand = null;
    this._pendingConfirmId = null;
    this.pendingConfirmLabel = null;
  }

  /**
   * Dart 930-939 (terminal cancel): the generation bump happens FIRST, in the same
   * frame as the wake, while the await continuation runs later - so the old loop exits
   * at its generation check and never gets to label this wake a user refusal. Reorder
   * it and history gains a refusal the user never performed (the V3-shaped bug).
   */
  wakeForCancelledFinish(): void {
    this.ctx.bumpGeneration();
    if (this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
      this._confirmCompleter.resolve(false);
    }
    this._pendingConfirmCommand = null;
    // R2: cancel 确认超时定时器，避免 Timer 泄漏
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
  }

  /**
   * Dart 1045-1055 (pauseTask): wake the awaiter, cancel the timer, and deliberately
   * leave the pending label alone. Nulling the completer here instead of completing it
   * is the hang this whole file exists to prevent.
   */
  wakeForPause(): void {
    if (this._confirmCompleter !== null && !this._confirmCompleter.isDone) {
      this._confirmCompleter.resolve(false);
    }
    // R2: 取消确认超时定时器，避免暂停后定时器仍占用资源
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
  }

  /**
   * Dart 3809-3811 (_finishTask): the timer is cancelled, but _confirmCompleter is
   * deliberately NOT cleared - the wait has already been exited before _finishTask
   * runs. Do not "tidy" this into the other wake paths.
   */
  finishCleanup(): void {
    this._confirmTimeoutTimer?.cancel();
    this._confirmTimeoutTimer = null;
  }
}
