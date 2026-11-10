// local_file_policy_tools.test.ts - the tool layer actually calls decide().
//
// local_file_policy.test.ts proves LocalFilePolicy.decide() itself is faithful to Dart.
// THIS file proves the six local_* tools in tools/builtin.ts route their path IO through
// resolveLocalPath -> policy.decide(), so the sensitive-path blacklist (the whole point of
// design-doc item 7) now guards the real read/write/patch/move/delete IO, not just a helper.
//
// Three postures are exercised:
//   1. default provider = trustedHost: ordinary temp paths still work (historical posture)
//      but a sensitive path (ssh key) is refused BEFORE any IO by the blacklist.
//   2. injected strict policy (enabled + allowlist): paths outside the roots are refused with
//      the refuse-unauthorised prefix, paths inside run.
//   3. the remote-path hint only appears on Windows + notInAllowlist + a POSIX-shaped path.
//
// setDefaultLocalFilePolicy mutates module state; every test resets it via resetDefault... in
// finally so a leaked strict policy cannot poison a sibling file (AGENTS.md R5).

import {describe, it, expect, afterEach} from "vitest";
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {
  LocalFileReadTool, LocalFileWriteTool, LocalFilePatchTool, LocalFileMoveTool,
  LocalFileDeleteTool, LocalFileSearchTool,
  setDefaultLocalFilePolicy, resetDefaultLocalFilePolicy,
} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";
import {LocalFilePolicy} from "../src/utils/local_file_policy.js";

const isWin = process.platform === "win32";
const COLON = ": "; // ASCII colon + space, byte-faithful to Dart local_file_tools.dart

function tempRoot(): string { return mkdtempSync(join(tmpdir(), "ac_pol_tools_")); }
const STRICT = (root: string): (() => LocalFilePolicy) =>
  () => new LocalFilePolicy({enabled: true, allowedDirs: [root]});

describe("default provider keeps the trusted posture but runs the blacklist", () => {
  afterEach(() => resetDefaultLocalFilePolicy());

  it("reads an ordinary temp file (allowlist wide open)", async () => {
    const root = tempRoot();
    try {
      const f = join(root, "a.txt");
      writeFileSync(f, "hello\nworld\n", "utf-8");
      const r = await new LocalFileReadTool().execute(ToolArgs.wrap({path: f}), {} as never);
      expect(r.success).toBe(true);
      expect(r.output).toContain("hello");
    } finally { rmSync(root, {recursive: true, force: true}); }
  });

  it("refuses an ssh key path via the blacklist before any IO", async () => {
    const base = process.env.USERPROFILE ?? process.env.HOME ?? "/home/u";
    const key = join(base, ".ssh", "id_rsa");
    const r = await new LocalFileReadTool().execute(ToolArgs.wrap({path: key}), {} as never);
    expect(r.success).toBe(false);
    expect(r.error).toContain("敏感路径禁止访问");
    expect(r.error).toContain("原因" + COLON);
  });
});

describe("injected strict policy enforces the allowlist", () => {
  afterEach(() => resetDefaultLocalFilePolicy());

  it("write outside the roots is refused with the unauthorised prefix", async () => {
    const root = tempRoot();
    const outside = mkdtempSync(join(tmpdir(), "ac_pol_out_"));
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      const denied = await new LocalFileWriteTool().execute(
        ToolArgs.wrap({path: join(outside, "x.txt"), content: "nope"}), {} as never);
      expect(denied.success).toBe(false);
      expect(denied.error).toContain("路径未获授权");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
      rmSync(outside, {recursive: true, force: true});
    }
  });

  it("write inside the roots runs and lands on disk", async () => {
    const root = tempRoot();
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      const ok = await new LocalFileWriteTool().execute(
        ToolArgs.wrap({path: join(root, "y.txt"), content: "yes"}), {} as never);
      expect(ok.success).toBe(true);
      expect(readFileSync(join(root, "y.txt"), "utf-8")).toBe("yes");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
    }
  });

  it("patch is refused outside the roots before touching the file", async () => {
    const root = tempRoot();
    const outside = mkdtempSync(join(tmpdir(), "ac_pol_out_"));
    try {
      const f = join(outside, "p.txt");
      writeFileSync(f, "old_text\n", "utf-8");
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalFilePatchTool().execute(
        ToolArgs.wrap({path: f, old: "old_text", new: "new_text"}), {} as never);
      expect(r.success).toBe(false);
      expect(r.error).toContain("路径未获授权");
      expect(readFileSync(f, "utf-8")).toBe("old_text\n"); // file untouched
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
      rmSync(outside, {recursive: true, force: true});
    }
  });

  it("delete is refused outside the roots and the file survives", async () => {
    const root = tempRoot();
    const outside = mkdtempSync(join(tmpdir(), "ac_pol_out_"));
    try {
      const f = join(outside, "d.txt");
      writeFileSync(f, "keep", "utf-8");
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalFileDeleteTool().execute(ToolArgs.wrap({path: f}), {} as never);
      expect(r.success).toBe(false);
      expect(r.error).toContain("路径未获授权");
      expect(readFileSync(f, "utf-8")).toBe("keep");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
      rmSync(outside, {recursive: true, force: true});
    }
  });

  it("move refuses when EITHER endpoint is outside the roots", async () => {
    const root = tempRoot();
    const outside = mkdtempSync(join(tmpdir(), "ac_pol_out_"));
    try {
      const src = join(outside, "m.txt");
      writeFileSync(src, "m", "utf-8");
      setDefaultLocalFilePolicy(STRICT(root));
      // source outside -> refused on the src resolve, before dst is even considered.
      const r = await new LocalFileMoveTool().execute(
        ToolArgs.wrap({path: src, dst: join(root, "m2.txt")}), {} as never);
      expect(r.success).toBe(false);
      expect(r.error).toContain("路径未获授权");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
      rmSync(outside, {recursive: true, force: true});
    }
  });

  it("search refuses a root outside the allowlist", async () => {
    const root = tempRoot();
    const outside = mkdtempSync(join(tmpdir(), "ac_pol_out_"));
    try {
      writeFileSync(join(outside, "s.txt"), "needle", "utf-8");
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalFileSearchTool().execute(
        ToolArgs.wrap({path: outside, query: "needle"}), {} as never);
      expect(r.success).toBe(false);
      expect(r.error).toContain("路径未获授权");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
      rmSync(outside, {recursive: true, force: true});
    }
  });
});

describe("remote-path hint is Windows-only and unauthorised-only", () => {
  afterEach(() => resetDefaultLocalFilePolicy());

  it("POSIX-shaped unauthorised path hints remote tools only on Windows", async () => {
    const root = tempRoot();
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      // a POSIX path that is not sensitive (not /etc) and not under the roots.
      const r = await new LocalFileReadTool().execute(
        ToolArgs.wrap({path: "/opt/srv/thing.txt"}), {} as never);
      expect(r.success).toBe(false);
      const hasHint = (r.error ?? "").includes("远程主机");
      expect(hasHint).toBe(isWin);
      expect(r.error).toContain("路径未获授权");
    } finally {
      resetDefaultLocalFilePolicy();
      rmSync(root, {recursive: true, force: true});
    }
  });

  it("a sensitive refusal never carries the remote hint", async () => {
    // /etc/passwd is blocked by checkPath (sensitive), so no remote hint even on Windows.
    const r = await new LocalFileReadTool().execute(
      ToolArgs.wrap({path: "/etc/passwd"}), {} as never);
    expect(r.success).toBe(false);
    expect(r.error).toContain("敏感路径禁止访问");
    expect((r.error ?? "").includes("远程主机")).toBe(false);
  });
});

