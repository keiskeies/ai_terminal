// permission_policy.ts - port of ai_terminal/lib/core/permission_policy.dart
//
// The one sanctioned implementation of "given a safety level and the current
// permission mode, what does the engine do with this command". Dart keeps it in a
// single function on purpose, with this comment on decideCommand:
//
//   This is the one implementation shared by the engine gate and the UI event
//   snapshot, so the two cannot drift into two copies of the matrix.
//
// Keeping it in one place matters on the Node side too: react/engine.ts asks this
// module what to do with a parser-supplied command, and stamps that same decision
// string onto AgentEvent.permissionDecision for the Dart UI to render
// (agent_command_block.dart branches on the strings, not on an enum). If the two
// sides computed the matrix separately, the UI could show "waiting for
// confirmation" on a command the engine had already run.
//
// IT IS CALLED NOW, from three sites over one table. react/engine.ts
// enrichCommandEvent() fills the snapshot on the command event, and the gate in the
// same file classifies again before anything runs (Dart parities 2978 and 3289 -
// a snapshot read and a decision read of the same pure table may see the same mode
// a moment apart, which is legitimate). The tool layer asks the destructive-tool
// row of this same matrix for the tool path (sec. 9 item 7). The "confirm" half of
// the matrix is served by react/confirm_flow.ts, which the engine drives for a warn
// / blocked command and rpc:confirm answers. Landing the matrix first, pure and
// exhaustively pinned against Dart, is why those wiring commits are one call site
// each with no policy inside them, which is what this module exists for. One
// consequence worth stating: a reject produces NO result event - nothing ran.

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

