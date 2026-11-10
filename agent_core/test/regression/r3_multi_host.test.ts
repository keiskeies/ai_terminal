// Regression: docs §6.2 r3_multi_host.test.ts (AGENTS.md R3).
//
// A running task MUST keep dispatching against the host captured at start -
// never the (mutable) active host. The historical Dart bug: _maybeAutoCompact
// and post-task cleanup read _registry.activeHostId, so a tab switch mid-task
// made the task summarize the WRONG conversation and overwrite the active
// host's state. In the Node port the engine has no active-host field at all;
// dispatch goes through commandExecutor(cmd, {hostId: task.hostId}) (engine.ts
// L176). These tests pin that contract under a simulated switchTab: the task
// is started on host-a, the harness switches the active tab to host-b while
// the executor is mid-await, and every subsequent dispatch must still name
// host-a.

import {describe, it, expect} from "vitest";
import {ReActEngine} from "../../src/react/engine.js";
import type {CommandExecResult, CommandExecutor} from "../../src/react/engine.js";
import {LlmClient, LlmResponseOptions, LlmResult} from "../../src/llm/clients.js";
import {ModelConfig, AgentEvent} from "../../src/rpc/schema.js";

const mc: ModelConfig = {provider: "openai", model: "gpt-test"};
// CJK parser keywords (the port mirrors the Dart reference which is CJK-only).
const CMD = "\u52a8\u4f5c: execute\n\u547d\u4ee4: "; // dongzuo: execute / mingling: (action: execute / command:)
const FIN = "\u52a8\u4f5c: finish"; // action: finish

// LLM script: each call returns the next canned response; on call k the
// onCall hook runs first (simulates harness events landing mid-await).
class ScriptedLlm implements LlmClient {
  readonly name = "scripted";
  calls = 0;
  constructor(private readonly responses: string[], private readonly onCall?: (n: number) => void) {}
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    void opts;
    this.calls++;
    this.onCall?.(this.calls);
    const text = this.responses.shift() ?? FIN;
    return {text, reasoning: ""};
  }
}

const ok: CommandExecResult = {stdout: "x", stderr: "", exitCode: 0, durationMs: 1, success: true};

describe("R3 task keeps its captured host across active-tab switches", () => {
  it("every command dispatch uses the start-time hostId, not the current active tab", async () => {
    // Harness state: the user is looking at host-a when the task starts...
    let activeHostId = "host-a";
    const dispatched: Array<{command: string; hostId?: string}> = [];

    const executor: CommandExecutor = async (command, ctx) => {
      dispatched.push({command, hostId: ctx.hostId});
      // Simulate the user switching tabs WHILE the command is in flight:
      // the harness flips activeHostId, but the running task must not care.
      activeHostId = "host-b";
      return ok;
    };

    // Two command steps: switch happens inside step 1's executor; step 2's
    // dispatch happens with activeHostId already on host-b.
    const llm = new ScriptedLlm([CMD + "uname -a", CMD + "id", FIN]);
    const emitted: AgentEvent[] = [];
    const engine = new ReActEngine(llm, mc, {
      onEvent: (e) => emitted.push(e),
      onFinished: () => {},
    }, {commandExecutor: executor});

    const state = await engine.run({taskId: "t1", goal: "collect facts", hostId: activeHostId, modelConfig: mc}, 6);
    expect(state).toBe("success");
    expect(dispatched.length).toBe(2);
    // The active tab moved on - but the task stayed on its captured host.
    expect(activeHostId).toBe("host-b");
    expect(dispatched[0].hostId).toBe("host-a");
    expect(dispatched[1].hostId).toBe("host-a");
  });

  it("host captured at start survives an activeHostId flip that lands during the LLM await", async () => {
    let activeHostId = "host-a";
    const seenHosts: Array<string | undefined> = [];
    const executor: CommandExecutor = async (_c, ctx) => {
      seenHosts.push(ctx.hostId);
      return ok;
    };
    // The tab switch lands while the engine awaits the FIRST llm call:
    // the task record was already built with hostId host-a, so dispatch stays put.
    const llm = new ScriptedLlm([CMD + "uptime", FIN], (n) => { if (n === 1) activeHostId = "host-c"; });
    const engine = new ReActEngine(llm, mc, {onEvent: () => {}, onFinished: () => {}}, {commandExecutor: executor});

    const state = await engine.run({taskId: "t2", goal: "g", hostId: "host-a", modelConfig: mc}, 5);
    expect(state).toBe("success");
    expect(seenHosts).toEqual(["host-a"]);
    expect(activeHostId).toBe("host-c"); // proof the switch really happened mid-run
  });
});
