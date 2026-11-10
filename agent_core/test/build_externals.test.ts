// Regression: the two esbuild paths must produce the same artifact contract.
//
// agent_core is built twice over: CI runs "npm run build" (esbuild CLI flags in
// package.json -> dist/index.js, the gate the CI job runs) and W6 packaging runs
// tools/nodeapp.mjs (esbuild JS API -> dist/<platform>/index.js, the artifact the
// Dart parent actually spawns). They were hand-maintained copies and they drifted:
// the CLI list lacked node-pty (plus net/tls/http/...), so the CI artifact INLINED
// node-pty while the packaging artifact kept it external.
//
// Inlining is not cosmetic. node-pty is a native addon pulled in through a dynamic
// import; bundling it rewrites its loader into dynamic requires of Node builtins.
// In the drifted artifact the failure lands even earlier - calling spawnLocalPty()
// threw
//
//   Dynamic require of "events" is not supported
//
// i.e. the local-PTY path of that artifact was dead on arrival, and the whole test
// suite stayed green because vitest runs src/*.ts and never dist/*.js. That blind
// spot is what this file closes: the assertions below run against a REAL BUILD.
//
// Owned here: the externals contract, and "the artifact loads and reaches node-pty".
// Owned elsewhere: PTY behaviour (pty adapter tests, against src), wire shape
// (check-schema-compat), parser parity (byte_comparison_10).

import {describe, it, expect, beforeAll} from "vitest";
import {existsSync, readFileSync, rmSync} from "node:fs";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url)); // agent_core/ (trailing sep)
const PKG = JSON.parse(readFileSync(ROOT + "package.json", "utf-8")) as {
  scripts: Record<string, string>;
};

/** --external:X flags from the CI script, and EXTERNALS from tools/nodeapp.mjs. */
function cliExternals(): string[] {
  return [...PKG.scripts.build.matchAll(/--external:([A-Za-z0-9_-]+)/g)].map((m) => m[1]).sort();
}
function nodeappExternals(): string[] {
  const src = readFileSync(ROOT + "tools/nodeapp.mjs", "utf-8");
  const block = /const EXTERNALS = \[([\s\S]*?)\];/.exec(src);
  expect(block, "EXTERNALS array vanished from tools/nodeapp.mjs").not.toBeNull();
  return [...block![1].matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort();
}

describe("esbuild externals: CI CLI vs tools/nodeapp.mjs packaging", () => {
  it("both build paths declare the same externals", () => {
    // THE regression. Drift here silently changes what the artifact contains, and
    // nothing else in the suite looks at the artifact.
    expect(cliExternals()).toEqual(nodeappExternals());
  });

  it("node-pty stays external in BOTH paths", () => {
    // A native addon cannot be bundled; this must not regress to "fine, nothing
    // imported it in this particular build graph".
    expect(cliExternals()).toContain("node-pty");
    expect(nodeappExternals()).toContain("node-pty");
  });

  it("every Node builtin reachable from the graph stays external", () => {
    // A builtin left in-graph is latent, not absent: net/tls/http arrive via the
    // MCP SDK and only fail once a socket is opened in the built artifact.
    for (const m of ["fs", "path", "os", "crypto", "child_process", "net", "tls", "http", "https"]) {
      expect(cliExternals(), m + " must stay external").toContain(m);
    }
  });

  it("the CI script pins the same target and format as packaging", () => {
    // Packaging targets node18 because that is the embedded Node the Dart side
    // ships; a freer CI target lets newer syntax into the shipped artifact.
    expect(PKG.scripts.build).toMatch(/--target=node18\b/);
    expect(PKG.scripts.build).toMatch(/--format=esm\b/);
    expect(PKG.scripts.build).toMatch(/--platform=node\b/);
  });
});

describe("the built artifact (not src/) loads", () => {
  // Build under dist/ (already gitignored) instead of a temp dir: the sandbox for
  // these runs can leave os.tmpdir() undefined, and an undefined-ish path silently
  // becomes a literal ./undefined/... INSIDE the repo. dist/ is the real output dir
  // and a subdirectory of it, so this never clobbers dist/index.js itself.
  const OUT = ROOT + "dist/_contract_probe";
  const ENTRY = OUT + "/index.js";
  let buildOutput = "";

  beforeAll(() => {
    rmSync(OUT, {recursive: true, force: true});
    const r = spawnSync(
      process.execPath,
      [
        ROOT + "node_modules/esbuild/bin/esbuild",
        "src/index.ts",
        "--bundle",
        "--outfile=" + ENTRY,
        "--platform=node",
        "--format=esm",
        "--target=node18",
        "--log-level=silent",
        ...cliExternals().map((m) => "--external:" + m),
      ],
      {cwd: ROOT, encoding: "utf-8"},
    );
    buildOutput = String(r.stdout ?? "") + String(r.stderr ?? "");
    expect(r.status, "esbuild failed with the declared externals:\n" + buildOutput).toBe(0);
    expect(existsSync(ENTRY), "no artifact at " + ENTRY).toBe(true);
  }, 120_000);

  it("importing the artifact does not throw", async () => {
    // This is the first thing the Dart parent pays for when it spawns the child.
    // If it throws, the agent dies before answering rpc:ping and the pipe is closed.
    const mod = await import(/* @vite-ignore */ ENTRY);
    for (const sym of ["ReActEngine", "ProcessSupervisor", "CheckpointStore", "buildDefaultToolRegistry", "spawnLocalPty"]) {
      expect(mod[sym], sym + " missing from the bundle").toBeTruthy();
    }
  }, 60_000);

  it("the local-PTY path reaches node-pty instead of dying in the bundle", async () => {
    // The exact call that threw in the drifted artifact. No real shell session is
    // asserted (host quirks: see r6_shell_fork) - only that control reaches the
    // addon rather than an esbuild shim.
    const mod = await import(/* @vite-ignore */ ENTRY);
    let outcome: string;
    try {
      const s = await mod.spawnLocalPty({shell: "cmd.exe", cols: 80, rows: 24});
      outcome = "ok";
      try { s?.kill?.(); } catch { /* best effort */ }
      try { s?.dispose?.(); } catch { /* best effort */ }
    } catch (e: unknown) {
      outcome = String((e as Error)?.message ?? e);
    }
    expect(outcome).not.toMatch(/Dynamic require|is not defined/);
  }, 60_000);

  it("no dynamic-require landmine survives in the bundle text", () => {
    // esbuild emits that string when CJS gets inlined into an ESM bundle. node-pty
    // and the MCP SDK are CJS, so a green build is not evidence of a working one -
    // the string is. Probe noise from other test files is not involved: this reads
    // the artifact we just produced.
    const text = readFileSync(ENTRY, "utf-8");
    expect(text).not.toMatch(/Dynamic require of/);
    // node-pty must be a real runtime import, its internals never inlined.
    expect(text).toMatch(/import\("node-pty"\)/);
    expect(text).not.toMatch(/loadNativeModule/);
    expect(text).not.toMatch(/build\/Release/);
  });

  it("the artifact is smaller than the same bundle with everything inlined", () => {
    // A cheap magnitude check that the externals actually took effect: inlining the
    // SDK + node-pty graph costs tens of KB, so a shrinking artifact means the flag
    // list is doing work. Compared against our own inlined build, not a golden size.
    const inlined = OUT + "/inlined.js";
    const r = spawnSync(
      process.execPath,
      [ROOT + "node_modules/esbuild/bin/esbuild", "src/index.ts", "--bundle", "--outfile=" + inlined,
        "--platform=node", "--format=esm", "--target=node18", "--log-level=silent"],
      {cwd: ROOT, encoding: "utf-8"},
    );
    expect(r.status, "inlined control build failed:\n" + r.stderr).toBe(0);
    expect(readFileSync(ENTRY).length).toBeLessThan(readFileSync(inlined).length);
    // and the control build is exactly where the landmine shows up: proving the
    // detector above is not asserting against a hypothetical
    expect(readFileSync(inlined, "utf-8")).toMatch(/Dynamic require of/);
    rmSync(inlined, {force: true});
  }, 120_000);

  it("leaves no build residue behind in the repo root", () => {
    // Guard against the failure mode this file itself caused while being written:
    // an undefined temp dir materialising as ./undefined/ inside the checkout.
    for (const stray of ["undefined", "tmp"]) {
      expect(existsSync(ROOT + stray), "probe residue: " + stray).toBe(false);
    }
    rmSync(OUT, {recursive: true, force: true});
    expect(existsSync(OUT)).toBe(false);
  });
});
