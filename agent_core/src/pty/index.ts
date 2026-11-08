// pty/index.ts - local PTY facade (node-pty).
export {spawnLocalPty, resolvePtyShell, buildPtyEnv, buildPtyConfig} from "./adapter.js";
export type {PtySession, PtyOptions, PtyConfig, PtyShellResolution, ShellKind, ExistCheck} from "./adapter.js";
