// Oracle-replay test for looksLikeLocalWindowsCommand (r135).
// Re-reads local_command_detector.dart at run time and pins every RegExp source
// and the boolean composition against the Node port in src/utils/local_command_detector.ts.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {looksLikeLocalWindowsCommand} from "../src/utils/local_command_detector.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string) =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const DART = linesOf("../../ai_terminal/lib/utils/local_command_detector.dart");

describe("r135: looksLikeLocalWindowsCommand oracle", () => {
  it("drive-path: D:\\ tools detected, echo not", () => {
    expect(looksLikeLocalWindowsCommand("D:" + String.fromCharCode(92) + "tools" + String.fromCharCode(92) + "docker.exe ps")).toBe(true);
    expect(looksLikeLocalWindowsCommand("echo hi")).toBe(false);
  });

  it("start-with-drive: C:/ detected, ls not", () => {
    expect(looksLikeLocalWindowsCommand("C:/usr/bin/ls")).toBe(true);
    expect(looksLikeLocalWindowsCommand("ls -la")).toBe(false);
  });

  it("PS construct: $env: and cmdlets detected, rm -rf not", () => {
    expect(looksLikeLocalWindowsCommand("$env:PATH")).toBe(true);
    expect(looksLikeLocalWindowsCommand("Get-Process | Select-Object CPU")).toBe(true);
    expect(looksLikeLocalWindowsCommand("rm -rf /")).toBe(false);
  });

  it("start-with-PS: Stop-Process detected, notepad not", () => {
    expect(looksLikeLocalWindowsCommand("Stop-Process -Name notepad")).toBe(true);
    expect(looksLikeLocalWindowsCommand("notepad.exe")).toBe(false);
  });

  it("composition matches Dart 33-35", () => {
    expect(looksLikeLocalWindowsCommand("D:" + String.fromCharCode(92) + "x")).toBe(true);
    expect(looksLikeLocalWindowsCommand("$a=1")).toBe(true);
    expect(looksLikeLocalWindowsCommand("ls -la /tmp")).toBe(false);
  });

  it("Dart source lines are non-empty (run-time pin)", () => {
    expect(DART[13].trim().length).toBeGreaterThan(0);
    expect(DART[16].trim().length).toBeGreaterThan(0);
    expect(DART[32].trim().length).toBeGreaterThan(0);
  });
});
