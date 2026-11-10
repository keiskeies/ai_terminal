// shell_detect.ts - R6: branch shell command wrappers by shell type
//
// Mirrors Dart's LocalShell / wrappedCommand logic:
//   bash/sh : separator ";"   exit: "$?"
//   PowerShell: separator ";"  exit: "$LASTEXITCODE"
//   cmd.exe : separator "&"    exit: "%errorlevel%"
//
// Detect at startup, branch per command.

export type ShellType = "bash" | "sh" | "zsh" | "powershell" | "cmd";

export interface ShellWrapper {
  /** Wrap a command to print a marker + exit code at the end. */
  wrapCommand(cmd: string, marker: string): string;
  /** Detect shell type from a path or name. */
}

export function detectShell(execPath: string): ShellType {
  const lower = execPath.toLowerCase();
  if (lower.includes("powershell") || lower.endsWith("pwsh")) return "powershell";
  if (lower.endsWith("cmd") || lower.endsWith("cmd.exe")) return "cmd";
  if (lower.endsWith("zsh")) return "zsh";
  return "bash"; // default for sh/bash/unknown
}

export function wrapCommand(cmd: string, shell: ShellType, marker: string): string {
  // R6.1 + R8.1 + R9: byte-faithful port of Dart wrapCommandWithExitMarker
  // (local_terminal_service.dart) / posixWrapWithExitMarker (command_executor.dart).
  // The wrapper must ECHO "<marker><exit-code>" into stdout:
  //  - a bare marker token is wrong: the shell tries to EXECUTE it, the
  //    command-not-found message lands on stderr and clobbers the pipeline
  //    exit code (bash 127, cmd 9009, PowerShell "not recognized" 1) - the
  //    real exit status is then lost forever (verified empirically on all
  //    three shells on this host);
  //  - completion detection matches the FULL pattern marker+digits (R8.1),
  //    so the literal command echo (where `$?` stays literal) never fires.
  // Caller convention (Dart): marker ends with ":" e.g. "EXITCODE_1:".
  switch (shell) {
    case "powershell": {
      // PowerShell branch mirrors Dart verbatim. $LASTEXITCODE must be reset
      // to $null first: it is session-scoped, a stale non-zero from a previous
      // native command would leak into this one. Cmdlets never set it, so $?
      // derives the code: $? -> 0, non-zero $LASTEXITCODE -> itself, else 1.
      return (
        "$LASTEXITCODE=$null; " +
        cmd +
        '; $__ec=if($?){0}elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}else{1}; echo "' +
        marker +
        '$__ec"'
      );
    }
    case "cmd":
      // cmd.exe: & separator + %errorlevel%. Byte-faithful to Dart (L206).
      // KNOWN CAVEAT kept for Dart parity (deviation would break the
      // Dart<->Node byte-comparison e2e layer): cmd expands %errorlevel% at
      // PARSE time of the whole line, so a non-zero code from a preceding
      // command in the same line can read as 0 (empirically confirmed on this
      // host). Fixing it requires /v:on + !errorlevel! on BOTH sides.
      return cmd + " & echo " + marker + "%errorlevel%";
    case "bash":
    case "sh":
    case "zsh":
    default:
      // POSIX (Dart posixWrapWithExitMarker): single-line commands append the
      // echo on the SAME line - a second line would linger in the tty input
      // queue and get eaten by anything reading /dev/tty (sudo password!).
      // Multi-line commands (heredocs) MUST put it on a new line: "EOF; echo"
      // is no longer recognized as the heredoc terminator and the write hangs.
      return cmd.indexOf("\n") >= 0
        ? cmd + "\necho \"" + marker + "$?\""
        : cmd + "; echo \"" + marker + "$?\"";
  }
}

/** R8.1: one hit of marker+digits in accumulated output. */
export interface ExitMarkerHit {
  /** Exit code captured from the marker digits. */
  exitCode: number;
  /** Output before the marker (the real stdout up to this point). */
  before: string;
  /** Output after the digits (streaming: subsequent chunks belong here). */
  after: string;
}

/**
 * R8.1 marker scanner (Dart ExitMarkerScanner.donePattern parity): match
 * ESCAPED-marker + digits, FIRST occurrence wins. A bare substring like the
 * command echo `echo "EXITCODE_1:$?"` never matches (no digit after the
 * colon) - this is the exact historical bug the rule was derived from.
 */
export function extractExitMarker(output: string, marker: string): ExitMarkerHit | null {
  const esc = marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = new RegExp(esc + "(\\d+)").exec(output);
  if (m === null) return null;
  return {
    exitCode: Number(m[1]),
    before: output.slice(0, m.index),
    after: output.slice(m.index + m[0].length),
  };
}

/** Locale-neutral OS name detection (R6.3): prefer PowerShell Get-CimInstance. */
export function detectOsInfoCommand(shell: ShellType): string {
  switch (shell) {
    case "powershell":
      return "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption";
    case "cmd":
      return "wmic os get caption /value";
    default:
      return "uname -s";
  }
}
