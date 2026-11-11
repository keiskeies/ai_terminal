// test/dispatcher_readonly.test.ts - Dart agent_engine.dart 3357-3373 parity:
// in read-only permission mode every tool whose kind is not read is refused
// BEFORE args parsing (design D3: the read-only file mode used to gate shell
// commands only, so tool calls could edit files straight through it). The
// criterion derives from ToolKind (Dart agent_tools.dart:182: isReadOnly is
// kind == read), so write-class tools are covered automatically - no second
// deny-list. The dispatcher-level contract: executed=false, success=false,
// failureKind permissionDenied, and the tool never runs.
// ASCII-only file per project emit rules.
import {describe, it, expect} from "vitest";
import {ToolDispatcher} from "../src/tools/dispatcher.js";
import {AgentTool, AgentToolRegistry, ToolKind, ToolResult} from "../src/tools/builtin.js";
import {buildDefaultToolRegistry} from "../src/tools/index.js";
import {ToolArgs} from "../src/tools/tool_args.js";
import {PermissionMode} from "../src/rpc/schema.js";

const NL = String.fromCharCode(10);

class DummyTool extends AgentTool {
  constructor(readonly name: string, readonly kindV: ToolKind) { super(); }
  readonly description = "d";
  readonly paramSpec = "none";
  executed = 0;
  override get kind(): ToolKind { return this.kindV; }
  toJsonSchema(): Record<string, unknown> | null { return null; }
  async execute(): Promise<ToolResult> { this.executed++; return ToolResult.success("ran " + this.name); }
}

function reg(...t: DummyTool[]): AgentToolRegistry {
  const r = new AgentToolRegistry();
  for (const x of t) r.register(x);
  return r;
}

describe("dispatcher read-only gate (Dart 3357-3373)", () => {
  it("write tool refused in readOnly mode before execute and before args parse", async () => {
    const w = new DummyTool("w_tool", ToolKind.write);
    const d = new ToolDispatcher(reg(w));
    const o = await d.dispatch({toolName: "w_tool", argsText: "path: /etc/passwd", permissionMode: () => "readOnly"});
    expect(o.executed).toBe(false);
    expect(o.event.type).toBe("result");
    expect(o.event.success).toBe(false);
    expect(o.event.failureKind).toBe("permissionDenied");
    expect(o.event.error).toContain("w_tool");
    expect(w.executed).toBe(0);
  });

  it("args parse is skipped: a malformed block still reports permissionDenied, not bad_args", async () => {
    const w = new DummyTool("w2", ToolKind.write);
    const d = new ToolDispatcher(reg(w));
    // a no-colon line is malformed for ToolArgs - the gate must fire first
    const o = await d.dispatch({toolName: "w2", argsText: "path: /x" + NL + "no colon line", permissionMode: () => "readOnly"});
    expect(o.event.failureKind).toBe("permissionDenied");
    expect(w.executed).toBe(0);
  });

  it("kind-derived coverage: destructive and network are refused too, read passes", async () => {
    const del = new DummyTool("d_tool", ToolKind.destructive);
    const net = new DummyTool("n_tool", ToolKind.network);
    const rd = new DummyTool("r_tool", ToolKind.read);
    const orch = new DummyTool("o_tool", ToolKind.orchestration);
    const d = new ToolDispatcher(reg(del, net, rd, orch));
    const mode: () => PermissionMode = () => "readOnly";
    expect((await d.dispatch({toolName: "d_tool", permissionMode: mode})).event.failureKind).toBe("permissionDenied");
    expect((await d.dispatch({toolName: "n_tool", permissionMode: mode})).event.failureKind).toBe("permissionDenied");
    expect((await d.dispatch({toolName: "o_tool", permissionMode: mode})).event.failureKind).toBe("permissionDenied");
    expect(del.executed).toBe(0);
    expect(net.executed).toBe(0);
    expect(orch.executed).toBe(0);
    const ok = await d.dispatch({toolName: "r_tool", permissionMode: mode});
    expect(ok.executed).toBe(true);
    expect(ok.event.success).toBe(true);
    expect(rd.executed).toBe(1);
  });

  it("other permission modes and an omitted permissionMode never gate", async () => {
    const w = new DummyTool("w3", ToolKind.write);
    const d = new ToolDispatcher(reg(w));
    for (const m of ["ask", "auto", "fullAuto"] as PermissionMode[]) {
      const o = await d.dispatch({toolName: "w3", permissionMode: () => m});
      expect(o.executed).toBe(true);
    }
    const o2 = await d.dispatch({toolName: "w3"});
    expect(o2.executed).toBe(true);
    expect(w.executed).toBe(4);
  });

  it("unknown tool keeps precedence: unknown_tool, not permissionDenied", async () => {
    const d = new ToolDispatcher(reg(new DummyTool("known", ToolKind.write)));
    const o = await d.dispatch({toolName: "nope", permissionMode: () => "readOnly"});
    expect(o.event.failureKind).toBe("unknown_tool");
  });

  it("real registry: local_file_read passes, local_file_write refused, file not created", async () => {
    const {tmpdir} = await import("os");
    const {join} = await import("path");
    const {existsSync, rmSync} = await import("fs");
    const dir = join(tmpdir(), "ac_ro_" + process.pid);
    const target = join(dir, "sub", "probe.txt");
    const d = new ToolDispatcher(buildDefaultToolRegistry());
    try {
      const w = await d.dispatch({toolName: "local_file_write", argsText: "path: " + target + NL + "content: hello", permissionMode: () => "readOnly"});
      expect(w.executed).toBe(false);
      expect(w.event.failureKind).toBe("permissionDenied");
      expect(existsSync(dir)).toBe(false); // nothing was ever created
      // a read-class tool passes the same gate: dir does not exist so the tool
      // itself fails, but executed=true proves the gate let it through.
      const r = await d.dispatch({toolName: "local_dir_list", argsText: "path: " + dir, permissionMode: () => "readOnly", isLocalSession: true});
      expect(r.executed).toBe(true);
    } finally { rmSync(dir, {recursive: true, force: true}); }
  });

  it("cancellation keeps precedence over the gate too (R1 before any side effect)", async () => {
    const w = new DummyTool("w4", ToolKind.write);
    const d = new ToolDispatcher(reg(w));
    const o = await d.dispatch({toolName: "w4", permissionMode: () => "readOnly", ctx: {cancelled: () => true}});
    expect(o.event.failureKind).toBe("cancelled");
  });
});
