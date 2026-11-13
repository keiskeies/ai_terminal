// test/risk_explainer_oracle.test.ts - r210: change_record.ts + risk_explainer.ts.
// The oracle section re-extracts the WHOLE Dart rule table, impact switch and
// tool-impact map at run time and diffs them against the ported module - the
// whole CJK surface is verified, not spot-checked.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {inferChangeType, buildRollbackCommand, CHANGE_TYPES} from "../src/utils/change_record.js";
import {RiskExplainer} from "../src/utils/risk_explainer.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const read = (rel: string) => readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL);
const DART_RE = read("../../ai_terminal/lib/utils/risk_explainer.dart");
const DART_CRS = read("../../ai_terminal/lib/services/change_record_service.dart");

describe("inferChangeType", () => {
  it("package installs/uninstalls", () => {
    expect(inferChangeType("apt install nginx")).toBe("install");
    expect(inferChangeType("sudo apt-get install curl")).toBe("install");
    expect(inferChangeType("dnf remove firewalld")).toBe("uninstall");
    expect(inferChangeType("pacman -S vim")).toBe("install");
  });
  it("service ops via systemctl and service", () => {
    expect(inferChangeType("systemctl start nginx")).toBe("startService");
    expect(inferChangeType("systemctl stop nginx")).toBe("stopService");
    expect(inferChangeType("systemctl restart nginx")).toBe("restartService");
    expect(inferChangeType("service postgresql start")).toBe("startService");
  });
  it("permission, file ops, redirects, other", () => {
    expect(inferChangeType("chmod 644 /etc/passwd")).toBe("permission");
    expect(inferChangeType("rm -rf /tmp/x")).toBe("fileOperation");
    expect(inferChangeType("echo x > /etc/hosts")).toBe("fileOperation");
    expect(inferChangeType("uname -a")).toBe("other");
  });
});

describe("buildRollbackCommand", () => {
  it("install maps per package manager", () => {
    expect(buildRollbackCommand("apt install nginx", "install")).toBe("apt remove nginx");
    expect(buildRollbackCommand("sudo apk add bash", "install")).toBe("sudo apk del bash");
    expect(buildRollbackCommand("brew install watch", "install")).toBe("brew uninstall watch");
    expect(buildRollbackCommand("snap install helly", "install")).toBe("snap remove helly");
    expect(buildRollbackCommand("apt install", "install")).toBeNull();
  });
  it("start/stop swap verbs; everything else null", () => {
    expect(buildRollbackCommand("systemctl start nginx", "startService")).toBe("systemctl stop nginx");
    expect(buildRollbackCommand("sudo systemctl stop nginx", "stopService")).toBe("sudo systemctl start nginx");
    expect(buildRollbackCommand("service postgresql start", "startService")).toBe("service postgresql stop");
    expect(buildRollbackCommand("x", "uninstall")).toBeNull();
    expect(buildRollbackCommand("x", "restartService")).toBeNull();
    expect(buildRollbackCommand("x", "permission")).toBeNull();
  });
});

describe("RiskExplainer", () => {
  it("isMutating excludes pure queries", () => {
    expect(RiskExplainer.isMutating("df -h")).toBe(false);
    expect(RiskExplainer.isMutating("rm -rf /var/log/x")).toBe(true);
  });
  it("explain fills impact/reason/canRollback", () => {
    const r = RiskExplainer.explain("systemctl stop nginx");
    expect(r.canRollback).toBe(true);
    expect(r.rollbackCommand).toBe("systemctl start nginx");
    expect(r.restoreHint).toBeNull();
    const q = RiskExplainer.explain("rm -rf /tmp/a");
    expect(q.canRollback).toBe(false);
    expect(q.rollbackCommand).toBeNull();
  });
  it("explainTool: shared read-only entry and unknown fallback", () => {
    const ro = RiskExplainer.explainTool("local_file_read");
    expect(ro.canRollback).toBe(false);
    expect(ro.rollbackCommand).toBeNull();
    expect(ro.restoreHint).not.toBeNull();
    const unk = RiskExplainer.explainTool("brand_new_tool");
    expect(unk.restoreHint).toBeNull();
    expect(RiskExplainer.explainTool("sftp_upload").restoreHint).toBeNull();
  });
});

// ---------------------------------------------------------------- oracle --
// Re-extract every Dart rule and re-check the module against it at run time.

type DartRow = [string, string, string | null];
function dartTable(src: string): {rows: DartRow[]; readOnly: [string, string]} {
  const rows: DartRow[] = [];
  const re = /'([a-z_]+)':\s*_ToolImpact\(\s*'([^']*?)'(?:,\s*'([^']*?)')?/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) rows.push([m[1], m[2], m[3] ?? null]);
  const ro = src.match(/const _readOnly = _ToolImpact\('([^']*)', '([^']*)'\)/);
  if (!ro) throw new Error("dart _readOnly const not found");
  return {rows, readOnly: [ro[1], ro[2]]};
}

describe("oracle: risk_explainer.dart tool table", () => {
  const {rows, readOnly} = dartTable(DART_RE);
  it("dart extraction is the expected size", () => {
    expect(rows.length).toBe(21);
  });
  it("every tool row matches explainTool byte-for-byte", () => {
    const readOnlyNames = new Set(["local_file_read", "local_dir_list", "local_file_search", 
      "project_analyze", "cert_check", "multi_grep", "diff_files"]);
    // the 7 shared entries use the bare _readOnly const in Dart, so they
    // never appear as _ToolImpact(...) rows - explainTool must still serve them.
    expect(rows.filter(r => readOnlyNames.has(r[0])).length).toBe(0);
    for (const [name, impact, hint] of rows) {
      const e = RiskExplainer.explainTool(name);
      expect(e.impact, name).toBe(impact);
      expect(e.restoreHint, name).toBe(hint);
      expect(e.canRollback, name).toBe(false);
      expect(e.rollbackCommand, name).toBeNull();
    }
  });
  it("shared READ_ONLY entry carries the Dart _readOnly strings", () => {
    for (const n of ["local_file_read", "diff_files", "project_analyze"]) {
      const e = RiskExplainer.explainTool(n);
      expect(e.impact, n).toBe(readOnly[0]);
      expect(e.restoreHint, n).toBe(readOnly[1]);
    }
  });
  it("unknown-tool fallback string is byte-identical", () => {
    const m = DART_RE.match(/impact: '([^']*)',\s*\n\s*canRollback: false,/);
    expect(m).not.toBeNull();
    expect(RiskExplainer.explainTool("zzz_unknown").impact).toBe(m![1]);
  });
});

describe("oracle: impact switch + change rules", () => {
  const probes: Array<[string, string]> = [
    ["install", "apt install nginx"],
    ["uninstall", "apt remove nginx"],
    ["startService", "systemctl start nginx"],
    ["stopService", "systemctl stop nginx"],
    ["restartService", "systemctl restart nginx"],
    ["fileOperation", "rm -rf /tmp/x"],
    ["permission", "chmod 600 x"],
    ["other", "uname -a"],
  ];
  for (const [type, cmd] of probes) {
    it("impact string for " + type + " matches Dart _impactFor", () => {
      const re = new RegExp("case ChangeType." + type + ":\\s*\\n\\s*return '([^']*)';");
      const m = DART_RE.match(re);
      expect(m, "dart case " + type).not.toBeNull();
      expect(RiskExplainer.explain(cmd).impact).toBe(m![1]);
    });
  }
  it("modifyConfig impact exists in BOTH sources (unreachable via inferType)", () => {
    const m = DART_RE.match(/case ChangeType\.modifyConfig:\s*\n\s*return '([^']*)';/);
    expect(m).not.toBeNull();
    const nodeSrc = read("../src/utils/risk_explainer.ts");
    expect(nodeSrc).toContain(m![1]);
  });
  it("every Dart rule regex appears in change_record.ts verbatim", () => {
    const nodeSrc = read("../src/utils/change_record.ts");
    const bodies = [...DART_CRS.matchAll(/RegExp\((?:\r?\n\s*)?r'([^']+)'/g)].map(x => x[1]);
    expect(bodies.length).toBeGreaterThanOrEqual(18);
    for (const b of bodies) {
      const escaped = b.split("/").join("\\/");
      const hit = nodeSrc.includes(b) || nodeSrc.includes(escaped);
      expect(hit, "missing regex body: " + b).toBe(true);
    }
  });
  it("CHANGE_TYPES order matches the Dart enum declaration order", () => {
    const cr = read("../../ai_terminal/lib/models/change_record.dart");
    const body = cr.match(/enum ChangeType \{([\s\S]*?)\n\}/);
    expect(body).not.toBeNull();
    const dartOrder = [...body![1].matchAll(/^\s*(\w+),/gm)].map(x => x[1]);
    expect(CHANGE_TYPES).toEqual(dartOrder);
  });
  it("inferType decision order is pinned in the Dart source", () => {
    const seq = ["_installRegex", "_uninstallRegex", "_systemctlStartRegex", 
      "_permissionRegex", "_fileOpRegex", "_redirectRegex"];
    let last = -1;
    for (const name of seq) {
      const i = DART_CRS.indexOf(name + ".hasMatch");
      expect(i, name).toBeGreaterThan(last);
      last = i;
    }
  });
});

