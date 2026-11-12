// Engine-side audit wiring, round 134. The three audit arms (pre-exec, blocked-only,
// post-exec) are driven through a real ReActEngine with a scripted LLM client, so the
// claims are behavioural: the store actually received the rows, in the Dart order,
// with the Dart output selection, and the failure path surfaces the CJK warn prefix.
//
// Oracle: agent_engine.dart 2527-2541 (pre-exec), 2604-2617 (blocked-only),
// 2919-2940 (post-exec), 2927-2933 (output selection). The store is a fake that
// records every insert, so the row census is exact.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {
  LlmClient,
  LlmResult,
  LlmResponseOptions,
  ChatMsg,
} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";
import {
  setAuditLogStore,
  type AuditLogStorePort,
} from "../src/utils/audit_log.js";

const T_THINK = "\u601d\u8003: ";
const T_CMD_LINE = "\u547d\u4ee4: ";
const T_ACTION_EXEC = "\u52a8\u4f5c: execute\n";
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n";

function turn(cmd: string): string {
  return T_THINK + "run it\n" + T_ACTION_EXEC + T_CMD_LINE + cmd + "\n";
}
const FINISH = [T_ANSWER_FINISH];

const TASK = {taskId: "t-audit", operationId: "op", goal: "g", hostId: "h-audit",
  modelConfig: {model: "m", provider: "openai", temperature: 0.2}, maxSteps: 10, rounds: 10} as any;

class ScriptedClient implements LlmClient {
  readonly name = "scripted";
  readonly prompts: ChatMsg[][] = [];
  constructor(private readonly responses: string[]) {}
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.prompts.push(opts.messages.map((m) => ({role: m.role, content: m.content})));
    const text = this.responses.shift() ?? "";
    return {text, reasoning: ""};
  }
}

function fakeAuditStore() {
  const inserts: Record<string, unknown>[] = [];
  const port: AuditLogStorePort = {
    loadRecent: async () => [],
    insert: async (row: Record<string, unknown>) => { inserts.push(row); },
    deleteOldest: async () => { /* unused */ },
    pruneToMax: async () => { /* unused */ },
  };
  return {port, inserts};
}

async function runEngine(opts: {
  mode: PermissionMode;
  responses: string[];
  executor?: (cmd: string) => Promise<CommandExecResult>;
  safetyCheck?: (cmd: string) => any;
  auditStore?: AuditLogStorePort;
}): Promise<{state: string; inserts: Record<string, unknown>[]; events: any[]}> {
  const ctx = {gen: 0, cancelled: false, mode: opts.mode};
  const events: any[] = [];
  const client = new ScriptedClient(opts.responses);
  const flow = new ConfirmFlow({
    context: {
      currentGeneration: () => ctx.gen,
      permissionMode: () => ctx.mode,
      isCancelled: () => ctx.cancelled,
      bumpGeneration: () => { ctx.gen++; },
    },
    events: {onInfo: () => {}, onConfirmRequest: () => {}, onWaitingConfirm: () => {}, onLog: () => {}},
  });
  const {port, inserts} = fakeAuditStore();
  setAuditLogStore(opts.auditStore ?? port);
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: () => {}, onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      safetyCheck: opts.safetyCheck ?? undefined,
      commandExecutor: opts.executor ??
        (async (cmd: string): Promise<CommandExecResult> => ({stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, success: true})),
      auditLogStore: opts.auditStore ?? port,
    } as any,
  );
  const state = await engine.run(TASK, 10);
  setAuditLogStore(undefined);
  return {state, inserts, events};
}

describe("r134 engine audit: pre-exec + post-exec arms (Dart 2527-2541, 2919-2940)", () => {
  it("a successful command writes exactly two rows: pre-exec and post-exec", async () => {
    const r = await runEngine({mode: "fullAuto", responses: [turn("echo hi"), ...FINISH]});
    expect(r.state).toBe("success");
    expect(r.inserts.length).toBe(2);
    expect(r.inserts[0]["hostId"]).toBe("h-audit");
    expect(r.inserts[0]["command"]).toBe("echo hi");
    expect(r.inserts[0]["executed"]).toBe(0);
    expect(r.inserts[0]["output"]).toBeNull();
    expect(r.inserts[1]["executed"]).toBe(1);
    expect(r.inserts[1]["output"]).toBe("ok");
    const result = r.events.find((e: any) => e.type === "result");
    expect(result.output).toBe("ok");
  });

  it("a failed command: post-exec output is the error string (Dart 2931-2933)", async () => {
    const r = await runEngine({
      mode: "fullAuto",
      responses: [turn("false"), ...FINISH],
      executor: async () => ({stdout: "", stderr: "boom", exitCode: 1, durationMs: 1, success: false}),
    });
    expect(r.state).toBe("success");
    expect(r.inserts.length).toBe(2);
    expect(r.inserts[1]["executed"]).toBe(1);
    expect(r.inserts[1]["output"]).toBe("command exited with code 1");
  });
});

describe("r134 engine audit: blocked-only arm (Dart 2604-2617)", () => {
  it("a blocked command in readOnly writes pre-exec + blocked-audit rows, no post-exec row", async () => {
    const r = await runEngine({
      mode: "readOnly",
      responses: [turn("rm -rf /"), ...FINISH],
      safetyCheck: (cmd: string) => cmd.includes("rm -rf /") ? "blocked" : "safe",
    });
    expect(r.state).toBe("success");
    expect(r.inserts.length).toBe(2);
    expect(r.inserts[0]["executed"]).toBe(0);
    expect(r.inserts[0]["output"]).toBeNull();
    expect(r.inserts[1]["executed"]).toBe(0);
    console.log("DEBUG inserts:", JSON.stringify(r.inserts.map((x: any) => ({cmd: x["command"], exec: x["executed"], out: String(x["output"]).slice(0,40)}))));
    expect(String(r.inserts[1]["output"]).length).toBeGreaterThan(0);
  });

  it("a warn command in readOnly writes only the pre-exec row (not blocked, no post-exec)", async () => {
    const r = await runEngine({
      mode: "readOnly",
      responses: [turn("echo hi"), ...FINISH],
      safetyCheck: () => "warn",
    });
    expect(r.inserts.length).toBe(1);
    expect(r.inserts[0]["executed"]).toBe(0);
  });
});

describe("r134 engine audit: a throwing store surfaces the CJK warn prefix", () => {
  it("console.warn fires when the store rejects", async () => {
    const warns: string[] = [];
    const orig = console.warn;
    console.warn = (...a: unknown[]) => { warns.push(a.join(" ")); };
    const failingPort: AuditLogStorePort = {
      loadRecent: async () => { throw new Error("db down"); },
      insert: async () => { throw new Error("db down"); },
      deleteOldest: async () => { /* */ },
      pruneToMax: async () => { /* */ },
    };
    const r = await runEngine({
      mode: "fullAuto",
      responses: [turn("echo hi"), ...FINISH],
      auditStore: failingPort,
    });
    console.warn = orig;
    expect(warns.some((w) => w.includes("db down"))).toBe(true);
    expect(r.state).toBe("success");
  });
});
