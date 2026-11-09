// W7 checkpoint store + engine resume tests (hermetic: uses temp dirs).
import {describe,it,expect,beforeEach,afterEach} from "vitest";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {rmSync, existsSync} from "node:fs";
import {CheckpointStore} from "../src/utils/checkpoint_store.js";
import {ReActEngine} from "../src/react/engine.js";
import {MockLlmClient} from "../src/llm/clients.js";

function makeStore() {
  const dir = join(tmpdir(), "ac_cp_" + process.pid + "_" + Math.random().toString(36).slice(2));
  return {store: new CheckpointStore(dir), cleanup: () => rmSync(dir, {recursive: true, force: true})};
}

const modelConfig = {provider: "openai" as const, model: "gpt-4o", apiKey: "k"};

describe("CheckpointStore", () => {
  it("save + load round-trips a checkpoint", () => {
    const {store, cleanup} = makeStore();
    try {
      const cp = {
        taskId: "task1", operationId: "op1", hostId: "host1", goal: "do thing",
        step: 3, conversation: [{role: "user", content: "hi"}], seenStableIds: ["a","b"],
        state: "inProgress" as const, savedAt: "2025-01-01T00:00:00Z",
      };
      store.save(cp);
      const loaded = store.load("task1");
      expect(loaded).not.toBeNull();
      expect(loaded!.taskId).toBe("task1");
      expect(loaded!.step).toBe(3);
      expect(loaded!.conversation).toHaveLength(1);
      expect(loaded!.state).toBe("inProgress");
    } finally { cleanup(); }
  });

  it("load returns null when no checkpoint exists", () => {
    const {store, cleanup} = makeStore();
    try { expect(store.load("nope")).toBeNull(); } finally { cleanup(); }
  });

  it("list returns only matching-state checkpoints", () => {
    const {store, cleanup} = makeStore();
    try {
      store.save({taskId:"a",hostId:"h",goal:"g",step:1,conversation:[],seenStableIds:[],state:"inProgress",savedAt:""});
      store.save({taskId:"b",hostId:"h",goal:"g",step:2,conversation:[],seenStableIds:[],state:"success",savedAt:""});
      const inProgress = store.list("inProgress");
      expect(inProgress.map(c=>c.taskId)).toEqual(["a"]);
      const all = store.list();
      expect(all).toHaveLength(2);
    } finally { cleanup(); }
  });

  it("delete is idempotent + removes the file", () => {
    const {store, cleanup} = makeStore();
    try {
      store.save({taskId:"x",hostId:"h",goal:"g",step:0,conversation:[],seenStableIds:[],state:"inProgress",savedAt:""});
      expect(store.load("x")).not.toBeNull();
      store.delete("x");
      expect(store.load("x")).toBeNull();
      store.delete("x"); // idempotent — no throw
      expect(store.load("x")).toBeNull();
    } finally { cleanup(); }
  });

  it("resumeHint: 'resume' only for inProgress, else 'fresh'", () => {
    const {store, cleanup} = makeStore();
    try {
      expect(store.resumeHint("none")).toBe("fresh");
      store.save({taskId:"live",hostId:"h",goal:"g",step:1,conversation:[],seenStableIds:[],state:"inProgress",savedAt:""});
      expect(store.resumeHint("live")).toBe("resume");
      store.save({taskId:"done",hostId:"h",goal:"g",step:5,conversation:[],seenStableIds:[],state:"success",savedAt:""});
      expect(store.resumeHint("done")).toBe("fresh");
    } finally { cleanup(); }
  });
});

describe("ReActEngine W7 resume", () => {
  it("emits a resume info event and starts from the checkpoint step", async() => {
    const {store, cleanup} = makeStore();
    try {
      // Pre-seed a checkpoint at step 1
      store.save({
        taskId: "t-resume", hostId: "h", goal: "g", step: 1,
        conversation: [{role: "user", content: "prev"}],
        seenStableIds: ["seed1"],
        state: "inProgress", savedAt: "2025-01-01T00:00:00Z",
      });

      const events: any[] = [];
      const llm = new MockLlmClient([
        "动作: ls -la\n工具: exec\n参数: []\n结束",
      ]);
      const engine = new ReActEngine(llm, modelConfig, {
        onEvent: (e) => events.push(e),
        onFinished: () => {},
      }, {checkpointStore: store, resumeFromCheckpoint: true});

      await engine.run({taskId: "t-resume", goal: "g", hostId: "h", modelConfig} as any, 5);

      // The resume info event should be present
      const resumeEvt = events.find((e) => e.type === "info" && String(e.text).includes("1"));
      expect(resumeEvt).toBeDefined();
    } finally { cleanup(); }
  });

  it("user cancel() -> terminal 'cancelled' + checkpoint deleted", async() => {
    const {store, cleanup} = makeStore();
    try {
      store.save({
        taskId: "t-cancel", hostId: "h", goal: "g", step: 0,
        conversation: [], seenStableIds: [],
        state: "inProgress", savedAt: "2025-01-01T00:00:00Z",
      });
      // Slow LLM: first response arrives after the caller has already cancelled.
      const llm = new MockLlmClient(["thinking"]);
      const engine = new ReActEngine(llm, modelConfig, {
        onEvent: () => {},
        onFinished: () => {},
      }, {checkpointStore: store});
      const p = engine.run({taskId: "t-cancel", goal: "g", hostId: "h", modelConfig} as any, 5);
      // Cancel after the run has started (before/at the first await boundary)
      engine.cancel();
      const state = await p;
      expect(state).toBe("cancelled");
      // W7: "cancelled" is a whitelist terminal -> checkpoint is deleted
      expect(store.load("t-cancel")).toBeNull();
    } finally { cleanup(); }
  });

    it("terminal FAILED keeps the checkpoint (resumable)", async() => {
    const {store, cleanup} = makeStore();
    try {
      store.save({
        taskId: "t-fail", hostId: "h", goal: "g", step: 0,
        conversation: [], seenStableIds: [],
        state: "inProgress", savedAt: "2025-01-01T00:00:00Z",
      });
      // No 动作: finish, no 命令: → maxNoCommandRetries exhausted → "failed"
      const llm = new MockLlmClient(["thinking... no command emitted"]);
      const engine = new ReActEngine(llm, modelConfig, {
        onEvent: () => {},
        onFinished: () => {},
      }, {checkpointStore: store});
      const state = await engine.run({taskId: "t-fail", goal: "g", hostId: "h", modelConfig} as any, 2);
      expect(state).toBe("failed");
      // FAILED is resumable → checkpoint is kept as the --resume seed point
      expect(store.load("t-fail")).not.toBeNull();
      expect(store.load("t-fail")!.state).toBe("inProgress");
    } finally { cleanup(); }
  });

  it("terminal success deletes the checkpoint", async() => {
    const {store, cleanup} = makeStore();
    try {
      store.save({
        taskId: "t-done", hostId: "h", goal: "g", step: 0,
        conversation: [], seenStableIds: [],
        state: "inProgress", savedAt: "2025-01-01T00:00:00Z",
      });
      const llm = new MockLlmClient(["思考: 完成\n动作: finish"]); // 动作: finish → success path // 动作: finish → success path
      const engine = new ReActEngine(llm, modelConfig, {
        onEvent: () => {},
        onFinished: () => {},
      }, {checkpointStore: store});
      await engine.run({taskId: "t-done", goal: "g", hostId: "h", modelConfig} as any, 3);
      // On a terminal non-interrupted finish the checkpoint file is deleted
      expect(store.load("t-done")).toBeNull();
    } finally { cleanup(); }
  });
});
