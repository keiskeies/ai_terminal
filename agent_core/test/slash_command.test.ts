// test/slash_command.test.ts - r207 port of utils/slash_command.dart.
// Unit pins for every branch + an oracle section that re-reads the Dart source
// at run time: the kGoalSubCommands set, the hasRest condition and the
// restore-mode comparison must keep matching the Dart text.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  parseSlashCommand, hasRest, matchModelNames, shouldRestorePermissionMode,
  kGoalSubCommands, parseGoalCommand,
} from "../src/utils/slash_command.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART = readFileSync(HERE + "../../ai_terminal/lib/utils/slash_command.dart", "utf-8").replace(/\r\n/g, NL);

const KNOWN = ["/goal", "/model", "/plan", "/permission"];

describe("parseSlashCommand", () => {
  it("rejects input that does not start with a slash", () => {
    expect(parseSlashCommand("hello", KNOWN)).toBeNull();
    expect(parseSlashCommand("  /goal x", KNOWN), "trim first").toEqual({name: "/goal", rest: "x"});
  });

  it("rejects unknown command names: a remote path is not a command", () => {
    // the hard requirement from the Dart header comment:
    // /etc/nginx 目录权限 must stay plain text
    expect(parseSlashCommand("/etc/nginx \u76EE\u5F55\u6743\u9650", KNOWN)).toBeNull();
    expect(parseSlashCommand("/help", KNOWN)).toBeNull();
  });

  it("name-only command has rest null", () => {
    expect(parseSlashCommand("/goal", KNOWN)).toEqual({name: "/goal", rest: null});
    expect(hasRest({name: "/goal", rest: null})).toBe(false);
  });

  it("command name matches case-insensitively and is lowercased", () => {
    expect(parseSlashCommand("/GOAL ship it", KNOWN)).toEqual({name: "/goal", rest: "ship it"});
  });

  it("rest keeps its own case/spaces/punctuation verbatim", () => {
    const r = parseSlashCommand("/goal   Fix the NGINX config!!  ", KNOWN);
    expect(r!.name).toBe("/goal");
    // Dart trims the WHOLE input first, so trailing spaces are already
    // gone; trimLeft then strips only the separator gap.
    expect(r!.rest).toBe("Fix the NGINX config!!");
    expect(hasRest(r!)).toBe(true);
  });

  it("name followed by only whitespace -> rest null (empty rest is null)", () => {
    expect(parseSlashCommand("/goal   ", KNOWN)).toEqual({name: "/goal", rest: null});
  });
});

describe("matchModelNames", () => {
  const NAMES = ["gpt-4o", "GPT-4o-mini", "claude-3.5-sonnet"];
  it("empty needle matches nothing", () => {
    expect(matchModelNames(NAMES, "   ")).toEqual([]);
  });
  it("exact (case-insensitive) wins over substring", () => {
    expect(matchModelNames(NAMES, "GPT-4O")).toEqual(["gpt-4o"]);
  });
  it("substring fallback can return multiple - the caller must not auto-pick", () => {
    expect(matchModelNames(NAMES, "gpt")).toEqual(["gpt-4o", "GPT-4o-mini"]);
  });
  it("no match -> empty list", () => {
    expect(matchModelNames(NAMES, "llama")).toEqual([]);
  });
});

describe("shouldRestorePermissionMode", () => {
  it("restores only when /plan's readOnly is still in place", () => {
    expect(shouldRestorePermissionMode("ask", "readOnly")).toBe(true);
    expect(shouldRestorePermissionMode("auto", "readOnly")).toBe(true);
    expect(shouldRestorePermissionMode("fullAuto", "readOnly")).toBe(true);
  });
  it("never restores when the user already moved off readOnly", () => {
    expect(shouldRestorePermissionMode("ask", "ask")).toBe(false);
    expect(shouldRestorePermissionMode("readOnly", "readOnly")).toBe(false);
    expect(shouldRestorePermissionMode("auto", "auto")).toBe(false);
  });
});

describe("parseGoalCommand", () => {
  it("bare /goal -> no sub, empty objective", () => {
    expect(parseGoalCommand(null)).toEqual({sub: null, objective: ""});
    expect(parseGoalCommand("   ")).toEqual({sub: null, objective: ""});
  });
  it("non-subcommand first word -> whole sentence is the objective", () => {
    expect(parseGoalCommand("deploy the api")).toEqual({sub: null, objective: "deploy the api"});
  });
  it("edit carries the rest of the sentence as the new objective", () => {
    expect(parseGoalCommand("edit ship v2")).toEqual({sub: "edit", objective: "ship v2"});
    expect(parseGoalCommand("EDIT")).toEqual({sub: "edit", objective: ""});
  });
  it("parameterless subs must own the whole line", () => {
    for (const s of ["pause", "resume", "done", "clear"]) {
      expect(parseGoalCommand(s), s).toEqual({sub: s, objective: ""});
      expect(parseGoalCommand(s.toUpperCase()), s).toEqual({sub: s, objective: ""});
    }
  });
  it("sub word + body falls back to objective: the pause-the-server case", () => {
    // `/goal pause the server 卡住了` is a user describing a problem, not an order
    const obj = "pause the server \u5361\u4F4F\u4E86";
    expect(parseGoalCommand(obj)).toEqual({sub: null, objective: obj});
  });
});

describe("oracle: slash_command.dart", () => {
  it("kGoalSubCommands matches the Dart set exactly", () => {
    const m = DART.match(/const Set<String> kGoalSubCommands = \{([\s\S]*?)\};/);
    expect(m, "Dart set literal").not.toBeNull();
    const dartSet = [...m![1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
    expect([...kGoalSubCommands].sort()).toEqual([...dartSet].sort());
  });

  it("hasRest is null+empty guarded in Dart too", () => {
    expect(DART).toContain("bool get hasRest => rest != null && rest!.isNotEmpty;");
  });

  it("restore rule compares against readOnly on both sides in Dart", () => {
    expect(DART).toContain("now == AgentPermissionMode.readOnly &&");
    expect(DART).toContain("before != AgentPermissionMode.readOnly;");
  });

  it("edit is the only sub carrying an argument in Dart", () => {
    expect(DART).toContain("if (lower == 'edit') {");
    expect(DART).toContain("if (tail.isNotEmpty) {");
  });
});
