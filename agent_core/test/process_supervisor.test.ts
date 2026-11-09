// W6 process supervisor tests — hermetic, no real process spawn.
import {describe,it,expect} from "vitest";
import {ProcessSupervisor} from "../src/utils/process_supervisor.js";
import {ChildProcess} from "node:child_process";
import {EventEmitter} from "node:events";
import {PassThrough} from "node:stream";

// Minimal fake child process for tests
class FakeChild extends EventEmitter {
  pid = 99999;
  stdin: any = {write: () => {}, destroy: () => {}};
  exited = false;
  killCode: string | null = null;
  constructor(private opts?: {exitAfterMs?: number, signal?: string}) {
    super();
    if (opts?.exitAfterMs !== undefined) {
      setTimeout(() => {
        this.exited = true;
        this.emit("exit", opts?.signal ? null : 0);
      }, opts.exitAfterMs);
    }
  }
  kill(signal?: string) {
    this.killCode = signal ?? "SIGTERM";
    if (!this.exited) {
      this.exited = true;
      this.emit("exit", signal ? null : 0);
    }
    return true;
  }
  unref() {}
}

function makeSupervisor(opts: any = {}) {
  let lastFake: FakeChild | null = null;
  const sup = new ProcessSupervisor({
    command: "node", args: ["--fake"],
    heartbeatMs: 100,
    missThreshold: 3,
    maxRestarts: 3,
    baseBackoffMs: 1,
    spawnFn: (_cmd, _args, _o) => { lastFake = new FakeChild(); return lastFake as any; },
    ...opts,
  });
  return {sup, getLastFake: () => lastFake!};
}

describe("ProcessSupervisor", () => {
  it("lazily spawns on first ensure() call", async () => {
    const {sup, getLastFake} = makeSupervisor();
    expect(sup.isRunning()).toBe(false);
    const h = await sup.ensure();
    expect(h.pid).toBe(99999);
    expect(sup.isRunning()).toBe(true);
    await sup.shutdown();
  });

  it("ensure() reuses a running handle (no double spawn)", async () => {
    const {sup} = makeSupervisor();
    const h1 = await sup.ensure();
    const h2 = await sup.ensure();
    expect(h1).toBe(h2);
    await sup.shutdown();
  });

  it("detects a crashed child and emits 'exited'", async () => {
    const {sup} = makeSupervisor({
      spawnFn: () => {
        const c = new FakeChild({exitAfterMs: 50});
        return c as any;
      },
    });
    const h = await sup.ensure();
    await h.exited; // wait for crash
    expect(sup.isRunning()).toBe(false);
  });

  it("re-spawns with backoff after crash", async () => {
    const {sup} = makeSupervisor({
      spawnFn: () => {
        const c = new FakeChild({exitAfterMs: 20});
        return c as any;
      },
    });
    const h1 = await sup.ensure();
    await h1.exited;
    // Second ensure() should trigger a restart
    const h2 = await sup.ensure();
    expect(h2.pid).toBe(99999);
    expect(h2).not.toBe(h1);
    await sup.shutdown();
  });

  it("refuses to restart after maxRestarts exceeded", async () => {
    const {sup} = makeSupervisor({
      maxRestarts: 2,
      baseBackoffMs: 1,
      spawnFn: () => {
        const c = new FakeChild({exitAfterMs: 5});
        return c as any;
      },
    });
    await sup.ensure();
    // crash + restart 1
    let h = await sup.ensure();
    await h.exited;
    // crash + restart 2
    h = await sup.ensure();
    await h.exited;
    // crash again — now restartCount >= maxRestarts
    h = await sup.ensure();
    await h.exited;
    await expect(sup.ensure()).rejects.toThrow(/max restarts/);
  });

  it("heartbeatMiss fires when heartbeatPing throws and child is still running", async () => {
    let missed = 0;
    const {sup} = makeSupervisor({
      heartbeatMs: 10,
      missThreshold: 999, // won't trigger death during test window
      heartbeatPing: async () => { throw new Error("no response"); },
    });
    const events: string[] = [];
    sup.on("heartbeatMiss", () => { missed++; });
    await sup.ensure();
    // Wait a few heartbeats
    await new Promise((r) => setTimeout(r, 80));
    expect(missed).toBeGreaterThanOrEqual(1);
    await sup.shutdown();
  }, 2000);

  it("shutdown() is idempotent and stops timers", async () => {
    const {sup} = makeSupervisor();
    await sup.ensure();
    await sup.shutdown();
    await sup.shutdown(); // second call — no throw
    expect(sup.isRunning()).toBe(false);
  });
});
