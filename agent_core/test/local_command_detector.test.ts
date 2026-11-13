// local_command_detector.test.ts - tests for src/utils/local_command_detector.ts
// Mirrors the Dart local_command_detector.dart logic (37 lines, 4 regex groups).

import {describe, it, expect} from "vitest";
import {looksLikeLocalWindowsCommand} from "../src/utils/local_command_detector.js";

describe("looksLikeLocalWindowsCommand", () => {
  it("empty command returns false", () => {
    expect(looksLikeLocalWindowsCommand("")).toBe(false);
    expect(looksLikeLocalWindowsCommand("   ")).toBe(false);
  });

  it("drive-letter path at start", () => {
    expect(looksLikeLocalWindowsCommand("C:\\Windows\\System32\\cmd.exe")).toBe(true);
    expect(looksLikeLocalWindowsCommand("D:/temp/test.txt")).toBe(true);
  });

  it("drive-letter path in middle (with PowerShell construct)", () => {
    // hasDrivePath && hasPSConstruct
    expect(looksLikeLocalWindowsCommand("echo C:\\temp && Get-ChildItem C:\\")).toBe(true);
    expect(looksLikeLocalWindowsCommand("dir C:\\temp")).toBe(false); // no PS construct
  });

  it("PowerShell cmdlet at start", () => {
    expect(looksLikeLocalWindowsCommand("Get-ChildItem C:\\")).toBe(true);
    expect(looksLikeLocalWindowsCommand("Set-Item -Path x")).toBe(true);
    expect(looksLikeLocalWindowsCommand("Test-Path /tmp")).toBe(true);
  });

  it("PowerShell variable at start", () => {
    expect(looksLikeLocalWindowsCommand("$env:PATH")).toBe(true);
    expect(looksLikeLocalWindowsCommand("$x = 5")).toBe(true);
  });

  it("Unix commands are not local-Windows", () => {
    expect(looksLikeLocalWindowsCommand("ls -la")).toBe(false);
    expect(looksLikeLocalWindowsCommand("cd /tmp && ls")).toBe(false);
    expect(looksLikeLocalWindowsCommand("echo hello")).toBe(false);
  });

  it("remote-like commands without Windows signals", () => {
    expect(looksLikeLocalWindowsCommand("ssh web1 'ls /var/log'")).toBe(false);
    expect(looksLikeLocalWindowsCommand("scp file.txt web1:/tmp/")).toBe(false);
  });

  it("PowerShell in middle without drive path is not local", () => {
    // Get-ChildItem in middle but no drive path and not at start
    expect(looksLikeLocalWindowsCommand("ssh web1 Get-ChildItem")).toBe(false);
  });
});