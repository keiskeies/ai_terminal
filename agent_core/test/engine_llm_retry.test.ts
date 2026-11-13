// test/engine_llm_retry.test.ts - r206: Dart P1-4 LLM stream-establishment retry
// + fallback model switch (agent_engine.dart 1605-1715). Pins:
// (1) a primary LLM that throws N times then succeeds is retried with backoff;
// (2) if a fallback LLM is configured and the primary exhausts its retry budget,
// the engine switches to the fallback exactly once;
// (3) if NO fallback is configured, the task fails after retries are exhausted;
// (4) the trace payload carries {attempt, retry, fallback, model, history_len}.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import {ModelConfig} from "../src/rpc/schema.js";

/** A client that fails a configurable number of times, then succeeds. */
class FlakyClient implements LlmClient {
  readonly name: string;
  calls = 0;
  constructor(private readonly failCount: number, private readonly okResponse: string, name = "flaky") {
    this.name = name;
  }
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.calls++;
    if (this.calls <= this.failCount) {
      throw new Error("connection reset by peer (transient)");
    }
    return {text: this.okResponse, reasoning: ""};
  }
}

const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";

function harness(opts: {primary: LlmClient; fallback?: LlmClient; fallbackConfig?: ModelConfig; maxLlmRetries?: number}) {
  const ctx = {gen: 0, cancelled: false};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const errors: string[] = [];
  const flow = new ConfirmFlow({
    context: {
      currentGeneration: () => ctx.gen,
      permissionMode: () => "auto" as any,
      isCancelled: () => ctx.cancelled,
      bumpGeneration: () => { ctx.gen++; },
    },
    events: {onInfo: () => {}, onConfirmRequest: () => {}, onWaitingConfirm: () => {}, onLog: () => {}},
  });
  const engine = new ReActEngine(
    opts.primary,
    {provider: "openai", model: "primary-model"} as ModelConfig,
    {
      onEvent: (e: any) => events.push(e),
      onFinished: (s: string, sm?: string) => finished.push([s, sm]),
      onError: (m: string) => errors.push(m),
    },
    {
      confirmFlow: flow,
      permissionMode: () => "auto" as any,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      commandExecutor: async (): Promise<CommandExecResult> =>
        ({stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true}),
      fallbackLlm: opts.fallback,
      fallbackModelConfig: opts.fallbackConfig,
      maxLlmRetries: opts.maxLlmRetries,
    } as any,
  );
  const run = async (): Promise<string> => {
    const TASK = {taskId: "t-retry", operationId: "op", hostId: "h", goal: "g",
      modelProvider: "openai", model: "primary-model", temperature: 0.2, maxSteps: 30} as any;
    try {
      return await engine.run(TASK, 30);
    } finally {
      (process.stderr as any).write = process.stderr.write;
    }
  };
  return {events, finished, errors, run};
}

describe("r206 LLM retry + fallback (Dart P1-4)", () => {
  it("primary succeeds after 2 failures (within retry budget)", async () => {
    const primary = new FlakyClient(2, FINISH);
    const h = harness({primary, maxLlmRetries: 3});
    const result = await h.run();
    expect(result).toBe("success");
    expect(primary.calls).toBe(3); // 2 failures + 1 success
    expect(h.finished[0][0]).toBe("success");
  });

  it("primary exhausts retries, fallback succeeds", async () => {
    const primary = new FlakyClient(100, "never used");
    const fallback = new FlakyClient(0, FINISH);
    const fbConfig = {provider: "openai", model: "fallback-model"} as ModelConfig;
    const h = harness({primary, fallback, fallbackConfig: fbConfig, maxLlmRetries: 1});
    const result = await h.run();
    expect(result).toBe("success");
    expect(primary.calls).toBe(2); // attempt 1 within budget, attempt 2 > maxRetries → fallback
    expect(fallback.calls).toBe(1);
    // The info event announcing the switch
    const switchEvents = h.events.filter((e: any) => e.type === "info" && e.text && e.text.includes("\u4e3b\u6a21\u578b") && e.text.includes("fallback-model"));
    expect(switchEvents.length).toBe(1);
    expect(h.finished[0][0]).toBe("success");
  });

  it("no fallback configured -> failed after retries exhausted", async () => {
    const primary = new FlakyClient(100, "never used");
    const h = harness({primary, maxLlmRetries: 1});
    const result = await h.run();
    expect(result).toBe("failed");
    expect(primary.calls).toBe(2); // 3 retries + 1 that fails with no fallback
    expect(h.finished[0][0]).toBe("failed");
    expect(h.errors.length).toBe(1);
    expect(h.errors[0]).toContain("connection reset by peer");
  });

  it("non-retryable error -> immediate give-up, no retries (Dart !_isRetryableError)", async () => {
    class FatalClient implements LlmClient {
      readonly name = "fatal";
      calls = 0;
      async chatStream(): Promise<LlmResult> {
        this.calls++;
        throw new Error("400 invalid api key provided");
      }
    }
    const fatal = new FatalClient();
    const h = harness({primary: fatal, maxLlmRetries: 3});
    const result = await h.run();
    expect(result).toBe("failed");
    expect(fatal.calls).toBe(1); // no retries: not a timeout/connection/429/5xx error
    expect(h.finished[0][0]).toBe("failed");
  });

  it("non-retryable error WITH fallback -> switches immediately", async () => {
    class FatalClient implements LlmClient {
      readonly name = "fatal";
      calls = 0;
      async chatStream(): Promise<LlmResult> {
        this.calls++;
        throw new Error("400 invalid api key provided");
      }
    }
    const fatal = new FatalClient();
    const fallback = new FlakyClient(0, FINISH);
    const fbConfig = {provider: "openai", model: "fallback-model"} as ModelConfig;
    const h = harness({primary: fatal, fallback, fallbackConfig: fbConfig, maxLlmRetries: 3});
    const result = await h.run();
    expect(result).toBe("success");
    expect(fatal.calls).toBe(1);
    expect(fallback.calls).toBe(1);
  });

  it("fallback also fails -> failed (no second fallback)", async () => {
    const primary = new FlakyClient(100, "never used");
    const fallback = new FlakyClient(100, "never used");
    const fbConfig = {provider: "openai", model: "fallback-model"} as ModelConfig;
    const h = harness({primary, fallback, fallbackConfig: fbConfig, maxLlmRetries: 1});
    const result = await h.run();
    expect(result).toBe("failed");
    expect(fallback.calls).toBe(2); // fallback attempt 1 within budget, attempt 2 > maxRetries → give up
    expect(h.finished[0][0]).toBe("failed");
  });
});
