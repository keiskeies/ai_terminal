// CI job shape guard (NOT one of the nine rules in design-doc 6.2, and not in
// the 6.3 status table): it guards the pipeline that is supposed to catch
// everything else. Same standing as manifest.test.ts (guards the manifest) and
// build_externals.test.ts (guards the bundle).
//
// Why this exists: the fixture step in agent-core-ci.yml ran with no
// working-directory, so on the runner it executed at the repo root, where there
// is no package.json - "npm run test:fixture" could therefore only ever fail.
// Every local gate was green while a CI step was structurally broken, because
// nothing under agent_core/ ever read the workflow file.
//
// The runner is ubuntu-latest and this repo is developed on Windows, so the
// asserts are about STRUCTURE (a step must say where it runs, the scripts it
// names must exist, the lockfile it caches must exist, the order the design doc
// installs gates in must not drift) - never about runner host behaviour, which
// no Windows checkout can observe.
import {describe, it, expect} from "vitest";
import {readFileSync, existsSync} from "fs";
import {fileURLToPath} from "url";
import {join} from "path";

const WF_PATH = fileURLToPath(new URL("../../.github/workflows/agent-core-ci.yml", import.meta.url));
const PKG_PATH = fileURLToPath(new URL("../package.json", import.meta.url));
const REPO = fileURLToPath(new URL("../..", import.meta.url));

const wfLines = readFileSync(WF_PATH, "utf-8").split(/\r?\n/);
const wf = wfLines.join("\n");
const PKG = JSON.parse(readFileSync(PKG_PATH, "utf-8")) as {scripts: Record<string, string>};

type Step = {name: string; run: string | null; wd: string | null};
// Steps are the 6-space-indented list items BELOW the "steps:" key. Bounding the
// scan there matters: the on.push.paths and on.pull_request.paths lists use the
// same 6-space dash shape and would otherwise be mistaken for steps.
function parseSteps(lines: string[]): Step[] {
  const start = lines.findIndex((l) => /^    steps:\s*$/.test(l));
  expect(start, "jobs.<job>.steps: not found").toBeGreaterThan(-1);
  const out: Step[] = [];
  let cur: Step | null = null;
  for (const line of lines.slice(start + 1)) {
    if (/^      - /.test(line)) {
      if (cur) out.push(cur);
      cur = {name: "", run: null, wd: null};
      continue;
    }
    if (!cur) continue;
    const nm = /^        name:\s*(.+)$/.exec(line);
    if (nm) { cur.name = nm[1].trim().replace(/^["']|["']$/g, ""); continue; }
    const run = /^        run:\s*(.+)$/.exec(line);
    if (run) { cur.run = run[1].trim(); continue; }
    const wd = /^        working-directory:\s*(.+)$/.exec(line);
    if (wd) cur.wd = wd[1].trim();
  }
  if (cur) out.push(cur);
  return out;
}
const steps = parseSteps(wfLines);
const runSteps = steps.filter((s) => s.run !== null);
// npm ci -> "ci", npm run x -> "x"; anything else is kept verbatim.
const target = (r: string): string => r.replace(/^npm\s+(run\s+)?/, "").trim();

describe("agent-core CI job steps are complete", () => {
  // Anti-vacuity: every rule below quantifies over runSteps. If the parser found
  // zero or one step, "all of them are fine" would be free.
  it("the parser really sees the run steps", () => {
    expect(runSteps.length).toBeGreaterThanOrEqual(7);
    expect(steps.length).toBeGreaterThanOrEqual(runSteps.length);
    // the two uses: steps (checkout, setup-node) must be the ones excluded above
    expect(runSteps.filter((s) => /^actions\//.test(s.run as string))).toEqual([]);
  });
  it("every run step declares its working directory", () => {
    const missing = runSteps.filter((s) => s.wd !== "agent_core").map((s) => s.name + " -> " + s.run);
    expect(missing, "run steps not scoped to agent_core").toEqual([]);
  });
  it("every npm run target it invokes exists in package.json scripts", () => {
    // Only "npm run X" resolves through package.json scripts; bare npm ci is an
    // npm built-in and is asserted separately in the install describe below.
    const names = runSteps.flatMap((s) => [...(s.run as string).matchAll(/\bnpm run ([A-Za-z0-9:_-]+)/g)].map((m) => m[1]));
    // 7 run steps: npm ci + npm test are bare (neither is "npm run"), the other
    // five resolve through scripts, and the order test below pins all seven.
    expect(names.sort()).toEqual(["build", "check:schema", "test:fixture", "test_e2e", "typecheck"]);
    expect(names.filter((n) => !(n in PKG.scripts)), "CI calls undefined scripts").toEqual([]);
  });
  it("gates run in the design-doc order, none dropped", () => {
    expect(runSteps.map((s) => target(s.run as string))).toEqual(
      ["ci", "typecheck", "test", "test_e2e", "build", "test:fixture", "check:schema"],
    );
  });
});

describe("agent-core CI job installs deterministically", () => {
  it("installs from the lockfile, never ad hoc", () => {
    const runs = runSteps.map((s) => s.run as string);
    expect(runs.filter((r) => /^npm ci\s*$/.test(r)).length, "exactly one npm ci").toBe(1);
    expect(runs.filter((r) => /^npm install\b/.test(r)), "npm install must not appear").toEqual([]);
    expect(runs.filter((r) => /npx\s/.test(r)), "npx must not appear").toEqual([]);
  });
  it("the lockfile it names for caching exists", () => {
    const lock = wf.match(/cache-dependency-path:\s*(\S+)/)?.[1];
    expect(lock, "setup-node must pin cache-dependency-path").toBeTruthy();
    expect(lock).toBe("agent_core/package-lock.json");
    expect(existsSync(join(REPO, lock as string)), lock + " missing").toBe(true);
  });
  it("the pinned runner node can execute the pinned build target", () => {
    const node = wf.match(/node-version:\s*"?(\d+)/)?.[1];
    expect(node, "node-version must pin a major").toBeTruthy();
    const buildTarget = PKG.scripts.build.match(/--target=node(\d+)/)?.[1];
    expect(buildTarget, "build must pin --target=nodeNN").toBeTruthy();
    expect(Number(node)).toBeGreaterThanOrEqual(Number(buildTarget));
  });
});

describe("agent-core CI job triggers on the work it guards", () => {
  it("push and pull_request both filter on agent_core sources", () => {
    // both are nested two spaces under the on: key
    expect(wfLines.filter((l) => /^  (push|pull_request):\s*$/.test(l)).length, "both triggers present").toBe(2);
    const filtered = wfLines.filter((l) => /^\s+-\s+"?agent_core\/\*\*"?/.test(l));
    expect(filtered.length, "agent_core/** path filter, once per trigger").toBeGreaterThanOrEqual(2);
    // the workflow guards itself, so editing it must run it
    expect(wfLines.some((l) => l.includes(".github/workflows/agent-core-ci.yml"))).toBe(true);
  });
  it("the feature-branch naming convention is a push trigger", () => {
    const branchLine = wfLines.find((l) => /^\s+branches:/.test(l)) ?? "";
    expect(/feat\/\*/.test(branchLine), "feat/** must trigger on push").toBe(true);
    expect(/\bmain\b/.test(branchLine), "main must trigger on push").toBe(true);
  });
});
