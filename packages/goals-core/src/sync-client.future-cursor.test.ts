import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { MemoryLocalStore } from "./local-store";
import { compareHlc, extractEntryTextField } from "./op-utils";
import { LoadOpsResp, PersistenceService } from "./persistence";
import { SyncClient } from "./sync-client";

class FutureAwarePersistenceService implements PersistenceService {
  readonly ops: AnyOp[];
  readonly strings = new Map<string, string>();
  private readonly listeners = new Set<
    (ops: AnyOp[], cursor: string) => void
  >();

  constructor(
    initialOps: AnyOp[] = [],
    public nowFn: () => number = () => Date.now(),
  ) {
    this.ops = [...initialOps].sort((a, b) =>
      compareHlc(a.hlcTimestamp, b.hlcTimestamp),
    );
  }

  private startAfterFor(cursor: string): string {
    const hlc = HLC.unpack(cursor);
    const ninetySecondsAgo = this.nowFn() - 90 * 1000;
    return hlc.timestamp < ninetySecondsAgo
      ? cursor
      : String(ninetySecondsAgo).padStart(15, "0");
  }

  async load({
    cursor = null,
    limit,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    let result = this.ops;
    if (cursor != null) {
      const startAfter = this.startAfterFor(cursor);
      result = result.filter((op) => compareHlc(op.hlcTimestamp, startAfter) > 0);
    }
    if (limit != null) {
      result = result.slice(0, limit);
    }
    let latestCursor = cursor;
    for (const op of result) {
      if (latestCursor == null || compareHlc(op.hlcTimestamp, latestCursor) > 0) {
        latestCursor = op.hlcTimestamp;
      }
    }
    return { ops: result, cursor: latestCursor };
  }

  async save(ops: Iterable<AnyOp>): Promise<void> {
    const batch = [...ops];
    for (const op of batch) {
      const text = extractEntryTextField(op);
      if (text) this.strings.set(text.entryId, text.text);
      if (!this.ops.some((existing) => existing.id === op.id)) {
        this.ops.push(op);
      }
    }
    this.ops.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
    if (batch.length > 0) {
      const maxHlc = batch
        .map((o) => o.hlcTimestamp)
        .sort(compareHlc)
        .at(-1)!;
      setTimeout(() => {
        for (const listener of this.listeners) listener(batch, maxHlc);
      }, 0);
    }
  }

  deliverWithoutLoad(ops: AnyOp[]): void {
    for (const op of ops) {
      if (!this.ops.some((existing) => existing.id === op.id)) {
        this.ops.push(op);
      }
    }
    this.ops.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
    if (ops.length > 0) {
      const maxHlc = ops
        .map((o) => o.hlcTimestamp)
        .sort(compareHlc)
        .at(-1)!;
      for (const listener of this.listeners) listener(ops, maxHlc);
    }
  }

  async count(): Promise<number> {
    return this.ops.length;
  }

  async loadString(entryId: string): Promise<string | null> {
    return this.strings.get(entryId) ?? null;
  }

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

class PullOnlyPersistenceService implements PersistenceService {
  private readonly ops: AnyOp[] = [];

  addRemoteOpSilently(op: AnyOp): void {
    this.ops.push(op);
    this.ops.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
  }

  async load({
    cursor = null,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    let latestCursor = cursor;
    for (const op of this.ops) {
      if (latestCursor == null || compareHlc(op.hlcTimestamp, latestCursor) > 0) {
        latestCursor = op.hlcTimestamp;
      }
    }
    return { ops: [...this.ops], cursor: latestCursor };
  }

  async save(): Promise<void> {}

  async loadString(): Promise<string | null> {
    return null;
  }

  async count(): Promise<number> {
    return this.ops.length;
  }

  subscribeJSON(): () => void {
    return () => {};
  }
}

const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("Future-cursor HLC seeding & monotonic cursor (#375)", () => {
  it("seeds writer HLC from future localStore.cursor on quiet startup so modifyGoal mints HLC > stored cursor", async () => {
    const now = Date.now();
    const futureMs = now + 24 * 60 * 60 * 1000;
    const futureCursor = new HLC(futureMs, 235, " SVB5").pack();

    const futureRootOp: DeltaOp = {
      id: "future-root-op",
      hlcTimestamp: futureCursor,
      version: 6,
      type: "delta",
      delta: { id: "future-root", text: "Future Root" },
    };

    const store = new MemoryLocalStore();
    await store.storeSyncedOps([futureRootOp]);
    store.setIndexGoalIds("rootGoals", new Set(["future-root"]));
    store.cursor = futureCursor;

    const persistence = new FutureAwarePersistenceService(
      [futureRootOp],
      () => now,
    );
    const client = new SyncClient(persistence, store);
    await client.init();

    await client.modifyGoal({ id: "new-goal", text: "Created Now" });
    await pause(20);

    const pushedOp = persistence.ops.find((op) => op.id !== "future-root-op")!;
    expect(pushedOp).toBeDefined();
    expect(compareHlc(pushedOp.hlcTimestamp, futureCursor)).toBeGreaterThan(0);
    expect(compareHlc(store.cursor!, futureCursor)).toBeGreaterThan(0);

    // Reloading client >90s later with futureCursor still sees the new goal.
    const reloadStore = new MemoryLocalStore();
    await reloadStore.storeSyncedOps([futureRootOp]);
    reloadStore.setIndexGoalIds("rootGoals", new Set(["future-root"]));
    reloadStore.cursor = futureCursor;
    persistence.nowFn = () => now + 10 * 60 * 1000;

    const reloadedClient = new SyncClient(persistence, reloadStore);
    await reloadedClient.init();
    expect(reloadedClient.stateSubject.value.get("new-goal")?.text).toBe(
      "Created Now",
    );

    reloadedClient.dispose();
    client.dispose();
  });

  it("seeds writer HLC from future localStore.cursor even when future op is on an unloaded child goal", async () => {
    const now = Date.now();
    const futureMs = now + 24 * 60 * 60 * 1000;
    const futureCursor = new HLC(futureMs, 235, " SVB5").pack();
    const rootOp: DeltaOp = {
      id: "root-op",
      hlcTimestamp: new HLC(now - 10 * 60 * 1000, 0, "seed").pack(),
      version: 6,
      type: "delta",
      delta: { id: "root", text: "Root" },
    };
    const futureChildOp: DeltaOp = {
      id: "future-child-op",
      hlcTimestamp: futureCursor,
      version: 6,
      type: "delta",
      delta: {
        id: "child",
        text: "Future Child",
        logEntry: {
          type: "addParent",
          id: "e-child",
          creationTime: now,
          parentId: "root",
        },
      },
    };

    const store = new MemoryLocalStore();
    await store.storeSyncedOps([rootOp, futureChildOp]);
    store.setIndexGoalIds("rootGoals", new Set(["root"]));
    store.cursor = futureCursor;

    const persistence = new FutureAwarePersistenceService(
      [rootOp, futureChildOp],
      () => now,
    );
    // Child is not a root goal, so init() only loads "root" and never sees
    // futureChildOp; writer HLC must be seeded from store.cursor.
    const client = new SyncClient(persistence, store);
    await client.init();

    await client.modifyGoal({ id: "writer-goal", text: "Writer" });
    await pause(20);

    const mintedOp = persistence.ops.find(
      (op) => op.id !== "root-op" && op.id !== "future-child-op",
    )!;
    expect(mintedOp).toBeDefined();
    expect(compareHlc(mintedOp.hlcTimestamp, futureCursor)).toBeGreaterThan(0);

    client.dispose();
  });

  it("CachingLocalStore.storeSyncedOps keeps cursor monotonic behind future cursor", async () => {
    const now = Date.now();
    const futureCursor = new HLC(now + 24 * 60 * 60 * 1000, 235, " SVB5").pack();
    const normalHlc = new HLC(now, 0, "wall").pack();

    const store = new MemoryLocalStore();
    await store.storeSyncedOps([
      {
        id: "future-op",
        hlcTimestamp: futureCursor,
        version: 6,
        type: "delta",
        delta: { id: "future-goal", text: "Future" },
      },
    ]);
    expect(store.cursor).toBe(futureCursor);

    await store.storeSyncedOps([
      {
        id: "normal-op",
        hlcTimestamp: normalHlc,
        version: 6,
        type: "delta",
        delta: { id: "normal-goal", text: "Normal" },
      },
    ]);

    expect(store.cursor).toBe(futureCursor);
    const loaded = await store.loadOpsForGoal("normal-goal");
    expect(loaded.map((o) => o.id)).toEqual(["normal-op"]);
  });

  it("normal wall-clock op received behind future cursor keeps cursor monotonic and stays visible in-session and across reload", async () => {
    const now = Date.now();
    const futureCursor = new HLC(now + 24 * 60 * 60 * 1000, 235, " SVB5").pack();
    const futureRootOp: DeltaOp = {
      id: "future-root-op",
      hlcTimestamp: futureCursor,
      version: 6,
      type: "delta",
      delta: { id: "future-root", text: "Future Root" },
    };

    const store = new MemoryLocalStore();
    await store.storeSyncedOps([futureRootOp]);
    store.setIndexGoalIds("rootGoals", new Set(["future-root"]));
    store.cursor = futureCursor;

    const persistence = new FutureAwarePersistenceService(
      [futureRootOp],
      () => now,
    );
    const client = new SyncClient(persistence, store);
    await client.init();

    const normalOp: DeltaOp = {
      id: "normal-wall-op",
      hlcTimestamp: new HLC(now, 1, "unseed").pack(),
      version: 6,
      type: "delta",
      delta: { id: "normal-root", text: "Normal Wall-Clock Goal" },
    };
    persistence.deliverWithoutLoad([normalOp]);
    await pause(20);

    expect(client.cursor).toBe(futureCursor);
    expect(client.stateSubject.value.get("normal-root")?.text).toBe(
      "Normal Wall-Clock Goal",
    );
    client.dispose();

    const quietPersistence = new FutureAwarePersistenceService([], () => now);
    const reloaded = new SyncClient(quietPersistence, store);
    await reloaded.init();

    expect(reloaded.cursor).toBe(futureCursor);
    expect(reloaded.stateSubject.value.get("normal-root")?.text).toBe(
      "Normal Wall-Clock Goal",
    );
    expect(reloaded.getRootGoalIds().has("normal-root")).toBe(true);
    reloaded.dispose();
  });

  it("post-startup pull delivering op <= baseStateCursor updates stateSubject for already-loaded goals and survives reload", async () => {
    const now = Date.now();
    const futureCursor = new HLC(now + 24 * 60 * 60 * 1000, 235, " SVB5").pack();
    const futureRootOp: DeltaOp = {
      id: "future-root-op",
      hlcTimestamp: futureCursor,
      version: 6,
      type: "delta",
      delta: { id: "future-root", text: "Future Root" },
    };

    const store = new MemoryLocalStore();
    await store.storeSyncedOps([futureRootOp]);
    store.setIndexGoalIds("rootGoals", new Set(["future-root"]));
    store.cursor = futureCursor;

    const persistence = new PullOnlyPersistenceService();
    const client = new SyncClient(persistence, store);
    await client.init();
    expect(client.stateSubject.value.get("future-root")?.log).toEqual([]);

    persistence.addRemoteOpSilently({
      id: "late-note-op",
      hlcTimestamp: new HLC(now, 1, "peer").pack(),
      version: 6,
      type: "delta",
      delta: {
        id: "future-root",
        logEntry: {
          id: "note-1",
          type: "note",
          creationTime: now,
          text: "Wall-clock note",
        },
      },
    });
    await client.sync();

    expect(client.cursor).toBe(futureCursor);
    expect(
      client.stateSubject.value
        .get("future-root")
        ?.log.some((e: any) => e.type === "note" && e.text === "Wall-clock note"),
    ).toBe(true);
    client.dispose();

    const reloaded = new SyncClient(new PullOnlyPersistenceService(), store);
    await reloaded.init();
    expect(reloaded.cursor).toBe(futureCursor);
    expect(
      reloaded.stateSubject.value
        .get("future-root")
        ?.log.some((e: any) => e.type === "note" && e.text === "Wall-clock note"),
    ).toBe(true);
    reloaded.dispose();
  });
});
