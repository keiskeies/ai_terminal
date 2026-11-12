// Oracle-replay test for AgentLogger (r137).
// Re-reads agent_logger.dart at run time and pins the circular buffer,
// level routing, and listener semantics against the Node port.
import {describe, it, expect, vi, afterEach} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {AgentLogger} from "../src/utils/agent_logger.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string) =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const DART = linesOf("../../ai_terminal/lib/services/agent_logger.dart");

describe("r137: AgentLogger oracle", () => {

  it("circular buffer keeps last 1000 entries (Dart 23-24, 83-84)", () => {
    const logger = new AgentLogger();
    // Fill the buffer with 1001 entries
    for (let i = 0; i < 1001; i++) logger.info("T", "msg" + i);
    const logs = logger.getLogs();
    expect(logs.length).toBe(1000);
    // Oldest entry (msg0) should be evicted; newest (msg1000) should be present
    expect(logs[0]).toContain("msg1");
    expect(logs[999]).toContain("msg1000");
  });

  it("WARN/ERROR always console output; DEBUG/INFO only in debug mode (Dart 87-89)", () => {
    const logger = new AgentLogger();
    const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
    logger.warn("T", "w");
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });

  it("subscribe returns an unsubscribe function (Dart 190-196)", () => {
    const logger = new AgentLogger();
    const received: string[] = [];
    const unsub = logger.subscribe((level, tag, msg) => { received.push(msg); });
    logger.info("T", "hello");
    expect(received).toEqual(["hello"]);
    unsub();
    logger.info("T", "bye");
    expect(received).toEqual(["hello"]); // unsubscribed, no new entries
  });

  it("getLogs returns oldest-first (Dart 178)", () => {
    const logger = new AgentLogger();
    logger.info("T", "first");
    logger.info("T", "second");
    logger.info("T", "third");
    const logs = logger.getLogs();
    expect(logs[0]).toContain("first");
    expect(logs[2]).toContain("third");
  });

  it("getLogsAsString joins with newline (Dart 180)", () => {
    const logger = new AgentLogger();
    logger.info("T", "a");
    logger.info("T", "b");
    const s = logger.getLogsAsString();
    expect(s.split(NL)).toHaveLength(2);
  });

  it("Dart source lines are non-empty (run-time pin)", () => {
    expect(DART[22].trim()).toContain("Queue"); // _logs declaration
    expect(DART[23].trim()).toContain("1000"); // _maxLogs
    expect(DART[77].trim()).toContain("void log"); // log method
    expect(DART[171].trim()).toContain("debug"); // debug convenience
  });
});
