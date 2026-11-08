// tools/dispatcher.ts - the "sink tool execution to Node" primitive (Phase 2 / W4).

// A ToolDispatcher looks up a tool by name in an AgentToolRegistry, parses its
// arguments through the R9 typed ToolArgs layer, executes the tool with a
// ToolContext, and maps the ToolResult back onto a stableId-derived `result`
// AgentEvent. The engine / reverse-RPC bridge call this; it is transport-agnostic
// so the same dispatch path serves both the local ReAct loop and remote tools.

// Design notes (AGENTS.md):
//   R9  args come in as ReAct free-text and are read ONLY through ToolArgs
//       typed accessors - never raw args["key"] + ad-hoc coercion.
//   R4  the result event id is stableId("result", ...) so downstream dedup
//       (which keys on stableId, not the sequence finalId) stays correct.
//   R1  ctx.cancelled is honoured at entry (short-circuit to a cancelled
//       result); the caller additionally guards the await with its own generation.

import {AgentTool, AgentToolRegistry, ToolContext, ToolResult} from "./builtin.js";
import {ToolArgs} from "./tool_args.js";
import {AgentEvent} from "../rpc/schema.js";
import {stableId} from "../utils/stable_hash.js";

export interface DispatchRequest {
  /** Tool name as the model emitted it (e.g. "fetch_url"). */
  toolName: string;
  /** ReAct 参数 block as free text; parsed via ToolArgs (R9). Empty/absent = no args. */
  argsText?: string;
  /** Owning host id for the event (multi-host isolation, R3). */
  hostId?: string;
  /** Session type; drives tool scope + the local-exec default shell. */
  isLocalSession?: boolean;
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
      return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"cancelled", failureKind:"cancelled"})};
    }

    const tool: AgentTool | undefined = this.registry.get(req.toolName);
    if (!tool) {
      return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"unknown tool: " + req.toolName, failureKind:"unknown_tool"})};
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
        return {executed:false, event: this.resultEvent({toolName:req.toolName, hostId:req.hostId, success:false, error:"malformed args block", failureKind:"bad_args", output:raw})};
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
    });
    return {executed: true, event};
  }

  private resultEvent(o: {toolName?:string; hostId?:string; success:boolean; output?:string; error?:string; failureKind?:string; durationMs?:number; diffAdditions?:number; diffDeletions?:number; hostResults?: Record<string, unknown>;}): AgentEvent {
    const statusKey = o.success ? "ok" : (o.error ?? "fail");
    const id = stableId("result", (o.toolName ?? "") + "|" + statusKey);
    return {
      id, type: "result", timestamp: Date.now(),
      toolName: o.toolName, hostId: o.hostId, commandId: undefined,
      success: o.success, output: o.output, error: o.error,
      failureKind: o.failureKind, durationMs: o.durationMs,
      diffAdditions: o.diffAdditions, diffDeletions: o.diffDeletions, hostResults: o.hostResults as AgentEvent["hostResults"],
    };
  }
}