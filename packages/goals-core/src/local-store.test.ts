import { afterEach, describe, expect, it, vi } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { CachingLocalStore } from "./local-store";
import { GoalIndexEntry, MemorySyncRepository } from "./sync-repository";

const hlc = (t: number) => `${String(t).padStart(15, "0")}:00000:srv`;

const status = (id: string, t: number, goalId: string): DeltaOp => ({
  id,
  hlcTimestamp: hlc(t),
  version: 6,
  type: "delta",
  delta: { id: goalId, logEntry: { type: "archiveNote", id: `e-${id}`, creationTime: t } },
});

/** Records every batched read the store makes. */
class RecordingRepository extends MemorySyncRepository {
  opReads: string[][] = [];
  indexReads: string[][] = [];
  stringReads: string[] = [];

  override async loadOps(opIds: Iterable<string>): Promise<Array<AnyOp | null>> {
    const ids = [...opIds];
    this.opReads.push(ids);
    return super.loadOps(ids);
  }

  override async loadGoalIndexEntries(
    goalIds: Iterable<string>,
  ): Promise<Map<string, GoalIndexEntry | null>> {
    const ids = [...goalIds];
    this.indexReads.push(ids);
    return super.loadGoalIndexEntries(ids);
  }

  override async loadString(key: string): Promise<string | null> {
    this.stringReads.push(key);
    return super.loadString(key);
  }
}

/** A store whose caches are cold over a repository holding [ops]. */
async function coldStore(ops: AnyOp[]) {
  const repo = new RecordingRepository();
  const writer = new CachingLocalStore(repo);
  await writer.storeSyncedOps(ops);
  const store = new CachingLocalStore(repo);
  repo.opReads = [];
  repo.indexReads = [];
  return { repo, store };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("CachingLocalStore reads", () => {
  it("batches op reads made close together and dedupes ids", async () => {
    const { repo, store } = await coldStore([
      status("a", 1, "g1"),
      status("b", 2, "g1"),
      status("c", 3, "g2"),
    ]);

    const results = await Promise.all([
      store.loadOpsById(["a", "b"]),
      store.loadOpsById(["b", "c"]),
      store.loadOpsById(["missing"]),
    ]);

    expect(results.map((ops) => ops.map((op) => op?.id ?? null))).toEqual([
      ["a", "b"],
      ["b", "c"],
      [null],
    ]);
    expect(repo.opReads).toEqual([["a", "b", "c", "missing"]]);

    // Cached ops are not read again.
    await store.loadOpsById(["a", "c"]);
    expect(repo.opReads).toHaveLength(1);
  });

  it("caps a batch's delay at 30 ms from its first request", async () => {
    vi.useFakeTimers();
    const { repo, store } = await coldStore([
      status("a", 1, "g1"),
      status("b", 2, "g1"),
      status("c", 3, "g1"),
      status("d", 4, "g1"),
      status("e", 5, "g1"),
    ]);

    // Each request lands 8 ms after the last, inside the 10 ms debounce.
    const loads: Promise<unknown>[] = [];
    for (const id of ["a", "b", "c", "d", "e"]) {
      loads.push(store.loadOpsById([id]));
      await vi.advanceTimersByTimeAsync(8);
    }
    await vi.runAllTimersAsync();
    await Promise.all(loads);

    expect(repo.opReads).toEqual([["a", "b", "c", "d"], ["e"]]);
  });

  it("shares one goal index read between goals requested together", async () => {
    const { repo, store } = await coldStore([
      status("a", 1, "g1"),
      status("b", 2, "g2"),
    ]);

    const [g1, g2, again] = await Promise.all([
      store.loadOpsForGoal("g1"),
      store.loadOpsForGoal("g2"),
      store.loadOpsForGoal("g1"),
    ]);

    expect(g1.map((op) => op.id)).toEqual(["a"]);
    expect(g2.map((op) => op.id)).toEqual(["b"]);
    expect(again.map((op) => op.id)).toEqual(["a"]);
    expect(repo.indexReads).toEqual([["g1", "g2"]]);
    expect(repo.opReads).toEqual([["a", "b"]]);
  });

  it("keeps an index entry written while a read of it was pending", async () => {
    const { repo, store } = await coldStore([status("a", 1, "g1")]);
    let releaseRead!: () => void;
    const readGate = new Promise<void>((r) => (releaseRead = r));
    const load = repo.loadGoalIndexEntries.bind(repo);
    repo.loadGoalIndexEntries = async (goalIds) => {
      const entries = await load(goalIds);
      await readGate;
      return entries;
    };

    const pending = store.loadOpsForGoal("g1");
    // Storing "b" waits on the same pending index read, then indexes it.
    const stored = store.storeSyncedOps([status("b", 2, "g1")]);
    releaseRead();
    await stored;

    // The pending load returns what it read; the cache keeps the newer entry.
    expect((await pending).map((op) => op.id)).toEqual(["a"]);
    expect((await store.loadOpsForGoal("g1")).map((op) => op.id).sort()).toEqual([
      "a",
      "b",
    ]);
  });
});

describe("CachingLocalStore string cache", () => {
  it("culls expired strings on a miss once past 1000 entries", async () => {
    vi.useFakeTimers();
    const repo = new RecordingRepository();
    const store = new CachingLocalStore(repo);
    for (let i = 0; i <= 1000; i++) {
      await store.setString(`k${i}`, `v${i}`);
    }

    // Past the 1000-entry threshold, unexpired entries are kept.
    expect(await store.loadString("k0")).toBe("v0");
    expect(repo.stringReads).toEqual([]);

    // Like the Dart, a hit on an expired entry still serves and renews it.
    vi.advanceTimersByTime(10 * 60 * 1000 + 1);
    expect(await store.loadString("k1")).toBe("v1");
    expect(repo.stringReads).toEqual([]);

    // A miss culls every expired entry; only the renewed one survives.
    expect(await store.loadString("absent")).toBeNull();
    expect(await store.loadString("k2")).toBe("v2");
    expect(await store.loadString("k1")).toBe("v1");
    expect(repo.stringReads).toEqual(["absent", "k2"]);
  });
});

describe("CachingLocalStore.settled", () => {
  it("waits for every queued storage batch, including later ones", async () => {
    const repo = new RecordingRepository();
    const store = new CachingLocalStore(repo);

    void store.storeSyncedOps([status("a", 1, "g1")]);
    const settled = store.settled();
    void store.storeSyncedOps([status("b", 2, "g1")]);
    await settled;

    expect((await repo.loadOps(["a", "b"])).map((op) => op?.id)).toEqual(["a", "b"]);
    expect(repo.cursor).toBe(hlc(2));
    expect((await repo.loadGoalIndexEntries(["g1"])).get("g1")?.opIds).toEqual([
      "a",
      "b",
    ]);
  });
});
