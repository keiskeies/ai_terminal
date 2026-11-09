// Hermetic tests for tools/check-schema-compat.mjs
// - Pass against the committed schema dir.
// - Fail when protocol.version.json declares the wrong major.
// - Fail when two oneOf branches share the same method const.
import {describe,it,expect} from "vitest";
import {spawnSync} from "node:child_process";
import * as fs from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";

const CWD = process.cwd();
const TOOL = join(CWD, "tools/check-schema-compat.mjs");
const SCHEMA_DIR = join(CWD, "schema");
const ALL_SCHEMAS = [
  "request.schema.json","reverse.schema.json","event.schema.json",
  "notification.schema.json","tool.schema.json","agent-bridge.schema.json",
];

function runCompat(toolPath: string) {
  const r = spawnSync("node", [toolPath], {encoding: "utf-8"});
  return {status: r.status ?? -1, out: (r.stdout ?? "") + (r.stderr ?? "")};
}

/** Build a temp tree: tmp/schema/*.json + tmp/tools/check-schema-compat.mjs */
function buildTempTree(): {tmp: string; schema: string; tool: string; cleanup: () => void} {
  const tmp = join(tmpdir(), "ac_compat_" + process.pid + "_" + Math.random().toString(36).slice(2));
  const schema = join(tmp, "schema");
  const toolDir = join(tmp, "tools");
  fs.mkdirSync(schema, {recursive: true});
  fs.mkdirSync(toolDir, {recursive: true});
  for (const f of ALL_SCHEMAS) {
    fs.copyFileSync(join(SCHEMA_DIR, f), join(schema, f));
  }
  fs.writeFileSync(join(schema, "protocol.version.json"),
    JSON.stringify({"$id":"protocol.version.json","type":"object","properties":{"major":{"const":1},"minor":{"const":0}}}));
  const tool = join(toolDir, "check-schema-compat.mjs");
  fs.copyFileSync(TOOL, tool);
  return {tmp, schema, tool, cleanup: () => fs.rmSync(tmp, {recursive: true, force: true})};
}

describe("check-schema-compat (D7)", () => {
  it("passes against the committed schema dir", () => {
    const r = runCompat(TOOL);
    expect(r.status).toBe(0);
    expect(r.out).toContain("check-schema-compat: PASSED");
  });

  it("detects a protocol version mismatch (major=2)", () => {
    const {tool, schema, cleanup} = buildTempTree();
    try {
      fs.writeFileSync(join(schema, "protocol.version.json"),
        JSON.stringify({"$id":"protocol.version.json","type":"object","properties":{"major":{"const":2},"minor":{"const":0}}}));
      const r = runCompat(tool);
      expect(r.status).toBe(1);
      expect(r.out).toContain("major=1, minor=0, got major=2");
    } finally { cleanup(); }
  });

  it("detects a duplicate method const in oneOf", () => {
    const {tool, schema, cleanup} = buildTempTree();
    try {
      const req = JSON.parse(fs.readFileSync(join(schema, "request.schema.json"), "utf-8"));
      // Force two branches to share the same method const
      req.oneOf[1].properties!.method!.const = req.oneOf[0].properties!.method!.const;
      fs.writeFileSync(join(schema, "request.schema.json"), JSON.stringify(req));
      const r = runCompat(tool);
      expect(r.status).toBe(1);
      expect(r.out).toContain("duplicate method const");
    } finally { cleanup(); }
  });
});
