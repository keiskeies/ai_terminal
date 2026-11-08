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
  switch (shell) {
    case "powershell":
      // PowerShell: ; separator, $LASTEXITCODE
      return cmd + "; " + marker + " $LASTEXITCODE";
    case "cmd":
      // cmd.exe: & separator, %errorlevel%
      return cmd + " & " + marker + " %errorlevel%";
    case "bash":
    case "sh":
    case "zsh":
    default:
      return cmd + "; " + marker + " $?";
  }
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
