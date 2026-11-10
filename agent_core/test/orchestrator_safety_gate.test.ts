// The batch parallel gate: agent_core/src/tools/orchestrator.ts against the Dart
// MultiHostExecutor, plus the SafetyGuard classifier the Dart gate consults.
//
// Dart decides parallel-versus-serial by asking SafetyGuard: in
// services/multi_host_executor.dart line 121 assigns the level from
// SafetyGuard.check(command) and line 122 compares it against SafetyLevel.safe,
// taking the Future.wait branch when they match. The Node batch path carried its
// own conservative whitelist instead and never went through
// src/utils/safety_guard.ts at all, so one question was answered by two unrelated
// classifiers. That is how drift becomes invisible: the whitelist can gain a head
// that the Dart tables would flag, or the Dart tables can learn a rule the
// whitelist ignores, and nothing anywhere would have noticed.
//
// The whitelist is deliberately NOT dropped, and layer 2 measures why. Of the 87
// command literals test/orchestrator.test.ts asserts against isReadOnlyCommand, 34
// classify as safe under SafetyGuard while the whitelist refuses them: docker rm,
// kubectl delete, git push, find -exec, mount --bind, every command chained with
// semicolon or pipe, and the empty command. Dart check alone would parallelise all
// of those across hosts, so a naive make-it-match-Dart edit would be a genuine
// safety regression. Pinning the number forces such an edit to argue with a test
// instead of with a comment.
//
// Three layers, cheapest first. Layer 1 parses the Dart gate out of the Dart
// source, since CI has no Dart SDK and the Dart file can never execute here.
// Layer 2 pins the relation between the two dimensions over the whole existing
// assertion corpus. Layer 3 proves the second gate is live on the batch path by
// counting in-flight RPCs through a fake client: concurrency is the only
// externally visible difference between the two branches, and a predicate
// injected through ExecuteBatchOptions is the only way to flip the branch for a
// command that both gates otherwise agree on.
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {isParallelSafeCommand, isReadOnlyCommand, ReverseRpcOrchestrator} from "../src/tools/orchestrator.js";
import type {ExecuteBatchOptions} from "../src/tools/orchestrator.js";
import {checkSafety} from "../src/utils/safety_guard.js";
import * as toolsBarrel from "../src/tools/index.js";
import * as rootBarrel from "../src/index.js";
import type {ReverseRpcClient} from "../src/rpc/client.js";

const HERE = dirname(fileURLToPath(new URL(import.meta.url)));
const AC = join(HERE, "..");
const ORCH_TS = join(AC, "src", "tools", "orchestrator.ts");
const TOOLS_INDEX_TS = join(AC, "src", "tools", "index.ts");
const ROOT_INDEX_TS = join(AC, "src", "index.ts");
const ORCH_TEST = join(AC, "test", "orchestrator.test.ts");
const DART_EXEC = join(AC, "..", "ai_terminal", "lib", "services", "multi_host_executor.dart");
const NL = String.fromCharCode(10);
const CRLF = String.fromCharCode(13) + String.fromCharCode(10);
const QUOTE = String.fromCharCode(34);
const APOS = String.fromCharCode(39);

const readText = (path: string): string => readFileSync(path, "utf-8").split(CRLF).join(NL);
const sha12 = (text: string): string => createHash("sha1").update(text).digest("hex").slice(0, 12);

const DART = readText(DART_EXEC);
const ORCH = readText(ORCH_TS);
const ORCH_SUITE = readText(ORCH_TEST);
const TOOLS_INDEX = readText(TOOLS_INDEX_TS);
const ROOT_INDEX = readText(ROOT_INDEX_TS);

// All three digests are taken over the newline-normalised text, because the Dart
// source on this checkout is CRLF while the readText() helper folds it; on raw bytes
// the Dart file hashes to a different value (93d6ae8ee92f). Pinning the basis keeps
// the assertion stable regardless of how the checkout normalises line endings.

// Red fingerprints: a Dart-side edit to the batch gate, or to the corpus this file
// counts, is meant to break these so that the numbers quoted above get re-derived
// instead of being quietly kept.
const DART_EXEC_SHA = "5c5bfe4da555";
const ORCH_TEST_SHA = "cca059b699cd";
const ORCH_SHA = "5c2ef645d5b0";

const dartLines = DART.split(NL);
const dartLineOf = (needle: string): number => {
  const hits: number[] = [];
  dartLines.forEach((l, i) => { if (l.includes(needle)) hits.push(i + 1); });
  return hits.length === 1 ? (hits[0] as number) : -1;
};

// --------------------------------------------------------------------------- 1
describe("Dart batch gate as the port sees it", () => {
  it("fingerprints the Dart executor, the gate and the TS corpus", () => {
    expect(sha12(DART)).toBe(DART_EXEC_SHA);
    expect(sha12(ORCH_SUITE)).toBe(ORCH_TEST_SHA);
    expect(sha12(ORCH)).toBe(ORCH_SHA);
  });

  it("asks SafetyGuard exactly once for the whole batch", () => {
    expect(dartLines.filter((l) => l.includes("SafetyGuard.check(command)")).length).toBe(1);
  });

  it("compares the level against SafetyLevel.safe one line below the check", () => {
    const check = dartLineOf("final level = SafetyGuard.check(command);");
    const cmp = dartLineOf("if (level == SafetyLevel.safe) {");
    expect(check).toBe(121);
    expect(cmp).toBe(122);
    expect(cmp - check).toBe(1);
  });

  it("keeps the safe branch parallel and the unsafe branch serial", () => {
    const wait = dartLineOf("await Future.wait(futures);");
    const stop = dartLineOf("if (stopOnFailure && !results[hostId]!.success) {");
    expect(wait).toBeGreaterThan(122);
    expect(stop).toBeGreaterThan(wait);
    const parallelWindow = dartLines.slice(122, wait);
    expect(parallelWindow.filter((l) => l.includes("_executeOneAndStore")).length).toBe(1);
    expect(parallelWindow.filter((l) => l.includes("stopOnFailure")).length).toBe(0);
    const serialWindow = dartLines.slice(wait, stop);
    expect(serialWindow.filter((l) => l.includes("SafetyGuard.check")).length).toBe(0);
  });
});

// --------------------------------------------------------------------------- 2
// Every isReadOnlyCommand(...) literal in the existing suite, parsed rather than
// transcribed, together with the value the suite asserts for it.
interface CorpusRow { command: string; asserted: boolean; }
function parseCorpus(src: string): CorpusRow[] {
  const rows: CorpusRow[] = [];
  const call = "isReadOnlyCommand(";
  let from = 0;
  for (;;) {
    const at = src.indexOf(call, from);
    if (at < 0) break;
    const open = at + call.length;
    const quote = src[open];
    if (quote !== QUOTE && quote !== APOS) { from = open; continue; }
    const close = src.indexOf(quote, open + 1);
    if (close < 0) { from = open; continue; }
    const command = src.slice(open + 1, close);
    const eol = src.indexOf(NL, close);
    const tail = src.slice(close, eol < 0 ? src.length : eol);
    rows.push({command, asserted: tail.includes("toBe(true)")});
    from = close + 1;
  }
  return rows;
}

const CORPUS = parseCorpus(ORCH_SUITE);

describe("the two dimensions and their measured relation", () => {
  it("parses the whole existing assertion corpus", () => {
    expect(CORPUS.length).toBe(87);
    expect(CORPUS.filter((r) => r.asserted).length).toBe(46);
    for (const row of CORPUS) {
      expect(isReadOnlyCommand(row.command)).toBe(row.asserted);
    }
  });

  it("the whitelist never claims more than the Dart classifier allows", () => {
    const retracted = CORPUS.filter((r) => r.asserted && checkSafety(r.command) !== "safe");
    expect(retracted).toStrictEqual([]);
  });

  it("Dart alone would parallelise 34 commands the whitelist refuses", () => {
    const onlyWhitelistStops = CORPUS.filter((r) => !r.asserted && checkSafety(r.command) === "safe");
    expect(onlyWhitelistStops.length).toBe(34);
    const set = new Set(onlyWhitelistStops.map((r) => r.command));
    for (const rep of ["git push origin main", "docker rm c", "kubectl delete pod x"]) {
      expect(set.has(rep)).toBe(true);
    }
  });

  it("the conjunction agrees with the whitelist on the whole corpus", () => {
    for (const row of CORPUS) {
      expect(isParallelSafeCommand(row.command)).toBe(row.asserted);
    }
  });
});

// --------------------------------------------------------------------------- 3
describe("the second gate is live on the batch path", () => {
  // Counts in-flight invokeSsh calls. The parallel branch overlaps them, the serial
  // branch never does, so the peak is the branch discriminator.
  function countingClient(): {client: ReverseRpcClient; peak: () => number; calls: () => number} {
    let inflight = 0;
    let high = 0;
    let total = 0;
    const c = {
      invokeSsh: async (_p: {hostId: string; command: string}) => {
        inflight += 1;
        total += 1;
        if (inflight > high) high = inflight;
        await new Promise((res) => { setTimeout(res, 5); });
        inflight -= 1;
        return {exitCode: 0, output: "ok", durationMs: 1, failureKind: "none"};
      },
    };
    return {client: c as unknown as ReverseRpcClient, peak: () => high, calls: () => total};
  }

  const HOSTS = ["web1", "web2", "web3"];

  it("a whitelisted, safe command overlaps its hosts", async () => {
    const probe = countingClient();
    const m = await new ReverseRpcOrchestrator(probe.client).executeBatch(HOSTS, "uptime", {});
    expect(probe.calls()).toBe(3);
    expect(probe.peak()).toBe(3);
    expect(m.size).toBe(3);
  });

  it("refusing the safety level serialises the very same command", async () => {
    const probe = countingClient();
    const seen: string[] = [];
    const opts: ExecuteBatchOptions = {
      stopOnFailure: true,
      safetyCheckForTesting: (command: string) => { seen.push(command); return "warn"; },
    };
    const m = await new ReverseRpcOrchestrator(probe.client).executeBatch(HOSTS, "uptime", opts);
    expect(probe.calls()).toBe(3);
    expect(probe.peak()).toBe(1);
    expect(m.size).toBe(3);
    expect(seen).toStrictEqual(["uptime"]);
  });

  it("the whitelist alone serialises, without consulting the injected probe", async () => {
    const probe = countingClient();
    let probed = 0;
    const opts: ExecuteBatchOptions = {
      safetyCheckForTesting: () => { probed += 1; return "safe"; },
    };
    await new ReverseRpcOrchestrator(probe.client).executeBatch(HOSTS, "rm -rf x", opts);
    expect(probe.peak()).toBe(1);
    expect(probed).toBe(0);
  });

  it("stopOnFailure only engages on the serial branch", async () => {
    const c = {
      invokeSsh: async (p: {hostId: string}) => ({
        exitCode: p.hostId === "web1" ? 1 : 0, output: "", durationMs: 1, failureKind: "none",
      }),
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const parallel = await ex.executeBatch(HOSTS, "uptime", {stopOnFailure: true});
    expect(parallel.get("web1")!.success).toBe(false);
    expect(parallel.get("web2")!.success).toBe(true);
    expect(parallel.get("web3")!.success).toBe(true);
    const serial = await ex.executeBatch(HOSTS, "uptime", {
      stopOnFailure: true,
      safetyCheckForTesting: () => "blocked",
    });
    expect(serial.get("web1")!.success).toBe(false);
    expect(serial.get("web2")!.stderr).toContain("已跳过（前序主机失败）");
  });

  it("the injectable seam defaults to the real classifier", () => {
    expect(checkSafety("uptime")).toBe("safe");
    expect(isParallelSafeCommand("uptime")).toBe(true);
    expect(isParallelSafeCommand("uptime", () => "warn")).toBe(false);
    expect(isParallelSafeCommand("", () => "safe")).toBe(false);
  });
});

// --------------------------------------------------------------------------- 4
describe("the gate is wired, not merely defined", () => {
  it("the batch method calls the gate and nothing else decides the branch", () => {
    const gateCall = "if (isParallelSafeCommand(command, opts.safetyCheckForTesting)) {";
    expect(ORCH.split(gateCall).length - 1).toBe(1);
    expect(ORCH.split("if (isReadOnlyCommand(command)) {").length - 1).toBe(0);
  });

  it("the gate delegates to the real SafetyGuard by default", () => {
    const importLine = "import {checkSafety} from " + QUOTE + "../utils/safety_guard.js" + QUOTE + ";";
    expect(ORCH.includes(importLine)).toBe(true);
    expect(ORCH.split("safetyCheck(command)").length - 1).toBe(1);
  });

  it("only the orchestrator, its barrel and this test mention the new gate", () => {
    const files = [
      "src/tools/orchestrator.ts",
      "src/tools/index.ts",
      "test/orchestrator_safety_gate.test.ts",
    ];
    const counts = [2, 1, 11];
    const actual = files.map((rel) => readText(join(AC, rel)).split("isParallelSafeCommand").length - 1);
    expect(actual).toStrictEqual(counts);
  });

  it("the tools barrel re-exports it and the root barrel stays quiet", () => {
    expect(TOOLS_INDEX.includes("isParallelSafeCommand")).toBe(true);
    expect(ROOT_INDEX.includes("isParallelSafeCommand")).toBe(false);
    const mod = toolsBarrel as unknown as Record<string, unknown>;
    expect(typeof mod.isParallelSafeCommand).toBe("function");
    expect(typeof mod.isReadOnlyCommand).toBe("function");
    expect("isParallelSafeCommand" in (rootBarrel as unknown as Record<string, unknown>)).toBe(false);
  });
});
