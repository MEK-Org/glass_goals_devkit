import { AnyOp } from "@thkp-eng/goals-types";
import { byHlc, compareHlc, extractEntryTextField } from "./op-utils";

export interface LoadOpsResp {
  ops: AnyOp[];
  /**
   * An opaque string that can be used to represent what has been fetched so
   * far. This will be null if there have been no ops for this user.
   */
  cursor: string | null;
}

export interface PersistenceService {
  save(ops: Iterable<AnyOp>): Promise<void>;
  load(options: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp>;
  loadString(entryId: string): Promise<string | null>;
  // returns the total number of ops that the user has access to until cursor
  count(options: { cursor?: string | null }): Promise<number>;
  // returns a subscription to new ops
  subscribeJSON(
    cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void;
}

/**
 * Port of the Dart `MemoryPersistenceService`: an in-memory server for tests.
 * Saved ops are kept sorted by HLC; each save is published to subscribers on
 * a later macrotask, and `settled()` waits for every pending publish.
 */
export class MemoryPersistenceService implements PersistenceService {
  ops: AnyOp[] = [];
  strings = new Map<string, string>();
  maxHlc: string | null = null;
  private readonly listeners = new Set<
    (ops: AnyOp[], cursor: string) => void
  >();
  private publishes: Promise<void>[] = [];

  constructor(ops: Iterable<AnyOp> = []) {
    this.ops = [...ops];
  }

  async settled(): Promise<void> {
    const pending = this.publishes;
    this.publishes = [];
    await Promise.all(pending);
  }

  async load({
    cursor = null,
    limit,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    if (this.ops.length === 0) {
      return { ops: [], cursor: null };
    }
    const startIndex = this.ops.findIndex(
      (op) => cursor == null || compareHlc(op.hlcTimestamp, cursor) > 0,
    );
    let result = startIndex === -1 ? [] : this.ops.slice(startIndex);
    if (limit != null) {
      result = result.slice(0, limit);
    }
    return {
      ops: result,
      cursor: result.length > 0 ? result[result.length - 1].hlcTimestamp : cursor,
    };
  }

  async save(ops: Iterable<AnyOp>): Promise<void> {
    const saved = [...ops];
    // Like the Dart double, the stored ops are rebuilt from this batch alone:
    // a later save replaces what an earlier one stored. Clients must not
    // depend on the server replaying history they already pulled.
    const opMap = new Map<string, AnyOp>();
    for (const op of saved) {
      opMap.set(op.id, op);
      const text = extractEntryTextField(op);
      if (text) {
        this.strings.set(text.entryId, text.text);
      }
      if (this.maxHlc == null || compareHlc(op.hlcTimestamp, this.maxHlc) > 0) {
        this.maxHlc = op.hlcTimestamp;
      }
    }
    this.ops = [...opMap.values()].sort(byHlc);
    const cursor = `${this.maxHlc}`;
    this.publishes.push(
      new Promise((resolve) =>
        setTimeout(() => {
          for (const listener of this.listeners) listener(saved, cursor);
          resolve();
        }, 0),
      ),
    );
  }

  async count({ cursor }: { cursor?: string | null }): Promise<number> {
    return cursor != null ? Number.parseInt(cursor, 10) : this.ops.length;
  }

  async loadString(entryId: string): Promise<string | null> {
    return this.strings.get(entryId) ?? null;
  }

  /** Like the Dart `stream`, the cursor is ignored and nothing is replayed. */
  subscribeJSON(
    _cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void {
    this.listeners.add(callback);
    return () => {
      this.listeners.delete(callback);
    };
  }
}
