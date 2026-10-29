export type Listener<T> = (value: T) => void;

/**
 * A minimal stand-in for rxdart's `BehaviorSubject`, used by the SyncClient
 * port. It holds the latest value, replays it to a new listener, and delivers
 * each event to listeners on a microtask, like a Dart broadcast stream.
 */
export class BehaviorSubject<T> {
  private readonly listeners = new Set<Listener<T>>();
  private closed = false;

  constructor(private current: T) {}

  get value(): T {
    return this.current;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  add(value: T): void {
    if (this.closed) {
      throw new Error("Cannot add new events after calling close");
    }
    this.current = value;
    for (const listener of this.listeners) {
      this.deliver(listener, value);
    }
  }

  /**
   * Listens for values. The current value is replayed first unless
   * `replay` is false. Returns a function that cancels the subscription.
   */
  subscribe(listener: Listener<T>, replay = true): () => void {
    this.listeners.add(listener);
    if (replay && !this.closed) {
      this.deliver(listener, this.current);
    }
    return () => {
      this.listeners.delete(listener);
    };
  }

  close(): void {
    this.closed = true;
    this.listeners.clear();
  }

  private deliver(listener: Listener<T>, value: T): void {
    queueMicrotask(() => {
      if (this.listeners.has(listener)) listener(value);
    });
  }
}
