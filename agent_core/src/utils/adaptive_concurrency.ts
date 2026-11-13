// adaptive_concurrency.ts - adaptive upload concurrency controller
//
// 1:1 port of Dart utils/adaptive_concurrency.dart (61 lines).
//
// chooseInitialUploadConcurrency: picks initial concurrency based on
// file count and average file size. Small files → high concurrency
// (latency-bound); large files → low concurrency (SSH/SFTP window-bound).
//
// AdaptiveConcurrency: AIMD controller - halve on 3 consecutive failures,
// increment by 1 every 20 consecutive successes (only below initial).

/** Choose initial upload concurrency from file count and average size. */
export function chooseInitialUploadConcurrency(opts: {
  fileCount: number;
  averageBytes: number;
}): number {
  if (opts.fileCount <= 1) return 1;
  if (opts.averageBytes < 256 * 1024) return 16;
  if (opts.averageBytes < 2 * 1024 * 1024) return 8;
  if (opts.averageBytes < 8 * 1024 * 1024) return 4;
  return 2;
}

/**
 * AIMD adaptive concurrency controller.
 * Halves on 3 consecutive failures; increments by 1 every 20 successes
 * (only when below initial). Use adaptive: false for fixed concurrency.
 */
export class AdaptiveConcurrency {
  readonly initial: number;
  readonly adaptive: boolean;
  private _current: number;
  private _successStreak = 0;
  private _failureStreak = 0;
  private _degraded = false;

  constructor(opts: {initial: number; adaptive?: boolean}) {
    this.initial = Math.max(1, opts.initial);
    this.adaptive = opts.adaptive ?? true;
    this._current = Math.max(1, opts.initial);
  }

  get current(): number { return this._current; }
  get finalConcurrency(): number { return this._current; }
  get degraded(): boolean { return this._degraded; }

  onSuccess(): void {
    if (!this.adaptive) return;
    this._failureStreak = 0;
    this._successStreak++;
    if (this._successStreak >= 20 && this._current < this.initial) {
      this._current++;
      this._successStreak = 0;
    }
  }

  onFailure(): void {
    if (!this.adaptive) return;
    this._successStreak = 0;
    this._failureStreak++;
    if (this._failureStreak >= 3 && this._current > 1) {
      this._current = Math.max(1, Math.floor(this._current / 2));
      this._failureStreak = 0;
      this._degraded = true;
    }
  }
}