// interrupted_turn_detector.test.ts
// Mirrors Dart interrupted_turn_detector_test.dart (71 lines, 5 cases).

import {describe, it, expect} from "vitest";
import {isInterruptedTurn, lastEventHostId} from "../src/utils/interrupted_turn_detector.js";
import type {AgentEvent} from "../src/rpc/schema.js";

describe("isInterruptedTurn + lastEventHostId (Dart oracle: interrupted_turn_detector_test.dart)", () => {

  it("new-format turn without finish/report is interrupted", () => {
    const events: AgentEvent[] = [
      {id: "e1", type: "command", timestamp: 1, command: "ls", hostId: "web-01", toolName: "exec_command"},
      {id: "e2", type: "result", timestamp: 2, commandId: "e1", success: true, durationMs: 12},
    ];
    expect(isInterruptedTurn(events)).toBe(true);
    expect(lastEventHostId(events)).toBe("web-01");
  });

  it("legacy events without new metadata are not mislabeled", () => {
    const events: AgentEvent[] = [
      {id: "c1", type: "command", timestamp: 1, command: "ls"},
      {id: "r1", type: "result", timestamp: 2, commandId: "c1", success: true},
    ];
    expect(isInterruptedTurn(events)).toBe(false);
  });

  it("turn with finish event is NOT interrupted", () => {
    const events: AgentEvent[] = [
      {id: "e1", type: "command", timestamp: 1, command: "ls", hostId: "web-01"},
      {id: "e2", type: "result", timestamp: 2, commandId: "e1", success: true, durationMs: 5},
      {id: "e3", type: "finish", timestamp: 3, summary: "done"},
    ];
    expect(isInterruptedTurn(events)).toBe(false);
  });

  it("empty event list is not interrupted", () => {
    expect(isInterruptedTurn([])).toBe(false);
    expect(lastEventHostId([])).toBe(null);
  });

  it("lastEventHostId returns the last non-empty host id", () => {
    const events: AgentEvent[] = [
      {id: "e1", type: "command", timestamp: 1, command: "ls", hostId: "web-01"},
      {id: "e2", type: "result", timestamp: 2, commandId: "e1", success: true},
      {id: "e3", type: "command", timestamp: 3, command: "pwd", hostId: "web-02"},
    ];
    expect(lastEventHostId(events)).toBe("web-02");
  });
});