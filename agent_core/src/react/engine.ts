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
}

export class ReActEngine {
  private readonly callbacks: EngineCallbacks;
  private readonly checkpointStore?: CheckpointStore;
  private readonly resumeFromCheckpoint?: boolean;
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
      if (!myGen.isCurrent()) return "interrupted";

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
      if (!myGen.isCurrent()) return "interrupted";

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
      if (!myGen.isCurrent()) return "interrupted";
      this.conversation.push({role: "assistant", content: response});

      // Check for a finish event
      const finishEvt = events.find((e) => e.type === "finish");
      if (finishEvt) {
        const state = finishEvt.finishState ?? "success";
        this.emitFinish(state, finishEvt.summary);
        return state;
      }

      // Check for a command event (tool call)
      const cmdEvt = events.find((e) => e.type === "command");
      if (cmdEvt) {
        this.noCommandRetries = 0; // R5: reset on success
        // Phase 2: dispatch to tool executor; Phase 0: stub
        const result: AgentEvent = {
          id: stableId("result", cmdEvt.command ?? ""),
          type: "result",
          timestamp: Date.now(),
          commandId: cmdEvt.commandId ?? cmdEvt.id,
          success: true,
          output: "[stub] command not yet wired (Phase 2)",
          durationMs: 0,
        };
        this.callbacks.onEvent(result);
        this.conversation.push({
          role: "user",
          content: "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: " + (result.output ?? ""), // "命令执行结果: "
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

  private emitFinish(state: AgentFinishState, summary?: string) {
    // W7: on a terminal state, clear the inProgress checkpoint for this task
    // ("interrupted" = process killed — the checkpoint IS the resume point, keep it)
    if (this.checkpointStore && state !== "interrupted" && this.lastTaskId) {
      this.checkpointStore.delete(this.lastTaskId);
    }
    const evt: AgentEvent = {
      id: stableId("finish", state + (summary ?? "")),
      type: "finish",
      timestamp: Date.now(),
      finishState: state,
      summary: summary ?? "",
    };
    this.callbacks.onEvent(evt);
    this.callbacks.onFinished(state, summary);
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
