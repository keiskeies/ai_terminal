// looksLikeLocalWindowsCommand - port of Dart local_command_detector.dart 9-36.
// Three RegExp groups: drive-letter path, PowerShell constructs, and
// command-starts-with checks. A command is local-Windows when ANY of the
// three positive signals fires.
//
// Deviation: Dart uses RegExp(r'''...''') raw strings; the JS port uses the
// RegExp constructor with double-quoted source strings.

const PS_CMDLETS =
  [
    'Select-Object',
    'ForEach-Object',
    'Where-Object',
    'Get-[A-Za-z]+',
    'Set-[A-Za-z]+',
    'New-Item',
    'Remove-Item',
    'Copy-Item',
    'Move-Item',
    'Test-Path',
    'Join-Path',
    'Start-Process',
    'Stop-Process',
    'Write-Host',
    'Out-File',
  ].join('|');

// Dart 14-15: drive path after start-of-string / whitespace / quote / = / (
const DRIVE_PATH_RE = new RegExp(String.raw`(^|[\s"'=(])[A-Za-z]:[\\/]`);
// Dart 17: command starts with a drive-letter path
const START_DRIVE_RE = new RegExp(String.raw`^[A-Za-z]:[\\/]`);
// Dart 19-24: PowerShell construct anywhere in the command
const PS_CONSTRUCT_RE = new RegExp("\\$\\w+\\s*=|\\$env:|\\b(" + PS_CMDLETS + ")\\b", "i");
// Dart 26-31: command STARTS with a PowerShell assignment/variable/cmdlet
const START_PS_RE = new RegExp("^(\\$\\w+\\s*=|\\$env:|\\b(" + PS_CMDLETS + ")\\b)", "i");

// Dart 33-35:
//   return (hasDrivePath && hasPowerShellConstruct) ||
//           startsWithDrivePath ||
//           startsWithPowerShell;
export function looksLikeLocalWindowsCommand(command: string): boolean {
  const text = command.trim();
  if (text.length === 0) return false;
  const hasDrivePath = DRIVE_PATH_RE.test(text);
  const startsWithDrivePath = START_DRIVE_RE.test(text);
  const hasPSConstruct = PS_CONSTRUCT_RE.test(text);
  const startsWithPS = START_PS_RE.test(text);
  return (hasDrivePath && hasPSConstruct) || startsWithDrivePath || startsWithPS;
}
