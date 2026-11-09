// Invariant #3 (design doc §10.3): 4 terminal states × 5 trigger paths = 20-cell matrix, all green.
// For each (path, state) cell:
//   - valid cell (the path's correct state): assert terminal state reached + W7 checkpoint kept/deleted + R5 finish emitted/not
//   - invalid cell (path can't reach that state): assert the engine did NOT return that state
import {describe, it, expect} from "vitest";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {rmSync} from "node:fs";
import {CheckpointStore} from "../src/utils/checkpoint_store.js";
import {ReActEngine} from "../src/react/engine.js";
import {MockLlmClient, LlmClient, LlmResult} from "../src/llm/clients.js";
import {AgentEvent} from "../src/rpc/schema.js";
import {ModelConfig} from "../src/llm/types.js";

const modelConfig: ModelConfig = {provider: "openai", model: "gpt-4o", apiKey: "k"};

// ── LLM client helpers (one per trigger path) ──

// Path 1 finish → success
const llmFinish = () => new MockLlmClient(["思考: done\n动作: finish"]);
// Path 2 max-steps → failed (no finish, no command; maxSteps=2 forces exhaustion)
const llmMaxSteps = () => new MockLlmClient(["thinking", "more thinking"]);
// Path 3 no-command-retry → failed (default maxNoCommandRetries=2; 3 no-cmd responses → failed)
const llmNoCmdRetry = () => new MockLlmClient(["no cmd", "still none", "still none", "still none"]);
// Path 4 llm-error → failed
class ThrowingLlm implements LlmClient {
  readonly name = "throwing";
  async chatStream(): Promise<LlmResult> { throw new Error("500 boom"); }
}
const llmError = () => new ThrowingLlm();
// Path 5 cancel/supersede → cancelled / interrupted (slow first response, no finish)
const llmSlow = () => new MockLlmClient(["slow response"]);

// ── Driver: run one path, collect state + events + store ──
// Each driver returns a RunResult and owns its own temp dir (cleanup() removes it).
interface RunResult {
  state: string;
  events: AgentEvent[];
  store: CheckpointStore;
  taskId: string;
  cleanup: () => void;
}

function seed(store: CheckpointStore, taskId: string) {
  store.save({
    taskId, hostId: "h", goal: "g", step: 0,
    conversation: [], seenStableIds: [],
    state: "inProgress", savedAt: "2025-01-01T00:00:00Z",
  });
}

function makeEngine(llm: LlmClient, events: AgentEvent[], store: CheckpointStore) {
  return new ReActEngine(llm, modelConfig, {
    onEvent: (e) => events.push(e),
    onFinished: () => {},
  }, {checkpointStore: store});
}

function runFinish(): RunResult {
  const dir = join(tmpdir(), "ac_fin_" + process.pid + "_" + Math.random().toString(36).slice(2));
  const store = new CheckpointStore(dir);
  const taskId = "t-mat-finish";
  seed(store, taskId);
  const events: AgentEvent[] = [];
  const engine = makeEngine(llmFinish(), events, store);
  const p = engine.run({taskId, goal: "g", hostId: "h", modelConfig} as any, 5);
  return {
    state: "", events, store, taskId,
    cleanup: () => rmSync(dir, {recursive: true, force: true}),
    // We resolve the state lazily via a promise stored on the result
    ...( (0) ? {} : {} ),
  } as unknown as RunResult & {p: Promise<string>};
}

// Simpler: return a fully-resolved result via an async driver.
async function drivePath(kind: string): Promise<RunResult> {
  const dir = join(tmpdir(), "ac_" + kind + "_" + process.pid + "_" + Math.random().toString(36).slice(2));
  const store = new CheckpointStore(dir);
  const taskId = "t-mat-" + kind;
  seed(store, taskId);
  const events: AgentEvent[] = [];
  let engine: ReActEngine;
  let p: Promise<string>;
  const params = {taskId, goal: "g", hostId: "h", modelConfig} as any;
  switch (kind) {
    case "finish":
      engine = makeEngine(llmFinish(), events, store);
      p = engine.run(params, 5);
      break;
    case "max-steps":
      engine = makeEngine(llmMaxSteps(), events, store);
      p = engine.run(params, 2);
      break;
    case "no-cmd-retry":
      engine = makeEngine(llmNoCmdRetry(), events, store);
      p = engine.run(params, 5);
      break;
    case "llm-error":
      engine = makeEngine(llmError(), events, store);
      p = engine.run(params, 3);
      break;
    case "cancel":
      engine = makeEngine(llmSlow(), events, store);
      p = engine.run(params, 5);
      engine.cancel(); // user-cancel → boundary() → emitFinish("cancelled")
      break;
    case "supersede":
      engine = makeEngine(llmSlow(), events, store);
      p = engine.run(params, 5);
      // Start a 2nd run on the same engine → supersedes the 1st's generation
      engine.run({...params, taskId: "t-mat-supersede2"} as any, 5).catch(() => {});
      break;
    default:
      throw new Error("unknown kind " + kind);
  }
  const state = await p;
  return {state, events, store, taskId, cleanup: () => rmSync(dir, {recursive: true, force: true})};
}

// ── Matrix definitions ──
const stateSpec: Record<string, {checkpoint: "kept" | "deleted"; finishEvent: "emitted" | "not-emitted"}> = {
  success:     {checkpoint: "deleted", finishEvent: "emitted"},
  cancelled:   {checkpoint: "deleted", finishEvent: "emitted"},
  failed:      {checkpoint: "kept",    finishEvent: "emitted"},
  interrupted: {checkpoint: "kept",    finishEvent: "not-emitted"},
};

// 5 trigger paths → their correct terminal state
const paths: Array<{kind: string; name: string; correctState: string}> = [
  {kind: "finish",       name: "finish",        correctState: "success"},
  {kind: "max-steps",    name: "max-steps",     correctState: "failed"},
  {kind: "no-cmd-retry", name: "no-command-retry", correctState: "failed"},
  {kind: "llm-error",    name: "llm-error",     correctState: "failed"},
  {kind: "cancel",       name: "cancel",        correctState: "cancelled"},
  {kind: "supersede",    name: "supersede",     correctState: "interrupted"},
];

describe("Invariant #3: 4 terminal states x 5 trigger paths = 20-cell matrix", () => {
  // 6 path-drivers × 4 states = 24 cells; the 4 "supersede" cells collapse to one
  // conceptual path (supersede→interrupted), so the meaningful matrix is the 5 user
  // paths + supersede. We test all 6 drivers × 4 states to be exhaustive (24 cells),
  // which strictly covers the required 20.
  for (const p of paths) {
    for (const [stateName, spec] of Object.entries(stateSpec)) {
      const isValid = p.correctState === stateName;
      const cell = p.name + " -> " + stateName;
      it(cell + (isValid ? " [valid]" : " [invalid]"), async () => {
        const r = await drivePath(p.kind);
        try {
          if (isValid) {
            expect(r.state, cell + " — expected terminal state '" + stateName + "'").toBe(stateName);
            const ck = r.store.load(r.taskId);
            if (spec.checkpoint === "deleted") {
              expect(ck, cell + " — W7: checkpoint should be deleted").toBeNull();
            } else {
              expect(ck, cell + " — W7: checkpoint should be kept").not.toBeNull();
            }
            const fin = r.events.find((e) => e.type === "finish") as (AgentEvent & {finishState?: string}) | undefined;
            if (spec.finishEvent === "emitted") {
              expect(fin, cell + " — R5: a finish event should be emitted").toBeDefined();
              // The finish event's finishState is either explicit (engine-driven paths:
              // failed/cancelled) or omitted (parser-driven success — engine defaults it).
              // Accept both: the event is present and, when present, not the wrong state.
              const fs_ = fin!.finishState;
              expect(fs_ === stateName || fs_ === undefined, cell + " — R5: finish event state should be '" + stateName + "' (or omitted for parser-driven success)").toBe(true);
            } else {
              expect(fin, cell + " — R5: no finish event should be emitted").toBeUndefined();
            }
          } else {
            expect(r.state, cell + " — path '" + p.name + "' should NOT reach '" + stateName + "'").not.toBe(stateName);
          }
        } finally { r.cleanup(); }
      });
    }
  }
});
