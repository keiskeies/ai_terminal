// ExitMarkerScanner - 1:1 port of Dart ai_terminal/lib/utils/exit_marker_scanner.dart
// (introduced in commit dea9cc1, perf: chunk-boundary carry for exit-code
// marker detection).
//
// Dart usage: the PTY/executeAndWait data callback feeds every raw chunk
// into one scanner instance; add() returns true the first time the
// marker+digits pattern completes. The carry is kept to marker.length+16
// chars so a marker split across two chunks is still caught. Node's
// local_exec path already resolves the marker over the final tail buffer
// (shell_detect.extractExitMarker), so this class exists for the streaming
// paths that must complete on the FIRST chunk containing the marker
// instead of waiting for the whole output.
import {agentLogger} from "./agent_logger.js";

function escapeRegExp(s: string): string {
  // Dart RegExp.escape equivalent: backslash + every regex metacharacter.
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export class ExitMarkerScanner {
  readonly donePattern: RegExp;
  private readonly _carryChars: number;
  private _carry = "";

  constructor(marker: string) {
    this.donePattern = new RegExp(escapeRegExp(marker) + "\\d+");
    this._carryChars = marker.length + 16;
  }

  /** Feed one chunk; returns true when marker+digits just completed. */
  add(chunk: string): boolean {
    const combined = this._carry + chunk;
    const found = this.donePattern.test(combined);
    this.donePattern.lastIndex = 0; // .test is stateful with /g; keep it stateless
    this._carry = combined.length > this._carryChars ? combined.slice(combined.length - this._carryChars) : combined;
    if (found) agentLogger.debug("ExitMarkerScanner", "marker seen");
    return found;
  }
}
