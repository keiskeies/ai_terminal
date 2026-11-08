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
