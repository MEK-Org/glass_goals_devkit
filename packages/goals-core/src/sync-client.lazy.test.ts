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
