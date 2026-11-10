// Regression: docs section 6.2 r6_shell_fork.test.ts (AGENTS.md R6.1 + R8.1).
//
// R6.1: command wrappers MUST branch by shell type - PowerShell uses ";" +
// $LASTEXITCODE, cmd.exe uses "&" + %errorlevel%, POSIX shells use ";" + $?.
// One shell's syntax on another means the completion marker never appears and
// executeAndWait waits forever. R8.1: marker detection matches the FULL
// pattern marker+digits; the bare substring (the literal command echo, where
// "$?" is just text) must never fire completion before the command ran.
//
// Historical bug this pins (found in the Node port, same shape as the Dart
// review that produced R6.1/R8.1): wrapCommand emitted `<cmd>; <marker> $?`
// - a bare token the shell tried to EXECUTE. Verified empirically on this
// host: bash -> 127 "command not found", cmd.exe -> 9009, PowerShell ->
// "not recognized" + exit 1. The pipeline exit code therefore became the
// not-found code and the real status was lost on every local_exec call.
//
// Hermeticity notes (do not "fix" these into flakes):
// * bash e2e is pinned at UNIT level only: the DSH Windows CI host mangles
//   bash argv through -c (probe: `false; echo "MK:$?"` printed MK:0; script
//   files exit 127). Asserting bash runtime behavior here would pin the
//   sandbox bug, not the contract.
// * the cmd.exe branch keeps Dart's byte form (deviation would break the
//   Dart<->Node byte-comparison layer), so %errorlevel% expands at PARSE time
//   and a wrapped non-zero code can read as 0. No cmd test asserts a non-zero
//   wrapped code; the close-code fallback test uses a RAW unwrapped command.
// * PowerShell here is blocked from launching native exes (AppLocker-style
//   "Cannot run a document in the middle of a pipeline"), so the end-to-end
//   non-zero fixture is a failing cmdlet (derivation -> 1). The $?-first
//   ordering is Dart-parity semantics, pinned deliberately.
// The marker round-trip through PowerShell and cmd.exe lives in
// test/builtin_tools.test.ts (runLocalCommand suite) - this file owns the
// per-shell byte contract and the scanner semantics.

import {describe, it, expect} from "vitest";
import {wrapCommand, extractExitMarker, detectShell} from "../../src/utils/shell_detect.js";

const M = "EXITCODE_LOCAL:"; // Dart convention: marker ends with ":"

describe("R6.1 wrapper forks by shell (Dart byte parity)", () => {
  it("posix single-line: same-line echo (a 2nd line would linger in the tty queue for sudo)", () => {
    expect(wrapCommand("ls -la", "bash", M)).toBe("ls -la; echo \"" + M + "$?\"");
    expect(wrapCommand("ls", "sh", M)).toBe("ls; echo \"" + M + "$?\"");
    expect(wrapCommand("ls", "zsh", M)).toBe("ls; echo \"" + M + "$?\"");
    expect(wrapCommand("ls", "zsh", M).indexOf("\n")).toBe(-1);
  });
  it("posix multi-line: echo on a NEW line (heredoc `EOF; echo` is not a terminator)", () => {
    const cmd = "cat > f <<'EOF'" + "\n" + "body" + "\n" + "EOF";
    const w = wrapCommand(cmd, "sh", M);
    const parts = w.split("\n");
    expect(parts[parts.length - 2]).toBe("EOF");          // terminator intact on its own line
    expect(parts[parts.length - 1]).toBe("echo \"" + M + "$?\"");
  });
  it("cmd.exe: & separator + echo marker%errorlevel% (no spaces: cmd echoes them)", () => {
    expect(wrapCommand("dir", "cmd", M)).toBe("dir & echo " + M + "%errorlevel%");
  });
  it("powershell: $LASTEXITCODE reset + $? derivation + echo marker$__ec", () => {
    const w = wrapCommand("Get-ChildItem", "powershell", M);
    expect(w.startsWith("$LASTEXITCODE=$null; Get-ChildItem; ")).toBe(true);
    expect(w).toContain("$__ec=if($?){0}");
    expect(w).toContain("elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}else{1}");
    expect(w.endsWith("echo \"" + M + "$__ec\"")).toBe(true);
  });
  it("each branch targets ITS shell: no cross-shell syntax leaks", () => {
    expect(wrapCommand("c", "bash", M)).not.toContain("%errorlevel%");
    expect(wrapCommand("c", "bash", M)).not.toContain("$LASTEXITCODE");
    expect(wrapCommand("c", "cmd", M)).not.toContain("$?");
    expect(wrapCommand("c", "cmd", M)).not.toContain("echo \"" + M);
    expect(wrapCommand("c", "powershell", M)).not.toContain("%errorlevel%");
    // PS reads $? only inside the $__ec derivation, never as the echoed code
    expect(wrapCommand("c", "powershell", M)).not.toContain("echo \"" + M + "$?\"");
    // POSIX shells never see the PowerShell-only constructs
    expect(wrapCommand("c", "sh", M)).not.toContain("$__ec");
  });
  it("detectShell still routes absolute paths (startup detection unchanged)", () => {
    expect(detectShell("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")).toBe("powershell");
    expect(detectShell("C:\\Windows\\System32\\cmd.exe")).toBe("cmd");
    expect(detectShell("/bin/bash")).toBe("bash");
  });
});

describe("R8.1 marker scanner: full pattern, first hit, carry semantics", () => {
  it("literal command echo (marker + literal $?) never matches", () => {
    // This is the R8.1 bug shape: a bare substring test would report DONE
    // before the command had even run, because the echoed command line
    // contains the marker verbatim.
    const echo = wrapCommand("echo done", "bash", M) + "\n";
    expect(echo).toContain(M);
    expect(extractExitMarker(echo, M)).toBe(null);
  });
  it("captures digits after the marker and splits before/after", () => {
    const hit = extractExitMarker("out line" + "\n" + M + "7" + "\n", M);
    expect(hit).not.toBe(null);
    expect(hit!.exitCode).toBe(7);
    expect(hit!.before).toBe("out line" + "\n");
    expect(hit!.after).toBe("\n");
  });
  it("first occurrence wins (Dart hasMatch semantics)", () => {
    const hit = extractExitMarker(M + "4 extra " + M + "9", M);
    expect(hit!.exitCode).toBe(4);
  });
  it("split marker across a chunk boundary needs the carry buffer", () => {
    // Dart ExitMarkerScanner keeps marker.length + 16 chars of tail as carry
    // and matches against carry + chunk; neither half alone may match.
    const a = "output" + "\n" + "EXITCODE_LO", b = "CAL:3" + "\n" + "more";
    expect(extractExitMarker(a, M)).toBe(null);
    expect(extractExitMarker(b, M)).toBe(null);
    const hit = extractExitMarker(a + b, M); // what the carry+chunk view sees
    expect(hit).not.toBe(null);
    expect(hit!.exitCode).toBe(3);
    expect(hit!.before).toBe("output" + "\n");
  });
  it("regex metacharacters in the marker are escaped, not interpreted", () => {
    expect(extractExitMarker("aXbY5", "a.b:")).toBe(null);
    expect(extractExitMarker("a.b:5", "a.b:")).not.toBe(null);
  });
});
