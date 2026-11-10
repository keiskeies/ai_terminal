/**
 * The persistent cross-task goal, ported 1:1 from lib/models/agent_goal.dart
 * (144 lines).
 *
 * Dart keeps this next to the other models; there is no src/models/ here and
 * goal_continuation.ts is its only real consumer, so both land under utils/.
 *
 * Field order, defaults and every string in toJson() mirror the Dart class:
 * status is persisted as status.name, so the spelling of "active"/"paused"/
 * "finished" is wire-visible, and the fromJson() fallbacks decide what a
 * hand-edited or older blob does. fromJson() returning null (rather than
 * throwing) is the contract - callers treat a null goal as "no goal mode".
 *
 * The DateTime handling is the one place the runtimes genuinely differ, so it
 * is spelled out rather than hidden:
 *
 * - Dart toIso8601String() on a local DateTime prints wall-clock time with SIX
 *   fractional digits and NO zone marker. JS toISOString() prints three digits
 *   and a trailing Z, i.e. it would rewrite the same instant into a different
 *   wall clock. dartIso8601Local() reproduces the Dart shape.
 * - Dart reads such a string back with DateTime.tryParse(...).toLocal(). For a
 *   zone-less ISO date-time, JS new Date() also parses as local, so a
 *   Dart-written value survives the round-trip. A zone-marked value does not:
 *   Dart converts it to local, and so does JS, but the printed form is local in
 *   both cases, which is what keeps them agreeing.
 * - Dart tryParse is more permissive than JS new Date() (it accepts a bare
 *   "2026-01-02T03:04" and space-separated forms). Anything JS cannot parse
 *   becomes null here, which makes fromJson() return null: fail toward "no goal
 *   mode", never toward a bogus timestamp.
 */

/** 目标模式的状态。 Port of Dart enum AgentGoalStatus. */
export const AGENT_GOAL_STATUSES = ["active", "paused", "finished"] as const;
export type AgentGoalStatus = (typeof AGENT_GOAL_STATUSES)[number];

export interface AgentGoalFields {
  id: string;
  hostId: string;
  objective: string;
  status?: AgentGoalStatus;
  roundsUsed?: number;
  maxRounds?: number;
  lastRoundCommands?: number;
  noProgressRounds?: number;
  note?: string | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface AgentGoalPatch {
  status?: AgentGoalStatus;
  objective?: string;
  roundsUsed?: number;
  maxRounds?: number;
  lastRoundCommands?: number;
  noProgressRounds?: number;
  note?: string | null;
  clearNote?: boolean;
  updatedAt?: Date;
}

/** Dart prints local wall-clock time with six fractional digits and no zone. */
function dartIso8601Local(d: Date): string {
  const pad = (n: number, w: number): string => String(n).padStart(w, "0");
  // Dart years outside 0..9999 gain a signed six-digit form; a goal created by
  // this app never gets there, and JS Date cannot represent it either.
  const micro = pad(d.getMilliseconds() * 1000, 6);
  return (
    pad(d.getFullYear(), 4) + "-" + pad(d.getMonth() + 1, 2) + "-" + pad(d.getDate(), 2) +
    "T" + pad(d.getHours(), 2) + ":" + pad(d.getMinutes(), 2) + ":" + pad(d.getSeconds(), 2) +
    "." + micro
  );
}

export class AgentGoal {
  readonly id: string;
  /** 归属 host（'local' 或服务器 id）；续跑必须用它，不能用活跃 host（AGENTS.md R3）。 */
  readonly hostId: string;
  /** 用户原文，不做大小写转换 */
  readonly objective: string;
  readonly status: AgentGoalStatus;
  /** 已用的目标轮次（只有目标驱动的任务计数；用户手动发消息不扣预算） */
  readonly roundsUsed: number;
  readonly maxRounds: number;
  /** 上一轮实际执行的命令数，用于无进展检测 */
  readonly lastRoundCommands: number;
  /** 连续多少轮步数没有增量。达到 2 就暂停而不是继续空转 */
  readonly noProgressRounds: number;
  /** 暂停/结束的原因，给用户看 */
  readonly note: string | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;

  static readonly DEFAULT_MAX_ROUNDS = 24;
  static readonly MAX_ALLOWED_ROUNDS = 256;

  constructor(f: AgentGoalFields) {
    this.id = f.id;
    this.hostId = f.hostId;
    this.objective = f.objective;
    this.status = f.status ?? "active";
    this.roundsUsed = f.roundsUsed ?? 0;
    this.maxRounds = f.maxRounds ?? AgentGoal.DEFAULT_MAX_ROUNDS;
    this.lastRoundCommands = f.lastRoundCommands ?? 0;
    this.noProgressRounds = f.noProgressRounds ?? 0;
    this.note = f.note ?? null;
    this.createdAt = f.createdAt;
    this.updatedAt = f.updatedAt;
  }

  get isActive(): boolean {
    return this.status === "active";
  }

  /** 预算是否已用尽 */
  get budgetExhausted(): boolean {
    return this.roundsUsed >= this.maxRounds;
  }

  get roundsLeft(): number {
    return this.maxRounds - this.roundsUsed > 0 ? this.maxRounds - this.roundsUsed : 0;
  }

  copyWith(patch: AgentGoalPatch): AgentGoal {
    return new AgentGoal({
      id: this.id,
      hostId: this.hostId,
      objective: patch.objective ?? this.objective,
      status: patch.status ?? this.status,
      roundsUsed: patch.roundsUsed ?? this.roundsUsed,
      maxRounds: patch.maxRounds ?? this.maxRounds,
      lastRoundCommands: patch.lastRoundCommands ?? this.lastRoundCommands,
      noProgressRounds: patch.noProgressRounds ?? this.noProgressRounds,
      // clearNote wins over note, exactly as Dart orders the ternary
      note: patch.clearNote === true ? null : (patch.note ?? this.note),
      createdAt: this.createdAt,
      updatedAt: patch.updatedAt ?? this.updatedAt,
    });
  }

  toJson(): Record<string, unknown> {
    return {
      id: this.id,
      hostId: this.hostId,
      objective: this.objective,
      status: this.status,
      roundsUsed: this.roundsUsed,
      maxRounds: this.maxRounds,
      lastRoundCommands: this.lastRoundCommands,
      noProgressRounds: this.noProgressRounds,
      note: this.note,
      createdAt: dartIso8601Local(this.createdAt),
      updatedAt: dartIso8601Local(this.updatedAt),
    };
  }

  static fromJson(json: unknown): AgentGoal | null {
    if (typeof json !== "object" || json === null || Array.isArray(json)) return null;
    const j = json as Record<string, unknown>;
    const objective = j.objective;
    if (typeof objective !== "string" || objective.trim().length === 0) return null;
    const createdAt = toDate(j.createdAt);
    const updatedAt = toDate(j.updatedAt);
    if (createdAt === null || updatedAt === null) return null;
    return new AgentGoal({
      id: typeof j.id === "string" ? j.id : "",
      hostId: typeof j.hostId === "string" ? j.hostId : "",
      objective,
      status: toStatus(j.status),
      roundsUsed: toInt(j.roundsUsed),
      // 夹取：改过上限或数据被外部编辑过时，不能让预算值突破硬上限
      maxRounds: clampRounds(j.maxRounds),
      lastRoundCommands: toInt(j.lastRoundCommands),
      noProgressRounds: toInt(j.noProgressRounds),
      note: typeof j.note === "string" ? j.note : null,
      createdAt,
      updatedAt,
    });
  }
}

function toStatus(raw: unknown): AgentGoalStatus {
  for (const s of AGENT_GOAL_STATUSES) {
    if (s === raw) return s;
  }
  // 未知/缺失状态一律当 paused：宁可停下等用户，也不要凭半个字段就自动续跑
  return "paused";
}

function toInt(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

function clampRounds(v: unknown): number {
  const raw = typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : AgentGoal.DEFAULT_MAX_ROUNDS;
  if (raw < 1) return 1;
  return raw > AgentGoal.MAX_ALLOWED_ROUNDS ? AgentGoal.MAX_ALLOWED_ROUNDS : raw;
}

function toDate(v: unknown): Date | null {
  if (typeof v !== "string") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}
