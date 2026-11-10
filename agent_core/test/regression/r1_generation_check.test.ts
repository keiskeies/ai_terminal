// Regression: docs §6.2 r1_generation_check.test.ts (AGENTS.md R1.1).
//
// Every await that may cross a task boundary MUST be followed by a generation
// check before touching shared state. The Node port centralizes this in
// ReActEngine.boundary(): generation mismatch + cancelled -> emit a cancelled
// finish and return cancelled; mismatch without cancel (superseded by a new
// run) -> return interrupted WITHOUT touching the shared conversation. These
// tests drive the REAL engine loop with an LLM whose chatStream awaits a gate,
// flipping the generation (cancel() or a second run()) while the first run is
// parked mid-await, then assert the loop drops exactly at the next boundary.

import {describe, it, expect} from "vitest";
import {ReActEngine} from "../../src/react/engine.js";
import {LlmClient, LlmResponseOptions, LlmResult} from "../../src/llm/clients.js";
import {ModelConfig, AgentEvent, AgentFinishState} from "../../src/rpc/schema.js";

const mc: ModelConfig = {provider: "openai", model: "gpt-test"};
const FIN = "\u52a8\u4f5c: finish"; // action: finish (CJK parser keyword)

// LLM whose chatStream parks on a gate; hook(n) runs before the n-th call.
class GateableLlm implements LlmClient {
  readonly name = "gateable";
  calls = 0;
  private resolvers: Array<() => void> = [];
  constructor(private readonly hook?: (n: number) => void, private readonly responses: string[] = []) {}
  chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    void opts;
    this.calls++;
    this.hook?.(this.calls);
    const text = this.responses.shift() ?? FIN;
    return new Promise<LlmResult>((resolve) => {
      this.resolvers.push(() => resolve({text, reasoning: ""}));
    });
  }
  releaseAll(): void {
    for (const r of this.resolvers.splice(0)) r();
  }
}

function mkEngine(llm: LlmClient, events: AgentEvent[]) {
  return new ReActEngine(llm, mc, {
    onEvent: (e) => events.push(e),
    onFinished: () => {},
  });
}
const run = (e: ReActEngine, taskId: string) =>
  e.run({taskId, goal: "g", hostId: "h", modelConfig: mc}, 5);
const tick = () => new Promise((r) => setTimeout(r, 0));

describe("R1.1 live generation checks in the engine loop", () => {
  it("cancel() while parked at an await -> boundary returns cancelled + emits finish once", async () => {
    const llm = new GateableLlm();
    const events: AgentEvent[] = [];
    const engine = mkEngine(llm, events);
    const p: Promise<AgentFinishState> = run(engine, "t1");

    await tick(); // now parked inside chatStream (await #1)
    expect(llm.calls).toBe(1);
    engine.cancel(); // generation bump + cancelled flag while parked
    llm.releaseAll(); // stale response arrives - the loop must drop it

    expect(await p).toBe("cancelled");
    expect(llm.calls).toBe(1); // loop stopped at the boundary, no further steps
    const finishes = events.filter((e) => e.type === "finish");
    expect(finishes.length).toBe(1);
    expect(finishes[0].finishState).toBe("cancelled");
  });

  it("superseded by a new run() while parked -> old task returns interrupted, emits no finish", async () => {
    const llm = new GateableLlm();
    const events: AgentEvent[] = [];
    const engine = mkEngine(llm, events);
    const p1: Promise<AgentFinishState> = run(engine, "t1");

    await tick();
    expect(llm.calls).toBe(1);
    const p2: Promise<AgentFinishState> = run(engine, "t2"); // bumps the generation
    llm.releaseAll(); // releases both parked calls

    expect(await p1).toBe("interrupted");
    // The superseded task emits NO finish: the new task owns shared state.
    expect(events.filter((e) => e.type === "finish" && e.finishState === "interrupted").length).toBe(0);
    // Only the new task's finish may exist (stale assistant text was dropped
    // before the shared-conversation push - no cross-task pollution).
    expect(events.filter((e) => e.type === "finish").length).toBeLessThanOrEqual(1);
    await p2;
  });

  it("control: no cancel and no supersede -> finish reaches success", async () => {
    const llm = new GateableLlm(undefined, [FIN]);
    const events: AgentEvent[] = [];
    const engine = mkEngine(llm, events);
    const p = run(engine, "t1");
    await tick();
    llm.releaseAll();
    expect(await p).toBe("success");
  });
});
