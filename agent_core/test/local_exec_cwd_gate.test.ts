// local_exec_cwd_gate.test.ts - local_exec gates its WORKING DIRECTORY.
//
// Dart local_exec_tool.dart:108-151 runs a DIFFERENT gate from the file tools: the verdict
// switch refuses sensitive/reserved/escape outright, but notInAllowlist is not a dead end -
// it raises an authorization request, and on approval RE-READS the policy and decides again
// (:136-138, the Flutter settings dialog writes the allowlist back). A cancellation check
// sits after the possibly-long dialog (:148-151). Pinned here, plus the absolute-path rule
// (:104-106) and the working-directory creation (:153-161).
//
// Every test resets both injected seams (policy provider + dialog) so nothing leaks into a
// sibling file (AGENTS.md R5).

import {describe, it, expect, afterEach} from "vitest";
import {mkdtempSync, existsSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {
  LocalExecTool, setDefaultLocalFilePolicy, resetDefaultLocalFilePolicy,
  setLocalDirAuthorizationRequest,
} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";
import {LocalFilePolicy} from "../src/utils/local_file_policy.js";

const COLON = ": ";
const tempRoot = (): string => mkdtempSync(join(tmpdir(), "ac_exec_gate_"));
const STRICT = (root: string): (() => LocalFilePolicy) =>
  () => new LocalFilePolicy({enabled: true, allowedDirs: [root]});
const ECHO = "echo hi";
const SHELL = process.platform === "win32" ? "cmd" : "bash";
const wrap = (command: string, cwd: string): never =>
  ToolArgs.wrap({command, cwd, shell: SHELL}) as never;
const cleanup = (...dirs: string[]): void => {
  resetDefaultLocalFilePolicy();
  setLocalDirAuthorizationRequest(null);
  for (const d of dirs) rmSync(d, {recursive: true, force: true});
};

afterEach(() => { resetDefaultLocalFilePolicy(); setLocalDirAuthorizationRequest(null); });

describe("the blacklist gate runs before anything spawns", () => {
  it("refuses a sensitive working directory even under the wide trustedHost posture", async () => {
    const home = process.env.USERPROFILE ?? process.env.HOME ?? "/home/u";
    const r = await new LocalExecTool().execute(wrap(ECHO, join(home, ".ssh")), {});
    expect(r.success).toBe(false);
    expect(r.error).toContain("本机目录被安全策略拒绝");
    expect(r.error).toContain("原因" + COLON);
  });

  it("refuses a relative cwd with the Dart wording, quoting what it received", async () => {
    const r = await new LocalExecTool().execute(wrap(ECHO, "./build"), {});
    expect(r.success).toBe(false);
    expect(r.error).toContain("cwd 必须是绝对路径");
    expect(r.error).toContain("./build");
  });
});

describe("notInAllowlist without a wired dialog is a dead end", () => {
  it("refuses with the settings-page guidance when no dialog is available", async () => {
    const root = tempRoot();
    const outside = tempRoot();
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalExecTool().execute(wrap(ECHO, join(outside, "work")), {});
      expect(r.success).toBe(false);
      expect(r.error).toContain("本机目录未授权");
      expect(r.error).toContain("设置 → Agent → 本地文件");
      expect(r.error).toContain("改用远程 execute");
    } finally { cleanup(root, outside); }
  });
});

describe("the authorization dialog path", () => {
  it("a declined request refuses and never runs the command", async () => {
    const root = tempRoot();
    const outside = tempRoot();
    let asked = 0;
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      setLocalDirAuthorizationRequest(async () => { asked++; return false; });
      const r = await new LocalExecTool().execute(wrap(ECHO, join(outside, "work")), {});
      expect(r.success).toBe(false);
      expect(r.error).toContain("用户拒绝授权本机目录");
      expect(r.error).toContain("不要反复重试同一目录");
      expect(asked).toBe(1);
    } finally { cleanup(root, outside); }
  });

  it("the dialog text clips the COMMAND (whitespace collapsed, one line)", async () => {
    const root = tempRoot();
    const outside = tempRoot();
    let seenDir = "";
    let seenReason = "";
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      setLocalDirAuthorizationRequest(async (dir, reason) => { seenDir = dir; seenReason = reason; return false; });
      const cmd = "docker" + "    build" + String.fromCharCode(9) + "-t  app .";
      await new LocalExecTool().execute(ToolArgs.wrap({command: cmd, cwd: join(outside, "work"), shell: SHELL}) as never, {});
      expect(seenReason).toContain("local_exec 需要在该目录执行本机命令");
      expect(seenReason).toContain("docker build -t app .");
      expect(seenReason.includes(String.fromCharCode(10))).toBe(false);
      expect(seenDir).toContain("work");
    } finally { cleanup(root, outside); }
  });

  it("a cancellation after the dialog stops before any spawn or mkdir", async () => {
    const root = tempRoot();
    const outer = tempRoot();
    const work = join(outer, "work");
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      setLocalDirAuthorizationRequest(async () => { setDefaultLocalFilePolicy(STRICT(work)); return true; });
      const r = await new LocalExecTool().execute(wrap(ECHO, work), {cancelled: () => true});
      expect(r.success).toBe(false);
      expect(r.error).toContain("任务已取消，本机命令未执行");
      expect(existsSync(work)).toBe(false);
    } finally { cleanup(root, outer); }
  });

  it("an approval that fails to widen the allowlist still refuses", async () => {
    const root = tempRoot();
    const outside = tempRoot();
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      setLocalDirAuthorizationRequest(async () => true);
      const r = await new LocalExecTool().execute(wrap(ECHO, join(outside, "work")), {});
      expect(r.success).toBe(false);
      expect(r.error).toContain("授权后仍无法访问本机目录");
      expect(r.error).toContain("原因" + COLON);
    } finally { cleanup(root, outside); }
  });
});

describe("an allowed cwd runs and creates the directory (Dart:153-161)", () => {
  it("spawns inside a missing but authorised cwd after creating it", async () => {
    const root = tempRoot();
    const work = join(root, "deep", "nest");
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalExecTool().execute(wrap(ECHO, work), {});
      expect(r.success).toBe(true);
      expect(existsSync(work)).toBe(true);
      expect(r.output).toContain("hi");
    } finally { cleanup(root); }
  });

  it("home expansion happens before the absolute check, and the refusal quotes the raw cwd", async () => {
    // Dart :103-106 order: _expandHome THEN p.isAbsolute, and the refusal still quotes
    // the raw cwd the model sent. With no USERPROFILE/HOME in the environment Dart
    // expands nothing and falls through to the absolute-path refusal, so both shapes
    // are asserted instead of assumed (the harness env varies).
    const root = tempRoot();
    const home = process.env.USERPROFILE ?? process.env.HOME;
    try {
      setDefaultLocalFilePolicy(STRICT(root));
      const r = await new LocalExecTool().execute(wrap(ECHO, "~/some_project"), {});
      expect(r.success).toBe(false);
      if (home === undefined || home === "") {
        expect(r.error).toContain("cwd 必须是绝对路径");
        expect(r.error).toContain("~/some_project"); // the raw cwd, quoted verbatim
      } else {
        expect(r.error).toContain("本机目录未授权");
        expect((r.error ?? "").includes("~")).toBe(false); // expanded before decide
      }
    } finally { cleanup(root); }
  });
});


