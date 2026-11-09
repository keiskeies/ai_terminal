// utils/checkpoint_store.ts - W7 checkpoint + resume
//
// File-backed task checkpoint store under ~/.ai_terminal/checkpoints/.
// Each checkpoint is a JSON file: <taskId>.json
//
// The engine calls saveCheckpoint() at every step boundary (or when
// resumeFromCheckpoint=true on rpc:startTask, the load is done before
// the loop starts).
//
// R5 terminal-state rule: checkpoints are only written for inProgress
// states; terminal states (success/cancelled/failed/interrupted) are
// marked as complete and the checkpoint file is deleted after a
// successful final save.

import {readFileSync, writeFileSync, unlinkSync, readdirSync, mkdirSync, existsSync} from "node:fs";
import {join} from "node:path";
import {homedir} from "node:os";

// ── Types ────────────────────────────────────────────────────────────────────

export interface TaskCheckpoint {
  /** Stable task id (matches rpc:startTask taskId). */
  taskId: string;
  /** Operation id (optional, carried through for audit). */
  operationId?: string;
  /** Frozen host id (R3 — never substitute). */
  hostId: string;
  /** The user goal string. */
  goal: string;
  /** 0-based step counter at the time of the snapshot. */
  step: number;
  /** Conversation history serialised (role + content). */
  conversation: Array<{role: string; content: string}>;
  /** stableId set already emitted (for R4 dedup on resume). */
  seenStableIds: string[];
  /** "inProgress" while the task is live; terminal state on crash. */
  state: "inProgress" | "success" | "cancelled" | "failed" | "interrupted";
  /** ISO-8601 UTC timestamp. */
  savedAt: string;
}

// ── Store ────────────────────────────────────────────────────────────────────

export class CheckpointStore {
  private readonly dir: string;

  constructor(dirOverride?: string) {
    this.dir = dirOverride ?? join(homedir(), ".ai_terminal", "checkpoints");
  }

  /** Ensure the store directory exists. */
  private ensureDir(): void {
    if (!existsSync(this.dir)) mkdirSync(this.dir, {recursive: true});
  }

  private fileFor(taskId: string): string {
    // Sanitise: only allow alphanumeric, dash, underscore, dot
    const safe = taskId.replace(/[^a-zA-Z0-9_\-]/g, "_");
    return join(this.dir, safe + ".json");
  }

  /** Persist a checkpoint to disk. Creates the directory if needed. */
  save(cp: TaskCheckpoint): void {
    this.ensureDir();
    writeFileSync(this.fileFor(cp.taskId), JSON.stringify(cp, null, 2), "utf-8");
  }

  /** Load a checkpoint for taskId. Returns null if not found. */
  load(taskId: string): TaskCheckpoint | null {
    const p = this.fileFor(taskId);
    if (!existsSync(p)) return null;
    try {
      return JSON.parse(readFileSync(p, "utf-8")) as TaskCheckpoint;
    } catch {
      return null;
    }
  }

  /**
   * List all checkpoint files.
   * @param stateIfOmitted filter by state; "any" or omitted returns all.
   */
  list(stateFilter?: "inProgress" | "success" | "cancelled" | "failed" | "interrupted"): TaskCheckpoint[] {
    if (!existsSync(this.dir)) return [];
    const out: TaskCheckpoint[] = [];
    for (const fname of readdirSync(this.dir)) {
      if (!fname.endsWith(".json")) continue;
      try {
        const cp = JSON.parse(readFileSync(join(this.dir, fname), "utf-8")) as TaskCheckpoint;
        if (stateFilter && cp.state !== stateFilter) continue;
        out.push(cp);
      } catch {
        // corrupted file — skip silently
      }
    }
    return out;
  }

  /** Delete the checkpoint for taskId (idempotent). */
  delete(taskId: string): void {
    const p = this.fileFor(taskId);
    if (existsSync(p)) unlinkSync(p);
  }

  /**
   * Resume hint: "resume" if a valid inProgress checkpoint exists for taskId,
   * "fresh" otherwise.
   */
  resumeHint(taskId: string): "resume" | "fresh" {
    const cp = this.load(taskId);
    return cp && cp.state === "inProgress" ? "resume" : "fresh";
  }
}

export default CheckpointStore;
