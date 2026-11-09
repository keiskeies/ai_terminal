#!/usr/bin/env node
// tools/nodeapp.mjs - Node-side agent_core bundling helper (W6).
//
//   node tools/nodeapp.mjs build --platform=win|mac|linux [--outdir=dist/<platform>]
//   node tools/nodeapp.mjs verify
//
// "build" runs esbuild (platform=node, format=esm, native+io externals) and
// writes dist/<platform>/index.js + manifest.json {platform, entry, sha256, bytes}.
// "verify" smoke-imports each built bundle in a fresh child and asserts the
// key public symbols are present.
//
// This is the Node-testable half of W6; real per-OS signing / native embed
// remains out of scope (handled by the packaging pipeline).

import {build} from "esbuild";
import {createHash} from "node:crypto";
import {writeFileSync, mkdirSync, readFileSync, existsSync} from "node:fs";
import {dirname, join, relative} from "node:path";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

const PLATFORMS = ["win", "mac", "linux"];
// externals: keep native/Node builtins out of the bundle, resolved at runtime
const EXTERNALS = [
  "fs","path","crypto","os","child_process","net","tls","http","https",
  "stream","buffer","util","readline","assert","string_decoder","url",
  "zlib","worker_threads","node-pty",
];
// symbols that MUST resolve after bundling (public API smoke check)
const EXPECTED_SYMBOLS = ["ReActEngine","ProcessSupervisor","CheckpointStore","buildDefaultToolRegistry"];

function parseArgs(argv) {
  const out = {cmd: null, platform: null, outdir: null};
  for (const a of argv) {
    if (a === "build" || a === "verify") out.cmd = a;
    else if (a.startsWith("--platform=")) out.platform = a.slice(11);
    else if (a.startsWith("--outdir=")) out.outdir = a.slice(9);
  }
  return out;
}

async function doBuild(platform, outdirOverride) {
  if (!PLATFORMS.includes(platform)) {
    console.error('nodeapp: unknown platform "' + platform + '" (want win|mac|linux)');
    process.exit(1);
  }
  const outdir = outdirOverride ?? join(ROOT, "dist", platform);
  const entry = join(outdir, "index.js");
  mkdirSync(outdir, {recursive: true});
  await build({
    entryPoints: [join(ROOT, "src", "index.ts")],
    bundle: true,
    outfile: entry,
    platform: "node",
    format: "esm",
    target: "node18",
    external: EXTERNALS,
    logLevel: "silent",
  });
  const raw = readFileSync(entry);
  const sha256 = createHash("sha256").update(raw).digest("hex");
  const manifest = {
    platform, entry: relative(ROOT, entry), sha256, bytes: raw.length,
    builtAt: new Date().toISOString(), nodeVersion: process.version,
  };
  writeFileSync(join(outdir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  console.log("nodeapp: built " + platform + " -> " + manifest.entry + " (" + raw.length + " B)");
  return manifest;
}

async function doVerify() {
  // Small child script (written once) that imports the bundle and checks symbols.
  const childScript = join(ROOT, "tools", "verify-bundle-child.mjs");
  let checked = 0;
  for (const p of PLATFORMS) {
    const manPath = join(ROOT, "dist", p, "manifest.json");
    if (!existsSync(manPath)) continue;
    const m = JSON.parse(readFileSync(manPath, "utf-8"));
    const entryAbs = join(ROOT, m.entry);
    const child = spawn(process.execPath, [childScript, entryAbs], {stdio: "inherit"});
    const rc = await new Promise((res) => child.on("close", res));
    if (rc !== 0) {
      console.error("nodeapp: verify FAILED for " + p + " (exit " + rc + ")");
      process.exit(1);
    }
    console.log("nodeapp: verify ok for " + p + " (" + m.entry + ", " + m.bytes + " B)");
    checked++;
  }
  if (checked === 0) console.log("nodeapp: no dist/*/manifest.json — nothing to verify (run build first)");
  process.exit(0);
}

const {cmd, platform, outdir} = parseArgs(process.argv.slice(2));
if (cmd === "build") {
  if (!platform) { console.error("nodeapp build: --platform= required (win|mac|linux)"); process.exit(1); }
  await doBuild(platform, outdir);
} else if (cmd === "verify") {
  await doVerify();
} else {
  console.log("usage: node tools/nodeapp.mjs build --platform=win|mac|linux [--outdir=...] | verify");
  process.exit(1);
}
