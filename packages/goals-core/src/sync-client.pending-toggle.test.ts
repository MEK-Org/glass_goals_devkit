import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { CachingLocalStore } from "./local-store";
import { LoadOpsResp, PersistenceService } from "./persistence";
import { byHlc, compareHlc } from "./op-utils";
import { MemorySyncRepository } from "./sync-repository";
import { SyncClient } from "./sync-client";

/**
 * These tests use the real SyncClient and CachingLocalStore. The service
 * retains every accepted op, while the repository can stop one local write
 * after the echo handler has observed it. That separates an acknowledged
 * operation from a durably stored one without depending on a timer.
 */
class ControlledPersistence implements PersistenceService {
  private readonly historyById = new Map<string, AnyOp>();
  private readonly listeners = new Set<
    (ops: AnyOp[], cursor: string) => void
  >();
  private readonly pendingEchoes: AnyOp[][] = [];

  constructor(seed: Iterable<AnyOp>) {
    this.remember(seed);
  }

  get history(): AnyOp[] {
    return [...this.historyById.values()].sort(byHlc);
  }

  get historyIds(): string[] {
    return this.history.map((op) => op.id);
  }

  async save(ops: Iterable<AnyOp>): Promise<void> {
    const batch = [...ops];
    this.remember(batch);
    this.pendingEchoes.push(batch);
  }

  async load({
    cursor = null,
    limit,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    let ops = this.history.filter(
      (op) => cursor == null || compareHlc(op.hlcTimestamp, cursor) > 0,
    );
    if (limit != null) ops = ops.slice(0, limit);
    return {
      ops,
      cursor: ops.length === 0 ? cursor : ops[ops.length - 1].hlcTimestamp,
    };
  }

  async loadString(_entryId: string): Promise<string | null> {
    return null;
  }

  async count({ cursor }: { cursor?: string | null }): Promise<number> {
    return this.history.filter(
      (op) => cursor == null || compareHlc(op.hlcTimestamp, cursor) <= 0,
    ).length;
  }

  subscribeJSON(
    _cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }

  /** Delivers exactly one accepted batch, after the test chooses the point. */
  deliverNextEcho(): void {
    const batch = this.pendingEchoes.shift();
    if (batch == null || batch.length === 0) {
      throw new Error("No accepted batch is waiting for an echo");
    }
    const cursor = [...batch].sort(byHlc).at(-1)!.hlcTimestamp;
    for (const listener of this.listeners) listener(batch, cursor);
  }

  private remember(ops: Iterable<AnyOp>): void {
    for (const op of ops) this.historyById.set(op.id, op);
  }
}

class GatedRepository extends MemorySyncRepository {
  readonly startedBatches: string[][] = [];
  readonly committedBatches: string[][] = [];
  private readonly startWaiters = new Map<number, () => void>();
  private nextGate: Promise<void> | null = null;
  private releaseNextGate: (() => void) | null = null;

  waitForStarts(count: number): Promise<void> {
    if (this.startedBatches.length >= count) return Promise.resolve();
    return new Promise((resolve) => this.startWaiters.set(count, resolve));
  }

  blockNextStore(): void {
    if (this.nextGate != null) throw new Error("A store is already blocked");
    this.nextGate = new Promise<void>((resolve) => {
      this.releaseNextGate = resolve;
    });
  }

  releaseBlockedStore(): void {
    const release = this.releaseNextGate;
    if (release == null) throw new Error("No store is blocked");
    this.releaseNextGate = null;
    release();
  }

  override async storeSyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    const batch = [...ops];
    this.startedBatches.push(batch.map((op) => op.id));
    for (const [count, resolve] of this.startWaiters) {
      if (this.startedBatches.length >= count) {
        this.startWaiters.delete(count);
        resolve();
      }
    }
    const gate = this.nextGate;
    this.nextGate = null;
    if (gate != null) await gate;
    await super.storeSyncedOps(batch);
    this.committedBatches.push(batch.map((op) => op.id));
  }
}

class TrackingStore extends CachingLocalStore {
  completedWrites = 0;
  private readonly completionWaiters = new Map<number, () => void>();

  constructor(repo: GatedRepository) {
    super(repo);
  }

  waitForCompletedWrites(count: number): Promise<void> {
    if (this.completedWrites >= count) return Promise.resolve();
    return new Promise((resolve) => this.completionWaiters.set(count, resolve));
  }

  override async storeSyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    await super.storeSyncedOps(ops);
    this.completedWrites++;
    for (const [count, resolve] of this.completionWaiters) {
      if (this.completedWrites >= count) {
        this.completionWaiters.delete(count);
        resolve();
      }
    }
  }
}

const textOf = (client: SyncClient) => client.getGoals().get("g")?.text;
const storedIds = async (repo: GatedRepository) =>
  (await repo.loadAllSyncedOps()).sort(byHlc).map((op) => op.id);

async function deliverAndSettle(
  persistence: ControlledPersistence,
  repository: GatedRepository,
  store: TrackingStore,
): Promise<void> {
  const starts = repository.startedBatches.length + 1;
  const completes = store.completedWrites + 1;
  persistence.deliverNextEcho();
  await repository.waitForStarts(starts);
  await store.waitForCompletedWrites(completes);
  await store.settled();
}

describe("SyncClient pending toggle persistence boundary (#42)", () => {
  it("keeps an echoed final Undo recoverable until its local write is durable", async () => {
    const original: DeltaOp = {
      id: "original",
      hlcTimestamp: new HLC(1_700_000_000_000, 0, "server").pack(),
      version: 6,
      type: "delta",
      delta: { id: "g", text: "Original" },
    };
    const persistence = new ControlledPersistence([original]);
    const repository = new GatedRepository();
    const store = new TrackingStore(repository);
    const initialStarts = repository.startedBatches.length + 1;
    const initialCompletes = store.completedWrites + 1;
    const client = new SyncClient(persistence, store);
    await client.init();
    await repository.waitForStarts(initialStarts);
    await store.waitForCompletedWrites(initialCompletes);
    await store.settled();
    expect(textOf(client)).toBe("Original");

    await client.modifyGoal({ id: "g", text: "Changed" });
    await deliverAndSettle(persistence, repository, store);
    expect(textOf(client)).toBe("Changed");

    // Undo and Redo operate against the echoed, locally durable change while
    // their echoes are held: this is the offline base-op path.
    await client.undo();
    expect(textOf(client)).toBe("Original");
    await client.redo();
    expect(textOf(client)).toBe("Changed");
    await deliverAndSettle(persistence, repository, store);
    await deliverAndSettle(persistence, repository, store);
    expect(textOf(client)).toBe("Changed");

    await client.undo();
    expect(textOf(client)).toBe("Original");
    repository.blockNextStore();
    const blockedStart = repository.startedBatches.length + 1;
    persistence.deliverNextEcho();
    await repository.waitForStarts(blockedStart);

    const historyIds = persistence.historyIds;
    const finalToggleId = historyIds.at(-1)!;
    expect({
      cursor: repository.cursor,
      persisted: await storedIds(repository),
      pending: repository.getUnsyncedOps().map((op) => op.id),
      acknowledged: [...repository.getAckedOpIds()],
      history: historyIds,
    }).toEqual({
      cursor: persistence.history.at(-1)!.hlcTimestamp,
      persisted: historyIds.slice(0, -1),
      pending: [finalToggleId],
      acknowledged: [finalToggleId],
      history: historyIds,
    });

    // This is the same repository after a stop, not a fresh replay double.
    // The final echoed op is accepted remotely but its local write is still
    // blocked, so restart must pull it again from the retained full history.
    client.dispose();
    const interrupted = new SyncClient(
      persistence,
      new TrackingStore(repository),
    );
    await interrupted.init();
    await interrupted.loadGoal("g");
    expect(textOf(interrupted)).toBe("Original");
    interrupted.dispose();

    // Once the original write completes, a later restart reaches the same
    // result without requiring recovery from an in-flight operation.
    repository.releaseBlockedStore();
    await store.waitForCompletedWrites(store.completedWrites + 1);
    await store.settled();
    const settled = new SyncClient(persistence, new TrackingStore(repository));
    await settled.init();
    await settled.loadGoal("g");
    expect(textOf(settled)).toBe("Original");
    settled.dispose();
  });
});
