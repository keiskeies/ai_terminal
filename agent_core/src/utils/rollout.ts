// utils/rollout.ts - W8 grayscale rollout bucketing (Node-side, hermetic)
//
// Mirrors the production "10% -> observe 7 days -> 100%" rollout policy as a
// deterministic, unit-testable function. The Dart side can call this (or mirror
// the same hash) to decide whether a given user is in the Node-agent cohort.
//
// Determinism: fnv1a-64 over "salt|userId", then the low 14 bits -> [0,9999]
// (4 decimal digits of even coverage). pct is 0..100 (integer percent).
//
// Override precedence (highest first):
//   1. explicit allow-list  -> always in
//   2. explicit deny-list  -> always out
//   3. env FORCE flag (NODE_AGENT_ROLLOT_FORCE) = "on"/"off"
//   4. deterministic hash bucket

import {fnv1a64DartCompat} from "./stable_hash.js";

export interface RolloutOptions {
  /** Integer percent 0..100 of users routed to the Node agent. Default 0 (opt-in only). */
  pct?: number;
  /** Salt for the hash. Changing salt re-buckets; keep stable across rollout phases. */
  salt?: string;
  /** Explicit users always in the rollout, regardless of pct. */
  allow?: readonly string[];
  /** Explicit users always out of the rollout, regardless of pct. */
  deny?: readonly string[];
  /** Force flag: "on" -> everyone in; "off" -> everyone out; undefined -> use hash. */
  force?: "on" | "off" | undefined;
}

/** Returns 0..9999 (uniform 10k buckets). */
function bucket(userId: string, salt: string): number {
  const h = fnv1a64DartCompat(salt + "|" + userId); // returns bigint
  // Take low 24 bits -> 0..16777215, then mod 10000 for near-uniform 4-digit bucket.
  return Number(h & 0xffffffn) % 10000;
}

/**
 * Decide whether a user should run under the Node agent.
 * Deterministic + stable for a given (userId, salt, pct, allow, deny, force).
 */
export function shouldUseNodeAgent(userId: string, opts: RolloutOptions = {}): boolean {
  const { pct = 0, salt = "ai_terminal-node-v1", allow, deny, force } = opts;

  // 1. allow-list wins
  if (allow?.includes(userId)) return true;
  // 2. deny-list
  if (deny?.includes(userId)) return false;
  // 3. force flag
  if (force === "on") return true;
  if (force === "off") return false;

  // 4. deterministic hash bucket
  const p = Math.max(0, Math.min(100, Math.round(pct)));
  if (p <= 0) return false;
  if (p >= 100) return true;
  return bucket(userId, salt) < p * 100;
}

/** Approximate expected in-rollout fraction for a given pct (sanity check). */
export function rolloutFraction(pct: number): number {
  const p = Math.max(0, Math.min(100, Math.round(pct)));
  return p / 100;
}
