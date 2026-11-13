// local_shell.test.ts - pure port of Dart local_shell.dart parseLocalShell/
// resolveDefaultLocalShell (:34-52, :59-67) plus the gate LocalExecTool runs
// with it (Dart local_exec_tool.dart:164-178, unknown value rejected before
// spawn). The spawn/timeout/cancel machinery in Dart runLocalCommand
// (:171-243) is already pinned by the runLocalCommand suite in
// builtin_tools.test.ts; this file only covers the arg-parsing layer.
import {describe, it, expect} from "vitest";
import {mkdtempSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {parseLocalShell, resolveDefaultLocalShell} from "../src/utils/local_shell.js";
import {LocalExecTool} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";

describe("parseLocalShell (Dart :34-52)", () => {
  it("maps every accepted alias, case-insensitive, with surrounding trim", () => {
    expect(parseLocalShell("powershell")).toEqual({kind: "powershell"});
    expect(parseLocalShell("  PS ")).toEqual({kind: "powershell"});
    expect(parseLocalShell("PwSh")).toEqual({kind: "powershell"});
    expect(parseLocalShell("cmd")).toEqual({kind: "cmd"});
    expect(parseLocalShell("CMD.EXE")).toEqual({kind: "cmd"});
    expect(parseLocalShell("bash")).toEqual({kind: "bash"});
    expect(parseLocalShell("sh")).toEqual({kind: "sh"});
  });
  it("empty / null / auto mean platform default", () => {
    expect(parseLocalShell("")).toBeNull();
    expect(parseLocalShell("   ")).toBeNull();
    expect(parseLocalShell(null)).toBeNull();
    expect(parseLocalShell(undefined)).toBeNull();
    expect(parseLocalShell("AUTO")).toBeNull();
  });
  it("an unrecognized value throws (Dart returns null; the tool turns that into a failure)", () => {
    expect(() => parseLocalShell("zsh")).toThrow(/unknown shell: zsh/);
    expect(() => parseLocalShell("git-bash")).toThrow(/unknown shell/);
  });
});

describe("resolveDefaultLocalShell (Dart :59-67)", () => {
  it("win32 -> powershell, else bash", () => {
    expect(resolveDefaultLocalShell()).toBe(process.platform === "win32" ? "powershell" : "bash");
  });
});

describe("LocalExecTool rejects an unknown shell BEFORE anything is spawned", () => {
  const root = mkdtempSync(join(tmpdir(), "ac_shell_gate_"));
  try {
    it("zsh is a clean failure naming the options; the command never runs", async () => {
      const res = await new LocalExecTool().execute(
        ToolArgs.wrap({command: "echo never", cwd: root, shell: "zsh"}) as never,
        {} as never,
      );
      expect(res.success).toBe(false);
      const msg = res.error ?? "";
      expect(msg).toContain("unknown shell: zsh");
      // The refusal is about the arg, not the command - nothing was executed.
      expect(msg).not.toContain("echo never");
      // Dart :168 option list is echoed back so the model can self-correct.
      expect(msg).toContain("powershell");
      expect(msg).toContain("cmd");
      expect(msg).toContain("bash");
    });
    it("trims + lowercases before matching: CMD.EXE (with space) runs, FiSH refuses", async () => {
      const good = await new LocalExecTool().execute(
        ToolArgs.wrap({command: "echo hi", cwd: root, shell: "CMD.EXE "}) as never,
        {} as never,
      );
      expect(good.success).toBe(true);
      expect(good.output).toContain("hi");

      const bad = await new LocalExecTool().execute(
        ToolArgs.wrap({command: "echo hi", cwd: root, shell: "FiSH"}) as never,
        {} as never,
      );
      expect(bad.success).toBe(false);
      expect((bad.error ?? "")).toContain("unknown shell: fish");
    });
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});
