// generation.ts - Task generation check to prevent stale-task state writes (R1.1)
//
// After every await that may cross a task boundary, call ensureCurrent() to verify
// the task hasn't been superseded or cancelled.
//
// In Dart this was: myGeneration === _currentTaskGeneration.
// In Node we use a monotonically-increasing token per task.

export interface GenerationCheck {
  /** True if the task is still the current one and not cancelled. */
  isCurrent(): boolean;
  /** Throw if stale. */
  ensureCurrent(): void;
}

export class TaskGeneration implements GenerationCheck {
  /** Bump the current generation (used by cancel()). */
  private _bumpCounter = 0;
  /** Increment the current-generation counter. */
  bump(): void { this._bumpCounter++; }
  constructor(private readonly myGen: number, private readonly currentGen: () => number, private readonly cancelled: () => boolean) {}

  isCurrent(): boolean {
    return !this.cancelled() && this.myGen === this.currentGen();
  }

  ensureCurrent(): void {
    if (!this.isCurrent()) {
      throw new StaleTaskError(this.myGen, this.currentGen());
    }
  }
}

export class StaleTaskError extends Error {
  constructor(readonly myGen: number, readonly currentGen: number) {
    super("Task generation stale: my=" + myGen + " current=" + currentGen + " — dropping state write");
    this.name = "StaleTaskError";
  }
}

/**
 * Helper: wrap a promise that may cross a task boundary.
 * After the await, check the generation before touching shared state.
 *
 * Usage:
 *   await maybeCrossBoundary(fn, taskGen);
 *   taskGen.ensureCurrent();  // <- mandatory after every cross-boundary await
 */
export function crossBoundary<T>(fn: () => Promise<T>, gen: GenerationCheck): Promise<T> {
  // The caller MUST call gen.ensureCurrent() after this resolves.
  // We can't enforce it inside the function; this is a review-checklist item.
  return fn();
}
