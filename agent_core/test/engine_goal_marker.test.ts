// Engine-side goal-marker hard guard, end to end (Dart agent_engine.dart 3861-3871).
//
// The model writes the goal-done marker into a command block; the executor call must
// turn it into a synthetic success observation instead of a shell invocation
// (CommandNotFoundException was the real-world symptom). Unit coverage of
// isGoalMarkerOnlyCommand lives in goal_continuation.test.ts; what only an engine run
// can prove is the ORDER (permission gate first, guard second, executor last), that
// the executor really is never called, and that the observation text is byte-faithful
// to the Dart string (checked against the Dart source itself, not a hand copy).
import {describe, it, expect} from "vitest";
import {fileURLToPath} from "node:url";
import {readFileSync} from "node:fs";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART_ENGINE = HERE + "../../ai_terminal/lib/services/agent_engine.dart";
const NL = String.fromCharCode(10);

function readText(path: string): string {
  return readFileSync(path, "utf-8").replace(/\r\n/g, NL);
}

// Byte-faithful Dart literals (3865 log, 3868 output). The test compares the engine
// against the Dart SOURCE captured below, so these constants only pin the escape
// forms used in assertions - a wrong constant cannot mask a wrong engine string
// because both sides are re-read from Dart for the byte test.
const MARKER = "\u76ee\u6807\u5df2\u8fbe\u6210"; // goal-done marker
const EXPECT_OUTPUT =
  "\u8fd9\u4e00\u884c\u662f\u7ed3\u8bba\u6807\u8bb0\uff0c\u4e0d\u9700\u8981\u6267\u884c\u3002\u82e5\u76ee\u6807\u786e\u5df2\u8fbe\u6210\uff0c\u8bf7\u5728 \u56de\u7b54: \u6b63\u6587\u91cc\u8bf4\u660e\u7ed3\u679c\u3002"; // Dart 3868
const T_RESULT_PREFIX = "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: "; // "command result: "
const T_THINK = "\u601d\u8003: "; // "thought: "
const T_ACTION_EXEC = "\u52a8\u4f5c: execute\n"; // "action: execute"
const T_CMD_LINE = "\u547d\u4ee4: "; // "command: "
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n"; // finish turn
const LOCK = String.fromCharCode(0xd83d, 0xdd12);

// The guard sits AFTER the permission gate (Dart: gate 2590-2725, guard 3864 inside
// _runCommand). A blocked command in readOnly must still produce refusal info and no
// result - that the marker path emits a result proves the guard did not move earlier.
const CMD_BLOCKED = "rm -rf /";
const CMD_SAFE = "echo hello world";

// Marker variants the strip class swallows: quotes, brackets, CJK punctuation.
const VARIANTS = [
  MARKER,
  String.fromCharCode(34) + MARKER + String.fromCharCode(34), // "marker" with dquotes
  "\u3010" + MARKER + "\u3011", // CJK bracket pair
  MARKER + "\u3002", // trailing CJK full stop
];

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

function turn(cmd: string): string {
  return T_THINK + "run it\n" + T_ACTION_EXEC + T_CMD_LINE + cmd + "\n";
}

const TASK = {taskId: "t-gm", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;

interface Harness {
  engine: ReActEngine;
  client: ScriptedClient;
  events: any[];
  execs: string[];
  logs: string[];
  run: () => Promise<string>;
}

function harness(mode: PermissionMode, responses: string[]): Harness {
  const ctx = {gen: 0, cancelled: false, mode};
  const events: any[] = [];
  const execs: string[] = [];
  const logs: string[] = [];
  const client = new ScriptedClient(responses);
  const flow = new ConfirmFlow({
    context: {
      currentGeneration: () => ctx.gen,
      permissionMode: () => ctx.mode,
      isCancelled: () => ctx.cancelled,
      bumpGeneration: () => { ctx.gen++; },
    },
    events: {onInfo: () => {}, onConfirmRequest: () => {}, onWaitingConfirm: () => {}, onLog: () => {}},
  });
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: () => {}, onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      commandExecutor: async (cmd: string): Promise<CommandExecResult> => {
        execs.push(cmd);
        return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
      },
    } as any,
  );
  const write = process.stderr.write.bind(process.stderr);
  (process.stderr as any).write = (chunk: any, enc?: any, cb?: any): boolean => {
    const s = String(chunk);
    if (s.startsWith("[agent-core] gate ")) logs.push(s);
    else write(chunk, enc, cb);
    return true;
  };
  const restore = () => { (process.stderr as any).write = write; };
  const run = async (): Promise<string> => {
    try {
      return await engine.run(TASK, 10);
    } finally {
      restore();
    }
  };
  return {engine, client, events, execs, logs, run};
}

const FINISH = [T_ANSWER_FINISH];

describe("engine goal-marker guard: the marker is not a command", () => {
  it("marker never reaches the executor and yields the synthetic observation", async () => {
    const h = harness("auto", [turn(MARKER), ...FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.execs).toEqual([]);
    const results = h.events.filter((e) => e.type === "result");
    expect(results.length).toBe(1);
    expect(results[0].command).toBe(MARKER);
    expect(results[0].success).toBe(true);
    expect(results[0].output).toBe(EXPECT_OUTPUT);
    expect(results[0].exitCode).toBe(0);
    // the model must see the explanation, in the same wrapper every result uses
    // The engine replays the goal prompt as the LAST user message each round, so the
    // observation is found by its wrapper prefix, not by position.
    const obsMsg = h.client.prompts[1].find((m) => m.role === "user" && m.content.startsWith(T_RESULT_PREFIX));
    expect(obsMsg === undefined).toBe(false);
    expect(obsMsg.content).toBe(T_RESULT_PREFIX + EXPECT_OUTPUT);
    // Dart 3865 log line, byte for byte, through logGate
    expect(h.logs.some((l) => l.includes(GOAL_LOG_FROM_DART()))).toBe(true);
  });

  it("every strip-class variant is caught, punctuation-decorated markers included", async () => {
    for (const v of VARIANTS) {
      const h = harness("auto", [turn(v), ...FINISH]);
      expect(await h.run()).toBe("success");
      expect(h.execs).toEqual([]);
      const r = h.events.find((e) => e.type === "result");
      expect(r === undefined).toBe(false);
      expect(r.output).toBe(EXPECT_OUTPUT);
    }
  });

  it("readOnly still rejects a blocked command: the guard sits after the gate", async () => {
    const h = harness("readOnly", [turn(CMD_BLOCKED), ...FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.execs).toEqual([]);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    const info = h.events.filter((e) => e.type === "info" && e.text.startsWith(LOCK));
    expect(info.length).toBe(1);
  });

  it("real commands are untouched by the guard", async () => {
    const h = harness("auto", [turn(CMD_SAFE), ...FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.execs).toEqual([CMD_SAFE]);
    const r = h.events.find((e) => e.type === "result");
    expect(r.output).toBe("ran");
  });

  it("observation and log strings match the Dart source byte for byte", async () => {
    const h = harness("auto", [turn(MARKER), ...FINISH]);
    await h.run();
    const r = h.events.find((e) => e.type === "result");
    expect(r.output).toBe(OUTPUT_FROM_DART());
    expect(h.logs.some((l) => l.includes(GOAL_LOG_FROM_DART()))).toBe(true);
  });
});

/** Extract the 3868 output string from the Dart source (guard body). */
function OUTPUT_FROM_DART(): string {
  const src = readText(DART_ENGINE);
  const at = src.indexOf("isGoalMarkerOnlyCommand(command)");
  if (at < 0) throw new Error("guard not found in Dart source");
  const m = src.slice(at).match(/success: true,\r?\n\s*output: '([^']+)'/);
  if (m === null) throw new Error("guard output not found");
  return m[1];
}

/** Extract the 3865 ReAct log string from the Dart source (guard body). */
function GOAL_LOG_FROM_DART(): string {
  const src = readText(DART_ENGINE);
  const at = src.indexOf("isGoalMarkerOnlyCommand(command)");
  if (at < 0) throw new Error("guard not found in Dart source");
  const m = src.slice(at).match(/agentLogger\.info\('ReAct', '([^']+)'\)/);
  if (m === null) throw new Error("guard log line not found");
  return m[1];
}
