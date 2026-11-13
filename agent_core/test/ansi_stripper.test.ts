// ansi_stripper.test.ts
// Mirrors Dart ansi_stripper_test.dart (49 lines, 7 cases).

import {describe, it, expect} from "vitest";
import {stripAnsi} from "../src/utils/ansi_stripper.js";

describe("AnsiStripper (Dart oracle: ansi_stripper_test.dart)", () => {

  it("removes CSI color sequences", () => {
    expect(stripAnsi('\x1b[1;32mActive: running\x1b[0m')).toBe('Active: running');
  });

  it("removes OSC title sequences and their partial residue", () => {
    expect(stripAnsi('\x1b]0;root@host:~\x07[root@host ~]# ls')).toBe('ls');
    expect(stripAnsi(']0;root@host:~\nresult')).toBe('result');
  });

  it("removes partial CSI fragments left after lost ESC", () => {
    expect(stripAnsi('[?2004h[Koutput[>0;10;1c')).toBe('output');
  });

  it("keeps newlines/tabs but removes other control chars and BEL", () => {
    expect(stripAnsi('a\x07b\tc\nd')).toBe('ab\tc\nd');
  });

  it("collapses 3+ blank lines into one blank line", () => {
    expect(stripAnsi('a\n\n\n\nb')).toBe('a\n\nb');
  });

  it("trims trailing spaces per line", () => {
    expect(stripAnsi('a   \nb  ')).toBe('a\nb');
  });

  it("strips prompt prefixes at line starts", () => {
    expect(stripAnsi('[root@host ~]# echo hi\n[deploy@web-1 ~]$ uptime')).toBe('echo hi\nuptime');
  });

  it("leaves plain Chinese output untouched", () => {
    expect(stripAnsi("\u6b63\u5728\u542f\u52a8 nginx \u670d\u52a1...")).toBe("\u6b63\u5728\u542f\u52a8 nginx \u670d\u52a1...");
  });
});