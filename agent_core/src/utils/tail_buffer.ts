// tail_buffer.ts - Bounded tail-retaining buffer for streaming text
//
// Replaces Dart's TailTextBuffer: keeps the most recent \`maxChars\` characters,
// amortized O(1) per append. Used for _accumulatedMessage capping (AGENTS.md R8).
//
// Boundary: when length exactly equals cap, the buffer is full; a new write evicts
// the oldest (head) character so the TAIL is always retained.

export class TailTextBuffer {
  private buf: string;
  private readonly max: number;

  constructor(maxChars: number) {
    if (!Number.isFinite(maxChars) || maxChars < 1) {
      throw new RangeError("maxChars must be a positive finite number");
    }
    this.max = Math.floor(maxChars);
    this.buf = "";
  }

  /** Append text, evicting from the head to stay within the cap. */
  write(text: string): this {
    if (!text) return this;
    this.buf += text;
    if (this.buf.length > this.max) {
      // Keep only the last \`max\` characters
      this.buf = this.buf.slice(this.buf.length - this.max);
    }
    return this;
  }

  /** The current retained tail. */
  tail(): string {
    return this.buf;
  }

  /** Length of retained content. */
  length(): number {
    return this.buf.length;
  }

  /** Whether the buffer is at its cap. */
  get isFull(): boolean {
    return this.buf.length === this.max;
  }

  /** Reset to empty. */
  clear(): this {
    this.buf = "";
    return this;
  }

  /** Overwrite with a new value, truncating to the cap. */
  set(value: string): this {
    this.clear();
    return this.write(value);
  }
}
