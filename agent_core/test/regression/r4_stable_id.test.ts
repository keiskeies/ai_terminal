// Regression: docs §6.2 r4_stable_id.test.ts (AGENTS.md R4).
//
// R4 makes three demands of the id space:
//   (a) dedup by stableId (content hash), never by a sequence id;
//   (b) with several commands in one run, every result links to its OWN command
//      id - not to one shared "_lastCommandEventId";
//   (c) a dedup hash with a low collision rate (the "h * 31 + b over int32" note).
//
// This file owns the DIVISION OF LABOUR between the two id shapes, which is where
// the port actually broke. There are two and only two legitimate id shapes:
//   stableId(type, content) - FNV-1a content hash, reproducible. Identity IS the
//                             content, so it is what the stream dedup gate keys
//                             on. Parser-produced events (thought/text/command/
//                             ask) plus the parser's finish.
//   genEventId()            - Dart AgentEvent._genId() (models/agent_event.dart:
//                             218): "evt_" + epoch ms + "_" + a process counter.
//                             An OCCURRENCE id: the event reports a fact, so two
//                             occurrences are two events even with equal content.
// The port initially minted result ids with stableId("result", tool + "|" +
// status), which hashed neither the command nor the args - every successful call
// of a tool therefore shared one id. That is the regression the collision bullets
// below pin, and it was a real defect: Dart's AgentEvent.result() always calls
// _genId() (agent_event.dart:181) and result events are emitted outside the Dart
// dedup gate, so ids must be unique per occurrence.
//
// Siblings, deliberately not re-owned here:
//   utils/stable_hash + e2e/byte_comparison_10 + fixture_diff - the digest itself
//     byte-for-byte against Dart, plus the locked golden hexes for parser events.
//   tools/dispatcher.test.ts - tool routing, failureKind and args parsing.
//   rpc/reverse_rpc.test.ts - reverse-RPC plumbing and payload shapes.
//   regression/r1_stream_cancel - the generation/cancel gates around emission.
//   regression/r5_terminal_whitelist - which terminal states may have side effects.

import {describe, it, expect} from "vitest";
import {readFileSync, rmSync} from "node:fs";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {fileURLToPath} from "node:url";
import {ReActEngine, CommandExecResult} from "../../src/react/engine.js";
import {CheckpointStore} from "../../src/utils/checkpoint_store.js";
import {parse} from "../../src/react/parser.js";
import {ToolDispatcher} from "../../src/tools/dispatcher.js";
import {buildDefaultToolRegistry} from "../../src/tools/index.js";
import {ReverseRpcClient} from "../../src/rpc/client.js";
import {genEventId, stableHashOf, stableId} from "../../src/utils/stable_hash.js";
import {MockLlmClient} from "../../src/llm/clients.js";
import {
  AgentEvent,
  AgentFinishState,
  JsonRpcNotification,
  JsonRpcRequest,
  ModelConfig,
} from "../../src/rpc/schema.js";
import {RpcTransport} from "../../src/rpc/transport.js";

const OCCURRENCE_ID = /^evt_\d+_\d+$/;
const HEX_ID = /^evt_[0-9a-f]+$/;

const MC: ModelConfig = {provider: "openai", model: "gpt-4o", apiKey: "k"};
const CMD = (c: string) => "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: " + c;
const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";
const NOISE = "\u53ea\u662f\u4e00\u6bb5\u666e\u901a\u7684\u56de\u590d\u6587\u5b57";

const task = (id: string) =>
  ({taskId: id, goal: "g", hostId: "h", modelConfig: MC}) as never;

async function drive(
  responses: string[],
  opts: {maxSteps?: number; taskId?: string; cancelAfterStart?: boolean} = {},
): Promise<AgentEvent[]> {
  const events: AgentEvent[] = [];
  const engine = new ReActEngine(
    new MockLlmClient(responses),
    MC,
    {onEvent: (e) => { events.push(e); }, onFinished: () => {}, onError: () => {}},
    {
      commandExecutor: async (cmd: string): Promise<CommandExecResult> => ({
        stdout: "out-of " + cmd, stderr: "", exitCode: 0, durationMs: 1, success: true,
      }),
    },
  );
  const p = engine.run(task(opts.taskId ?? "r4-" + Math.random().toString(36).slice(2)), opts.maxSteps ?? 8);
  if (opts.cancelAfterStart) engine.cancel();
  await p;
  return events;
}

const of = (events: AgentEvent[], type: string) => events.filter((e) => e.type === type);

/** Read the TS source of a src/ file: shape-of-the-code assertions, like r5 does. */
function src(rel: string): string {
  return readFileSync(fileURLToPath(new URL("../../src/" + rel, import.meta.url)), "utf-8");
}

describe("content hash (stableId) is for identity, and identity IS content", () => {
  it("an identical step across two engine instances hashes to the same id", async () => {
    const a = await drive([CMD("uname -a"), FINISH], {taskId: "r4-x1"});
    const b = await drive([CMD("uname -a"), FINISH], {taskId: "r4-x2"});
    const ca = of(a, "command")[0];
    const cb = of(b, "command")[0];
    expect(ca).toBeDefined();
    expect(cb).toBeDefined();
    // Cross-instance equality is what lets a replayed step be recognised: the dedup
    // gate keys on this id, so a per-instance id would make every repeat look new.
    expect(cb.id).toBe(ca.id);
    expect(ca.id).toMatch(HEX_ID);
    expect(ca.id).toBe(stableId("command", "uname -a"));
  });

  it("ids namespace by type: one content under three types gives three ids", () => {
    const ids = new Set([
      stableId("command", "echo hi"),
      stableId("thought", "echo hi"),
      stableId("text", "echo hi"),
    ]);
    expect(ids.size).toBe(3);
    for (const id of ids) expect(id).toMatch(HEX_ID);
    // stableHashOf hashes the input verbatim (no type salt) - a different function
    // for a different job, not a second spelling of stableId.
    expect(stableHashOf("echo hi")).toMatch(HEX_ID);
    expect(stableHashOf("echo hi")).not.toBe(stableId("command", "echo hi"));
  });

  it("no sequence component leaks into a content hash", () => {
    const id = stableId("command", "ls -la");
    expect(id.startsWith("evt_")).toBe(true);
    expect(id.slice(4).includes("_")).toBe(false); // the shape only genEventId may have
    expect(Number.isNaN(parseInt(id.slice(4), 16))).toBe(false);
  });

  it("the dedup gate keys on that hash, so a repeated turn emits exactly once", async () => {
    const events = await drive([NOISE, NOISE, NOISE, FINISH], {maxSteps: 9, taskId: "r4-dedupe"});
    const texts = of(events, "text");
    expect(texts.length).toBe(1);
    expect(texts[0].id).toBe(stableId("text", NOISE));
  });
});

describe("occurrence ids (genEventId) are Dart _genId, and nothing else", () => {
  it("shape: evt_<epoch ms>_<counter>, strictly increasing, never a hash", () => {
    const before = Date.now();
    const a = genEventId();
    const b = genEventId();
    const ma = /^evt_(\d+)_(\d+)$/.exec(a);
    const mb = /^evt_(\d+)_(\d+)$/.exec(b);
    expect(ma, a).not.toBeNull();
    expect(mb, b).not.toBeNull();
    expect(Number(ma![1])).toBeGreaterThanOrEqual(before);
    expect(Number(ma![1])).toBeLessThanOrEqual(Date.now());
    expect(Number(mb![2])).toBeGreaterThan(Number(ma![2])); // monotonic -> no collision in-process
    expect(a).not.toBe(b);
    expect(a).toMatch(OCCURRENCE_ID);
    expect(a).not.toMatch(HEX_ID); // the counter segment keeps it out of the hex space
  });

  it("occurrence events carry occurrence ids (regression: they were content-hashed)", async () => {
    const events = await drive([CMD("make build"), CMD("make build"), FINISH], {taskId: "r4-occ"});
    const results = of(events, "result");
    expect(results.length).toBe(2);
    const ids = results.map((e) => e.id);
    // The defect: both results got stableId("result","...") - the SAME id, because
    // neither the command nor the args entered the key. A card key or dedup keyed
    // on event.id collapses two runs of the command into one row.
    expect(new Set(ids).size).toBe(2);
    for (const e of results) expect(e.id, e.command ?? "result").toMatch(OCCURRENCE_ID);
    // the repeat command itself is still deduped by its content hash, and the
    // two results stay linked to that one command
    const cmds = of(events, "command");
    expect(cmds.length).toBe(1);
    expect(cmds[0].id).toMatch(HEX_ID);
    for (const r of results) expect(r.commandId).toBe(cmds[0].id);
  });

  it("finish has two producers with two id shapes, and both are correct", async () => {
    // (1) the AI said "finish": the finish event comes from the PARSER, so its id
    //     is a content hash and finishState is absent - the engine then defaults
    //     the returned state to "success".
    const ok = await drive([FINISH], {taskId: "r4-f-parse"});
    const pf = of(ok, "finish");
    expect(pf.length).toBe(1);
    // the id is exactly what the parser mints for that text (stableId over the
    // captured answer body) - the engine forwards it untouched.
    const parsed = parse(FINISH).filter((e) => e.type === "finish");
    expect(parsed.length).toBe(1);
    expect(pf[0].id).toBe(parsed[0].id);
    expect(pf[0].id).toMatch(HEX_ID);
    expect(pf[0].id).toBe(stableId("finish", "ok"));
    expect(pf[0].finishState ?? "success").toBe("success");
    // (2) engine-emitted terminals (emitFinish) are occurrences.
    const failed = await drive(["a"], {maxSteps: 3, taskId: "r4-f-max"});
    const ff = of(failed, "finish");
    expect(ff.length).toBe(1);
    expect(ff[0].finishState).toBe("failed");
    expect(ff[0].id).toMatch(OCCURRENCE_ID);
    const cancelled = await drive([NOISE], {maxSteps: 3, taskId: "r4-f-cancel", cancelAfterStart: true});
    const cf = of(cancelled, "finish");
    expect(cf.length).toBe(1);
    expect(cf[0].finishState).toBe("cancelled");
    expect(cf[0].id).toMatch(OCCURRENCE_ID);
    // and the two engine terminals never share an id even though the states differ
    expect(cf[0].id).not.toBe(ff[0].id);
  });

  it("the resume notice is an occurrence id, not a per-task hash", async () => {
    // Regression: engine.ts minted it as stableId("info", "resumed " + taskId), so
    // resuming the same task twice produced one identical id for two notices.
    const dir = join(tmpdir(), "ac_r4_resume_" + process.pid + "_" + Math.random().toString(36).slice(2));
    const store = new CheckpointStore(dir);
    const taskId = "r4-resume";
    try {
      const ids: string[] = [];
      const seed = () => store.save({
        taskId, hostId: "h", goal: "g", step: 2,
        conversation: [{role: "user", content: "earlier"}],
        seenStableIds: [], state: "inProgress", savedAt: new Date().toISOString(),
      } as never);
      seed();
      for (const _ of [0, 1]) {
        // Two resumes of the SAME task id, so any task-derived hash would repeat.
        // Re-seed first: a successful run deletes its checkpoint (r5_terminal_
        // whitelist owns that gate), so the second resume needs its own snapshot.
        seed();
        const engine = new ReActEngine(new MockLlmClient([FINISH]), MC, {
          onEvent: (e) => { if (e.type === "info") ids.push(e.id); },
          onFinished: () => {}, onError: () => {},
        }, {checkpointStore: store, resumeFromCheckpoint: true});
        await engine.run(task(taskId), 4);
      }
      expect(ids.length).toBe(2);
      for (const id of ids) expect(id).toMatch(OCCURRENCE_ID);
      expect(ids[0]).not.toBe(ids[1]);
      // every engine-minted occurrence site uses the sequence id, never a hash
      const es = src("react/engine.ts");
      expect(es).toMatch(/id: genEventId\(\)/);
      expect(es).not.toMatch(/stableId\("info"/);
      expect(es).not.toMatch(/stableId\("result"/);
      expect(es).not.toMatch(/stableId\("finish"/);
    } finally {
      rmSync(dir, {recursive: true, force: true});
    }
  });
});

describe("R4(b): every result links to its OWN command", () => {
  it("two commands in one run give two results with distinct commandIds", async () => {
    const events = await drive([CMD("echo one"), CMD("echo two"), FINISH], {taskId: "r4-link"});
    const cmds = of(events, "command");
    const results = of(events, "result");
    expect(cmds.length).toBe(2);
    expect(results.length).toBe(2);
    expect(new Set(cmds.map((e) => e.id)).size).toBe(2);
    // The historical bug: one _lastCommandEventId for all results, so both cards
    // linked to whichever command was written last.
    expect(results[0].commandId).toBe(cmds[0].id);
    expect(results[1].commandId).toBe(cmds[1].id);
    expect(results[0].commandId).not.toBe(results[1].commandId);
    expect(results[0].output ?? "").toContain("echo one");
    expect(results[1].output ?? "").toContain("echo two");
  });

  it("dispatcher threads commandId through every result path, including failures", async () => {
    const d = new ToolDispatcher(buildDefaultToolRegistry());
    const okA = await d.dispatch({toolName: "fetch_url", argsText: "url: data:text/plain,hi", commandId: "cmd-alpha"});
    const okB = await d.dispatch({toolName: "fetch_url", argsText: "url: data:text/plain,bye", commandId: "cmd-beta"});
    expect(okA.executed).toBe(true);
    expect(okA.event.commandId).toBe("cmd-alpha");
    expect(okB.event.commandId).toBe("cmd-beta");
    // distinct occurrences of the same tool -> distinct ids (the fixed collision)
    expect(okB.event.id).not.toBe(okA.event.id);
    const unknown = await d.dispatch({toolName: "no_such_tool", argsText: "", commandId: "cmd-x"});
    expect(unknown.event.failureKind).toBe("unknown_tool");
    expect(unknown.event.commandId).toBe("cmd-x");
    const cancelled = await d.dispatch({
      toolName: "fetch_url", argsText: "url: data:text/plain,x", commandId: "cmd-cancel",
      ctx: {cancelled: () => true},
    });
    expect(cancelled.event.failureKind).toBe("cancelled");
    expect(cancelled.event.commandId).toBe("cmd-cancel");
    // a block the typed parser rejects (line without a colon) -> bad_args
    const bad = await d.dispatch({
      toolName: "local_file_read",
      argsText: "path: /x\ncontinuation without colon",
      commandId: "cmd-bad",
    });
    expect(bad.event.failureKind).toBe("bad_args");
    expect(bad.event.commandId).toBe("cmd-bad");
    // no command context -> undefined. Never a borrowed/stale command id, which is
    // exactly the mis-linking R4 warns about.
    const bare = await d.dispatch({toolName: "fetch_url", argsText: "url: data:text/plain,hi"});
    expect(bare.event.commandId).toBeUndefined();
    for (const e of [okA, okB, unknown, cancelled, bad, bare]) {
      expect(e.event.id, e.event.toolName ?? "dispatch").toMatch(OCCURRENCE_ID);
    }
  });
});

describe("R4(a): dedup keys on the stable id, never on a sequence id", () => {
  it("the engine's dedup set would be useless if it keyed on occurrence ids", async () => {
    // Contrast the two id spaces through the gate: parser events (content hash)
    // dedup, occurrence events (genEventId) must NOT be gated - if they were, the
    // second "make build" result above would silently vanish.
    const events = await drive([NOISE, CMD("ls"), NOISE, CMD("ls"), FINISH], {maxSteps: 12, taskId: "r4-mixed"});
    expect(of(events, "text").length).toBe(1);      // hash-deduped
    expect(of(events, "command").length).toBe(1);   // hash-deduped
    expect(of(events, "result").length).toBe(2);    // occurrences, ungated, unique ids
    expect(new Set(of(events, "result").map((e) => e.id)).size).toBe(2);
    // the gate still keys on the event id, which at that point in the pipeline is
    // the stable content hash - keying it on a sequence id is the R4 failure mode.
    expect(src("react/engine.ts")).toMatch(/seenStableIds\.has\(evt\.id\)/);
  });
});

describe("R4(c): the dedup hash must not be an int32 rolling hash", () => {
  it("20k near-neighbour commands hash collision-free through the 63-bit digest", () => {
    const seen = new Set<string>();
    let collisions = 0;
    for (let i = 0; i < 20000; i++) {
      const id = stableId("command", "echo run_step_" + i);
      if (seen.has(id)) collisions++;
      seen.add(id);
    }
    expect(collisions).toBe(0);
    expect(seen.size).toBe(20000);
  });

  it("deterministic corpus: h*31+b over int32 collides on near neighbours, the digest does not", () => {
    // The reference implementation from the historical bug, reproduced verbatim so
    // the contrast stays measurable rather than rhetorical.
    const int32 = (s: string) => {
      let h = 0;
      for (let i = 0; i < s.length; i++) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0;
      return h >>> 0;
    };
    // LCG instead of Math.random(): a failure must be reproducible from the seed.
    let seed = 0x5eed1234;
    const rnd = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
    const alpha = "abcdefghijklmnopqrstuvwxyz0123456789";
    const corpus: string[] = [];
    for (let i = 0; i < 200000; i++) {
      let s = "";
      const len = 8 + (rnd() % 9);
      for (let k = 0; k < len; k++) s += alpha[rnd() % alpha.length];
      corpus.push("command:echo " + s);
    }
    const buckets = new Map<number, string>();
    let int32Collisions = 0;
    let pair: [string, string] | undefined;
    const digest = new Map<string, string>();
    let digestCollisions = 0;
    for (const s of corpus) {
      const a = int32(s);
      const prevA = buckets.get(a);
      if (prevA === undefined) buckets.set(a, s);
      else if (prevA !== s) { int32Collisions++; if (!pair) pair = [prevA, s]; }
      const b = stableId("command", s.slice("command:echo ".length));
      const prevB = digest.get(b);
      if (prevB === undefined) digest.set(b, s);
      else if (prevB !== s) digestCollisions++;
    }
    // The 32-bit accumulator is ~16 bits of digest too narrow to be a dedup key.
    expect(int32Collisions).toBeGreaterThan(0);
    expect(pair, "expected a colliding pair to inspect").toBeDefined();
    const [x, y] = pair as [string, string];
    expect(x).not.toBe(y);
    expect(int32(x)).toBe(int32(y));
    // ... and the digest separates that very pair.
    expect(stableId("command", x)).not.toBe(stableId("command", y));
    // Zero collisions for the digest on this corpus is the property R4 asks for.
    expect(digestCollisions).toBe(0);
    expect(digest.size).toBeGreaterThan(corpus.length - 2); // near-perfect: 1 in 2^63
  });

  it("the digest stays inside 63 bits and keeps short-input ids longer than 8 hex digits", () => {
    const id = stableId("command", "A");
    const bits = BigInt("0x" + id.slice(4)).toString(2).length;
    expect(bits).toBeLessThanOrEqual(63); // the Dart-compatible mask, see stable_hash.ts
    expect(id.length).toBeGreaterThan("evt_".length + 8);
    expect(stableId("command", "A")).not.toBe(stableId("command", "a"));
  });
});

describe("R4 in the reverse direction: reverse-RPC ids are deterministic too", () => {
  class FakeTransport implements RpcTransport {
    readonly sent: JsonRpcRequest[] = [];
    private readonly pending = new Map<string, (v: unknown) => void>();
    closedFlag = false;
    request<T>(msg: JsonRpcRequest): Promise<T> {
      this.sent.push(msg);
      return new Promise<T>((resolve) => {
        this.pending.set(msg.id, (v) => resolve(v as T));
        const cb = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        cb?.({jsonrpc: "2.0", id: msg.id, result: {ok: true, exitCode: 0, saved: true, hits: [], success: true}});
      });
    }
    notify(_msg: JsonRpcNotification): void {}
    respond(_id: string, _result: unknown): void {}
    reject(_id: string, _code: number, _message: string): void {}
    onNotification(_h: (n: JsonRpcNotification) => void): void {}
    onRequest(_h: (r: JsonRpcRequest) => void): void {}
    get closed(): boolean { return this.closedFlag; }
    close(): void { this.closedFlag = true; }
  }

  it("rev-<base36> monotonic ids replace Math.random()", async () => {
    const t = new FakeTransport();
    const c = new ReverseRpcClient(t);
    await c.invokeSsh({hostId: "h1", command: "ls"});
    await c.invokeSsh({hostId: "h1", command: "pwd"});
    await c.queryKnowledge({query: "ssh"});
    const ids = t.sent.map((r) => r.id);
    expect(ids).toEqual(["rev-1", "rev-2", "rev-3"]);
    for (const id of ids) expect(id).toMatch(/^rev-[0-9a-z]+$/);
    // A random request id cannot be replayed or diffed against a recorded session,
    // and it destroys the property R4 exists for: ids that say "same call again".
    expect(t.sent.every((r) => r.jsonrpc === "2.0")).toBe(true);
  });
});
