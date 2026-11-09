// W6 nodeapp bundle helper tests — hermetic (no real OS packaging).
// Exercises the manifest + verify logic without needing dist/ artifacts:
// we invoke nodeapp.mjs in a temp outdir and inspect the manifest.
import {describe,it,expect,afterEach} from "vitest";
import {spawnSync} from "node:child_process";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {rmSync, readFileSync, existsSync, mkdirSync} from "node:fs";
import {pathToFileURL} from "node:url";
import {createHash} from "node:crypto";

const NODEAPP = "tools/nodeapp.mjs";

function runNodeapp(args: string[]) {
  const r = spawnSync("node", [NODEAPP, ...args], {encoding: "utf-8", cwd: __dirname + "/.."});
  return r;
}

describe("nodeapp.mjs", () => {
  it("build writes index.js + manifest.json with sha256 + bytes", () => {
    const outdir = join(tmpdir(), "nodeapp_test_" + Math.random().toString(36).slice(2));
    mkdirSync(outdir, {recursive: true});
    const r = runNodeapp(["build", "--platform=linux", "--outdir=" + outdir]);
    expect(r.status).toBe(0);
    const manifest = JSON.parse(readFileSync(join(outdir, "manifest.json"), "utf-8"));
    expect(manifest.platform).toBe("linux");
    expect(manifest.bytes).toBeGreaterThan(0);
    expect(manifest.sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(existsSync(join(outdir, "index.js"))).toBe(true);
    rmSync(outdir, {recursive: true, force: true});
  });

  it("rejects unknown platform with exit 1", () => {
    const r = runNodeapp(["build", "--platform=amiga"]);
    expect(r.status).toBe(1);
  });

  it("verify exits 0 when no builds exist (no dist/*/manifest.json)", () => {
    // verify iterates PLATFORMS in dist/; with none present it should still exit 0
    const r = runNodeapp(["verify"]);
    expect(r.status).toBe(0);
  });

  it("manifest sha256 matches a re-hash of the emitted index.js (integrity)", () => {
    const outdir = join(tmpdir(), "nodeapp_integ_" + Math.random().toString(36).slice(2));
    mkdirSync(outdir, {recursive: true});
    const r = runNodeapp(["build", "--platform=mac", "--outdir=" + outdir]);
    expect(r.status).toBe(0);
    
    const raw = readFileSync(join(outdir, "index.js"));
    const recomputed = createHash("sha256").update(raw).digest("hex");
    const manifest = JSON.parse(readFileSync(join(outdir, "manifest.json"), "utf-8"));
    expect(manifest.sha256).toBe(recomputed);
    expect(manifest.bytes).toBe(raw.length);
    rmSync(outdir, {recursive: true, force: true});
  });
});
