import {describe, it, expect} from "vitest";
import {parse} from "../src/react/parser.js";

describe("ReAct parser", () => {
  it("parses thought / plan / command / ask", () => {
    const input = [
      "思考: 我先检查系统",
      "计划:",
      "  [ ] 检查磁盘",
      "  [x] 已完成备份",
      "命令: ls -la /tmp",
      "选项: A|B|C",
    ].join("\n");
    const evts = parse(input);
    const types = evts.map((e) => e.type);
    expect(types).toContain("thought");
    expect(types).toContain("plan");
    expect(types).toContain("command");
    expect(types).toContain("ask");

    const plan = evts.find((e) => e.type === "plan");
    expect(plan!.planSteps!.length).toBe(2);
    expect(plan!.planSteps![0].status).toBe("pending");
    expect(plan!.planSteps![1].status).toBe("completed");

    const cmd = evts.find((e) => e.type === "command");
    expect(cmd!.command).toBe("ls -la /tmp");
  });

  it("converts XML fenced tool_call to a command event", () => {
    const LT = String.fromCharCode(60);
    const GT = String.fromCharCode(62);
    const input = [
      "---",
      LT + "function=terminal" + GT,
      LT + "parameter=command" + GT,
      "echo hello",
      LT + "/" + "parameter" + GT,
      LT + "/" + "function" + GT,
      "---",
    ].join("\n");
    const evts = parse(input);
    expect(evts.length).toBe(1);
    expect(evts[0].type).toBe("command");
    expect(evts[0].command).toBe("echo hello");
  });

  it("extracts code-fence commands", () => {
    const BT3 = String.fromCharCode(96).repeat(3);
    const input = [
      "命令:",
      BT3 + "bash",
      "uname -a",
      BT3,
    ].join("\n");
    const evts = parse(input);
    const cmd = evts.find((e) => e.type === "command");
    expect(cmd!.command).toBe("uname -a");
  });
});