// Regression: docs §6.2 r1_then_onerror.test.ts (AGENTS.md R1, third bullet).
//
// R1.3: "Every .then() on an async future MUST have an onError handler (or be
// wrapped in try/catch). An unhandled rejection leaves any linked Completer
// forever incomplete, deadlocking the ReAct loop." Plus its sibling: "Do not
// swallow exceptions in catch blocks - a caught error must either be rethrown,
// logged with context, or translated into a failed task state."
//
// This file owns the two places the port could lose an error on its way out:
//
//  (A) RPC server handlers. A handler may throw ANY value, not just an Error
//      ("throw 'boom'", "throw undefined", a rejected promise, a circular object
//      that breaks JSON.stringify). Wrapping used to be an "e as Error" cast, so
//      the wire reply was {ok:false, error:undefined} and the err:uncaught
//      notification carried message:undefined - the parent received a failure
//      with NO diagnostic. In Dart every throwable has toString(), so this class
//      of silent failure does not exist there; the port must not invent it.
//
//  (B) Engine consumer callbacks. onEvent/onFinished/onError are external code.
//      index.ts starts the run and returns {ok:true} WITHOUT awaiting it, so a
//      throw from a sink escaped as an UNHANDLED REJECTION - Node >=15 kills the
//      process on the default --unhandled-rejections=strict, killing the child
//      agent mid-task. It also skipped finishSideEffects(), so the task stayed
//      "running" forever: the same "divergent terminal path" that R5 forbids.
//      Both are now contained, and containment is LOGGED, never silent (R1.3's
//      other half).
//
// Siblings, deliberately not re-owned here:
//   regression/r1_generation_check  - R1.1 stale-generation gates.
//   regression/r1_stream_cancel     - R1.2 stream cancel/complete pairing.
//   rpc_transport.test.ts           - transport framing and Error-typed rejections.
//   regression/r5_terminal_whitelist- which terminal states may side-effect.
//   rpc_start_task.test.ts          - the rpc:startTask request/response contract.

import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {RpcServer} from "../../src/rpc/server.js";
import {ReActEngine, CommandExecResult} from "../../src/react/engine.js";
import {MockLlmClient} from "../../src/llm/clients.js";
import {
  AgentEvent,
  AgentFinishState,
  JsonRpcNotification,
  JsonRpcRequest,
  ModelConfig,
} from "../../src/rpc/schema.js";
import {RpcTransport} from "../../src/rpc/transport.js";

const MC: ModelConfig = {provider: "openai", model: "gpt-4o", apiKey: "k"};
const CMD = (c: string) => "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: " + c;
const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";
const task = (id: string) =>
  ({taskId: id, goal: "g", hostId: "h", modelConfig: MC}) as never;

function src(rel: string): string {
  return readFileSync(fileURLToPath(new URL("../../src/" + rel, import.meta.url)), "utf-8");
}

/** Records everything the server tries to write, so nothing can go out unseen. */
class RecordingTransport implements RpcTransport {
  readonly responses: Array<{id: string; result: unknown}> = [];
  readonly notifications: JsonRpcNotification[] = [];
  private reqHandler: ((r: JsonRpcRequest) => void) | null = null;
  closedFlag = false;

  request<T>(): Promise<T> { return Promise.resolve({} as T); }
  notify(n: JsonRpcNotification): void { this.notifications.push(n); }
  respond(id: string, result: unknown): void { this.responses.push({id, result}); }
  reject(_id: string, _code: number, _message: string): void {}
  onNotification(_h: (n: JsonRpcNotification) => void): void {}
  onRequest(h: (r: JsonRpcRequest) => void): void { this.reqHandler = h; }
  get closed(): boolean { return this.closedFlag; }
  close(): void { this.closedFlag = true; }

  send(id: string, method: string, params?: Record<string, unknown>): void {
    expect(this.reqHandler, "server never wired onRequest").not.toBeNull();
    this.reqHandler!({jsonrpc: "2.0", id, method, params: params ?? {}});
  }
  replyFor(id: string): any {
    const r = this.responses.filter((x) => x.id === id).pop();
    return r?.result;
  }
  uncaughtFor(idFragment: string): JsonRpcNotification | undefined {
    // notifications are appended in the same order as the requests we sent
    const idx = this.responses.findIndex((r) => r.id === idFragment);
    if (idx < 0) return undefined;
    return this.notifications.filter((n) => n.method === "err:uncaught")[idx];
  }
}

describe("(A) server handlers: every throwable arrives as a diagnostic", () => {
  // The exact set that used to land as error:undefined. A string has no .message,
  // undefined/null have no properties at all, and a circular or BigInt-bearing
  // object makes the NAIVE describer (JSON.stringify) throw inside the catch.
  const cases: Array<[string, () => unknown]> = [
    ["string", () => "boom"],
    ["undefined", () => undefined],
    ["null", () => null],
    ["number", () => 42],
    ["boolean", () => true],
    ["plain object", () => ({code: 7})],
    ["array", () => [1, 2]],
    ["function", () => function namedHandler() {}],
    ["circular object", () => { const o: any = {a: 1}; o.self = o; return o; }],
    ["BigInt-bearing object", () => ({big: 10n})],
    ["Error (control)", () => new Error("real error")],
  ];

  for (const [label, make] of cases) {
    it("throwing " + label + " still yields a non-empty error string + err:uncaught", async () => {
      const t = new RecordingTransport();
      const server = new RpcServer(t);
      server.register("probe", async () => { throw make(); });
      t.send("req-" + label, "probe");
      await new Promise((r) => setTimeout(r, 0));

      const reply = t.replyFor("req-" + label);
      expect(reply, "no response was sent for " + label).toBeDefined();
      expect(reply.ok).toBe(false);
      // THE regression: the cast gave error:undefined, which JSON then DROPS from
      // the payload entirely - the parent saw {ok:false} with no reason at all.
      expect(typeof reply.error, "error must be a string for " + label).toBe("string");
      expect((reply.error as string).length, label + " must not be empty").toBeGreaterThan(0);
      expect(reply.error).not.toBe("undefined");
      expect(reply.error).not.toBe("null");
      // the crash-report notification carries the SAME diagnostic
      const note = t.uncaughtFor("req-" + label);
      expect(note, "expected err:uncaught for " + label).toBeDefined();
      const params = note!.params as Record<string, unknown>;
      expect(typeof params.message).toBe("string");
      expect((params.message as string).length).toBeGreaterThan(0);
      expect(params.message).toBe(reply.error);
    });
  }

  it("an Error keeps its own message instead of a wrapper (no double-wrapping)", async () => {
    const t = new RecordingTransport();
    const server = new RpcServer(t);
    server.register("probe", async () => { throw new Error("ssh pool exhausted"); });
    t.send("r1", "probe");
    await new Promise((r) => setTimeout(r, 0));
    expect(t.replyFor("r1").error).toBe("ssh pool exhausted");
  });

  it("the describer itself cannot throw - one failure, not two", async () => {
    // A second throw from inside the catch would replace the original diagnostic
    // with the describer's own failure (and, pre-await, escape the handler).
    const t = new RecordingTransport();
    const server = new RpcServer(t);
    const hostile: any = {};
    hostile.self = hostile;
    hostile.toJSON = () => { throw new Error("toJSON is hostile"); };
    server.register("probe", async () => { throw hostile; });
    t.send("r2", "probe");
    await new Promise((r) => setTimeout(r, 0));
    const reply = t.replyFor("r2");
    expect(typeof reply.error).toBe("string");
    expect((reply.error as string).length).toBeGreaterThan(0);
    // exactly one response and one notification: the failure is reported once
    expect(t.responses.length).toBe(1);
    expect(t.notifications.length).toBe(1);
  });

  it("unknown method is still a typed reply, never a throw", async () => {
    const t = new RecordingTransport();
    new RpcServer(t);
    expect(() => t.send("r3", "no/such/method")).not.toThrow();
    await new Promise((r) => setTimeout(r, 0));
    expect(t.replyFor("r3").error).toBe("unknown_method");
  });

  it("a rejected handler promise is caught like a sync throw", async () => {
    const t = new RecordingTransport();
    const server = new RpcServer(t);
    server.register("probe", () => Promise.reject("rejected reason"));
    t.send("r4", "probe");
    await new Promise((r) => setTimeout(r, 10));
    const reply = t.replyFor("r4");
    expect(typeof reply.error).toBe("string");
    expect(reply.error as string).toContain("rejected reason");
  });
});

describe("(B) engine sinks: a throwing consumer cannot abort the run", () => {
  /** Replace process.stderr.write for one call, returning everything captured. */
  async function withStderrTap<T>(fn: (lines: string[]) => Promise<T>): Promise<T> {
    const lines: string[] = [];
    const original = process.stderr.write.bind(process.stderr);
    (process.stderr as any).write = (chunk: any) => { lines.push(String(chunk)); return true; };
    try {
      return await fn(lines);
    } finally {
      (process.stderr as any).write = original;
    }
  }

  const okExec = async (): Promise<CommandExecResult> => ({
    stdout: "stub", stderr: "", exitCode: 0, durationMs: 1, success: true,
  });

  it("a throwing onEvent does not escape run() and the task still terminates", async () => {
    const events: AgentEvent[] = [];
    let finished: AgentFinishState | null = null;
    const engine = new ReActEngine(new MockLlmClient([CMD("uname -a"), FINISH]), MC, {
      onEvent: (e) => {
        events.push(e);
        if (e.type === "result") throw new Error("sink exploded"); // transport hiccup
      },
      onFinished: (s) => { finished = s; },
      onError: () => {},
    }, {commandExecutor: okExec});

    // The pre-fix contract: this await REJECTED. index.ts never awaits the run, so
    // in production the rejection was unhandled -> process death (Node >=15).
    const state = await withStderrTap(() => engine.run(task("r1-3-on-event"), 6));

    expect(state).toBe("success");
    // R5: the terminal path stayed intact even though the sink threw mid-loop -
    // every event including finish was delivered and onFinished still ran.
    expect(events.map((e) => e.type)).toContain("command");
    expect(events.map((e) => e.type)).toContain("finish");
    expect(finished).toBe("success");
  });

  it("the swallowed failure is LOUD in two channels (R1.3 second half)", async () => {
    await withStderrTap(async (lines) => {
      const errors: string[] = [];
      const engine = new ReActEngine(new MockLlmClient([FINISH]), MC, {
        onEvent: () => { throw new Error("channel closed"); },
        onFinished: () => {},
        onError: (m) => { errors.push(m); },
      });
      await engine.run(task("r1-3-loud"), 4);

      expect(errors.length).toBeGreaterThan(0);
      const hostLine = errors[0];
      expect(hostLine).toContain("onEvent");        // which callback
      expect(hostLine).toContain("channel closed"); // why
      // stderr reaches the Dart parent's log; the host notification reaches the UI
      const joined = lines.join("");
      expect(joined).toContain("[agent-core]");
      expect(joined).toContain("onEvent");
      expect(joined).toContain("channel closed");
    });
  });

  it("a throwing onFinished is contained too - the terminal state is already decided", async () => {
    await withStderrTap(async () => {
      const errors: string[] = [];
      const engine = new ReActEngine(new MockLlmClient([FINISH]), MC, {
        onEvent: () => {},
        onFinished: () => { throw "string thrown from onFinished"; }, // non-Error
        onError: (m) => { errors.push(m); },
      });
      await expect(engine.run(task("r1-3-on-finished"), 4)).resolves.toBe("success");
      expect(errors.join("\n")).toContain("onFinished");
      expect(errors.join("\n")).toContain("string thrown from onFinished");
    });
  });

  it("a throwing onError cannot bring down the failure reporter", async () => {
    await withStderrTap(async (lines) => {
      const engine = new ReActEngine(new MockLlmClient([CMD("uname -a"), FINISH]), MC, {
        onEvent: () => { throw new Error("first failure"); },
        onFinished: () => {},
        onError: () => { throw new Error("the error reporter is also broken"); },
      }, {commandExecutor: okExec});
      // The sink is hostile and the reporting channel with it. The run must still
      // return a terminal state instead of rejecting.
      const state = await engine.run(task("r1-3-double-fault"), 4);
      expect(["success", "failed"]).toContain(state);
      expect(lines.join("").length).toBeGreaterThan(0);
    });
  });

  it("missing onError stays optional (no crash when only two callbacks exist)", async () => {
    await withStderrTap(async () => {
      const engine = new ReActEngine(new MockLlmClient([FINISH]), MC, {
        onEvent: () => { throw undefined; }, // "throw undefined" from a JS sink
        onFinished: () => {},
      } as never);
      await expect(engine.run(task("r1-3-no-onerror"), 4)).resolves.toBe("success");
    });
  });

  it("the engine recovers: the next run on the same instance is unaffected", async () => {
    const engine = new ReActEngine(new MockLlmClient([FINISH, FINISH]), MC, {
      onEvent: (e) => { if (e.type === "finish") throw new Error("transient"); },
      onFinished: () => {},
      onError: () => {},
    });
    await withStderrTap(async () => {
      await expect(engine.run(task("r1-3-reuse-1"), 4)).resolves.toBe("success");
    });
    await expect(engine.run(task("r1-3-reuse-2"), 4)).resolves.toBe("success");
  });

  it("shape lint: no callback is invoked outside a guard, and nothing is silent", () => {
    const s = src("react/engine.ts");
    // every consumer callback call sits inside the guarded wrappers
    const direct = s.match(/this\.callbacks\.(onEvent|onFinished|onError)/g) ?? [];
    expect(direct.sort()).toEqual([
      "this.callbacks.onError", "this.callbacks.onEvent", "this.callbacks.onFinished",
    ]);
    // the three above are the READS inside the wrappers; nothing calls one directly
    expect(s.match(/this\.callbacks\.onEvent\(evt\);/g)?.length).toBe(1);
    expect(s.match(/this\.callbacks\.onFinished\(state, summary\);/g)?.length).toBe(1);
    expect(s.match(/cb\(msg\);/g)?.length).toBe(1);
    // 3 wrappers, each wrapping its own callback
    expect(s).toMatch(/private emit\(evt: AgentEvent\): void \{\s*try \{/);
    expect(s).toMatch(/private reportFinished\([^)]*\): void \{\s*try \{/);
    expect(s).toMatch(/private reportError\(msg: string\): void \{\s*const cb = this\.callbacks\.onError;/);
    // the guard logs to the host AND to stderr - a bare catch-with-no-body is the
    // swallow R1.3 forbids
    expect(s).toMatch(/private reportCallbackFailure\(which: string, context: string, e: unknown\): void \{/);
    expect(s).toMatch(/this\.reportError\(line\);/);
    // ... and the stderr write is itself guarded, so a closed pipe cannot throw
    // out of the reporter.
    expect(s).toMatch(/try \{\s*process\.stderr\.write/);
    // containment must not become infinite recursion when the error channel itself
    // is the failing callback (onError -> report -> onError -> RangeError)
    expect(s).toMatch(/private reportingCallbackFailure = false;/);
    expect(s).toMatch(/if \(!this\.reportingCallbackFailure\) \{/);
    // the RPC server keeps the same discipline
    const srv = src("rpc/server.ts");
    expect(srv).toMatch(/const err = e instanceof Error \? e : new Error\(toThrowableText\(e\)\);/);
    expect(srv).toMatch(/function toThrowableText\(e: unknown\): string \{/);
  });
});
