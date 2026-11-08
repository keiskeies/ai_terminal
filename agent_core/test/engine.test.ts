// test/engine.test.ts - ReAct engine e2e with MockLlmClient (R9 pipeline test)
import {describe, it, expect} from "vitest";
import {ReActEngine} from "../src/react/engine.js";
import {MockLlmClient} from "../src/llm/clients.js";
import {ModelConfig, AgentEvent} from "../src/rpc/schema.js";

const mc: ModelConfig = {provider: "openai", model: "gpt-test"};
// CJK keywords (the parser mirrors the Dart reference which is CJK-only)
const CMD_KW = "命令:";
const TXT_KW = "回答:";

describe("ReActEngine e2e (R9)", () => {
  it("emits command + result events from a tool-call response", async () => {
    const emitted: AgentEvent[] = [];
    const llm = new MockLlmClient([CMD_KW + " ls -la"]);
    const engine = new ReActEngine(llm, mc, {
      onEvent: (e) => emitted.push(e),
      onFinished: () => {},
    });
    await engine.run({taskId: "t1", goal: "list files", hostId: "h1", modelConfig: mc}, 3);
    const types = emitted.map((e) => e.type);
    expect(types).toContain("command");
    const cmd = emitted.find((e) => e.type === "command");
    expect(cmd!.command).toBe("ls -la");
    // result stub emitted too
    expect(types).toContain("result");
  });

  it("no-command retry exhaustion -> failed", async () => {
    const emitted: AgentEvent[] = [];
    const llm = new MockLlmClient([TXT_KW + " no command here"]);
    const engine = new ReActEngine(llm, mc, {
      onEvent: (e) => emitted.push(e),
      onFinished: () => {},
    });
    const state = await engine.run({taskId: "t2", goal: "g", hostId: "h", modelConfig: mc}, 5);
    expect(state).toBe("failed");
  });
});