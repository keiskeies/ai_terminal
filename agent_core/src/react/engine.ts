// react/engine.ts - ReAct loop skeleton (Phase 0)
// Drives the LLM -> parse -> tool dispatch -> emit-event pipeline.
//
// Phase 0: skeleton with cancellation guards (R1), terminal-state consistency (R5),
// and stableId-based deduplication (R4). Phase 2 wires in real built-in + MCP tools.
// W7: optional checkpoint store + resume-from-checkpoint support.

import {parse} from "./parser.js";
import {AgentEvent, AgentFinishState, ModelConfig, StartTaskParams} from "../rpc/schema.js";
import {LlmClient, ChatMsg} from "../llm/clients.js";
import {TaskGeneration} from "../utils/generation.js";
import {stableId} from "../utils/stable_hash.js";
import {CheckpointStore} from "../utils/checkpoint_store.js";

export interface EngineCallbacks {
  /** Emit a parsed event to the parent (stdio). */
  onEvent: (evt: AgentEvent) => void;
  /** Task finished. State is the terminal finish state. */
  onFinished: (state: AgentFinishState, summary?: string) => void;
  /** LLM error. */
  onError?: (msg: string) => void;
}

export interface EngineOptions {
  /** W7: checkpoint store — if present, a snapshot is written at every step boundary. */
  checkpointStore?: CheckpointStore;
  /** W7: when true, load an existing inProgress checkpoint for the task and seed state. */
  resumeFromCheckpoint?: boolean;
  /**
   * Phase 2: real command executor. When present, a parsed command event is
   * dispatched through this callback (mirroring Dart CommandExecutor.executeAndWait)
   * and the result event carries the real output/exitCode/durationMs. When absent,
   * the engine falls back to the Phase-0 stub result so non-wired callers keep working.
   */
  commandExecutor?: CommandExecutor;
}

/** Phase 2 command-executor result shape (1:1 fields the result event needs). */
export interface CommandExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  durationMs: number;
  timedOut?: boolean;
  failureKind?: string;
  success: boolean;
}
/** Phase 2 command executor: run a raw shell command on the task host. */
export type CommandExecutor = (
  command: string,
  ctx: {cancelled?: () => boolean; hostId?: string},
) => Promise<CommandExecResult>

export class ReActEngine {
  private readonly callbacks: EngineCallbacks;
  private readonly checkpointStore?: CheckpointStore;
  private readonly resumeFromCheckpoint?: boolean;
  private readonly commandExecutor?: CommandExecutor;
  private currentGen = 0;
  private cancelled = false;
  private conversation: ChatMsg[] = [];
  private noCommandRetries = 0;
  private readonly maxNoCommandRetries = 2; // R5: reset on success
  private readonly seenStableIds = new Set<string>();
  private lastTaskId?: string;

  constructor(
    private readonly llm: LlmClient,
    private readonly modelConfig: ModelConfig,
    callbacks: EngineCallbacks,
    options?: EngineOptions,
  ) {
    this.callbacks = callbacks;
    this.checkpointStore = options?.checkpointStore;
    this.resumeFromCheckpoint = options?.resumeFromCheckpoint;
    this.commandExecutor = options?.commandExecutor;
  }

  private makeGen(): TaskGeneration {
    const myGen = this.currentGen;
    return new TaskGeneration(
      myGen,
      () => this.currentGen,
      () => this.cancelled,
    );
  }

  /**
   * Run the ReAct loop for the given task.
   * Returns the terminal finish state.
   */
  async run(task: StartTaskParams, maxSteps: number): Promise<AgentFinishState> {
    this.currentGen++;
    this.cancelled = false;
    this.lastTaskId = task.taskId;
    const myGen = this.makeGen();
    this.conversation = [];
    this.noCommandRetries = 0;
    this.seenStableIds.clear();

    // W7: resume from checkpoint if requested and one exists
    let startStep = 0;
    if (this.resumeFromCheckpoint && this.checkpointStore) {
      const cp = this.checkpointStore.load(task.taskId);
      if (cp && cp.state === "inProgress") {
        this.conversation = cp.conversation.map((m) => ({role: m.role as "system" | "user" | "assistant", content: m.content}));
        this.seenStableIds.clear();
        for (const id of cp.seenStableIds) this.seenStableIds.add(id);
        startStep = cp.step;
        this.callbacks.onEvent({
          id: stableId("info", "resumed " + task.taskId),
          type: "info",
          timestamp: Date.now(),
          text: "\u6062\u590d\u4efb\u52a1\u5230\u7b2c " + startStep + " \u6b65", // "恢复任务到第 N 步"
        });
      }
    }

    for (let step = startStep; step < maxSteps; step++) {
      // R1: generation check at the start of each step
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Build the LLM request
      const systemPrompt = this.modelConfig.systemPrompt ?? "";
      const msgs: ChatMsg[] = [
        {role: "system", content: systemPrompt},
        ...this.conversation,
        {role: "user", content: task.goal},
      ];

      // Call LLM (streaming in Phase 1)
      let response: string;
      try {
        const result = await this.llm.chatStream({modelConfig: this.modelConfig, messages: msgs});
        response = result.text;
      } catch (e: any) {
        // R5: AI error -> failed, never completed
        this.callbacks.onError?.(e.message ?? String(e));
        this.emitFinish("failed", e.message ?? String(e));
        return "failed";
      }
      // R1: generation check after await
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Parse the ReAct response into events
      const events = parse(response);

      // R4: dedupe by stableId (the parser assigns id via stableId)
      for (const evt of events) {
        if (this.seenStableIds.has(evt.id)) continue;
        this.seenStableIds.add(evt.id);
        this.callbacks.onEvent(evt);
      }

      // Append AI response to conversation history
      // R5: generation check before mutating shared history
      { const s = this.boundary(myGen); if (s !== null) return s; }
      this.conversation.push({role: "assistant", content: response});

      // Check for a finish event (the parser's finish event was already delivered to the
      // parent via the R4-dedup loop above; do NOT re-emit it — only run the side effects).
      const finishEvt = events.find((e) => e.type === "finish");
      if (finishEvt) {
        const state = finishEvt.finishState ?? "success";
        this.finishSideEffects(state, finishEvt.summary); // no 2nd finish event; Dart parity
        return state;
      }

      // Check for a command event (tool call)
      const cmdEvt = events.find((e) => e.type === "command");
      if (cmdEvt) {
        const cmd = cmdEvt.command ?? "";
        // Phase 2: dispatch to the injected command executor; Phase 0: stub fallback.
        let execRes: CommandExecResult;
        if (this.commandExecutor) {
          execRes = await this.commandExecutor(cmd, {cancelled: () => this.cancelled, hostId: task.hostId});
          // R1: generation check after the await.
          { const s = this.boundary(myGen); if (s !== null) return s; }
        } else {
          execRes = {stdout: "", stderr: "", exitCode: 0, durationMs: 0, success: true};
        }
        this.noCommandRetries = 0; // R5: reset on a real command execution
        const result: AgentEvent = {
          id: stableId("result", cmd),
          type: "result",
          timestamp: Date.now(),
          commandId: cmdEvt.commandId ?? cmdEvt.id,
          command: cmdEvt.command,
          success: execRes.success,
          output: (execRes.stdout + (execRes.stderr ? "\n[stderr]\n" + execRes.stderr : "")).trimEnd() || "(no output)",
          error: execRes.success ? undefined : ("command exited with code " + execRes.exitCode + (execRes.timedOut ? " (timed out)" : "")),
          durationMs: execRes.durationMs,
          exitCode: execRes.exitCode,
          failureKind: execRes.failureKind,
        };
        this.callbacks.onEvent(result);
        this.conversation.push({
          role: "user",
          content: "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: " + (result.output ?? "") + (result.error ? "\n[error] " + result.error : ""), // "命令执行结果: "
        });
      } else {
        // No command emitted - retry a few times
        this.noCommandRetries++;
        if (this.noCommandRetries > this.maxNoCommandRetries) {
          this.emitFinish("failed", "no-command retry exhaustion");
          return "failed";
        }
      }

      // W7: checkpoint at every step boundary (inProgress state)
      if (this.checkpointStore) {
        this.checkpointStore.save({
          taskId: task.taskId,
          operationId: task.operationId,
          hostId: task.hostId,
          goal: task.goal,
          step: step + 1,
          conversation: this.conversation.map((m) => ({role: m.role, content: m.content})),
          seenStableIds: [...this.seenStableIds],
          state: "inProgress",
          savedAt: new Date().toISOString(),
        });
      }
    }

    // Max steps exhausted (R5: all terminal paths emit finish + call onFinished)
    this.emitFinish("failed", "max steps exhausted");
    return "failed";
  }

  /**
   * W7: clear the inProgress checkpoint ONLY when the task is genuinely finished.
   * - "success" / "cancelled": terminal, nothing to resume -> delete the checkpoint.
   * - "failed": resumable (max-steps / no-command retry / LLM error) -> KEEP it so a
   *   follow-up --resume can seed from the last saved step (design doc: crash-recovery).
   * - "interrupted": process killed mid-run -> KEEP it as the crash-recovery resume point.
   */
  private finishSideEffects(state: AgentFinishState, summary?: string): void {
    if (
      this.checkpointStore &&
      this.lastTaskId &&
      (state === "success" || state === "cancelled")
    ) {
      this.checkpointStore.delete(this.lastTaskId);
    }
    this.callbacks.onFinished(state, summary);
  }

  /** Emit a finish event to the parent + run the W7 side effects (checkpoint delete + onFinished). */
  private emitFinish(state: AgentFinishState, summary?: string): void {
    const evt: AgentEvent = {
      id: stableId("finish", state + (summary ?? "")),
      type: "finish",
      timestamp: Date.now(),
      finishState: state,
      summary: summary ?? "",
    };
    this.callbacks.onEvent(evt);
    this.finishSideEffects(state, summary);
  }
  /**
   * R1/R5 boundary check: returns the terminal finish state to return when the task is
   * no longer current, or null when still current.
   *  - user cancel() -> "cancelled" (emit a cancelled finish; W7 deletes checkpoint)
   *  - superseded generation (new task started) -> "interrupted" (no finish; new task owns state)
   */
  private boundary(myGen: TaskGeneration): AgentFinishState | null {
    if (myGen.isCurrent()) return null;
    if (this.cancelled) {
      this.emitFinish("cancelled", "task cancelled by user");
      return "cancelled";
    }
    // Superseded by a new task: do NOT emit a finish for the old task (the new task
    // owns the shared state). The caller just returns silently.
    return "interrupted";
  }

  /** Cancel the current task (R1 generation bump + cancelled flag). */
  cancel() {
    this.cancelled = true;
    this.currentGen++;
  }

  /** R5: whitelist terminal states that should record side effects. */
  static isSideEffectState(s: AgentFinishState): boolean {
    return s === "success";
  }
}
