// Engine-side change-window arm, end to end (doc sec. 9 item 7; Dart agent_engine.dart
// 2573-2588, wired in round 133).
//
// Round 132 proved the config maths and the reason sentence against the Dart source. It
// deliberately did NOT wire the arm, so it could not prove the wiring: that
// react/engine.ts consults the freeze BETWEEN classification and the permission gate,
// that a frozen command never reaches the executor, never arms a confirmation, never
// mints a result event, and never logs the step/permission line - and that with nothing
// saved the pipeline stays byte-identical to the pre-r133 gate.
//
// Everything below drives a real ReActEngine with a scripted LLM client, so every claim
// is behavioural: the prompts the model actually received, the events that actually left
// the process, the executor calls that actually happened, and the lines logGate actually
// wrote to stderr. ASCII-pure: CJK literals are \uXXXX escapes, and the window texts come
// from the module's exported constants rather than being re-typed here.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow, formatObservationFailure} from "../src/react/confirm_flow.js";
import {
  LlmClient,
  LlmResult,
  LlmResponseOptions,
  ChatMsg,
} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";
import type {ChangeWindowCheck, ChangeWindowConfig, ChangeWindowSettingsPort} from "../src/utils/change_window.js";
import {
  SETTINGS_KEY,
  LOAD_FAIL_PREFIX,
  REASON_HEAD,
  REASON_HOUR_SEP,
  REASON_HOUR_TAIL,
  REASON_WEEKDAY_SEP,
  REASON_TAIL,
  WINDOW_INFO_HEAD,
  WINDOW_INFO_TAIL,
  WINDOW_LOG_WARN,
  checkChangeWindowCommand,
  defaultChangeWindowConfig,
  fmtHour,
  fmtWeekdays,
  loadChangeWindow,
  saveChangeWindow,
  setChangeWindowStore,
  toWeekday,
} from "../src/utils/change_window.js";

const T_THINK = "\u601d\u8003: ";                       // "think: "
const T_CMD_LINE = "\u547d\u4ee4: ";                     // "command: "
const T_ACTION_EXEC = "\u52a8\u4f5c: execute\n";         // "action: execute"
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n"; // finish turn
// The permission gate's own log line (engine.ts, Dart 2593-2594): "step N - permission MODE -> DECISION".
// Pinned as head + tail fragments because the arm must NOT write it for a frozen command.
const STEP_HEAD = "\u6b65\u9aa4 ";                       // "step "
const STEP_TAIL = " \u00b7 \u6743\u9650 ";               // " - permission "
// The anti-hallucination guard's refusal info (Dart 1460), needed to prove a window
// refusal does not count as an executed command.
const GUARD_INFO = "\u26a0\ufe0f AI \u672a\u5b9e\u9645\u6267\u884c\u547d\u4ee4\u5c31\u58f0\u79f0\u5b8c\u6210\uff0c\u8981\u6c42\u5b9e\u9645\u9a8c\u8bc1";

const CMD_WARN = "rm -rf ./build-cache";   // classified warn by the real table
const CMD_SAFE = "echo hello world";       // classified safe
const REASON_STUB = "stub-freeze-reason";  // an injected reason, no CJK needed

function turn(cmd: string): string {
  return T_THINK + "run it\n" + T_ACTION_EXEC + T_CMD_LINE + cmd + "\n";
}

const FINISH = [T_ANSWER_FINISH];

const TASK = {taskId: "t-window", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;

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

/** Capture every logGate line a run writes. logGate is stderr-only by design, so this -
 * not an event - is the only way to see the frozen-window warn and the step/permission
 * line. The same idiom engine_is_task_complete_fallback.test.ts uses. */
async function captureGate<T>(fn: () => Promise<T>): Promise<[T, string]> {
  const writes: string[] = [];
  const orig = process.stderr.write.bind(process.stderr);
  process.stderr.write = ((chunk: any): boolean => {
    writes.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    const value = await fn();
    return [value, writes.join("")];
  } finally {
    process.stderr.write = orig;
  }
}

interface Harness {
  engine: ReActEngine;
  flow: ConfirmFlow;
  client: ScriptedClient;
  events: any[];
  requests: string[];
  order: string[];
  windowCalls: string[];
  ctx: {gen: number; cancelled: boolean; mode: PermissionMode};
  run: () => Promise<string>;
}

function harness(opts: {
  mode: PermissionMode;
  responses: string[];
  guard?: boolean;
  safetyCheck?: (cmd: string) => any;
  windowCheck?: (cmd: string) => ChangeWindowCheck;
  executor?: (cmd: string) => Promise<CommandExecResult>;
}): Harness {
  const ctx = {gen: 0, cancelled: false, mode: opts.mode};
  const events: any[] = [];
  const requests: string[] = [];
  const order: string[] = [];
  const windowCalls: string[] = [];
  const client = new ScriptedClient(opts.responses);
  // A flow is ALWAYS wired: if the window arm armed a confirmation the ask/auto cases
  // would hang, which is itself the answer - a frozen command never reaches that code.
  const flow = new ConfirmFlow({
    context: {
      currentGeneration: () => ctx.gen,
      permissionMode: () => ctx.mode,
      isCancelled: () => ctx.cancelled,
      bumpGeneration: () => { ctx.gen++; },
    },
    events: {
      onInfo: (t) => requests.push(t),
      onConfirmRequest: (r) => requests.push("request:" + r.confirmId + ":" + r.riskLevel),
      onWaitingConfirm: () => requests.push("waiting"),
      onLog: () => {},
    },
  });
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: () => {}, onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      hallucinationGuard: opts.guard === true,
      safetyCheck: opts.safetyCheck ?? undefined,
      changeWindowCheck: opts.windowCheck ?? undefined,
      commandExecutor: opts.executor ??
        (async (cmd: string): Promise<CommandExecResult> => {
          order.push("exec");
          requests.push("exec:" + cmd);
          return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
        }),
    } as any,
  );
  if (opts.windowCheck !== undefined) {
    // Wrap the injected seam so "how many times did the gate consult the window?" is
    // answerable. Done via the option rather than the engine: the option IS the seam.
    const inner = opts.windowCheck;
    (engine as any).changeWindowCheckFn = (cmd: string): ChangeWindowCheck => {
      windowCalls.push(cmd);
      return inner(cmd);
    };
  }
  return {
    engine,
    flow,
    client,
    events,
    requests,
    order,
    windowCalls,
    ctx,
    run: () => engine.run(TASK, 10) as Promise<string>,
  };
}

describe("change-window arm: inert when nothing is saved (DEFAULT_ENABLED=false)", () => {
  it("an unwired store leaves the whole gate pipeline exactly as r132 left it", async () => {
    const h = harness({mode: "fullAuto", responses: [turn(CMD_WARN), ...FINISH]});
    const [state, log] = await captureGate(() => h.run());
    expect(state).toBe("success");
    expect(h.order).toStrictEqual(["exec"]);
    expect(h.events.filter((e) => e.type === "result").length).toBe(1);
    expect(h.events.filter((e) => e.type === "info").length).toBe(0);
    // The window warn never fires, and the permission line still does: the arm ran and
    // stepped aside, it did not replace the gate.
    expect(log.includes("[agent-core] gate warn: " + WINDOW_LOG_WARN)).toBe(false);
    expect(log.includes(STEP_HEAD)).toBe(true);
    expect(log.includes(STEP_TAIL + "fullAuto")).toBe(true);
  });

  it("the seam is consulted once per attempt - classification keeps its Dart double call", async () => {
    const seen: string[] = [];
    const h = harness({
      mode: "fullAuto",
      responses: [turn(CMD_WARN), ...FINISH],
      safetyCheck: (cmd: string) => { seen.push("classify:" + cmd); return "warn" as any; },
      windowCheck: () => ({allowed: true, reason: null}),
    });
    const [state] = await captureGate(() => h.run());
    expect(state).toBe("success");
    // Dart classifies twice per command (event snapshot 2978 + gate) - the window arm
    // must NOT add a third call, and it is consulted once, at the gate only: the command
    // event's enrich pass stays window-free, so the wire snapshot cannot drift.
    expect(seen).toStrictEqual(["classify:" + CMD_WARN, "classify:" + CMD_WARN]);
    expect(h.windowCalls).toStrictEqual([CMD_WARN]);
    expect(h.order).toStrictEqual(["exec"]);
    expect(h.events.filter((e) => e.type === "result").length).toBe(1);
  });
});

describe("change-window arm: a frozen window refuses before the permission gate", () => {
  it("one info event, the Dart observation, no result event, no executor call", async () => {
    const h = harness({
      mode: "fullAuto",
      responses: [turn(CMD_WARN), ...FINISH],
      windowCheck: () => ({allowed: false, reason: REASON_STUB}),
    });
    const [state, log] = await captureGate(() => h.run());
    expect(state).toBe("success");              // the loop survived the refusal
    expect(h.client.prompts.length).toBe(2);    // the model was asked again
    expect(h.order).toStrictEqual([]);          // never anywhere near the executor
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.length).toBe(1);
    expect(infos[0].text).toBe(WINDOW_INFO_HEAD + CMD_WARN + WINDOW_INFO_TAIL + REASON_STUB);
    // Dart 2579-2584: ReActObservation(success:false, error: reason).format() - handed to
    // the model verbatim, so the next turn is told WHY nothing ran.
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content === formatObservationFailure(CMD_WARN, REASON_STUB))).toBe(true);
    // Dart 2577: agentLogger.warn, stderr-only like every other gate line.
    expect(log.includes("[agent-core] gate warn: " + WINDOW_LOG_WARN + CMD_WARN)).toBe(true);
    // Dart 2586-2587 returns _EarlyExecutionResult from inside the gate helper, so the
    // permission decision is never taken and never logged for a frozen command.
    expect(log.includes(STEP_HEAD)).toBe(false);
    expect(log.includes(STEP_TAIL)).toBe(false);
  });

  it("no permission tier can override the freeze, and the readOnly info is skipped too", async () => {
    for (const mode of ["readOnly", "ask", "auto", "fullAuto"] as PermissionMode[]) {
      const h = harness({
        mode,
        responses: [turn(CMD_WARN), ...FINISH],
        windowCheck: () => ({allowed: false, reason: REASON_STUB}),
      });
      const [state] = await captureGate(() => h.run());
      expect(state).toBe("success");
      expect(h.order).toStrictEqual([]);                                    // no executor
      expect(h.requests.some((r) => r.startsWith("request:"))).toBe(false); // no confirm box
      expect(h.flow.hasPendingConfirm).toBe(false);
      expect(h.events.some((e) => e.type === "result")).toBe(false);
      // Exactly ONE info event: in readOnly the permission-refusal info would otherwise
      // be emitted, so one event proves the window arm ran first and exited the gate.
      const infos = h.events.filter((e) => e.type === "info");
      expect(infos.length).toBe(1);
      expect(infos[0].text.startsWith(WINDOW_INFO_HEAD)).toBe(true);
    }
  });

  it("the command event snapshot still reports what the PERMISSION gate would have done", async () => {
    // Dart stamps riskLevel / permissionDecision at emit time (2971-2983), and the UI
    // renders that snapshot. The window is NOT a permission tier, so the card keeps
    // saying "execute" for a command the freeze refused. Pinned so nobody "fixes" the
    // card by consulting the window inside enrichCommandEvent - that would be a wire
    // change, not a bug fix.
    const h = harness({
      mode: "fullAuto",
      responses: [turn(CMD_WARN), ...FINISH],
      windowCheck: () => ({allowed: false, reason: REASON_STUB}),
    });
    await captureGate(() => h.run());
    const cmd = h.events.find((e) => e.type === "command");
    expect(cmd.riskLevel).toBe("warn");
    expect(cmd.permissionDecision).toBe("execute");
    expect(h.order).toStrictEqual([]);
  });

  it("a window refusal is not an executed command for the finish guard (Dart 2388)", async () => {
    // Dart sets _hasExecutedAnyCommand inside the EXECUTED branch only. So with the guard
    // on, a run whose only command was frozen still gets its finish refused twice: a
    // blocked command must never look like progress.
    const h = harness({
      mode: "fullAuto",
      guard: true,
      responses: [turn(CMD_WARN), T_ANSWER_FINISH, T_ANSWER_FINISH, T_ANSWER_FINISH],
      windowCheck: () => ({allowed: false, reason: REASON_STUB}),
    });
    const [state] = await captureGate(() => h.run());
    expect(state).toBe("success");
    expect(h.client.prompts.length).toBe(4);   // frozen turn + 2 refused finishes + 1 pass
    expect(h.events.filter((e) => e.type === "info" && e.text === GUARD_INFO).length).toBe(2);
    expect(h.events.filter((e) => e.type === "info" && e.text.startsWith(WINDOW_INFO_HEAD)).length).toBe(1);
    expect(h.events.filter((e) => e.type === "finish").length).toBe(1);
    expect(h.order).toStrictEqual([]);
    // Mirror: the same guard is satisfied by a command that actually ran.
    const h2 = harness({mode: "fullAuto", guard: true, responses: [turn(CMD_SAFE), ...FINISH]});
    await captureGate(() => h2.run());
    expect(h2.client.prompts.length).toBe(2);
    expect(h2.events.filter((e) => e.type === "info" && e.text === GUARD_INFO).length).toBe(0);
    expect(h2.order).toStrictEqual(["exec"]);
  });
});

describe("change-window arm: the real module function decides, config by config", () => {
  // 2026-03-11 is a Wednesday; 14:00 sits outside a 22:00-06:00 freeze. Fixed Date parts,
  // so the composition is deterministic whatever clock the suite runs under.
  const WED = new Date(2026, 2, 11, 14, 0, 0);
  const FREEZE: ChangeWindowConfig = {enabled: true, startHour: 22, endHour: 6, allowedWeekdays: []};
  const seam = (cmd: string): ChangeWindowCheck => checkChangeWindowCommand(cmd, {now: WED, config: FREEZE});

  it("frozen hour: the warn command is refused with the Dart sentence, the safe one runs", async () => {
    const h = harness({
      mode: "fullAuto",
      responses: [turn(CMD_WARN), turn(CMD_SAFE), ...FINISH],
      windowCheck: seam,
    });
    const [state] = await captureGate(() => h.run());
    expect(state).toBe("success");
    expect(h.order).toStrictEqual(["exec"]);    // only the safe command ever ran
    expect(h.events.filter((e) => e.type === "result").length).toBe(1);
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.length).toBe(1);
    expect(infos[0].text).toBe(
      WINDOW_INFO_HEAD + CMD_WARN + WINDOW_INFO_TAIL +
      REASON_HEAD + fmtHour(22) + REASON_HOUR_SEP + fmtHour(6) + REASON_HOUR_TAIL +
      REASON_TAIL + "warn");
    expect(h.windowCalls).toStrictEqual([CMD_WARN, CMD_SAFE]);
    // Dart 143-145: a safe command never consults the calendar at all - the module
    // returns before the hour maths, and the engine executes it.
    expect(h.requests.filter((r) => r === "exec:" + CMD_SAFE).length).toBe(1);
  });

  it("the weekday clause is part of the reason the model is handed", async () => {
    const cfg: ChangeWindowConfig = {enabled: true, startHour: 22, endHour: 6, allowedWeekdays: [3]};
    const h = harness({
      mode: "ask",
      responses: [turn(CMD_WARN), ...FINISH],
      windowCheck: (cmd: string) => checkChangeWindowCommand(cmd, {now: WED, config: cfg}),
    });
    const [state, log] = await captureGate(() => h.run());
    expect(state).toBe("success");
    expect(h.order).toStrictEqual([]);
    expect(h.flow.hasPendingConfirm).toBe(false);   // ask would normally arm a box here
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.length).toBe(1);
    expect(infos[0].text).toBe(
      WINDOW_INFO_HEAD + CMD_WARN + WINDOW_INFO_TAIL +
      REASON_HEAD + "22" + REASON_HOUR_SEP + "06" + REASON_HOUR_TAIL +
      REASON_WEEKDAY_SEP + fmtWeekdays([3]) + REASON_TAIL + "warn");
    expect(log.includes("[agent-core] gate warn: " + WINDOW_LOG_WARN + CMD_WARN)).toBe(true);
  });

  it("an open window leaves the decision to the permission gate (ask still confirms)", async () => {
    const open: ChangeWindowConfig = {enabled: true, startHour: 9, endHour: 18, allowedWeekdays: []};
    const h = harness({
      mode: "ask",
      responses: [turn(CMD_WARN), ...FINISH],
      windowCheck: (cmd: string) => checkChangeWindowCommand(cmd, {now: WED, config: open}),
    });
    // The 14:00 hour falls inside 09:00-18:00, so the ask-mode box must be armed by the
    // engine and answered over the flow - the pre-r133 behaviour, untouched.
    const run = h.run();
    for (let i = 0; i < 400 && !h.flow.hasPendingConfirm; i++) await new Promise<void>((r) => setTimeout(r, 5));
    expect(h.flow.hasPendingConfirm).toBe(true);
    h.flow.confirmDangerousCommand();
    expect(await run).toBe("success");
    expect(h.order).toStrictEqual(["exec"]);
    expect(h.events.filter((e) => e.type === "result").length).toBe(1);
    expect(h.events.filter((e) => e.type === "info").length).toBe(0);
  });
});

describe("change-window arm: the injected store seam (deviation 1 and 7)", () => {
  interface MemPort extends ChangeWindowSettingsPort {
    saved: Array<[string, Record<string, unknown>]>;
    cached: unknown;
  }
  const memPort = (cached: unknown = undefined): MemPort => ({
    cached,
    saved: [],
    getCached: (_key: string) => this_cached(),
    set: (_key: string, value: Record<string, unknown>) => { mem.saved.push([_key, value]); },
  });
  // Small dance so the closure can see the object it is defined inside.
  let mem: MemPort;
  function this_cached(): unknown { return mem.cached; }
  const seed = (cached: unknown): MemPort => { mem = memPort(cached); return mem; };

  const resetStore = async (): Promise<void> => {
    setChangeWindowStore(undefined);
    await saveChangeWindow(defaultChangeWindowConfig());
  };

  it("a saved freeze reaches the engine through the DEFAULT seam", async () => {
    // No changeWindowCheck injected: the engine's default seam is
    // checkChangeWindowCommand(command), which reads the module cache - exactly like the
    // Dart static call. Weekday [not-today] makes "outside" clock-independent.
    const wd = toWeekday(new Date());
    const notToday = wd === 7 ? 1 : wd + 1;
    const port = seed(undefined);
    setChangeWindowStore(port);
    try {
      await saveChangeWindow({enabled: true, startHour: 9, endHour: 17, allowedWeekdays: [notToday]});
      const h = harness({mode: "fullAuto", responses: [turn(CMD_WARN), ...FINISH]});
      const [state, log] = await captureGate(() => h.run());
      expect(state).toBe("success");
      expect(h.order).toStrictEqual([]);
      expect(log.includes("[agent-core] gate warn: " + WINDOW_LOG_WARN + CMD_WARN)).toBe(true);
      const infos = h.events.filter((e) => e.type === "info");
      expect(infos.length).toBe(1);
      expect(infos[0].text).toBe(
        WINDOW_INFO_HEAD + CMD_WARN + WINDOW_INFO_TAIL +
        REASON_HEAD + "09" + REASON_HOUR_SEP + "17" + REASON_HOUR_TAIL +
        REASON_WEEKDAY_SEP + fmtWeekdays([notToday]) + REASON_TAIL + "warn");
      // The store really was written, under the Dart key, with the four Dart keys in the
      // Dart order - the config the engine honoured is the config on disk.
      expect(port.saved.length).toBe(1);
      expect(port.saved[0][0]).toBe(SETTINGS_KEY);
      expect(Object.keys(port.saved[0][1])).toStrictEqual(["enabled", "startHour", "endHour", "allowedWeekdays"]);
    } finally {
      await resetStore();
    }
  });

  it("a saved window that covers now leaves the command to the permission gate", async () => {
    const wd = toWeekday(new Date());
    const port = seed(undefined);
    setChangeWindowStore(port);
    try {
      // startHour === endHour is Dart's "no window" edge (117-121), so this stays true
      // whatever hour the suite runs at.
      await saveChangeWindow({enabled: true, startHour: 9, endHour: 9, allowedWeekdays: [wd]});
      const h = harness({mode: "fullAuto", responses: [turn(CMD_WARN), ...FINISH]});
      const [state, log] = await captureGate(() => h.run());
      expect(state).toBe("success");
      expect(h.order).toStrictEqual(["exec"]);
      expect(h.events.filter((e) => e.type === "result").length).toBe(1);
      expect(log.includes(WINDOW_LOG_WARN)).toBe(false);
      expect(log.includes(STEP_HEAD)).toBe(true);
    } finally {
      await resetStore();
    }
  });

  it("a corrupt stored config keeps the previous cache, and the command runs", async () => {
    // Dart load() 71-81: fromJson throws on a bad int.parse, the catch debugPrints and
    // keeps the old cache. The Node port keeps the DEFAULT (disabled), so the freeze
    // never becomes a silent veto - and the failure is logged, not swallowed (R8).
    const port = seed({enabled: true, startHour: 22, endHour: 6, allowedWeekdays: ["nope"]});
    setChangeWindowStore(port);
    try {
      const warns: string[] = [];
      const origWarn = console.warn;
      console.warn = (...args: unknown[]) => { warns.push(args.map((a) => String(a)).join(" ")); };
      try {
        await loadChangeWindow();
      } finally {
        console.warn = origWarn;
      }
      expect(warns.length).toBe(1);
      expect(warns[0].startsWith(LOAD_FAIL_PREFIX)).toBe(true);
      const h = harness({mode: "fullAuto", responses: [turn(CMD_WARN), ...FINISH]});
      const [, log] = await captureGate(() => h.run());
      expect(h.order).toStrictEqual(["exec"]);
      expect(log.includes(WINDOW_LOG_WARN)).toBe(false);
    } finally {
      await resetStore();
    }
  });
});
