// utils/process_supervisor.ts - W6 process manager (lazy spawn / heartbeat / crash restart)
//
// Manages a spawned agent_core Node child process:
//   - lazy spawn: the child is not started until the first call
//   - heartbeat: periodic ping via reverse-rpc channel; if N consecutive
//     heartbeats are missed the child is considered dead
//   - crash restart: when the child exits unexpectedly the supervisor
//     re-spawns it with exponential backoff (capped), up to maxRestarts
//   - clean shutdown: shutdown() kills the child and stops the timer
//
// The supervisor owns the ProcessHandle it returns. Callers must not call
// .kill() / .unref() directly — use handle.dispose() for clean teardown.
//
// No external deps. Works in both real-process mode (for production) and
// injected-spawn mode (for tests, where we pass a fake child).

import {spawn, ChildProcess} from "node:child_process";
import {EventEmitter} from "node:events";

// ── Types ────────────────────────────────────────────────────────────────────

export interface ProcessHandle {
  readonly pid: number;
  /** Write a line to the child's stdin. */
  write(line: string): void;
  /** Resolve when the child exits; return code or null if killed by signal. */
  exited: Promise<number | null>;
  /** Kill the child (SIGTERM by default). Resolves when it actually exits. */
  kill(signal?: NodeJS.Signals): Promise<void>;
  /** Whether the child is currently running. */
  isRunning(): boolean;
  /** Cleanly dispose: kill if running, clear timers. Idempotent. */
  dispose(): Promise<void>;
}

export interface SupervisorConfig {
  /** Command to spawn the child (node + bundle path). */
  command: string;
  args: string[];
  /** Optional env override (merged over process.env). */
  env?: NodeJS.ProcessEnv;
  /** ms between heartbeat pings. 0 = no heartbeat. Default 5000. */
  heartbeatMs?: number;
  /** How many consecutive missed heartbeats before declaring death. Default 3. */
  missThreshold?: number;
  /** Max restarts before giving up. Default 5. */
  maxRestarts?: number;
  /** Base backoff ms. Doubling each restart, capped at 30_000. */
  baseBackoffMs?: number;
  /** Override the spawn factory (tests inject a fake child here). */
  spawnFn?: (cmd: string, args: string[], opts: any) => ChildProcess;
  /** Injectable heartbeat-ping function. In real mode this would go through
   *  the reverse-rpc channel; default is a no-op that relies on child exit. */
  heartbeatPing?: (handle: ProcessHandle) => Promise<void>;
}

// ── Supervisor ───────────────────────────────────────────────────────────────

export class ProcessSupervisor extends EventEmitter {
  private readonly cfg: Required<Omit<SupervisorConfig,'env'|'spawnFn'|'heartbeatPing'>> & Pick<SupervisorConfig,'env'|'spawnFn'|'heartbeatPing'>;
  private handle: ProcessHandle | null = null;
  private restartCount = 0;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private missCount = 0;
  private disposedInstances = new Set<ProcessHandle>();

  constructor(cfg: SupervisorConfig) {
    super();
    this.cfg = {
      command: cfg.command,
      args: cfg.args,
      env: cfg.env,
      heartbeatMs: cfg.heartbeatMs ?? 5000,
      missThreshold: cfg.missThreshold ?? 3,
      maxRestarts: cfg.maxRestarts ?? 5,
      baseBackoffMs: cfg.baseBackoffMs ?? 500,
      spawnFn: cfg.spawnFn,
      heartbeatPing: cfg.heartbeatPing,
    };
  }

  /**
   * Lazily spawn the child if not already running. Returns the current handle.
   * If the previous handle has exited and restarts remain, spawns a fresh one.
   */
  async ensure(): Promise<ProcessHandle> {
    if (this.handle && this.handle.isRunning()) return this.handle;
    // previous handle died → attempt restart with backoff
    if (this.handle) {
      if (this.restartCount >= this.cfg.maxRestarts) {
        throw new Error(
          "ProcessSupervisor: max restarts (" + this.cfg.maxRestarts + ") reached; not respawning");
      }
      const backoff = Math.min(this.cfg.baseBackoffMs * Math.pow(2, this.restartCount), 30_080);
      await sleep(backoff);
      this.restartCount++;
      this.emit("restarted", this.restartCount);
    }
    this.handle = this.spawnChild();
    this.startHeartbeat();
    return this.handle;
  }

  /** Tear down: kill the running child (if any) and stop all timers. Idempotent. */
  async shutdown(): Promise<void> {
    this.stopHeartbeat();
    if (this.handle && this.handle.isRunning()) {
      await this.handle.dispose();
    }
    this.handle = null;
  }

  /** True if the supervisor has a live child right now. */
  isRunning(): boolean {
    return this.handle !== null && this.handle.isRunning();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  private spawnChild(): ProcessHandle {
    const sup = this;
    const spawner = this.cfg.spawnFn ?? (
      (cmd: string, args: string[], opts: any) =>
        spawn(cmd, args, {stdio: "pipe", ...opts})
    );
    const child: ChildProcess = spawner(this.cfg.command, this.cfg.args, {
      env: {...process.env, ...this.cfg.env},
    });

    const state = {exiting: false};
    const exited = new Promise<number | null>((resolve) => {
      const onExit = (code: number | null) => {
        state.exiting = true;
        this.stopHeartbeat();
        this.emit("exited", code, this.restartCount);
        resolve(code);
      };
      child.once("exit", onExit);
      // Also handle spawn error (ENOENT etc.) — emit "error" then exit with -1
      child.once("error", (err) => {
        this.emit("spawnError", err);
        // force-exit if the child didn't start
        if (!state.exiting) onExit(-1);
      });
    });

    let killAck: Promise<void> = exited.then(() => {});

    const handle: ProcessHandle = {
      pid: child.pid ?? -1,
      write(line: string) {
        if (!state.exiting) child.stdin?.write(line + "\n");
      },
      exited,
      async kill(signal: NodeJS.Signals = "SIGTERM") {
        if (!state.exiting) child.kill(signal);
        return killAck;
      },
      isRunning: () => !state.exiting,
      dispose: (() => {
        let done = false;
        return async () => {
          if (done) return;
          done = true;
          sup.disposedInstances.add(handle);
          if (!state.exiting) child.kill("SIGTERM");
          await killAck;
        };
      })(),
    };
    return handle;
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    if (this.cfg.heartbeatMs <= 0 || !this.cfg.heartbeatPing) return;
    this.missCount = 0;
    this.heartbeatTimer = setInterval(async () => {
      if (!this.handle || !this.handle.isRunning()) return;
      try {
        await this.cfg.heartbeatPing!(this.handle);
        this.missCount = 0;
      } catch {
        this.missCount++;
        this.emit("heartbeatMiss", this.missCount);
        if (this.missCount >= this.cfg.missThreshold) {
          this.emit("dead", this.missCount);
          await this.handle.dispose();
          // ensure() will respawn on next call if restarts remain
        }
      }
    }, this.cfg.heartbeatMs);
    // Don't keep the event loop alive just for the heartbeat
    if (this.heartbeatTimer?.unref) this.heartbeatTimer.unref();
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
