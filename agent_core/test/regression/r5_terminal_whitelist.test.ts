// Regression: docs §6.2 r5_terminal_whitelist.test.ts (AGENTS.md R5).
//
// This file owns the SHAPE of the terminal-state gates. The 20-cell state x path
// matrix lives in test/terminal_state_matrix.test.ts (which trigger path reaches
// which state) and the persistence/RPC wiring in checkpoint_store.test.ts /
// w5_e2e.test.ts / rpc_start_task.test.ts - none of that is repeated here. What is
// unique to this file is the anti-blacklist requirement: a gate written as
// \`!isCancelled\` silently admits \`failed\` plus every state added later, so terminal
// side effects (knowledge-base writes, persistence, telemetry) fire for tasks that
// never succeeded.
//
// Contracts pinned:
//   1. ReActEngine.isSideEffectState is a WHITELIST admitting exactly "success", and
//      its source text is whitelist-shaped (no \`!==\` / \`!\` blacklist operators).
//   2. The W7 checkpoint-delete gate is a DIFFERENT, explicitly enumerated whitelist
//      (success + cancelled). Same terminal states, different side effect, different
//      membership - the two must never be collapsed into one gate.
//   3. Error-triggered paths end in \`failed\` (never a success-ish state) and still
//      emit exactly one finish event + one onFinished with the reason (all-paths).
//   4. The no-command retry budget resets on a successful command execution AND at
//      the top of run(), so an early failure cannot poison a later task.
import {describe, it, expect} from "vitest";
import {readFileSync, rmSync} from "node:fs";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import {tmpdir} from "node:os";
import {ReActEngine} from "../../src/react/engine.js";
import {CheckpointStore} from "../../src/utils/checkpoint_store.js";
import {MockLlmClient, LlmClient} from "../../src/llm/clients.js";
import {AgentEvent, AgentFinishState, ModelConfig} from "../../src/rpc/schema.js";

const mc: ModelConfig = {provider: "openai", model: "gpt-4o", apiKey: "k"};
// CJK ReAct field keywords - the parser only understands the Dart spellings.
const FIN = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish"; // answer + action: finish
const CMD = "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: echo hi"; // thought/action/command
const NOCMD = "\u53ea\u662f\u4e00\u6bb5\u666e\u901a\u6587\u5b57"; // plain prose, no ReAct field
const PARKED = "\u56de\u7b54: parked";
const STATES: AgentFinishState[] = ["success", "cancelled", "failed", "interrupted"];
const engineSrc = () => readFileSync(fileURLToPath(new URL("../../src/react/engine.ts", import.meta.url)), "utf-8");
const throwingLlm = (): LlmClient => ({name: "throwing", chatStream: async () => { throw new Error("500 boom"); }});
const task = (taskId: string) => ({taskId, goal: "g", hostId: "h", modelConfig: mc}) as never;

interface Driven {
  state: AgentFinishState;
  events: AgentEvent[];
  finished: Array<{state: AgentFinishState; summary: string | undefined}>;
  errors: string[];
}

/** Drive one trigger path with no checkpoint store. */
async function drive(kind: "no-cmd" | "max-steps" | "llm-error" | "cancel", responses: string[], maxSteps = 5): Promise<Driven> {
  const events: AgentEvent[] = [];
  const finished: Driven["finished"] = [];
  const errors: string[] = [];
  const engine = new ReActEngine(kind === "llm-error" ? throwingLlm() : new MockLlmClient(responses), mc, {
    onEvent: (e) => { events.push(e); },
    onFinished: (state, summary) => { finished.push({state, summary}); },
    onError: (m) => { errors.push(m); },
  });
  const p = engine.run(task("t-r5-" + kind), maxSteps);
  if (kind === "cancel") engine.cancel(); // boundary() -> emitFinish("cancelled")
  const state = await p;
  return {state, events, finished, errors};
}

describe("R5 side-effect gate is a whitelist admitting exactly one state", () => {
  it("isSideEffectState admits success and nothing else", () => {
    for (const s of STATES) {
      expect(ReActEngine.isSideEffectState(s), "membership for " + s).toBe(s === "success");
    }
  });

  it("the source of the gate is whitelist-shaped, not a blacklist", () => {
    // A review-time guarantee: \`s !== "cancelled"\` / \`!isCancelled\` reads as
    // "everything except one state" and admits failed + every future state. The
    // gate must be a positive equality against the single allowed state.
    const src = engineSrc();
    const at = src.indexOf("static isSideEffectState(");
    expect(at, "gate still exists on ReActEngine").toBeGreaterThan(-1);
    const body = src.slice(at, src.indexOf("}", at));
    expect(body).toContain('=== "success"');
    expect(body).not.toMatch(/!==|!\(/);
  });

  it("the historical blacklist would have admitted failed - the whitelist does not", () => {
    // AGENTS.md R5 names \`if (!isCancelled) recordLearning()\` as the bug. On the
    // states the gate must exclude, the two shapes DISAGREE - that disagreement is
    // the whole point of the rule, so pin both sides.
    const blacklist = (s: AgentFinishState) => s !== "cancelled";
    for (const s of ["failed", "interrupted"] as const) {
      expect(ReActEngine.isSideEffectState(s), "whitelist rejects " + s).toBe(false);
      expect(blacklist(s), "blacklist would admit " + s).toBe(true);
    }
  });

  it("a terminal state added later is excluded without touching the gate", () => {
    // Whitelists fail closed, blacklists fail open. This holds structurally: a new
    // literal can never satisfy \`s === "success"\`.
    for (const future of ["timedOut", "crashed", "expired", "completed"]) {
      expect(ReActEngine.isSideEffectState(future as AgentFinishState), "future state " + future).toBe(false);
    }
  });
});

describe("R5 the W7 checkpoint gate is a second, different whitelist", () => {
  it("membership differs from the side-effect gate on exactly one state", () => {
    // Enumerated in finishSideEffects(): success + cancelled delete the checkpoint
    // (nothing to resume); failed + interrupted keep it (crash-recovery resume).
    for (const s of STATES) {
      const deletes = s === "success" || s === "cancelled";
      expect(deletes, "checkpoint-delete membership for " + s).toBe(deletes);
      expect(ReActEngine.isSideEffectState(s), "record-side-effect membership for " + s).toBe(s === "success");
      if (s === "cancelled") {
        // the one state where the gates disagree -> one gate cannot serve both
        expect(deletes).toBe(true);
        expect(ReActEngine.isSideEffectState(s)).toBe(false);
      }
    }
  });

  it("the gate text in finishSideEffects stays an explicit two-state whitelist", () => {
    const src = engineSrc();
    const at = src.indexOf("private finishSideEffects(");
    expect(at, "finishSideEffects still exists").toBeGreaterThan(-1);
    const body = src.slice(at, src.indexOf("this.callbacks.onFinished", at));
    expect(body).toContain('state === "success"');
    expect(body).toContain('state === "cancelled"');
    expect(body).not.toContain("failed"); // failed must never join the delete set
    expect(body).not.toMatch(/!==|!\(/);
  });

  it("cancelled: checkpoint deleted, but no recording side effect", async () => {
    const dir = join(tmpdir(), "ac_r5_cancel_" + process.pid + "_" + Math.random().toString(36).slice(2));
    const store = new CheckpointStore(dir);
    const taskId = "t-r5-cancel";
    store.save({taskId, hostId: "h", goal: "g", step: 0, conversation: [], seenStableIds: [], state: "inProgress", savedAt: "2025-01-01T00:00:00Z"});
    try {
      const events: AgentEvent[] = [];
      const engine = new ReActEngine(new MockLlmClient([PARKED]), mc, {
        onEvent: (e) => { events.push(e); },
        onFinished: () => {},
      }, {checkpointStore: store});
      const p = engine.run(task(taskId), 5);
      engine.cancel();
      expect(await p).toBe("cancelled");
      expect(store.load(taskId), "cancelled is in the checkpoint whitelist -> deleted").toBeNull();
      expect(ReActEngine.isSideEffectState("cancelled"), "...but not in the recording whitelist").toBe(false);
      expect(events.filter((e) => e.type === "finish").length, "cancelled still emits finish").toBe(1);
    } finally { rmSync(dir, {recursive: true, force: true}); }
  });

  it("crosswalk: each trigger path maps onto both whitelists as the matrix expects", async () => {
    // Complements terminal_state_matrix.test.ts: same path drivers, but the
    // assertion is about GATE MEMBERSHIP rather than raw reachability.
    const spec: Array<{kind: string; state: AgentFinishState; delete: boolean; record: boolean}> = [
      {kind: "finish", state: "success", delete: true, record: true},
      {kind: "cancel", state: "cancelled", delete: true, record: false},
      {kind: "max-steps", state: "failed", delete: false, record: false},
      {kind: "no-cmd", state: "failed", delete: false, record: false},
      {kind: "llm-error", state: "failed", delete: false, record: false},
      {kind: "supersede", state: "interrupted", delete: false, record: false},
    ];
    for (const s of spec) {
      const dir = join(tmpdir(), "ac_r5_x_" + s.kind + "_" + process.pid + "_" + Math.random().toString(36).slice(2));
      const store = new CheckpointStore(dir);
      const taskId = "t-r5-x-" + s.kind;
      store.save({taskId, hostId: "h", goal: "g", step: 0, conversation: [], seenStableIds: [], state: "inProgress", savedAt: "2025-01-01T00:00:00Z"});
      try {
        const responses =
          s.kind === "finish" ? [FIN] :
          s.kind === "cancel" || s.kind === "supersede" ? [PARKED] :
          s.kind === "no-cmd" ? [NOCMD, NOCMD, NOCMD] : ["a", "b"];
        const engine = new ReActEngine(s.kind === "llm-error" ? throwingLlm() : new MockLlmClient(responses), mc, {
          onEvent: () => {},
          onFinished: () => {},
        }, {checkpointStore: store});
        const p = engine.run(task(taskId), s.kind === "max-steps" ? 2 : 5);
        if (s.kind === "cancel") engine.cancel();
        if (s.kind === "supersede") engine.run(task(taskId + "2"), 1);
        const state = await p;
        expect(state, s.kind + " terminal state").toBe(s.state);
        expect(store.load(taskId) !== null, s.kind + " -> checkpoint kept?").toBe(!s.delete);
        expect(ReActEngine.isSideEffectState(state), s.kind + " -> recording gate").toBe(s.record);
      } finally { rmSync(dir, {recursive: true, force: true}); }
    }
  });
});

describe("R5 every terminal path reports the error, none reports success", () => {
  it("error-triggered paths: failed + exactly one finish event + one onFinished with the reason", async () => {
    const specs: Array<{kind: "no-cmd" | "max-steps" | "llm-error"; responses: string[]; maxSteps: number; summary: string; onError: number}> = [
      {kind: "no-cmd", responses: [NOCMD, NOCMD, NOCMD], maxSteps: 9, summary: "no-command retry exhaustion", onError: 0},
      {kind: "max-steps", responses: ["a", "b"], maxSteps: 2, summary: "max steps exhausted", onError: 0},
      {kind: "llm-error", responses: [], maxSteps: 3, summary: "500 boom", onError: 1},
    ];
    for (const s of specs) {
      const r = await drive(s.kind, s.responses, s.maxSteps);
      const tag = s.kind + " -> ";
      expect(r.state, tag + "state").toBe("failed");
      const fins = r.events.filter((e) => e.type === "finish");
      expect(fins.length, tag + "finish events").toBe(1);
      expect(fins[0].finishState, tag + "finish state").toBe("failed");
      expect(r.finished.length, tag + "onFinished count (streaming flush must not be cut)").toBe(1);
      expect(r.finished[0].state, tag + "onFinished state").toBe("failed");
      expect(r.finished[0].summary, tag + "onFinished reason").toBe(s.summary);
      expect(r.errors.length, tag + "onError count (R1.1: never swallow)").toBe(s.onError);
      expect(ReActEngine.isSideEffectState(r.state), tag + "recording gate stays off").toBe(false);
    }
  });

  it("no trigger path ever lands on a success-ish state", async () => {
    const got: AgentFinishState[] = [];
    got.push((await drive("no-cmd", [NOCMD, NOCMD, NOCMD])).state);
    got.push((await drive("max-steps", ["a", "b"], 2)).state);
    got.push((await drive("llm-error", [])).state);
    got.push((await drive("cancel", [PARKED])).state);
    expect(got).toEqual(["failed", "failed", "failed", "cancelled"]);
    for (const s of got) expect(s, "error/cancel trigger must never be success").not.toBe("success");
  });
});

describe("R5 retry budget resets - an early failure cannot poison later work", () => {
  const okExec = async (): Promise<{stdout: string; stderr: string; exitCode: number; durationMs: number; success: boolean}> =>
    ({stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, success: true});

  it("a successful command execution clears the counter mid-run", async () => {
    // Budget is 2 (maxNoCommandRetries): 3 consecutive no-command steps terminate.
    // Two bursts of two around one command = 4 no-command steps, which only
    // survives because the command resets the counter back to 0.
    const seq = [NOCMD, NOCMD, CMD, NOCMD, NOCMD, FIN];
    const events: AgentEvent[] = [];
    let calls = 0;
    const engine = new ReActEngine(new MockLlmClient(seq), mc, {
      onEvent: (e) => { events.push(e); },
      onFinished: () => {},
    }, {commandExecutor: async () => { calls++; return okExec(); }});
    const state = await engine.run(task("t-r5-reset-mid"), 12);
    expect(state).toBe("success");
    expect(calls, "the single command ran exactly once").toBe(1);
    const results = events.filter((e) => e.type === "result");
    expect(results.length).toBe(1);
    expect(results[0].success).toBe(true);
    expect(results[0].commandId, "result links to its own command (R4)").toBeTruthy();
  });

  it("exhausting the budget in run #1 does not shorten run #2 on the same engine", async () => {
    // run() re-zeroes the counter (and the R4 dedupe set) while the shared mock
    // keeps consuming its canned turns (MockLlmClient.shift). If the counter leaked,
    // run #2 would terminate on its very first no-command step instead of using
    // the remaining budget before reaching its finish.
    const events: AgentEvent[] = [];
    const engine = new ReActEngine(new MockLlmClient([NOCMD, NOCMD, NOCMD, "", "", FIN]), mc, {
      onEvent: (e) => { events.push(e); },
      onFinished: () => {},
    });
    expect(await engine.run(task("t-r5-r1"), 9)).toBe("failed");
    expect(await engine.run(task("t-r5-r2"), 9)).toBe("success");
    const fins = events.filter((e) => e.type === "finish");
    expect(fins.length, "one finish per run - all-paths consistency").toBe(2);
    // engine-driven exhaustion names the state; the parser-driven finish omits it
    // and the engine defaults it to success (Dart parity).
    expect(fins[0].finishState, "run #1 finish event").toBe("failed");
    expect(fins[1].finishState ?? "success", "run #2 finish event").toBe("success");
  });
});
