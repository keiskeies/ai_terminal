// interrupted_turn_detector.ts - detects "new-format but incomplete" turns
//
// 1:1 port of Dart utils/interrupted_turn_detector.dart (34 lines).
//
// A "new format" turn has at least one event with hostId, toolName, planSteps,
// durationMs, outputTotalChars, outputTruncated, outputTail, hostResults, or
// failureKind. If such a turn has command/plan/result events but no finish/report,
// it was interrupted (process killed, user cancelled, etc.).
//
// Legacy turns (no new-format metadata) are never marked as interrupted.

import type {AgentEvent} from "../rpc/schema.js";

/**
 * True when the event list looks like a new-format turn that was interrupted
 * (has command/result/plan but no finish/report, and at least one event carries
 * new-format metadata).
 */
export function isInterruptedTurn(events: readonly AgentEvent[]): boolean {
  if (events.length === 0) return false;

  // If any event is a finish or report, the turn completed normally.
  if (events.some((e) => e.type === "finish" || e.type === "report")) return false;

  // New-format metadata check: at least one event must carry a field that
  // only exists in the new format. Legacy events have none of these.
  const hasNewMetadata = events.some((e) =>
    e.hostId !== undefined ||
    e.toolName !== undefined ||
    e.planSteps !== undefined ||
    e.durationMs !== undefined ||
    e.outputTotalChars !== undefined ||
    e.outputTruncated !== undefined ||
    e.outputTail !== undefined ||
    e.hostResults !== undefined ||
    e.failureKind !== undefined
  );
  if (!hasNewMetadata) return false;

  // Must have at least one command, plan, or result event.
  return events.some((e) => e.type === "command" || e.type === "plan" || e.type === "result");
}

/**
 * Returns the host id from the last event in the list that carries one,
 * scanning from the end. Used for host validation when resuming a task.
 */
export function lastEventHostId(events: readonly AgentEvent[]): string | null {
  for (let i = events.length - 1; i >= 0; i--) {
    const host = events[i].hostId;
    if (host !== undefined && host !== null && host.trim().length > 0) return host.trim();
  }
  return null;
}