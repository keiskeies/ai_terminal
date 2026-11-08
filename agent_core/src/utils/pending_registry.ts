// pending_registry.ts - R1.2: ensure all pending completers resolve on cancel/disconnect
//
// In Dart, StreamSubscription.cancel() does NOT trigger onDone; you had to manually
// complete() waiting Completers. In Node, AbortSignal doesn't fire stream.on("end");
// PendingRegistry provides the equivalent "resolve all waiters" primitive.

export class PendingRegistry {
  private waiters = new Set<() => void>();

  register(resolver: () => void): void {
    this.waiters.add(resolver);
  }

  /** Resolve all pending waiters and clear the set. Idempotent. */
  resolveAll(reason?: string): void {
    for (const w of this.waiters) {
      try {
        w();
      } catch {
        // A waiter that throws on resolve must not block others
      }
    }
    this.waiters.clear();
    void reason;
  }

  get size(): number {
    return this.waiters.size;
  }

  get isEmpty(): boolean {
    return this.waiters.size === 0;
  }
}

export class CompleterLike<T = void> {
  private resolveFn: ((v: T) => void) | null = null;
  private rejectFn: ((e: unknown) => void) | null = null;
  private done = false;
  readonly promise: Promise<T>;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveFn = resolve;
      this.rejectFn = reject;
    });
  }

  get isDone(): boolean { return this.done; }

  resolve(value: T): void {
    if (this.done) return;
    this.done = true;
    this.resolveFn?.(value);
  }

  reject(error: unknown): void {
    if (this.done) return;
    this.done = true;
    this.rejectFn?.(error);
  }
}
