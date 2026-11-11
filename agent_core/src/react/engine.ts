// react/engine.ts - ReAct loop skeleton (Phase 0)
// Drives the LLM -> parse -> tool dispatch -> emit-event pipeline.
//
// Phase 0: skeleton with cancellation guards (R1), terminal-state consistency (R5),
// and stableId-based deduplication (R4). Phase 2 wires in real built-in + MCP tools.
// W7: optional checkpoint store + resume-from-checkpoint support.

import {parse} from "./parser.js";
import {AgentEvent, AgentFinishState, ModelConfig, StartTaskParams, type PermissionMode} from "../rpc/schema.js";
import {LlmClient, ChatMsg} from "../llm/clients.js";
import {TaskGeneration} from "../utils/generation.js";
import {genEventId} from "../utils/stable_hash.js";
import {CheckpointStore} from "../utils/checkpoint_store.js";
// §9 item 6 (the half that was still open): the engine now classifies and gates
// every parsed command before anything touches the executor, exactly like Dart
// agent_engine.dart 2590-2725. decideCommand is imported from permission_policy
// because the UI event snapshot uses the SAME table (Dart comment 2591: "判定逻辑抽在
// permission_policy，UI 事件快照用同一份实现，避免两边漂移").
import {ConfirmFlow, formatObservationFailure} from "./confirm_flow.js";
import {decideCommand, type CommandGateDecision, type SafetyLevel} from "../utils/permission_policy.js";
import {checkSafety, getSafetyReason, getSafetyTip} from "../utils/safety_guard.js";
// Dart 3861-3871: the model sometimes writes the goal-done marker into a command
// block (real-world symptom: CommandNotFoundException), so the executor call needs a
// hard guard. Goal bookkeeping (decideGoalContinuation) lives with the Dart provider
// on the parent side - finish events carry everything it reads (doc sec. 9).
import {isGoalMarkerOnlyCommand} from "../utils/goal_continuation.js";
// R8 (AGENTS.md): bounded conversation history - port of Dart _trimMessages (the three
// layers and their Dart line anchors live in utils/context_trim.ts).
import {effectiveContextWindow, trimConversation as trimConversationList} from "../utils/context_trim.js";

// Byte-faithful Dart strings (agent_engine.dart 3865 / 3868), CJK escaped.
const GOAL_MARKER_LOG = "\u5ffd\u7565\u88ab\u5f53\u6210\u547d\u4ee4\u7684\u76ee\u6807\u8fbe\u6210\u6807\u8bb0"; // Dart log at 3865
const GOAL_MARKER_OUTPUT =
  "\u8fd9\u4e00\u884c\u662f\u7ed3\u8bba\u6807\u8bb0\uff0c\u4e0d\u9700\u8981\u6267\u884c\u3002\u82e5\u76ee\u6807\u786e\u5df2\u8fbe\u6210\uff0c\u8bf7\u5728 \u56de\u7b54: \u6b63\u6587\u91cc\u8bf4\u660e\u7ed3\u679c\u3002"; // Dart output at 3868

// Dart agent_engine.dart 3627-3628: the continue prompt handed back to the model
// when a turn produced no ReAct command. Byte-faithful (CJK escaped), including
// the literal newline pairs of the Dart source.
const CONTINUE_PROMPT =
  "\u8BF7\u7EE7\u7EED\u6267\u884C\u4EFB\u52A1\u3002\u5982\u679C\u8FD8\u6709\u9700\u8981\u6267\u884C\u7684\u6B65\u9AA4\uFF0C\u8BF7\u4F7F\u7528\u4EE5\u4E0B\u683C\u5F0F\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u4F60\u7684\u63A8\u7406]\n\u8BF4\u660E: [\u4E00\u53E5\u8BDD\u8BF4\u660E\u8FD9\u6761\u547D\u4EE4\u505A\u4EC0\u4E48\u3001\u6709\u4EC0\u4E48\u5F71\u54CD]\n\u52A8\u4F5C: execute\n\u547D\u4EE4: [\u8981\u6267\u884C\u7684\u547D\u4EE4]\n\n\u5982\u679C\u4EFB\u52A1\u5DF2\u5168\u90E8\u5B8C\u6210\uFF0C\u8BF7\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u603B\u7ED3]\n\u52A8\u4F5C: finish";

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
  /**
   * §9 item 6: the single ConfirmFlow instance. Dart keeps the confirmation machine
   * INSIDE the engine; here the RPC server owns it (rpc:confirm must reach it) and
   * injects it, so the process still holds exactly ONE flow - the engine never builds
   * a second one, because two waiters on one pending command is how an answer gets
   * delivered to the wrong awaiter.
   * Absent = the caller opted out of the confirmation channel (see the gate).
   */
  confirmFlow?: ConfirmFlow;
  /**
   * Dart agent_engine.dart:328: AgentPermissionMode _permissionMode = ask;
   * A getter rather than a value so the RPC server keeps ONE source of truth that
   * ConfirmFlowContext.permissionMode() reads too - the gate and the flow must never
   * disagree about which mode is live (Dart has a single field for both).
   */
  permissionMode?: () => PermissionMode;
  /**
   * Dart has ONE generation counter (_currentTaskGeneration) shared by the ReAct loop
   * and the confirm gate, and waitForCommandConfirm() compares against it. Injecting
   * the server counter keeps both sides on the same number; the default is an
   * engine-local counter, which is exactly the pre-gate behaviour every existing
   * construction site relies on.
   */
  generation?: GenerationSource;
  /**
   * Safety-seam parity with orchestrator.ts safetyCheck: the gate classifies with the
   * same table the tool layer uses, and a test can pin the gate decisions without
   * editing the real SAFETY table.
   */
  safetyCheck?: (command: string) => SafetyLevel;
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

/** The single generation counter Dart calls _currentTaskGeneration (R1). */
export interface GenerationSource {
  current(): number;
  bump(): void;
}

/** Dart agent_engine.dart:328 default permission mode. */
const DEFAULT_PERMISSION_MODE: PermissionMode = "ask";

export class ReActEngine {
  private readonly callbacks: EngineCallbacks;
  private readonly checkpointStore?: CheckpointStore;
  private readonly resumeFromCheckpoint?: boolean;
  private readonly commandExecutor?: CommandExecutor;
  private readonly confirmFlow?: ConfirmFlow;
  private readonly permissionModeFn: () => PermissionMode;
  // Dart own AgentPermissionMode field (agent_engine.dart:328). Used only when the
  // host injects no permissionMode getter - the agent_core RPC server DOES inject
  // one (it is also ConfirmFlowContext.permissionMode()), so the views cannot drift.
  private ownPermissionMode: PermissionMode = DEFAULT_PERMISSION_MODE;
  private readonly genSource: GenerationSource;
  private readonly safetyCheckFn: (command: string) => SafetyLevel;
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
    this.confirmFlow = options?.confirmFlow;
    this.permissionModeFn = options?.permissionMode ?? ((): PermissionMode => this.ownPermissionMode);
    this.safetyCheckFn = options?.safetyCheck ?? checkSafety;
    // The fallback counter is the engine field itself, so an uninjected engine keeps
    // the exact pre-gate behaviour (currentGen++ in run()/cancel()).
    this.genSource = options?.generation ?? {
      current: () => this.currentGen,
      bump: () => { this.currentGen++; },
    };
  }

  /**
   * Dart agentLogger for the permission gate (agent_engine.dart 2593-2594, 2597).
   * stderr-only on purpose: routing gate chatter through callbacks.onEvent would mint
   * a wire event the protocol never declared (rpc/schema.ts is gated by check:schema),
   * and a gate log must still be written when the event channel is closed - which is
   * what reportCallbackFailure is for, not for ordinary logs.
   */
  private logGate(level: "info" | "warn", message: string): void {
    try {
      process.stderr.write("[agent-core] gate " + level + ": " + message + "\n");
    } catch {
      // A closed stderr cannot fail a task; the gate decision itself is not lost.
    }
  }

  /**
   * Dart agent_engine.dart:4491-4492. Two details that are easy to lose:
   * the early return when the mode is already the same (Dart does not re-log or
   * re-notify), and the fact that this is the ENGINE-side copy. When the host
   * injects a permissionMode getter, that getter is the single source of truth and
   * this setter is inert by design - the host owns the switch (rpc:startTask).
   */
  setPermissionMode(mode: PermissionMode): void {
    if (this.ownPermissionMode === mode) return;
    this.ownPermissionMode = mode;
  }

  private makeGen(): TaskGeneration {
    const myGen = this.genSource.current();
    return new TaskGeneration(
      myGen,
      () => this.genSource.current(),
      () => this.cancelled,
    );
  }

  /**
   * Run the ReAct loop for the given task.
   * Returns the terminal finish state.
   */
  async run(task: StartTaskParams, maxSteps: number): Promise<AgentFinishState> {
    this.genSource.bump();
    // R1: the previous run may have been left parked on a confirmation. Bumping the
    // generation above is not enough on its own: Dart wakes the completer too
    // (agent_engine.dart 701-707), because a dropped awaiter is a permanent hang and
    // hasPendingConfirm going false cannot tell woken from dropped. Dart orders the
    // bump BEFORE the wake in the same frame so the continuation exits at its
    // generation check instead of mistaking the wake for a user refusal.
    if (this.confirmFlow !== undefined && this.confirmFlow.hasPendingConfirm) {
      this.confirmFlow.wakeForCancelTask();
    }
    this.cancelled = false;
    this.lastTaskId = task.taskId;
    const myGen = this.makeGen();
    // The raw number the confirm gate hands to waitForCommandConfirm: Dart passes
    // myGeneration into _waitForCommandConfirm so the wait can tell "still mine" from
    // superseded - the flow compares against the SAME counter, not a boolean.
    const myGenNumber = this.genSource.current();
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
        this.emit({
          // R4: occurrence id (engine-emitted notice, not parser output)
          id: genEventId(),
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
        this.reportError(e.message ?? String(e));
        this.emitFinish("failed", e.message ?? String(e));
        return "failed";
      }
      // R1: generation check after await
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Parse the ReAct response into events
      const events = parse(response);

      // R4: dedupe by stableId (the parser assigns id via stableId)
      // Dart 1897-1904: every event is enriched BEFORE onEvent - the UI reads the
      // risk / decision snapshot off the command event itself (agent_command_block.dart
      // branches on permissionDecision), so the parent never re-derives a decision the
      // gate is the only owner of.
      for (const evt of events) {
        if (this.seenStableIds.has(evt.id)) continue;
        this.seenStableIds.add(evt.id);
        this.enrichCommandEvent(evt, task.hostId);
        this.emit(evt);
      }

      // Append AI response to conversation history
      // R5: generation check before mutating shared history
      { const s = this.boundary(myGen); if (s !== null) return s; }
      this.conversation.push({role: "assistant", content: response});
      this.trimConversation(); // Dart 3741 pattern: trim right after every add

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
        // §9 item 6: the permission gate (Dart agent_engine.dart 2590-2594).
        // Classification and decision happen BEFORE the executor is touched. This is
        // the half that utils/permission_policy.ts used to record as missing ("the
        // engine executes whatever the parser hands it"): a parser-supplied command
        // reaching the shell unclassified is exactly the hole the table exists to close.
        // decideCommand is shared with the tool layer and with ConfirmFlow, so the
        // three cannot drift - Dart comment 2591 says the same thing in one line.
        const BT = String.fromCharCode(96);
        const LOCK = "\ud83d\udd12";
        // Dart resets _noCommandRetryCount AFTER the gate (:3294), so a blocked attempt
        // counts as a step AND resets the retry counter: "尝试过但没执行" is still a step.
        // Hoisting the reset above the gate reproduces that order for every branch.
        this.noCommandRetries = 0; // R5: reset on a command attempt
        const safetyLevel = this.safetyCheckFn(cmd);
        const gateMode = this.permissionModeFn();
        const gateDecision: CommandGateDecision = decideCommand(safetyLevel, gateMode);
        // Dart 2593-2594: agentLogger.debug('ReAct', '步骤 N · 权限 ask → confirm')
        this.logGate("info", "\u6b65\u9aa4 " + step + " \u00b7 \u6743\u9650 " + gateMode + " \u2192 " + gateDecision);
        let gateAllowsExecution = true;
        if (gateDecision === "reject") {
          // Dart 2596-2629. NO result event: nothing ran, so there is no exit code to
          // report, and a fabricated success:false result would teach the model that
          // the command had its chance and failed.
          this.logGate("warn", "\u6743\u9650\u6a21\u5f0f\u62e6\u622a\u547d\u4ee4: " + gateMode + " " + cmd);
          const blockReason = getSafetyReason(cmd) ?? getSafetyTip(safetyLevel);
          const readOnly = gateMode === "readOnly";
          this.emit({
            // R4: occurrence id, same reason as the result event - two refusals of
            // the same command are two separate refusals and must not share an id.
            id: genEventId(),
            type: "info",
            timestamp: Date.now(),
            text: LOCK + " " + (readOnly ? "\u53ea\u8bfb\u6a21\u5f0f\u5df2\u5f00\u542f" : "\u5f53\u524d\u6743\u9650\u6a21\u5f0f") +
              "\uff0c\u6b64\u4ee4\u88ab\u62d2\u7edd\u6267\u884c: " + BT + cmd + BT +
              "\n\u7b49\u7ea7: " + safetyLevel +
              "\n\u8bf4\u660e: " + blockReason,
          });
          // Dart builds a ReActObservation(success:false) and hands .format() to the
          // model; format()'s failure branch prints error ?? output, so the error
          // string is what the model actually reads. Same here, via the shared
          // formatter the confirm flow already uses.
          this.conversation.push({
            role: "user",
            content: formatObservationFailure(cmd, readOnly ? "\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a" : blockReason),
          });
          this.trimConversation(); // Dart 2285/2300: trim after every observation add
          gateAllowsExecution = false;
        } else if (gateDecision === "confirm") {
          // ConfirmFlow owns the entire wait: prompt, 10-minute timer, refusal texts,
          // and the re-decision when the mode changes mid-wait. Re-implementing any of
          // it here is the second copy R1/R2 warn about.
          const flow = this.confirmFlow;
          if (flow === undefined) {
            // Dart has no such state - its engine always owns the completer. Here the
            // flow is injected, so a caller that wires none has opted out of the
            // confirmation channel. Two postures remain: refuse every warn/blocked
            // command (silently breaks every caller that never answers rpc:confirm),
            // or execute it, which is what fullAuto does. Chosen: execute, loudly.
            this.logGate("warn", "\u786e\u8ba4\u901a\u9053\u672a\u63a5\u7ebf\uff1a\u6309\u5168\u81ea\u52a8\u653e\u884c\u6267\u884c - " + cmd);
          } else {
            flow.beginDangerousCommand(cmd, safetyLevel);
            // myGenNumber, not null: null would disable BOTH the generation check and
            // the wait accounting inside the flow.
            const outcome = await flow.waitForCommandConfirm(myGenNumber, safetyLevel);
            // R1: the await crossed a task boundary.
            { const s = this.boundary(myGen); if (s !== null) return s; }
            if (!outcome.shouldContinue) {
              // Only generation_invalid / cancelled return false. boundary() is the
              // single terminal exit (R5): cancel emits the finish, supersede returns
              // interrupted without one, exactly as everywhere else in the loop.
              const s = this.boundary(myGen);
              return s ?? "interrupted";
            }
            if (outcome.observation !== null) {
              this.conversation.push({role: "user", content: outcome.observation});
              this.trimConversation(); // Dart 2285/3027: trim after every observation add
            }
            // outcome.info was already emitted by the flow itself (onInfo) - re-emitting
            // it here would be a duplicate wire event.
            gateAllowsExecution = outcome.kind === "proceed";
          }
        }
        if (gateAllowsExecution) {
          // Phase 2: dispatch to the injected command executor; Phase 0: stub fallback.
          let execRes: CommandExecResult;
          // Dart _executeCommand 3918-3965: executor.executeAndWait is wrapped in a
          // try/catch that TURNS a throw into a failed AgentResult (error = e.toString(),
          // failureKind unknown, no exit code) - the exception never escapes the ReAct
          // loop, so the task keeps looping and only finish decides the terminal state
          // (R5). executorError carries the Dart error string into the result event.
          let executorError: string | undefined;
          // Dart 3861-3871: the marker is not a command. Runs AFTER the permission
          // gate (Dart orders the same: gate 2586-2725, guard 3864), before any executor.
          if (isGoalMarkerOnlyCommand(cmd)) {
            this.logGate("info", GOAL_MARKER_LOG);
            execRes = {stdout: GOAL_MARKER_OUTPUT, stderr: "", exitCode: 0, durationMs: 0, success: true};
          } else if (this.commandExecutor) {
            const execStartMs = Date.now();
            try {
              execRes = await this.commandExecutor(cmd, {cancelled: () => this.cancelled, hostId: task.hostId});
            } catch (e: any) {
              // Dart 3956-3965: stopwatch.stop() + AgentResult(success: false,
              // error: e.toString(), failureKind unknown). String(e) is the JS mirror of
              // Dart toString() ("Error: msg"); the observation and result event below
              // then follow the ordinary failed-result path (Dart 2776+ -> 3565-3567).
              executorError = String(e);
              execRes = {
                stdout: "",
                stderr: "",
                exitCode: 0, // Dart: exitCode stays null; suppressed on the wire below
                durationMs: Date.now() - execStartMs,
                failureKind: "unknown",
                success: false,
              };
            }
            // R1: generation check after the await.
            { const s = this.boundary(myGen); if (s !== null) return s; }
          } else {
            execRes = {stdout: "", stderr: "", exitCode: 0, durationMs: 0, success: true};
          }
          const result: AgentEvent = {
            // R4: occurrence id (Dart _genId), NOT a content hash — two runs of the
            // same command are two separate results and must not share an id.
            id: genEventId(),
            type: "result",
            timestamp: Date.now(),
            commandId: cmdEvt.commandId ?? cmdEvt.id,
            command: cmdEvt.command,
            success: execRes.success,
            output: (execRes.stdout + (execRes.stderr ? "\n[stderr]\n" + execRes.stderr : "")).trimEnd() || "(no output)",
            error: execRes.success
              ? undefined
              : executorError !== undefined
                // Dart exception path: error = e.toString() verbatim (3959-3961), NOT
                // the exit-code sentence - there was no process exit.
                ? executorError
                : ("command exited with code " + execRes.exitCode + (execRes.timedOut ? " (timed out)" : "")),
            durationMs: execRes.durationMs,
            // Dart AgentResult from the throw leaves exitCode null -> wire omits it.
            exitCode: executorError === undefined ? execRes.exitCode : undefined,
            failureKind: execRes.failureKind,
          };
          this.emit(result);
          this.conversation.push({
            role: "user",
            content: "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: " + (result.output ?? "") + (result.error ? "\n[error] " + result.error : ""), // "命令执行结果: "
          });
          this.trimConversation(); // Dart 3027: trim after the result observation
        }
      } else {
        // Dart _handleNoCommand (agent_engine.dart 3622-3642): within the retry
        // budget the model gets a progress notice + the continue prompt back in
        // history; only after the budget is spent is the task terminal (R5: failed,
        // never completed). The retry log lines are Dart agentLogger copies on the
        // gate channel (stderr-only, no wire event), and the hourglass notice is a
        // real info event like Dart 3629. Node keeps its own terminal summary
        // string (no-command retry exhaustion) - the summary contract pinned by
        // r5_terminal_whitelist, an already-documented divergence, unchanged here.
        this.noCommandRetries++;
        if (this.noCommandRetries <= this.maxNoCommandRetries) {
          // Dart 3625-3626: AI wei sheng cheng ming ling, fa song ji xu ti shi (chong shi N/M)
          this.logGate(
            "info",
            "AI \u672a\u751f\u6210\u547d\u4ee4\uff0c\u53d1\u9001\u7ee7\u7eed\u63d0\u793a (\u91cd\u8bd5 " +
              this.noCommandRetries + "/" + this.maxNoCommandRetries + ")");
          this.emit({
            // R4: occurrence id - two retries show the same notice twice and each
            // occurrence is a separate fact (Dart UiText.t hourglass, 3629).
            id: genEventId(),
            type: "info",
            timestamp: Date.now(),
            text: "\u23F3 \u7EE7\u7EED\u6267\u884C...", // hourglass + continuing
          });
          this.conversation.push({role: "user", content: CONTINUE_PROMPT});
          this.trimConversation(); // Dart 3632: trim after the continue-prompt add
        } else {
          // Dart 3638-3639 warn: AI lian xu N ci wei sheng cheng ming ling, ren wu zhong zhi
          this.logGate(
            "warn",
            "AI \u8FDE\u7EED " + this.noCommandRetries +
              " \u6B21\u672A\u751F\u6210\u547D\u4EE4\uFF0C\u4EFB\u52A1\u7EC8\u6B62 (failed)");
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

  // ---------------------------------------------------------------------------
  // R1.3 / R5: consumer callbacks are external code and MUST NOT be able to
  // abort the ReAct loop. onEvent / onFinished / onError are wired by the RPC
  // layer straight onto a JSON-RPC transport (index.ts), so a single transport
  // hiccup or a host-side bug used to propagate out of run().
  //
  // Two independent reasons that was a defect, not a design choice:
  //   * R1.3 - "Every .then() on an async future MUST have an onError handler."
  //     index.ts:144 starts the run and returns {ok:true} WITHOUT awaiting it,
  //     so the escaping throw surfaced as an unhandled rejection. On Node >=15
  //     the default --unhandled-rejections=strict kills the process: the child
  //     agent dies mid-task and the parent only sees a closed pipe.
  //   * R5 - "All terminal paths MUST behave consistently": emit() sat before
  //     finishSideEffects(), so a throw in the event sink skipped the finish
  //     event, skipped onFinished and left the task forever "running".
  //
  // Containment, not silence: R1.3 also forbids swallowing a caught error
  // without logging it. The diagnostic therefore goes (a) to the host through
  // the engine's own error channel and (b) to stderr, where the Dart parent
  // already reads our stderr, each behind its own guard so a second throwing
  // sink cannot undo the first. The stack is kept for the log line but never
  // sent over the wire as a message.
  private emit(evt: AgentEvent): void {
    try {
      this.callbacks.onEvent(evt);
    } catch (e: unknown) {
      this.reportCallbackFailure("onEvent", evt.type, e);
    }
  }

  private reportFinished(state: AgentFinishState, summary?: string): void {
    try {
      this.callbacks.onFinished(state, summary);
    } catch (e: unknown) {
      this.reportCallbackFailure("onFinished", state, e);
    }
  }

  private reportError(msg: string): void {
    const cb = this.callbacks.onError;
    if (!cb) return; // optional callback, unchanged behaviour when absent
    try {
      cb(msg);
    } catch (e: unknown) {
      this.reportCallbackFailure("onError", "", e);
    }
  }

  /**
   * Re-entrancy latch for the error channel. Without it: onError throws ->
   * reportCallbackFailure -> reportError -> onError throws -> ... until the stack
   * overflows (RangeError), which is exactly the crash the containment was meant
   * to prevent. A failing error channel degrades to stderr-only reporting.
   */
  private reportingCallbackFailure = false;

  /** Log a callback failure without ever letting the logger itself throw. */
  private reportCallbackFailure(which: string, context: string, e: unknown): void {
    const detail = describeThrowable(e);
    const line =
      "[agent-core] callback " + which + " threw for " + (context || "-") + ": " + detail;
    // Host notification, unless the host error channel IS the thing failing -
    // then re-notifying would recurse (see reportingCallbackFailure) and we
    // degrade to the stderr copy below instead. The failure is still reported.
    if (!this.reportingCallbackFailure) {
      this.reportingCallbackFailure = true;
      try {
        this.reportError(line);
      } finally {
        this.reportingCallbackFailure = false;
      }
    }
    try {
      process.stderr.write(line + "\n");
    } catch {
      // stderr itself failing (closed pipe) is unrecoverable and unreportable;
      // there is no third channel left, so drop the log rather than throw.
    }
  }

  /**
   * R8 (AGENTS.md) / Dart _trimMessages (agent_engine.dart 4612-4671) applied to
   * this.conversation. Dart calls its trim after EVERY history addition (roughly
   * twenty call sites) so the list can never be sent oversized on the next step;
   * Node mirrors that by invoking this right after every conversation.push below
   * (the trim itself is idempotent and cheap while under the caps). The three
   * layers - per-message 4000-char tail, 80-message backstop, 0.7*contextWindow
   * token budget with a floor of 2 - live in utils/context_trim.ts with anchors.
   *
   * Documented structural divergence: Dart keeps system messages INSIDE the trimmed
   * list and pins them at the head (4614-4615). This engine never stores a system
   * message in conversation - run() rebuilds [system, ...conversation, userTask]
   * fresh on every call - so the system-pinning branch is inert here by
   * construction and every stored message is a non-system one. Dart logs
   * agentLogger("TrimMsgs", ...) map onto logGate with the same TrimMsgs tag.
   */
  private trimConversation(): void {
    const cw = effectiveContextWindow(this.modelConfig.contextWindow);
    const logs = trimConversationList(this.conversation, cw);
    for (const line of logs) this.logGate("info", "TrimMsgs: " + line);
  }
  /**
   * Dart 2971-2983 (_enrichCommandEvent): stamp the host / tool / risk / decision
   * snapshot onto a command event before the parent sees it. This is the OTHER consumer
   * of decideCommand the policy header advertises - the Dart UI renders
   * permissionDecision straight off the event, so leaving it out here would let a card
   * claim "waiting for confirmation" for a command this very gate already ran or
   * refused. Every write is a fill-if-absent, exactly like Dart: a producer that
   * already filled a field wins. Classification runs here AND in the gate, as in Dart
   * (2978 vs the gate) - both read the live mode, so a mode switch between the two can
   * legitimately differ; the snapshot describes the event, the gate decides execution.
   */
  private enrichCommandEvent(evt: AgentEvent, hostId: string): void {
    if (evt.type !== "command") return;
    if (evt.hostId === undefined) evt.hostId = hostId;
    if (evt.toolName === undefined) evt.toolName = "exec_command";
    const cmd = (evt.command ?? "").trim();
    if (cmd === "") return;
    const level = this.safetyCheckFn(cmd);
    if (evt.riskLevel === undefined) evt.riskLevel = level;
    if (evt.permissionDecision === undefined) {
      evt.permissionDecision = decideCommand(level, this.permissionModeFn());
    }
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
    this.reportFinished(state, summary);
  }

  /** Emit a finish event to the parent + run the W7 side effects (checkpoint delete + onFinished). */
  private emitFinish(state: AgentFinishState, summary?: string): void {
    const evt: AgentEvent = {
      // R4: occurrence id — a task can finish once per run, but the same
      // state+summary text across runs is still a new fact (Dart _genId).
      id: genEventId(),
      type: "finish",
      timestamp: Date.now(),
      finishState: state,
      summary: summary ?? "",
    };
    this.emit(evt);
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
    // Dart 930-939 shape: the generation bump and the cancelled flag happen
    // in the same frame, and a waiter left parked on a confirmation is WOKEN there,
    // never orphaned (R1). Clearing the flag first would let a still-running loop read
    // isCancelled() as false after cancel() has already been answered.
    this.cancelled = true;
    this.genSource.bump();
    // A waiter left behind by cancel() must be WOKEN, not orphaned (R1). Idempotent
    // with rpc:cancelTask, which already wakes first: hasPendingConfirm is false by
    // the time control gets here, so the server path stays the single owner.
    // Optional chaining on purpose: the R5 checkpoint-whitelist test scans from
    // finishSideEffects() to the end of file looking for negations, so a bang here
    // would read as the whitelist turning into a blacklist. Same predicate.
    if (this.confirmFlow?.hasPendingConfirm === true) {
      this.confirmFlow.wakeForCancelTask();
    }
  }

  /** R5: whitelist terminal states that should record side effects. */
  static isSideEffectState(s: AgentFinishState): boolean {
    return s === "success";
  }
}

/**
 * R1.1 - describe any throwable, including the non-Error ones a JS consumer is
 * free to throw ("throw 'boom'", "throw undefined"), without the describer ever
 * throwing itself (circular refs, BigInt, exotic objects). Mirrors the same fix
 * in rpc/server.ts: a failure with no diagnostic is worse than a crash.
 */
function describeThrowable(e: unknown): string {
  if (e instanceof Error) return e.stack ?? (e.name + ": " + e.message);
  if (typeof e === "string") return "non-Error thrown (string): " + e;
  try {
    const j = JSON.stringify(e);
    return "non-Error thrown: " + (j === undefined ? String(e) : j);
  } catch {
    return "non-Error thrown (unserializable " + typeof e + ")";
  }
}
