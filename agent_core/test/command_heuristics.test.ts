// ASCII-only file per project emit rules; CJK literals are \uXXXX escapes
// byte-compared against the Dart oracle where stated.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));

import {isQueryCommand, QUERY_PREFIXES, INTERACTIVE_PREFIXES} from "../src/utils/command_heuristics.js";

function dartHeur(): string {
  return readFileSync(HERE + "../../ai_terminal/lib/utils/command_heuristics.dart", "utf-8").replace(/\r\n/g, NL);
}
// single-quoted literals between two markers, Dart backslash-n resolved
function dartLiterals(src: string, startMark: string, endMark: string): string[] {
  const a = src.indexOf(startMark);
  const b = src.indexOf(endMark, a);
  if (a < 0 || b < 0) throw new Error("oracle markers not found");
  const body = src.slice(a, b);
  const out: string[] = [];
  const re = /'((?:[^'\\]|\\.)*)'/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) out.push(m[1].replace(/\\n/g, NL));
  return out;
}

describe("isQueryCommand oracle parity (command_heuristics.dart 40-117)", () => {
  it("query prefix table equals the Dart literal list, order included", () => {
    const oracle = dartLiterals(dartHeur(), "final queryPrefixes = [", NL + "  ];");
    expect(QUERY_PREFIXES.length).toBeGreaterThan(100);
    expect(QUERY_PREFIXES).toEqual(oracle);
  });
  it("interactive exclusion table equals the Dart literal list", () => {
    const oracle = dartLiterals(dartHeur(), "const interactivePrefixes = [", NL + "  ];");
    expect(INTERACTIVE_PREFIXES).toEqual(oracle);
  });
});

describe("isQueryCommand behaviour", () => {
  it("bare interactive names are rejected outright", () => {
    for (const c of ["top", "less", "more", "vi", "vim", "nano"]) {
      expect(isQueryCommand(c)).toBe(false);
    }
  });
  it("interactive prefixes rejected even with args", () => {
    expect(isQueryCommand("tail -f app.log")).toBe(false);
    expect(isQueryCommand("  tail --follow x")).toBe(false);
    expect(isQueryCommand("tailf app.log")).toBe(false);
    expect(isQueryCommand("less /var/log/syslog")).toBe(false);
    expect(isQueryCommand("vim /etc/hosts")).toBe(false);
  });
  it("plain tail and head are queries", () => {
    expect(isQueryCommand("tail -n 50 app.log")).toBe(true);
    expect(isQueryCommand("head -100 big.csv")).toBe(true);
  });
  it("sub-command granularity mirrors Dart", () => {
    expect(isQueryCommand("systemctl status nginx")).toBe(true);
    expect(isQueryCommand("systemctl restart nginx")).toBe(false);
    expect(isQueryCommand("docker ps -a")).toBe(true);
    expect(isQueryCommand("docker rm web1")).toBe(false);
    expect(isQueryCommand("git log --oneline -5")).toBe(true);
    expect(isQueryCommand("git commit -m x")).toBe(false);
    expect(isQueryCommand("iptables -nL")).toBe(true);
    expect(isQueryCommand("iptables -F")).toBe(false);
    expect(isQueryCommand("sed -n 10p f")).toBe(true);
    expect(isQueryCommand("sed -i s/a/b/ f")).toBe(false);
  });
  it("leading whitespace and case are normalised like Dart", () => {
    expect(isQueryCommand("   CAT NOTES.md")).toBe(true);
    expect(isQueryCommand(NL + "  PS aux")).toBe(true);
  });
  it("documented quirk kept 1:1: bare w prefix swallows write- verbs", () => {
    // The Dart table has a bare "w" (for who), so startsWith matches "wall" /
    // "write-item". Parity beats intuition: fixing it needs a Dart-side change
    // first, never a silent one-sided Node fix.
    expect(isQueryCommand("write-item foo")).toBe(true);
  });
});
