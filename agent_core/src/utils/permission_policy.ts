// permission_policy.ts - port of ai_terminal/lib/core/permission_policy.dart
//
// The one sanctioned implementation of "given a safety level and the current
// permission mode, what does the engine do with this command". Dart keeps it in a
// single function on purpose, with this comment on decideCommand:
//
//   This is the one implementation shared by the engine gate and the UI event
//   snapshot, so the two cannot drift into two copies of the matrix.
//
// Keeping it in one place matters on the Node side too: react/engine.ts will call
// decideCommand() to gate execution, and the same decision string is written to
// AgentEvent.permissionDecision for the Dart UI to render (agent_command_block.dart
// branches on the strings, not on an enum). If the two sides computed the matrix
// separately, the UI could show "waiting for confirmation" on a command the engine
// had already run.
//
// NOT WIRED YET, and deliberately so: computing a SafetyLevel requires the
// SafetyGuard classifier (now ported to utils/safety_guard.ts - design doc sec. 9
// item 7, and still uncalled), and acting on "confirm" requires the confirm
// round-trip (rpc:confirm is still a
// Phase 2 placeholder - sec. 9 item 6). Wiring the gate before either exists would
// mean either blocking commands with no way to unblock them or ignoring the decision
// outright. This module is landed first, pure and exhaustively pinned against Dart,
// so the wiring commit can be a one-line call site with no policy inside it.

import type {PermissionMode} from "../rpc/schema.js";

// SafetyLevel is owned by safety_guard.ts, because that is where Dart declares the
// enum and the values it persists into AgentEvent.riskLevel. Re-exported so the gate
// matrix still reads as the standalone module it is and existing imports keep
// resolving - two declarations of one wire contract is how the two sides drift.
import {SAFETY_LEVELS, type SafetyLevel} from "./safety_guard.js";

export {SAFETY_LEVELS};
export type {SafetyLevel};


// Dart: enum CommandGateDecision { execute, confirm, reject }
export const GATE_DECISIONS = ["execute", "confirm", "reject"] as const;
export type CommandGateDecision = (typeof GATE_DECISIONS)[number];

// Dart defines these as top-level const strings rather than reusing
// CommandGateDecision.name, with the reason spelled out in permission_policy.dart:
// events are persisted and replayed from history, so the wire strings must not
// follow a rename of the enum. Pinned against both spellings in the test.
export const PERMISSION_DECISION_EXECUTE: CommandGateDecision = "execute";
export const PERMISSION_DECISION_CONFIRM: CommandGateDecision = "confirm";
export const PERMISSION_DECISION_REJECT: CommandGateDecision = "reject";

/**
 * Decide how to handle a command under the current permission mode.
 *
 * Branch ORDER is load-bearing, not stylistic. Reading top to bottom:
 *   1. readOnly rejects everything that is not safe - including blocked, so a
 *      read-only session never even reaches the "ask the user" branch.
 *   2. blocked needs confirmation in every mode except fullAuto.
 *   3. warn is executed everywhere except ask, where it needs confirmation.
 *   4. everything else executes.
 *
 * The trap is branch 1 vs branch 2: for (blocked, readOnly) the first branch wins,
 * so the answer is reject, not confirm. Hoisting the blocked check above readOnly -
 * which looks harmless, since both branches mention blocked - turns a hard refusal
 * in a read-only session into a confirmation prompt the user is invited to approve.
 * Branches 2 and 3 cover disjoint safety levels, so their relative order is the one
 * ordering change that is genuinely behaviour-preserving.
 */
export function decideCommand(level: SafetyLevel, mode: PermissionMode): CommandGateDecision {
  if (mode === "readOnly") {
    return level === "safe" ? PERMISSION_DECISION_EXECUTE : PERMISSION_DECISION_REJECT;
  }
  if (level === "blocked") {
    return mode === "fullAuto" ? PERMISSION_DECISION_EXECUTE : PERMISSION_DECISION_CONFIRM;
  }
  if (level === "warn") {
    return mode === "ask" ? PERMISSION_DECISION_CONFIRM : PERMISSION_DECISION_EXECUTE;
  }
  return PERMISSION_DECISION_EXECUTE;
}

/**
 * Whether a destructive tool call (local_file_delete and friends) needs user
 * confirmation. Dart: `bool destructiveToolNeedsConfirm(mode) =>
 * mode != AgentPermissionMode.fullAuto;`
 *
 * Read-only mode is refused earlier, by the tool's own read-only gate, so this only
 * separates "full auto, just do it" from "ask first" for every other mode.
 */
export function destructiveToolNeedsConfirm(mode: PermissionMode): boolean {
  return mode !== "fullAuto";
}

