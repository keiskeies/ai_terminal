// pty/adapter.ts - node-pty wrapper (Phase 2 / W4), replacing Dart flutter_pty.

// Mirrors LocalTerminalService (flutter_pty) 1:1 on the contract that matters:
//   - Windows ConPTY quirk: under ConPTY, spawning powershell.exe directly exits
//     silently; it must be hosted by cmd.exe (`/K powershell.exe -NoLogo`).
//   - non-Windows env disables pagers (PAGER/SYSTEMD_PAGER/GIT_PAGER/MANPAGER=cat)
//     so interactive shell commands never stall at an (END) prompt.
//   - R6: shell selection branches by platform; TERM=xterm-256color on all.
//   - R8: output is buffered with a tail-retaining cap; exit completes waiters.

// The native node-pty spawn is isolated behind spawnLocalPty(); the pure config
// helpers (resolvePtyShell / buildPtyEnv / buildPtyConfig) are separately exported
// and unit-testable without a live process. The filesystem-existence check used for
// POSIX shell fallback is injectable (`exists`) so these helpers stay pure and
// platform-independent in tests.

import * as fsNode from "fs";

// node-pty 1.x: spawn(file, args, {cols,rows,cwd,env,encoding,useConpty}),
// returns IPty { pid, onData(data:string)=>IDisposable, onExit(e)=>IDisposable,
//                write, resize(cols,rows), kill, dispose }.
// Type the native module loosely so the build does not require @types/node-pty.
interface NodePtyIPty {
  readonly pid: number;
  onData: (cb: (data: string) => void) => { dispose(): void };
  onExit: (cb: (e: { exitCode: number; signal?: number }) => void) => { dispose(): void };
  write(data: string): void;
  resize(columns: number, rows: number): void;
  kill(signal?: string): void;
  dispose(): void;
}
interface NodePty {
  spawn(file: string, args: string[], options: {
    cols?: number; rows?: number; cwd?: string; env?: Record<string, string>;
    encoding?: string | null; useConpty?: boolean; name?: string;
  }): NodePtyIPty;
}

let nativeModule: NodePty | null = null;
async function loadNative(): Promise<NodePty> {
  if (nativeModule) return nativeModule;
  const m = (await import("node-pty")) as unknown;
  nativeModule = m as unknown as NodePty;
  return nativeModule;
}

export type ShellKind = "powershell" | "cmd" | "bash" | "zsh" | "sh";
/** Injected filesystem-existence predicate (default: fs.existsSync). */
export type ExistCheck = (p: string) => boolean;

export interface PtyShellResolution {
  shell: string;
  args: string[];
  kind: ShellKind;
  /** True on the Windows ConPTY powershell-hosted-by-cmd case. */
  powersShellHosted: boolean;
}

/** Default (real) existence check; only used outside tests. */
function defaultExists(p: string): boolean {
  try { return fsNode.existsSync(p); } catch { return false; }
}

// Classify a shell path by its basename (bash/zsh/sh). The Dart original does not
// classify kind - this is an adapter detail; basename is the only robust signal.
function kindFromPath(p: string): ShellKind {
  const base = p.split("/").pop() ?? p.split("\\").pop() ?? p;
  if (base.endsWith("zsh")) return "zsh";
  if (base === "sh" || base.endsWith("/sh")) return "sh";
  if (base === "bash" || base.endsWith("bash")) return "bash";
  return "sh";
}

/**
 * Resolve the interactive shell + args for the given platform (R6). On Windows
 * PowerShell is preferred when present, but spawned THROUGH cmd.exe because of the
 * flutter_pty/ConPTY quirk. On POSIX, prefer $SHELL, else bash/zsh/sh, with -l.
 * `exists` is injectable so the logic is deterministic and host-independent.
 */
export function resolvePtyShell(
  platform: NodeJS.Platform = process.platform,
  env: Record<string, string | undefined> = process.env,
  exists: ExistCheck = defaultExists,
): PtyShellResolution {
  if (platform === "win32") {
    const psPath = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    if (exists(psPath)) {
      return {shell: "cmd.exe", args: ["/K", "powershell.exe", "-NoLogo"], kind: "powershell", powersShellHosted: true};
    }
    return {shell: "cmd.exe", args: [], kind: "cmd", powersShellHosted: false};
  }
  const userShell = env["SHELL"];
  if (userShell && exists(userShell)) {
    const kind: ShellKind = kindFromPath(userShell);
    return {shell: userShell, args: ["-l"], kind, powersShellHosted: false};
  }
  for (const cand of ["/bin/bash", "/bin/zsh", "/bin/sh"]) {
    if (exists(cand)) {
      const kind: ShellKind = kindFromPath(cand);
      return {shell: cand, args: ["-l"], kind, powersShellHosted: false};
    }
  }
  return {shell: "bash", args: ["-l"], kind: "bash", powersShellHosted: false};
}

/**
 * Build the child env: TERM always; pagers disabled on non-Windows (R8: keep commands
 * from stalling at an (END) prompt). Merges over the base process.env.
 */
export function buildPtyEnv(platform: NodeJS.Platform = process.platform, base: Record<string, string | undefined> = process.env): Record<string, string> {
  const env: Record<string, string> = {};
  for (const k of Object.keys(base)) if (base[k] !== undefined) env[k] = base[k] as string;
  env["TERM"] = "xterm-256color";
  if (platform !== "win32") {
    env["PAGER"] = "cat";
    env["SYSTEMD_PAGER"] = "cat";
    env["GIT_PAGER"] = "cat";
    env["MANPAGER"] = "cat";
    env["CLICOLOR"] = "1";
    env["LSCOLORS"] = "ExFxCxDxBxegedabagacad";
    env["LS_COLORS"] = "rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32";
  }
  return env;
}

export interface PtyConfig {
  shell: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
  cols: number;
  rows: number;
  useConpty: boolean;
}

export interface PtyOptions {
  columns?: number;
  rows?: number;
  cwd?: string;
  /** Override the resolved shell (e.g. for tests). */
  shell?: string;
  shellArgs?: string[];
  platform?: NodeJS.Platform;
  env?: Record<string, string | undefined>;
  /** Injected existence predicate (threaded to resolvePtyShell). */
  exists?: ExistCheck;
}

/** Pure: assemble the full spawn config from options. No side effects. */
export function buildPtyConfig(opts: PtyOptions = {}): PtyConfig {
  const platform = opts.platform ?? process.platform;
  const cols = opts.columns ?? 80;
  const rows = opts.rows ?? 24;
  const resolved = opts.shell
    ? {shell: opts.shell, args: opts.shellArgs ?? [], kind: "sh" as ShellKind, powersShellHosted: false}
    : resolvePtyShell(platform, opts.env ?? process.env, opts.exists ?? defaultExists);
  const cwd = opts.cwd ?? (platform === "win32" ? (process.env["USERPROFILE"] ?? process.cwd()) : (process.env["HOME"] ?? process.cwd()));
  return {
    shell: resolved.shell,
    args: resolved.args,
    cwd, env: buildPtyEnv(platform, opts.env ?? process.env), cols, rows,
    useConpty: platform === "win32",
  };
}

export interface PtySession {
  readonly pid: number | null;
  readonly running: boolean;
  /** Subscribe to raw output. Returns a disposable. */
  onOutput(cb: (chunk: string) => void): { dispose(): void };
  /** Subscribe to exit. Returns a disposable. */
  onExit(cb: (e: { exitCode: number; signal?: number }) => void): { dispose(): void };
  /** Bounded, tail-retaining buffer of everything observed so far. */
  bufferedOutput(): string;
  write(data: string): void;
  resize(columns: number, rows: number): void;
  kill(): void;
  dispose(): void;
}

const MAX_BUFFER = 20000; // R8: bounded, tail retained

/**
 * Spawn a real PTY session. Fails fast (throws) if the native module is missing or
 * the ConPTY/pipe attach fails on this host. Output listeners accumulate into a
 * tail-capped buffer.
 */
export async function spawnLocalPty(opts: PtyOptions = {}): Promise<PtySession> {
  const cfg = buildPtyConfig(opts);
  const pty = await loadNative();
  const handle: NodePtyIPty = pty.spawn(cfg.shell, cfg.args, {
    cols: cfg.cols, rows: cfg.rows, cwd: cfg.cwd, env: cfg.env,
    encoding: "utf8", useConpty: cfg.useConpty, name: "xterm-256color",
  });

  let buffer = "";
  let exited = false;
  const outSubs = new Set<(c: string) => void>();
  const exitSubs = new Set<(e: { exitCode: number; signal?: number }) => void>();
  let disposed = false;

  const dataSub = handle.onData((chunk) => {
    buffer += chunk;
    if (buffer.length > MAX_BUFFER) buffer = buffer.slice(-MAX_BUFFER); // R8 tail
    for (const cb of outSubs) cb(chunk);
  });
  const exitSub = handle.onExit((e) => {
    if (exited) return;
    exited = true;
    for (const cb of exitSubs) cb(e);
  });

  const session: PtySession = {
    get pid() { return handle.pid; },
    get running() { return !exited && !disposed; },
    onOutput(cb) { outSubs.add(cb); return {dispose: () => outSubs.delete(cb)}; },
    onExit(cb) { exitSubs.add(cb); return {dispose: () => exitSubs.delete(cb)}; },
    bufferedOutput: () => buffer,
    write(data: string) { if (!exited && !disposed) handle.write(data); },
    resize(columns, rows) { if (!disposed) handle.resize(columns, rows); },
    kill() { if (!exited && !disposed) try { handle.kill(); } catch {} },
    dispose() {
      if (disposed) return;
      disposed = true;
      try { dataSub.dispose(); } catch {}
      try { exitSub.dispose(); } catch {}
      try { handle.dispose(); } catch {}
      outSubs.clear(); exitSubs.clear();
    },
  };
  return session;
}