import {describe,it,expect} from "vitest";
import {parse} from "../src/react/parser.js";

describe("parser 动作: finish -> finish event", () => {
  it("动作: finish alone emits a finish event (no summary)", () => {
    const ev = parse("思考: 任务完成\n动作: finish");
    const f = ev.find((e) => e.type === "finish");
    expect(f).toBeDefined();
    expect(f!.finishState).toBeUndefined();
    expect(f!.summary).toBeUndefined();
  });

  it("回答: body + 动作: finish -> finish.summary carries the answer body", () => {
    const ev = parse("思考: 完成\n回答: 已部署 v2.0，测试通过\n动作: finish");
    const f = ev.find((e) => e.type === "finish");
    expect(f).toBeDefined();
    expect(f!.summary).toBe("已部署 v2.0，测试通过");
  });

  it("动作: execute does NOT emit a finish event", () => {
    const ev = parse("动作: execute\n命令: ls -la");
    expect(ev.find((e) => e.type === "finish")).toBeUndefined();
    expect(ev.find((e) => e.type === "command")).toBeDefined();
  });
});
