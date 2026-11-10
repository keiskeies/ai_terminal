// LocalFilePolicy: agent_core/src/utils/local_file_policy.ts against the Dart
// services/local_file_policy.dart, and specifically against the checkPath blacklist
// site that Dart runs at line 147 of that file.
//
// This closes the half of section 9 item 7 that the batch-gate round left open.
// src/utils/safety_guard.ts had already been ported 1:1 with all its rules and
// Chinese wording, but checkPath had exactly zero callers on the Node side, so the
// sensitive-path dimension existed in code and guarded nothing. local_file_policy.ts
// is what calls it, which makes line 147 of the Dart file a line with a real caller
// in this repo for the first time.
//
// Two gates, and the Dart doc is emphatic that neither is optional: an allowlist
// that is EMPTY by default, so a fresh core authorises no file at all, outranked by
// a blacklist - a user who whitelists their whole home directory must still be
// refused the ssh key, because local write access must not become persistent
// control of the machine. Layer 2 probes exactly that precedence, since it is the
// only reason two gates exist where one would be shorter.
//
// Layer 1 parses the Dart source, because CI has no Dart SDK and it can never run
// here. Layer 2 is behaviour, using only cross-platform paths so it also holds on
// Linux. Layer 3 pins the wiring surface. The policy is not yet consumed by the
// tool layer - the local_file tools still run their primitives unguarded - which
// is the next increment of section 9 item 7. What this file does prove is that the
// blacklist half of the policy now has a real caller: the checkPath orphan is
// closed, so a sensitive path handed to a policy object is refused before the
// allowlist roots are ever consulted.
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {
  DEFAULT_MAX_READ_BYTES,
  LOCAL_FILE_POLICY_SETTINGS_KEY,
  LocalFilePolicy,
  LocalPathDecision,
  LocalPathVerdict,
} from "../src/utils/local_file_policy.js";
import {checkPath} from "../src/utils/safety_guard.js";

const HERE = dirname(fileURLToPath(new URL(import.meta.url)));
const AC = join(HERE, "..");
const POLICY_TS = join(AC, "src", "utils", "local_file_policy.ts");
const OPS_TS = join(AC, "src", "utils", "local_file_ops.ts");
const DART_POLICY = join(AC, "..", "ai_terminal", "lib", "services", "local_file_policy.dart");
const DART_TOOLS = join(AC, "..", "ai_terminal", "lib", "services", "local_file_tools.dart");
const DART_EXEC = join(AC, "..", "ai_terminal", "lib", "services", "local_exec_tool.dart");
const NL = String.fromCharCode(10);
const CRLF = String.fromCharCode(13) + String.fromCharCode(10);
const DOLLAR = String.fromCharCode(36);
const TRASH = ".ai_terminal_trash";

const readText = (path: string): string => readFileSync(path, "utf-8").split(CRLF).join(NL);
const sha12 = (text: string): string => createHash("sha1").update(text).digest("hex").slice(0, 12);
const hasCJK = (s: string): boolean => /[\u3000-\u9fff\uff00-\uffef]/.test(s);

const DART = readText(DART_POLICY);
const DART_TOOLS_TXT = readText(DART_TOOLS);
const DART_EXEC_TXT = readText(DART_EXEC);
const POLICY = readText(POLICY_TS);
const OPS = readText(OPS_TS);
const dartLines = DART.split(NL);

// Red fingerprints: an edit to the Dart policy, or to the Node port this file
// quotes literals from, is meant to break these so the numbers and the wording
// below are re-derived instead of being quietly kept.
const DART_POLICY_SHA = "a3057e0f61de";
const DART_TOOLS_SHA = "4d5a9567e302";
const DART_EXEC_SHA = "c061acd3286c";
const POLICY_SHA = "94dc4862f4bd";

const dartLineOf = (needle: string): number => {
  const hits: number[] = [];
  dartLines.forEach((l, i) => {
    if (l.includes(needle)) hits.push(i + 1);
  });
  return hits.length === 1 ? (hits[0] as number) : -1;
};

// a forward-slash-joined temp root works on win32 and posix alike
const rootDir = join(AC, "dist", ".sg", "lfp_root");
const ROOT_FWD = rootDir.split(String.fromCharCode(92)).join("/");

// ---------------------------------------------------------------- layer 1
describe("Dart policy source as the port sees it", () => {
  it("fingerprints both sides", () => {
    expect(sha12(DART)).toBe(DART_POLICY_SHA);
    expect(sha12(DART_TOOLS_TXT)).toBe(DART_TOOLS_SHA);
    expect(sha12(DART_EXEC_TXT)).toBe(DART_EXEC_SHA);
    expect(sha12(POLICY)).toBe(POLICY_SHA);
  });

  it("runs the gates in one fixed order: empty, disabled, reserved, blacklist, roots", () => {
    const empty = dartLineOf("if (rawPath.trim().isEmpty) {");
    const disabled = dartLineOf("if (!enabled) {");
    const reserved = dartLineOf("if (p.split(lexical).contains(trashDirName)) {");
    const blacklist = dartLineOf("final safety = SafetyGuard.checkPath(lexical);");
    const rootsEmpty = dartLineOf("if (roots.isEmpty) {");
    const within = dartLineOf("if (_isWithin(probe, root)) {");
    expect([empty, disabled, reserved, blacklist, rootsEmpty, within]).toStrictEqual([121, 125, 138, 147, 158, 167]);
    // the blacklist is consulted before any root is collected, so a sensitive path
    // can never reach the within-a-root loop and be allowed by it
    expect(blacklist).toBeLessThan(dartLineOf("final roots = ["));
    expect(dartLines.filter((l) => l.includes("SafetyGuard.checkPath(lexical)")).length).toBe(1);
    expect(dartLineOf("if (safety.level == SafetyLevel.blocked) {")).toBe(148);
  });

  it("never produces escape from decide, and the port does not invent one", () => {
    // escape exists in the enum and in the tool-layer refusal-prefix map, but
    // decide() has no path returning it: the traversal case is caught by
    // normalise-then-within and reported as notInAllowlist. Pinning that the port
    // also never yields escape keeps the two verdict sets identical.
    expect(dartLineOf("escape,")).toBe(19);
    const decideBody = dartLines.slice(119, 176);
    expect(decideBody.filter((l) => l.includes("escape")).length).toBe(0);
    expect(POLICY.split("LocalPathVerdict.escape").length - 1).toBe(0);
  });

  it("reproduces every AI-facing Chinese literal verbatim", () => {
    // Pull the single-quoted CJK literals out of the Dart source, drop the two
    // debugPrint lines (the Node port has no SettingsDao and no logging dependency,
    // so they have no counterpart by design), split on interpolation, then require
    // every remaining CJK run to appear byte-identically in the TS source.
    const lits: string[] = [];
    const re = /'([^'\\\n]*)'/g;
    let m = re.exec(DART);
    while (m !== null) {
      if (hasCJK(m[1] as string)) lits.push(m[1] as string);
      m = re.exec(DART);
    }
    const business = lits.filter((s) => !s.startsWith("[LocalFilePolicy]"));
    expect(business.length).toBe(6);
    let runs = 0;
    for (const lit of business) {
      // strip Dart dollar-identifier interpolation so only the literal text is compared
      const dollarRe = new RegExp(String.fromCharCode(92) + DOLLAR + "[A-Za-z_][A-Za-z0-9_]*", "g");
      const stripped = lit.replace(dollarRe, "");
      for (const part of stripped.split(DOLLAR)) {
        if (!hasCJK(part)) continue;
        runs += 1;
        expect(POLICY.includes(part)).toBe(true);
      }
    }
    expect(runs).toBe(6);
  });

  it("shares one trash name across policy, ops and Dart", () => {
    expect(LocalFilePolicy.trashDirName).toBe(TRASH);
    expect(DART.includes("'" + TRASH + "'")).toBe(true);
    expect(OPS.includes('"' + TRASH + '"')).toBe(true);
  });

  it("defaults to deny-all and reads maxReadBytes from the same defaults", () => {
    expect(dartLineOf("this.enabled = false,")).toBe(67);
    expect(dartLineOf("this.maxReadBytes = 2 * 1024 * 1024,")).toBe(69);
    expect(LocalFilePolicy.load().enabled).toBe(false);
    expect(LocalFilePolicy.load().allowedDirs).toStrictEqual([]);
    expect(LocalFilePolicy.load().maxReadBytes).toBe(DEFAULT_MAX_READ_BYTES);
    expect(DEFAULT_MAX_READ_BYTES).toBe(2 * 1024 * 1024);
  });

  it("maps each verdict to exactly one refusal prefix in the tool layer", () => {
    // local_file_tools.dart turns a verdict into the prefix of the failure the AI
    // reads. Pinning the five prefixes means a rename on either side is caught.
    for (const verdict of ["sensitive", "reserved", "notInAllowlist", "escape", "allowed"]) {
      const pair = "LocalPathVerdict." + verdict + " => ";
      expect(DART_TOOLS_TXT.split(pair).length - 1).toBe(1);
    }
    expect(DART_TOOLS_TXT.includes("LocalFilePolicy.decide")).toBe(true);
    expect(DART_EXEC_TXT.includes("policy.decide(cwd)")).toBe(true);
  });
});

// ---------------------------------------------------------------- layer 2
describe("decide behaviour mirrors the gate order", () => {
  const disabled = LocalFilePolicy.load();
  const enabled = new LocalFilePolicy({enabled: true, allowedDirs: [ROOT_FWD]});

  it("empty path is refused before anything else", () => {
    const d = enabled.decide("   ");
    expect(d.verdict).toBe(LocalPathVerdict.notInAllowlist);
    expect(d.reason).toBe("路径为空");
    expect(d.resolved).toBe("");
    expect(d.isAllowed).toBe(false);
  });

  it("a disabled policy refuses even a path that would be within a root", () => {
    const d = disabled.decide(ROOT_FWD + "/src/a.ts");
    expect(d.verdict).toBe(LocalPathVerdict.notInAllowlist);
    expect(d.reason).toBe("本地文件访问未开启。请在 设置 → Agent → 本地文件 中添加允许访问的目录。");
    // the reason still carries the raw path back so the caller can echo it
    expect(disabled.decide(ROOT_FWD).resolved).toBe(ROOT_FWD);
  });

  it("the trash directory is reserved and cannot be touched directly", () => {
    const d = enabled.decide(ROOT_FWD + "/" + TRASH + "/entry");
    expect(d.verdict).toBe(LocalPathVerdict.reserved);
    expect(d.reason).toBe(TRASH + " 是回收区，只能由删除工具自身写入，不能直接访问。");
  });

  it("the blacklist outranks the allowlist - a home-wide allowlist still loses to ssh", () => {
    // this is the whole point of the two-gate design (local_file_policy.dart:147):
    // a root covering the sensitive path must NOT let it through. checkPath reports
    // id_rsa as blocked, so the verdict is sensitive even though the path is inside
    // the (deliberately broad) allowedDirs root.
    const homeRoot = new LocalFilePolicy({enabled: true, allowedDirs: [process.env.USERPROFILE ?? process.env.HOME ?? "/"]});
    const sshKey = (process.env.USERPROFILE ?? process.env.HOME ?? "").split(String.fromCharCode(92)).join("/") + "/.ssh/id_rsa";
    expect(checkPath(sshKey).level).toBe("blocked");
    const d = homeRoot.decide(sshKey);
    expect(d.verdict).toBe(LocalPathVerdict.sensitive);
    expect(d.isAllowed).toBe(false);
    // and the blacklist check runs first: a sensitive path under a root that is NOT
    // whitelisted is reported as sensitive, not notInAllowlist
    const d2 = enabled.decide(sshKey);
    expect(d2.verdict).toBe(LocalPathVerdict.sensitive);
  });

  it("a path inside the root is allowed and re-exposed as resolved", () => {
    const target = ROOT_FWD + "/src/a.ts";
    const d = enabled.decide(target);
    expect(d.verdict).toBe(LocalPathVerdict.allowed);
    expect(d.isAllowed).toBe(true);
    expect(d.reason).toBeUndefined();
    expect(d.resolved.length).toBeGreaterThan(0);
    expect(enabled.decide(ROOT_FWD).verdict).toBe(LocalPathVerdict.allowed);
  });

  it("a path outside every root is refused with the current allowlist echoed", () => {
    const d = enabled.decide("/etc/hostname");
    // checkPath does not block every system path, so the ordering test relies on a
    // path that checkPath leaves alone; it lands in the allowlist loop
    expect([LocalPathVerdict.sensitive, LocalPathVerdict.notInAllowlist]).toContain(d.verdict);
    if (d.verdict === LocalPathVerdict.notInAllowlist) {
      expect(d.reason).toContain("路径不在授权目录内。当前授权: ");
    }
  });

  it("an enabled policy with zero roots is still deny-all", () => {
    const none = new LocalFilePolicy({enabled: true});
    const d = none.decide(ROOT_FWD + "/x");
    expect(d.verdict).toBe(LocalPathVerdict.notInAllowlist);
    expect(d.reason).toBe("尚未配置任何允许访问的目录。");
  });

  it("extraRoots let a per-task project root through without touching the allowlist", () => {
    const none = new LocalFilePolicy({enabled: true});
    expect(none.decide(ROOT_FWD).verdict).toBe(LocalPathVerdict.notInAllowlist);
    expect(none.decide(ROOT_FWD, [ROOT_FWD]).verdict).toBe(LocalPathVerdict.allowed);
  });

  it("traversal out of a root collapses to notInAllowlist, never allowed", () => {
    const d = enabled.decide(ROOT_FWD + "/../..", []);
    expect(d.verdict).not.toBe(LocalPathVerdict.allowed);
  });
});

// ---------------------------------------------------------------- layer 3
describe("the blacklist gate is wired, not merely defined", () => {
  it("local_file_policy.ts calls checkPath exactly once on the lexical path", () => {
    expect(POLICY.split("checkPath(lexical)").length - 1).toBe(1);
    expect(POLICY.includes('from "./safety_guard.js"')).toBe(true);
    expect(POLICY.split("from \"./safety_guard.js\"").length - 1).toBe(1);
    const idx = POLICY.indexOf("checkPath(lexical)");
    const reservedIdx = POLICY.indexOf("LocalPathVerdict.reserved");
    // reserved is checked before the blacklist, mirroring the Dart order
    expect(reservedIdx).toBeLessThan(idx);
    const rootsEmptyIdx = POLICY.indexOf("尚未配置任何允许访问的目录。");
    expect(idx).toBeLessThan(rootsEmptyIdx);
  });

  it("checkPath now has a real caller in src, closing the orphan", () => {
    // the whole reason item 7 was open: checkPath existed but nobody called it.
    // Guard against a future edit that drops the call and silently re-orphan it.
    const callLine = POLICY.split(NL).filter((l) => l.includes("const safety = checkPath(lexical);"));
    expect(callLine.length).toBe(1);
  });

  it("load treats a throwing or non-object reader as disabled, never as allow-all", () => {
    expect(LocalFilePolicy.load(() => {
      throw new Error("boom");
    }).enabled).toBe(false);
    expect(LocalFilePolicy.load(() => undefined).enabled).toBe(false);
    expect(LocalFilePolicy.load(() => 42).enabled).toBe(false);
    expect(LocalFilePolicy.load(() => ({enabled: true, allowedDirs: ["/x"]})).enabled).toBe(true);
    expect(LOCAL_FILE_POLICY_SETTINGS_KEY).toBe("localFilePolicy");
  });

  it("fromMap is defensive: a bad maxReadBytes falls back to the default", () => {
    const p = LocalFilePolicy.fromMap({enabled: "yes", allowedDirs: "not-a-list", maxReadBytes: "nope"});
    expect(p.enabled).toBe(false);
    expect(p.allowedDirs).toStrictEqual([]);
    expect(p.maxReadBytes).toBe(DEFAULT_MAX_READ_BYTES);
  });

  it("toMap/fromMap round-trips and copyWith preserves the untouched fields", () => {
    const p = new LocalFilePolicy({enabled: true, allowedDirs: ["/a"], maxReadBytes: 999});
    const back = LocalFilePolicy.fromMap(p.toMap());
    expect(back.enabled).toBe(true);
    expect(back.allowedDirs).toStrictEqual(["/a"]);
    expect(back.maxReadBytes).toBe(999);
    const c = p.copyWith({maxReadBytes: 1000});
    expect(c.enabled).toBe(true);
    expect(c.allowedDirs).toStrictEqual(["/a"]);
    expect(c.maxReadBytes).toBe(1000);
  });

  it("LocalPathDecision.isAllowed is true only for the allowed verdict", () => {
    for (const verdict of [LocalPathVerdict.notInAllowlist, LocalPathVerdict.sensitive, LocalPathVerdict.escape, LocalPathVerdict.reserved]) {
      expect(new LocalPathDecision(verdict, "/x").isAllowed).toBe(false);
    }
    expect(new LocalPathDecision(LocalPathVerdict.allowed, "/x").isAllowed).toBe(true);
  });
});
