import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { CachingLocalStore } from "./local-store";
import { GoalIndexEntry, MemorySyncRepository } from "./sync-repository";

const hlc = (t: number) => `${String(t).padStart(15, "0")}:00000:SVB5`;

const textOp = (id: string, t: number, goalId: string, text: string): DeltaOp => ({
  id,
  hlcTimestamp: hlc(t),
  version: 6,
  type: "delta",
  delta: { id: goalId, text },
});

const GOAL_ID = "goalG";
const OLD_OP = textOp("op_old", 1794930562329, GOAL_ID, "Old title");
const INCOMING_OP = textOp("op_incoming", 1794930965354, GOAL_ID, "Incoming title");
const DANGLING_OP = textOp("op_dangling", 1794930858323, GOAL_ID, "Late title");

/**
 * MemorySyncRepository whose `loadOps` can pause around the point where the
 * superclass resolves the ids, so a `loadOpsForGoal` read can be held open at
 * a deterministic spot while another `storeSyncedOps` batch lands —
 * reproducing the prune/index race from review 5944743935 without timing
 * luck.
 *
 * holdBeforeResolution pauses the read before it resolves (the missing op is
 * genuinely absent when the read resolves). holdAfterResolution lets the read
 * resolve first but delays its return, so the missing op can land after the
 * read observed it missing but before loadOpsForGoal continues.
 */
class GatedLoadOpsRepository extends MemorySyncRepository {
  holdBeforeResolution: boolean;
  private gatePredicate: (ids: string[]) => boolean;
  private armed = false;
  private gate: Promise<void> | null = null;
  private releaseGate!: () => void;
  private gateEnteredResolve!: (ids: string[]) => void;
  readonly gateEntered: Promise<string[]>;

  constructor(
    gatePredicate: (ids: string[]) => boolean,
    { holdBeforeResolution = true } = {},
  ) {
    super();
    this.gatePredicate = gatePredicate;
    this.holdBeforeResolution = holdBeforeResolution;
    this.gateEntered = new Promise((resolve) => {
      this.gateEnteredResolve = resolve;
    });
  }

  armGate(): void {
    this.armed = true;
    if (this.gate == null) {
      this.gate = new Promise((resolve) => {
        this.releaseGate = resolve;
      });
    }
  }

  release(): void {
    this.releaseGate();
  }

  override async loadOps(opIds: Iterable<string>): Promise<Array<AnyOp | null>> {
    const ids = [...opIds];
    if (this.armed && this.gatePredicate(ids)) {
      this.armed = false;
      if (this.holdBeforeResolution) {
        this.gateEnteredResolve(ids);
        await this.gate;
      }
      const result = await super.loadOps(ids);
      if (!this.holdBeforeResolution) {
        this.gateEnteredResolve(ids);
        await this.gate;
      }
      return result;
    }
    return super.loadOps(ids);
  }
}

async function seedRepository(
  options: { holdBeforeResolution?: boolean } = {},
): Promise<GatedLoadOpsRepository> {
  const repo = new GatedLoadOpsRepository(
    (ids) => ids.includes("op_dangling"),
    options,
  );
  await repo.storeSyncedOps([OLD_OP]);
  await repo.storeGoalIndexEntry(GOAL_ID, {
    opIds: ["op_old", "op_dangling"],
  });
  repo.cursor = OLD_OP.hlcTimestamp;
  return repo;
}

async function waitForGate(repo: GatedLoadOpsRepository): Promise<void> {
  const timeout = new Promise<never>((_, reject) =>
    setTimeout(() => {
      repo.release();
      reject(
        new Error(
          "the loadOpsForGoal read never reached the gated repository call",
        ),
      );
    }, 10_000),
  );
  await Promise.race([repo.gateEntered, timeout]);
}

describe("CachingLocalStore loadOpsForGoal prune under concurrent indexing (#375)", () => {
  it("preserves op references indexed while the missing-op read is paused (unrelated incoming op)", async () => {
    const repo = await seedRepository();
    const store = new CachingLocalStore(repo);

    repo.armGate();
    const loadPromise = store.loadOpsForGoal(GOAL_ID);
    await waitForGate(repo);

    // While the read is paused, an unrelated op for the same goal is stored
    // and indexed and the cursor advances past it.
    await store.storeSyncedOps([INCOMING_OP]);
    await store.settled();
    expect(repo.cursor).toBe(INCOMING_OP.hlcTimestamp);

    repo.release();
    const result = await loadPromise;

    expect(result.map((op) => op.id)).toEqual(["op_old"]);

    // The durable entry must still reference the concurrently indexed op;
    // its HLC is <= cursor, so an incremental replay would never re-deliver
    // it.
    expect(await repo.loadGoalIndexEntry(GOAL_ID)).toEqual({
      opIds: ["op_old", "op_incoming"],
    } satisfies GoalIndexEntry);

    const coldOps = await new CachingLocalStore(repo).loadOpsForGoal(GOAL_ID);
    expect(coldOps.map((op) => op.id)).toEqual(["op_old", "op_incoming"]);
  });

  it("keeps the initially missing op when it arrives while the read is paused", async () => {
    const repo = await seedRepository({ holdBeforeResolution: false });
    const store = new CachingLocalStore(repo);

    repo.armGate();
    // The read resolves [op_old, null] (op_dangling is genuinely absent from
    // the repository), then holds before loadOpsForGoal continues.
    const loadPromise = store.loadOpsForGoal(GOAL_ID);
    await waitForGate(repo);

    // The missing op lands (stored and cursor-covered) after the read saw it
    // missing but before the prune decision.
    await store.storeSyncedOps([DANGLING_OP]);
    await store.settled();
    expect(repo.cursor).toBe(DANGLING_OP.hlcTimestamp);

    repo.release();
    const result = await loadPromise;

    expect(result.map((op) => op.id)).toEqual(["op_old", "op_dangling"]);
    expect(await repo.loadGoalIndexEntry(GOAL_ID)).toEqual({
      opIds: ["op_old", "op_dangling"],
    } satisfies GoalIndexEntry);

    const coldOps = await new CachingLocalStore(repo).loadOpsForGoal(GOAL_ID);
    expect(coldOps.map((op) => op.id)).toEqual(["op_old", "op_dangling"]);
  });
});
