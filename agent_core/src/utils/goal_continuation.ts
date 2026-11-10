/**
 * Goal-mode continuation decisions, ported 1:1 from
 * lib/utils/goal_continuation.dart (255 lines).
 *
 * Pure functions on purpose - the doc comment in Dart says the same thing and
 * for the same reason: runaway auto-continuation is the single biggest risk of
 * this feature, and the branches (disconnect, timeout, budget exhausted at
 * exactly the wrong moment) are near-impossible to hit deliberately on a real
 * device.
 *
 * decideGoalContinuation() is a pure function, so Dart's DateTime.now() inside
 * it is reproduced as new Date() rather than injected. No parameter was added
 * for a clock: a port that changes the signature is not a port. The consequence
 * is that updatedAt is not pinned by tests - tests assert the fields the
 * decision is made of and that updatedAt moved forward, nothing more.
 *
 * Dart string interpolation is spelled as concatenation here, and the CJK
 * literals are byte-for-byte the Dart ones: test/goal_continuation.test.ts
 * extracts the literals out of the Dart source and compares them, so a
 * reworded note on either side turns the build red instead of silently
 * splitting the user-facing text in two languages.
 */

// Type-only import: the finish-state union lives in rpc/schema.ts (it is the
// wire contract), and nothing here needs a runtime value from it.
import type {AgentFinishState} from "../rpc/schema.js";
import {AgentGoal, AGENT_GOAL_STATUSES} from "./agent_goal.js";

export {AGENT_GOAL_STATUSES, AgentGoal};
export type {AgentGoalStatus} from "./agent_goal.js";

/** 续跑决策的结果类型。 Port of Dart enum GoalAction. */
export const GOAL_ACTIONS = ["continueRound", "finish", "pause"] as const;
export type GoalAction = (typeof GOAL_ACTIONS)[number];

export class GoalDecision {
  readonly action: GoalAction;
  /** 决策后的目标状态（含 roundsUsed / lastStepIndex 等推进），调用方直接落盘 */
  readonly goal: AgentGoal;
  /** 给用户看的原因；continueRound 时为 null */
  readonly note: string | null;
  /** 本轮决策依据，用于测试与日志 */
  readonly reason: string;

  constructor(init: {action: GoalAction; goal: AgentGoal; reason: string; note?: string | null}) {
    this.action = init.action;
    this.goal = init.goal;
    this.reason = init.reason;
    this.note = init.note ?? null;
  }
}

/** 模型在回答里声明目标达成的标记（出现在行首即算） */
export const GOAL_DONE_MARKER = "目标已达成";

/**
 * 整条“命令”其实只是达成标记。
 *
 * 真机复拍发现：模型会把「目标已达成」写进 命令: 块，于是被丢进 shell，
 * 得到一条 CommandNotFoundException。提示词只能降低概率，挡不住，
 * 所以执行侧必须有一道硬守卫。
 *
 * The Dart character class strips quote-ish and bracket-ish punctuation plus
 * the CJK punctuation that models sprinkle around the marker. Same characters,
 * same order; the backtick is spelled by codepoint so this file stays free of
 * template-literal noise, not because the class differs.
 *
 * Dart's RegExp is RE2. This class holds literal characters only - no
 * shorthand, no ranges, no anchors - so RE2 and V8 agree on it, which is not
 * true of the whitespace classes in safety_guard.ts. The global flag is what
 * makes replace() mean Dart's replaceAll().
 */
const MARKER_STRIP_CLASS =
  "[" +
  '"' +
  "'" +
  String.fromCharCode(96) +
  // Dart writes these escaped inside its raw literal; a JS class needs the same
  // escapes or the class terminates early.
  "()\\[\\]" +
  "\u3010\u3011\u300c\u300d\u300e\u300f" +
  "\u3002\uff0c,\uff1a:\uff1b;\uff01!" +
  "]";

export const GOAL_MARKER_STRIP_PATTERN = MARKER_STRIP_CLASS;

/** 判断一轮的收尾文本是否声明了目标达成。 */
export function isGoalMarkerOnlyCommand(command: string): boolean {
  const stripped = command.replace(new RegExp(MARKER_STRIP_CLASS, "g"), "").trim();
  return stripped.length > 0 && stripped === GOAL_DONE_MARKER;
}

/**
 * 判断一轮的收尾文本是否声明了目标达成。
 *
 * 要求出现在**行首**，避免模型在正文里引述这句话就误判完成。
 *
 * split is on a bare LF in both runtimes: Dart splits on the single character
 * "\n" and so does this, which means a CRLF summary leaves a trailing CR on the
 * line - trimLeft() does not remove it, but startsWith() only inspects the head,
 * so the verdict is the same on both sides.
 */
export function goalMarkedDone(summary: string | null): boolean {
  if (summary === null) return false;
  for (const line of summary.split("\n")) {
    if (line.trimStart().startsWith(GOAL_DONE_MARKER)) return true;
  }
  return false;
}

/**
 * 目标模式的续跑决策——设计文档 §3.2.4 的终态矩阵，纯函数。
 *
 * 判定顺序即优先级，**不可重排**：用户取消必须排在预算检查之前，
 * 否则“取消后预算还剩”会被当成“还能继续”而复活。
 */
export function decideGoalContinuation(opts: {
  goal: AgentGoal;
  finishState: AgentFinishState | null;
  /** 本轮实际执行的命令数（成功+失败），无进展判定的依据 */
  commandsRun: number;
  hadConfirmTimeout: boolean;
  connectionAlive: boolean;
  isForegroundHost: boolean;
  finishSummary: string | null;
}): GoalDecision {
  const {goal, finishState, commandsRun, hadConfirmTimeout, connectionAlive, isForegroundHost, finishSummary} = opts;

  // 1. 模型显式声明达成
  if (goalMarkedDone(finishSummary)) {
    return new GoalDecision({
      action: "finish",
      reason: "objective_done",
      goal: goal.copyWith({
        status: "finished",
        note: "模型声明目标已达成",
        updatedAt: new Date(),
      }),
    });
  }

  // 2. 用户点停止：绝不自动复活
  if (finishState === "cancelled") {
    return new GoalDecision({
      action: "pause",
      reason: "user_cancelled",
      note: "你停止了任务，目标已暂停",
      goal: goal.copyWith({
        status: "paused",
        note: "你停止了任务，目标已暂停",
        updatedAt: new Date(),
      }),
    });
  }

  // 3. 人不在看管：确认超时说明没人批准，继续跑只会反复超时空转
  if (hadConfirmTimeout) {
    return new GoalDecision({
      action: "pause",
      reason: "confirm_timeout",
      note: "有操作因超时未获确认被自动拒绝，目标已暂停",
      goal: goal.copyWith({
        status: "paused",
        note: "有操作因超时未获确认被自动拒绝，目标已暂停",
        updatedAt: new Date(),
      }),
    });
  }

  // 4. 执行环境异常：连接断了或会话已切走，此时发任务只会失败或跑错机器
  if (!connectionAlive) {
    return new GoalDecision({
      action: "pause",
      reason: "disconnected",
      note: "终端连接已断开，目标已暂停",
      goal: goal.copyWith({
        status: "paused",
        note: "终端连接已断开，目标已暂停",
        updatedAt: new Date(),
      }),
    });
  }
  if (!isForegroundHost) {
    return new GoalDecision({
      action: "pause",
      reason: "not_foreground",
      note: "已切到其他会话，回到本会话后恢复目标",
      goal: goal.copyWith({
        status: "paused",
        note: "已切到其他会话，回到本会话后恢复目标",
        updatedAt: new Date(),
      }),
    });
  }

  // 5. 硬止损：预算耗尽。放在“失败”之前——预算没了就该结束而不是暂停等恢复
  if (goal.budgetExhausted) {
    return new GoalDecision({
      action: "finish",
      reason: "budget_exhausted",
      note: "轮次预算耗尽（" + goal.roundsUsed + "/" + goal.maxRounds + "）",
      goal: goal.copyWith({
        status: "finished",
        note: "轮次预算耗尽（" + goal.roundsUsed + "/" + goal.maxRounds + "）",
        updatedAt: new Date(),
      }),
    });
  }

  // 6. 任务异常终止：继续跑就是烧 token
  if (finishState === "failed") {
    return new GoalDecision({
      action: "pause",
      reason: "task_failed",
      note: "上一轮任务失败，目标已暂停",
      goal: goal.copyWith({
        status: "paused",
        note: "上一轮任务失败，目标已暂停",
        updatedAt: new Date(),
      }),
    });
  }

  // 7. 无进展检测：这一轮一条命令都没执行，说明模型只是又想了想、没动手。
  //    曾用“步数是否比上一轮多”判定，但 stepIndex 是每个任务各自从 1 计的，
  //    跨轮比较必然误判——真机复拍里两轮各跑 4 条命令就被判成“连续无进展”暂停了。
  const progressed = commandsRun > 0;
  const noProgressRounds = progressed ? 0 : goal.noProgressRounds + 1;
  if (noProgressRounds >= 2) {
    return new GoalDecision({
      action: "pause",
      reason: "no_progress",
      note: "连续 " + noProgressRounds + " 轮没有新进展，目标已暂停",
      goal: goal.copyWith({
        status: "paused",
        noProgressRounds,
        lastRoundCommands: commandsRun,
        note: "连续 " + noProgressRounds + " 轮没有新进展，目标已暂停",
        updatedAt: new Date(),
      }),
    });
  }

  // 8. 正常续跑：success（本轮收尾）与 interrupted（步数用满）都算有进展
  return new GoalDecision({
    action: "continueRound",
    reason: progressed ? "progress" : "continue",
    goal: goal.copyWith({
      roundsUsed: goal.roundsUsed + 1,
      lastRoundCommands: commandsRun,
      noProgressRounds,
      clearNote: true,
      updatedAt: new Date(),
    }),
  });
}
/**
 * 是否真的要把续跑任务排上去。三个 provider 侧的守卫，抽出来是为了可测：
 *
 * - 目标必须仍然活跃（用户可能在决策与执行之间点了暂停）；
 * - 同一个终局任务只许续跑一次——取消与异常路径可能连着发出两个 finish 事件，
 *   不去重就会一次结束起两个任务；
 * - 引擎正在跑就不抢跑（startTask 自己也会拒，但那里的拒绝会写成一条
 *   “Agent 正在执行任务”的错误，用户看到的是莫名其妙的报错）。
 */
export function shouldScheduleGoalRound(opts: {
  goal: AgentGoal | null;
  finishingTaskId: string | null;
  alreadyContinuedTaskId: string | null;
  engineRunning: boolean;
}): boolean {
  const {goal, finishingTaskId, alreadyContinuedTaskId, engineRunning} = opts;
  if (goal?.isActive !== true) return false;
  if (finishingTaskId !== null && finishingTaskId === alreadyContinuedTaskId) return false;
  return !engineRunning;
}

/**
 * 恢复目标后要不要立刻补起一轮。
 *
 * 续跑只在任务终局时触发，而被取消/失败暂停的目标**已经没有在跑的任务了**。
 * 所以“恢复”若只把状态翻成 active，横幅会显示进行中却什么都不做——那是个假恢复。
 */
export function shouldKickGoalRound(opts: {
  goalActive: boolean;
  isForegroundHost: boolean;
  engineRunning: boolean;
  connectionAlive: boolean;
}): boolean {
  const {goalActive, isForegroundHost, engineRunning, connectionAlive} = opts;
  return goalActive && isForegroundHost && !engineRunning && connectionAlive;
}

/**
 * 续跑任务的提示词。
 *
 * 只带目标、剩余预算与“达成就声明”的约定，**不拼历史全文**：
 * 上下文由引擎自己维护，重复拼进去会白白撑爆窗口。
 */
export function buildGoalContinuationPrompt(goal: AgentGoal): string {
  const done = goal.roundsUsed + 1;
  return (
    "【目标模式 · 自动续跑】第 " + done + "/" + goal.maxRounds + " 轮\n" +
    "目标：" + goal.objective + "\n\n" +
    "请继续朝该目标推进。若你确认目标已经完全达成，" +
    "只在「回答:」正文里单独一行写 " + GOAL_DONE_MARKER + " 并说明结果；" +
    "这一行是给你的结论，**不是命令**，绝不能放进 命令: 块或工具参数里。" +
    "未达成则正常执行下一步，不要提前结束。"
  );
}
