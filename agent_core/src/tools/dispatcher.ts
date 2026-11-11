// tools/dispatcher.ts - the "sink tool execution to Node" primitive (Phase 2 / W4).

// A ToolDispatcher looks up a tool by name in an AgentToolRegistry, parses its
// arguments through the R9 typed ToolArgs layer, executes the tool with a
// ToolContext, and maps the ToolResult back onto an occurrence-id `result`
// AgentEvent. The engine / reverse-RPC bridge call this; it is transport-agnostic
// so the same dispatch path serves both the local ReAct loop and remote tools.

// Design notes (AGENTS.md):
//   R9  args come in as ReAct free-text and are read ONLY through ToolArgs
//       typed accessors - never raw args["key"] + ad-hoc coercion.
//   R4  a result event carries an OCCURRENCE id (genEventId) plus commandId
//       linking it to its own command; the content-hash stableId belongs to
//       parser-produced events only (see utils/stable_hash.ts).
//   R1  ctx.cancelled is honoured at entry (short-circuit to a cancelled
//       result); the caller additionally guards the await with its own generation.

import {AgentTool, AgentToolRegistry, ToolContext, ToolResult} from "./builtin.js";
import {ToolArgs} from "./tool_args.js";
import {AgentEvent, PermissionMode} from "../rpc/schema.js";
import {genEventId} from "../utils/stable_hash.js";

export interface DispatchRequest {
  /** Tool name as the model emitted it (e.g. "fetch_url"). */
  toolName: string;
  /** ReAct 参数 block as free text; parsed via ToolArgs (R9). Empty/absent = no args. */
  argsText?: string;
  /** Owning host id for the event (multi-host isolation, R3). */
  hostId?: string;
  /** Session type; drives tool scope + the local-exec default shell. */
  isLocalSession?: boolean;
  /**
   * R4: id of the `command` event that produced this call. Threaded onto the
   * result event so each result links to its OWN command - the historical Dart
   * bug used one shared `_lastCommandEventId`, which mis-linked every result
   * card to the last command once more than one command existed.
   */
  commandId?: string;
  /**
   * Dart agent_engine.dart 3357-3373: in read-only permission mode every tool
   * whose kind is not read is refused BEFORE args parsing (the same order as
   * Dart: unknown-tool check, then this gate, then argument handling). Omitted
   * = no gate, so direct W5 dispatch callers keep their prior behaviour; the
   * engine-side tool path passes the live mode once dispatch is wired there.
   */
  permissionMode?: () => PermissionMode;
  /** Opts carried to the tool (executor / cancelled / hostIds / isLocalSession). */
  ctx?: Partial<ToolContext>;
}

export interface DispatchOutcome {
  event: AgentEvent;
  /** True when the tool itself produced the result (vs. a dispatcher-level failure). */
  executed: boolean;
}

export class ToolDispatcher {
  constructor(private readonly registry: AgentToolRegistry) {}

  /**
   * Dispatch a named tool call. Always resolves (never throws to the caller);
   * failures are surfaced as a `result` event with success=false.
   */
  async dispatch(req: DispatchRequest): Promise<DispatchOutcome> {
    const ctx: ToolContext = {
      ...req.ctx,
      hostIds: req.ctx?.hostIds,
      isLocalSession: req.isLocalSession ?? req.ctx?.isLocalSession,
      cancelled: req.ctx?.cancelled,
    };

    // R1: honour cancellation before any side effect.
    if (ctx.cancelled?.()) {
      return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"cancelled", failureKind:"cancelled", commandId:req.commandId})};
    }

    const tool: AgentTool | undefined = this.registry.get(req.toolName);
    if (!tool) {
      return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"unknown tool: " + req.toolName, failureKind:"unknown_tool", commandId:req.commandId})};
    }

    // Dart 3357-3373: the read-only file mode used to gate shell commands only,
    // so a tool call could edit files straight through it (design D3). The
    // criterion derives from ToolKind, so every new write-class tool is covered
    // automatically and no second deny-list is maintained.
    if (req.permissionMode?.() === "readOnly" && !tool.isReadOnly) {
      // Dart raises an info event + observation and bumps the no-command retry
      // counter; the dispatcher has neither conversation nor counters, so the
      // refusal surfaces as a permissionDenied result event (failureKind from
      // CommandFailureKind.permissionDenied, orchestrator.ts) without touching
      // the tool. The engine tool path will translate it once dispatch is wired.
      return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"read-only mode: tool refused: " + req.toolName, failureKind:"permissionDenied", commandId:req.commandId})};
    }

    // R9: parse free-text args once, through the typed layer. Empty input is valid
    // (no args); a non-empty block that fails to parse is a bad-args failure.
    let args: ToolArgs;
    const raw = req.argsText?.trim() ?? "";
    if (raw === "") {
      args = ToolArgs.EMPTY;
    } else {
      const parsed = ToolArgs.parse(raw);
      if (parsed === null) {
        return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"malformed args block", failureKind:"bad_args", output:raw, commandId:req.commandId})};
      }
      args = parsed;
    }

    const t0 = Date.now();
    let res: ToolResult;
    try {
      res = await tool.execute(args, ctx);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      res = ToolResult.failure("tool threw: " + msg);
    }
    const durationMs = Date.now() - t0;

    // R1: the caller re-checks its generation after the await; we also surface a
    // cancelled marker if the tool finished during a cancel so the UI never lies.
    const cancelledMid = ctx.cancelled?.() === true;

    const event = this.resultEvent({
      toolName: req.toolName, hostId: req.hostId,
      success: res.success, output: res.output, error: res.error,
      durationMs, diffAdditions: res.diffAdditions, diffDeletions: res.diffDeletions,
      hostResults: res.hostResults, failureKind: cancelledMid ? "cancelled" : undefined,
      commandId: req.commandId,
    });
    return {executed: true, event};
  }

  private resultEvent(o: {toolName?:string; hostId?:string; success:boolean; output?:string; error?:string; failureKind?:string; durationMs?:number; diffAdditions?:number; diffDeletions?:number; hostResults?: Record<string, unknown>; commandId?:string;}): AgentEvent {
    // R4: result events are OCCURRENCES, not parser output, so their id comes from
    // Dart's _genId sequence (see utils/stable_hash.ts). The previous
    // stableId("result", tool + "|" + status) hashed only the tool name and the
    // status, so every successful call of a tool produced the SAME id - a second
    // fetch_url / a repeated command collided with the first and a dedup or card
    // key keyed on the id collapsed two distinct results into one. The link back to
    // the originating command is commandId, never the id.
    const id = genEventId();
    return {
      id, type: "result", timestamp: Date.now(),
      // R4: link to the originating command event (undefined only when the caller
      // dispatched without a command context, e.g. a direct tool call from W5 tests).
      toolName: o.toolName, hostId: o.hostId, commandId: o.commandId,
      success: o.success, output: o.output, error: o.error,
      failureKind: o.failureKind, durationMs: o.durationMs,
      diffAdditions: o.diffAdditions, diffDeletions: o.diffDeletions, hostResults: o.hostResults as AgentEvent["hostResults"],
    };
  }
}