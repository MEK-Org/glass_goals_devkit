import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, DisableOp } from "@thkp-eng/goals-types";
import { MemoryLocalStore } from "./local-store";
import { MemoryPersistenceService } from "./persistence";
import { SyncClient } from "./sync-client";

// Deterministic counters, not timings: the instrumented store counts per-goal
// loads and full-history reads, and SyncClient.stats counts the delta ops a
// projection replays.

class CountingLocalStore extends MemoryLocalStore {
  loads = new Map<string, number>();
  getAllOpsCalls = 0;

  override async loadOpsForGoal(goalId: string): Promise<AnyOp[]> {
    this.loads.set(goalId, (this.loads.get(goalId) ?? 0) + 1);
    return super.loadOpsForGoal(goalId);
  }

  override async getAllOps(): Promise<AnyOp[]> {
    this.getAllOpsCalls++;
    return super.getAllOps();
  }
}

const hlc = (t: number) => `${String(t).padStart(15, "0")}:00000:srv`;

const text = (id: string, t: number, goalId: string, value: string): DeltaOp => ({
  id,
  hlcTimestamp: hlc(t),
  version: 6,
  type: "delta",
  delta: { id: goalId, text: value },
});

const addParent = (id: string, t: number, goalId: string, parentId: string): DeltaOp => ({
  id,
  hlcTimestamp: hlc(t),
  version: 6,
  type: "delta",
  delta: {
    id: goalId,
    logEntry: { type: "addParent", id: `e-${id}`, creationTime: t, parentId },
  },
});

const disable = (id: string, t: number, opId: string): DisableOp => ({
  id,
  hlcTimestamp: hlc(t),
  version: 6,
  type: "disable",
  opId,
});

const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function settle(persistence: MemoryPersistenceService) {
  for (let i = 0; i < 3; i++) {
    await persistence.settled();
    await pause(1);
  }
}

/** A root with `n` children, each with a title and a later retitle. */
function corpus(n: number): AnyOp[] {
  const ops: AnyOp[] = [text("r", 1000, "root", "Root")];
  for (let i = 0; i < n; i++) {
    ops.push(text(`c${i}`, 2000 + i, `g${i}`, `Goal ${i}`));
    ops.push(addParent(`p${i}`, 20000 + i, `g${i}`, "root"));
    ops.push(text(`t${i}`, 40000 + i, `g${i}`, `Goal ${i} v2`));
  }
  return ops;
}

/** Builds the corpus through a first session, then returns a cold client. */
async function coldClient(n: number, residentSoftCap = 2000) {
  const persistence = new MemoryPersistenceService();
  const store = new CountingLocalStore();
  await persistence.save(corpus(n));
  await settle(persistence);
  const producer = new SyncClient(persistence, store);
  await producer.init();
  await settle(persistence);
  producer.dispose();

  store.loads.clear();
  store.getAllOpsCalls = 0;
  const client = new SyncClient(persistence, store, { residentSoftCap });
  await client.init();
  await settle(persistence);
  return { persistence, store, client };
}

describe("lazy SyncClient — instrumented local store", () => {
  it("a cold start loads only root goals, never the full history", async () => {
    const { store, client } = await coldClient(300);
    expect([...store.loads.keys()]).toEqual(["root"]);
    expect(store.getAllOpsCalls).toBe(0);
    expect(client.numResidentGoals).toBe(1);
    expect(client.stats.appliedDeltaOps).toBeLessThanOrEqual(301);
    client.dispose();
  });

  it("loadGoal reads one goal's indexed ops once, then serves cache hits", async () => {
    const { store, client } = await coldClient(300);
    const goal = await client.loadGoal("g7");
    expect(goal?.text).toBe("Goal 7 v2");
    expect(goal?.superGoalIds).toEqual(new Set(["root"]));
    expect(store.loads.get("g7")).toBe(1);

    await client.loadGoal("g7");
    await client.loadGoal("g7");
    expect(store.loads.get("g7")).toBe(1);
    expect([...store.loads.keys()].sort()).toEqual(["g7", "root"]);
    expect(store.getAllOpsCalls).toBe(0);
    client.dispose();
  });

  it("warm batches replay only working ops, not the historical base", async () => {
    const n = 600; // 1801 historical ops
    const { persistence, store, client } = await coldClient(n);
    await client.loadGoal("g3");
    const loadsBefore = new Map(store.loads);
    const appliedBefore = client.stats.appliedDeltaOps;

    for (let i = 0; i < 10; i++) {
      await persistence.save([text(`w${i}`, 90000 + i, "g3", `warm ${i}`)]);
      await settle(persistence);
    }

    expect(client.stateSubject.value.get("g3")?.text).toBe("warm 9");
    expect(store.loads).toEqual(loadsBefore);
    expect(store.getAllOpsCalls).toBe(0);
    // Each batch replays the session's working ops (at most 10 here) a small
    // constant number of times; one full rebuild would replay 1801 ops.
    const replayed = client.stats.appliedDeltaOps - appliedBefore;
    expect(replayed).toBeLessThan(200);
    client.dispose();
  });

  it("evicts unpinned goals past residentSoftCap and reloads them on demand", async () => {
    const { store, client } = await coldClient(50, 5);
    for (let i = 0; i < 50; i++) {
      const goal = await client.loadGoal(`g${i}`);
      expect(goal?.text).toBe(`Goal ${i} v2`);
      expect(client.numResidentGoals).toBeLessThanOrEqual(5);
    }
    const before = store.loads.get("g0");
    expect((await client.loadGoal("g0"))?.text).toBe("Goal 0 v2");
    expect(store.loads.get("g0")).toBe((before ?? 0) + 1);
    client.dispose();
  });

  it("projections never mutate the cold base or a prior emission", async () => {
    const { persistence, client } = await coldClient(5);
    await client.loadGoal("g1");
    const first = client.stateSubject.value;
    const firstGoal = first.get("g1")!;
    const firstRoot = first.get("root")!;
    const rootChildren = [...firstRoot.subGoalIds].sort();

    await persistence.save([
      text("x1", 90000, "g1", "changed"),
      addParent("x2", 90001, "g1", "g2"),
      disable("x3", 90002, "p1"),
    ]);
    await settle(persistence);

    const next = client.stateSubject.value;
    expect(next).not.toBe(first);
    expect(next.get("g1")?.text).toBe("changed");
    expect(firstGoal.text).toBe("Goal 1 v2");
    expect([...firstGoal.superGoalIds]).toEqual(["root"]);
    expect([...firstRoot.subGoalIds].sort()).toEqual(rootChildren);
    client.dispose();
  });

  it("getGoals returns the resident projection and subscribe follows emissions", async () => {
    const { persistence, client } = await coldClient(5);
    const seen: number[] = [];
    const unsubscribe = client.subscribe((state) => seen.push(state.size));
    expect(seen).toEqual([client.getGoals().size]);
    expect(client.getGoals().has("g2")).toBe(false);

    await client.loadGoal("g2");
    await settle(persistence);
    expect(client.getGoals().get("g2")?.text).toBe("Goal 2 v2");
    expect(seen.length).toBeGreaterThan(1);
    unsubscribe();
    client.dispose();
  });
});

/**
 * A store whose op lookups by id can be held open or failed on demand.
 * `loadGoal` resolves Disable/Enable targets through `loadOpsById` after it
 * installs the goal's base entry, so holding that lookup pauses a load in
 * flight.
 */
class GatedLocalStore extends CountingLocalStore {
  gate: Promise<unknown> | null = null;
  failNext: Error | null = null;

  override async loadOpsById(opIds: Iterable<string>): Promise<Array<AnyOp | null>> {
    const ids = [...opIds];
    if (this.gate) await this.gate;
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = null;
      throw error;
    }
    return super.loadOpsById(ids);
  }
}

/** Saves [ops] through a producer session, so they sit before the cursor. */
async function persistedStore(ops: AnyOp[], store = new GatedLocalStore()) {
  const persistence = new MemoryPersistenceService();
  await persistence.save(ops);
  await settle(persistence);
  const producer = new SyncClient(persistence, store);
  await producer.init();
  await settle(persistence);
  producer.dispose();
  return { persistence, store };
}

/** `slow` resolves a Disable target from the store; `fast` does not. */
const twoChildren = (): AnyOp[] => [
  text("r", 1000, "root", "Root"),
  text("s1", 1001, "slow", "Slow"),
  text("s2", 1002, "slow", "Slow v2"),
  addParent("sp", 1003, "slow", "root"),
  disable("sd", 1004, "s2"),
  text("f1", 1005, "fast", "Fast"),
  addParent("fp", 1006, "fast", "root"),
];

describe("lazy SyncClient — loads in flight during eviction", () => {
  it("roots above a tiny cap stay loadable after init and restart", async () => {
    // rb's Disable target is read from the store, so its init load is still
    // in flight when ra and rc finish and evict down to the cap. Loading kid
    // afterwards emits a fresh state built from the base.
    const { persistence, store } = await persistedStore([
      text("ta", 1000, "ra", "Root ra"),
      text("tb", 1001, "rb", "Root rb"),
      text("tb2", 1002, "rb", "Root rb v2"),
      disable("db", 1003, "tb2"),
      text("tc", 1004, "rc", "Root rc"),
      text("tk", 1005, "kid", "Kid"),
      addParent("pk", 1006, "kid", "ra"),
    ]);

    for (let session = 0; session < 2; session++) {
      const client = new SyncClient(persistence, store, { residentSoftCap: 2 });
      store.gate = pause(5);
      await client.init();
      store.gate = null;
      await settle(persistence);
      expect((await client.loadGoal("kid"))?.text).toBe("Kid");
      for (const id of ["ra", "rb", "rc"]) {
        expect((await client.loadGoal(id))?.text).toBe(`Root ${id}`);
      }
      expect(client.numResidentGoals).toBeLessThanOrEqual(2);
      client.dispose();
    }
  });

  it("a goal evicted mid-load is not recorded as loaded", async () => {
    const { persistence, store } = await persistedStore(twoChildren());
    const client = new SyncClient(persistence, store, { residentSoftCap: 1 });
    await client.init();
    await settle(persistence);
    const rootRef = await client.loadGoalRef("root");

    let release!: () => void;
    store.gate = new Promise<void>((r) => (release = r));
    const slow = client.loadGoal("slow");
    await pause(1);
    expect((await client.loadGoal("fast"))?.text).toBe("Fast");
    store.gate = null;
    release();

    expect((await slow)?.text).toBe("Slow");
    expect((await client.loadGoal("slow"))?.text).toBe("Slow");
    expect(rootRef.goal?.text).toBe("Root");
    // Completed unpinned goals still evict and reload.
    expect(client.numResidentGoals).toBeLessThanOrEqual(2);
    const fastLoads = store.loads.get("fast")!;
    expect((await client.loadGoal("fast"))?.text).toBe("Fast");
    expect(store.loads.get("fast")).toBe(fastLoads + 1);
    await rootRef.dispose();
    client.dispose();
  });

  it("concurrent loads of every goal under a tiny cap all return the goal", async () => {
    const { persistence, store } = await persistedStore(twoChildren());
    const client = new SyncClient(persistence, store, { residentSoftCap: 1 });
    await client.init();
    await settle(persistence);

    const ids = ["root", "slow", "fast"];
    const goals = await Promise.all(ids.map((id) => client.loadGoal(id)));
    expect(goals.map((goal) => goal?.text)).toEqual(["Root", "Slow", "Fast"]);
    for (const [i, id] of ids.entries()) {
      expect((await client.loadGoal(id))?.text).toBe(goals[i]?.text);
    }
    client.dispose();
  });

  it("a failed load releases its protection from eviction", async () => {
    const { persistence, store } = await persistedStore(twoChildren());
    const client = new SyncClient(persistence, store, { residentSoftCap: 1 });
    await client.init();
    await settle(persistence);

    const rootRef = await client.loadGoalRef("root");

    store.failNext = new Error("store unavailable");
    await expect(client.loadGoal("slow")).rejects.toThrow("store unavailable");

    // With root pinned, only slow and fast can go; a leaked protection on
    // slow would leave two goals resident.
    expect((await client.loadGoal("fast"))?.text).toBe("Fast");
    expect(client.numResidentGoals).toBe(1);
    expect((await client.loadGoal("slow"))?.text).toBe("Slow");
    await rootRef.dispose();
    client.dispose();
  });
});

/**
 * Holds one goal's `loadOpsForGoal` until the client next stores synced ops,
 * which `persistOps` does after it has built the pulled state but before the
 * pull installs it as the new base.
 */
class PullRacingLocalStore extends GatedLocalStore {
  heldGoalId: string | null = null;
  private release: (() => void) | null = null;
  private armed!: () => void;
  /** Resolves once the held goal's ops are read and waiting on the release. */
  held = new Promise<void>((r) => (this.armed = r));

  override loadOpsForGoal(goalId: string): Promise<AnyOp[]> {
    const ops = super.loadOpsForGoal(goalId);
    if (goalId !== this.heldGoalId) return ops;
    this.heldGoalId = null;
    // Resolved directly, so the load resumes one microtask after the release,
    // ahead of the pull's continuation.
    return new Promise<AnyOp[]>((resolve) => {
      void ops.then((loaded) => {
        this.release = () => resolve(loaded);
        this.armed();
      });
    });
  }

  override storeSyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    this.release?.();
    this.release = null;
    return super.storeSyncedOps(ops);
  }
}

describe("lazy SyncClient — a pull racing a goal load", () => {
  it("a goal loaded while a pull installs its state stays loaded", async () => {
    const store = new PullRacingLocalStore();
    const { persistence } = await persistedStore(twoChildren(), store);
    const client = new SyncClient(persistence, store);
    await client.init();
    await settle(persistence);

    // A remote retitle of the root makes the next pull non-empty.
    await persistence.save([text("r2", 2000, "root", "Root v2")]);
    store.heldGoalId = "fast";
    const fast = client.loadGoal("fast");
    await store.held;
    await client.sync();

    expect((await fast)?.text).toBe("Fast");
    expect((await client.loadGoal("root"))?.text).toBe("Root v2");
    expect((await client.loadGoal("fast"))?.text).toBe("Fast");
    expect(client.getGoals().get("fast")?.text).toBe("Fast");
    client.dispose();
  });
});
