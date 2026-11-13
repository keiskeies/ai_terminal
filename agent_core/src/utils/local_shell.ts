// parseLocalShell - pure port of Dart local_shell.dart parseLocalShell (:34-52).
//
// The Dart local_exec_tool validates its "shell" argument through this parser:
// empty/"auto" means "use the platform default", and an unrecognized value is
// rejected BEFORE anything is spawned (Dart local_exec_tool.dart:164-178). The
// Node LocalExecTool had been casting an arbitrary string to ShellType instead,
// so e.g. shell: "zsh" would have silently produced bash arguments. This
// restores the gate; the platform default and compatibility check stay inline
// in builtin.ts (Node desktop-only: win32 -> powershell, else bash, mirroring
// Dart resolveDefaultLocalShell which returns bash when /bin/bash exists).
//
// parseLocalShell returns null for "use the platform default" and throws for
// an unknown value - the caller turns the throw into a ToolResult.failure with
// the Dart message wording.
import type {ShellType} from "./shell_detect.js";

export type ParsedLocalShell = {kind: ShellType} | null;

export function parseLocalShell(raw: string | null | undefined): ParsedLocalShell {
  const value = (raw ?? "").trim().toLowerCase();
  if (value === "" || value === "auto") return null;
  switch (value) {
    case "powershell":
    case "ps":
    case "pwsh":
      return {kind: "powershell"};
    case "cmd":
    case "cmd.exe":
      return {kind: "cmd"};
    case "bash":
      return {kind: "bash"};
    case "sh":
      return {kind: "sh"};
    default:
      throw new Error("unknown shell: " + value + " (options: powershell / cmd / bash / sh)");
  }
}

/** Dart resolveDefaultLocalShell (:59-67) for a Node desktop host. */
export function resolveDefaultLocalShell(): ShellType {
  return process.platform === "win32" ? "powershell" : "bash";
}
