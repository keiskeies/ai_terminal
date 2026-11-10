// stable_hash.ts - Byte-identical port of Dart ReactStreamParser._stableId
//
// Dart original (react_stream_parser.dart):
//   int hash = 0xcbf29ce484222325;
//   for (final b in bytes) {
//     hash ^= b;
//     hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
//   }
//   return 'evt_' + hash.toRadixString(16);
//
// CRITICAL: this is NOT standard FNV-1a. The "& 0x7FFFFFFFFFFFFFFF" clears the
// most-significant bit every iteration, so the running hash stays < 2^63.
// We must replicate the 64-bit semantics exactly using BigInt:
//   - multiply by the FNV prime, keep low 64 bits (mod 2^64)
//   - AND with 0x7FFFFFFFFFFFFFFF (mask to 63 bits)
// This makes Node and Dart produce the SAME hex string for identical input.

const FNV_PRIME: bigint = 0x100000001b3n;
const MASK63: bigint = 0x7FFFFFFFFFFFFFFFn;
const MASK64: bigint = 0xFFFFFFFFFFFFFFFFn;
const INITIAL: bigint = 0xcbf29ce484222325n;

export function fnv1a64DartCompat(input: string): bigint {
  const bytes = new TextEncoder().encode(input);
  let hash: bigint = INITIAL;
  for (const b of bytes) {
    hash ^= BigInt(b);
    hash = (hash * FNV_PRIME) & MASK64;
    hash = hash & MASK63;
  }
  return hash;
}

export function stableId(typeName: string, content: string): string {
  const h = fnv1a64DartCompat(typeName + ":" + content);
  return "evt_" + h.toString(16);
}

export function stableHashOf(input: string): string {
  return "evt_" + fnv1a64DartCompat(input).toString(16);
}

// ─────────────────────────────────────────────────────────────────────────────
// Dart AgentEvent._genId() (models/agent_event.dart:218-220):
//   static String _genId() =>
//       'evt_${DateTime.now().millisecondsSinceEpoch}_${_counter++}';
//   static int _counter = 0;
//
// R4: this is the *other* half of the id space, and confusing the two is a real
// bug. A content hash ("evt_" + fnv1a64) is a STABLE id: it must be reproducible
// because dedup keys on it, so it belongs to parser-produced events (thought /
// text / command / ask / plan) whose identity IS their content. Events that
// report an OCCURRENCE (result / finish / info) are distinct facts even when
// their content repeats - re-running `make build` twice produces two results the
// UI must render as two cards. Minting those from a content hash makes the second
// one collide with the first (identical id), which downstream dedup / card keys
// silently collapse into one. Dart therefore uses this sequence id for them.
//
// Byte-faithful to Dart: decimal epoch millis, then a process-wide counter that
// starts at 0.
// ─────────────────────────────────────────────────────────────────────────────
let genIdCounter = 0;

/** Occurrence-id for an engine-emitted event (Dart AgentEvent._genId parity). */
export function genEventId(): string {
  return "evt_" + Date.now().toString() + "_" + (genIdCounter++).toString();
}
