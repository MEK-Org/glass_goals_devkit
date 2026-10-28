import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, LogEntry } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { SyncClient } from "./sync-client";

/**
 * Characterization tests for two coupled behaviours in `applyDeltaOp`, both
 * of which the reference Dart `_applyDeltaOp`
 * (`goals_core/lib/src/sync/sync_client.dart`) has and an earlier TS port had
 * collapsed:
 *
 *  1. Log-entry dedup keys on (id, type) — the Dart's
 *     `e.id == entry.id && e.runtimeType == entry.runtimeType` — not id alone.
 *  2. `_evaluateSuperGoals` runs even when the entry is already in the log,
 *     because a re-delivered parent op may still need to update the super goal
 *     ("We evaluate super goals even if the entry is already in the log...").
 */

let seq = 0;
function nextHlc(): string {
  seq += 1;
  return new HLC(1_700_000_000_000 + seq, 0, "test-client").pack();
}

function deltaOp(goalId: string, entry: LogEntry, opId?: string): DeltaOp {
  return {
    hlcTimestamp: nextHlc(),
    id: opId ?? `op-${goalId}-${entry.id}-${entry.type}`,
    version: 6,
    type: "delta",
    delta: { id: goalId, logEntry: entry },
  } as DeltaOp;
}

function createGoal(goalId: string): DeltaOp {
  return {
    hlcTimestamp: nextHlc(),
    id: `op-create-${goalId}`,
    version: 6,
    type: "delta",
    delta: { id: goalId, text: goalId },
  } as DeltaOp;
}

async function applied(ops: AnyOp[]) {
  const client = new SyncClient(null);
  await client.init();
  await client.applyOps(ops);
  return client.getGoals();
}

describe("applyDeltaOp — log entry dedup keys on (id, type)", () => {
  it("keeps two entries that share an id but differ in type", async () => {
    const sharedId = "shared-entry-id";
    const goals = await applied([
      createGoal("g"),
      deltaOp("g", {
        id: sharedId,
        creationTime: 1,
        type: "note",
        text: "a note",
      } as unknown as LogEntry),
      deltaOp("g", {
        id: sharedId,
        creationTime: 2,
        type: "priority",
        priority: 5,
      } as unknown as LogEntry),
    ]);

    const log = goals.get("g")!.log;
    expect(log.filter((e) => e.id === sharedId)).toHaveLength(2);
    expect(new Set(log.map((e) => e.type))).toEqual(
      new Set(["note", "priority"]),
    );
  });

  it("still dedups a genuine redelivery of the same (id, type)", async () => {
    const entry = {
      id: "e1",
      creationTime: 1,
      type: "note",
      text: "once",
    } as unknown as LogEntry;

    // Same log entry delivered by two distinct ops.
    const goals = await applied([
      createGoal("g"),
      deltaOp("g", entry, "op-first"),
      deltaOp("g", entry, "op-second"),
    ]);

    expect(goals.get("g")!.log.filter((e) => e.id === "e1")).toHaveLength(1);
  });
});

describe("applyDeltaOp — evaluateSuperGoals runs for already-logged entries", () => {
  it("applies the parent edge when a setParent entry is redelivered after the parent loads", async () => {
    const entry = {
      id: "set-1",
      creationTime: 1,
      type: "setParent",
      parentId: "p",
    } as unknown as LogEntry;

    // First delivery: parent "p" does not exist yet, so the down edge can't be
    // attached. Second delivery of the *same* entry, after "p" exists, must
    // still wire up the parent's subGoal — the dedup guard must not swallow the
    // re-evaluation.
    const goals = await applied([
      createGoal("c"),
      deltaOp("c", entry, "op-a"),
      createGoal("p"),
      deltaOp("c", entry, "op-b"),
    ]);

    // Entry logged once (dedup by id+type held)...
    expect(goals.get("c")!.log.filter((e) => e.id === "set-1")).toHaveLength(1);
    // ...but the super-goal wiring reflects the second evaluation.
    expect([...goals.get("c")!.superGoalIds]).toEqual(["p"]);
    expect([...goals.get("p")!.subGoalIds]).toEqual(["c"]);
  });
});

// Holds for working ops: ops after the base cursor, and every op received
// this session. See SYNC_PARITY.md for ops at or before the base cursor.
describe("working-op projection — effective operation history", () => {
  it("replays in HLC order when a late older op arrives and when disable/enable changes a prior op", async () => {
    const at = (timestamp: number) =>
      new HLC(timestamp, 0, "history-client").pack();
    const text = (id: string, value: string, timestamp: number): DeltaOp => ({
      hlcTimestamp: at(timestamp),
      id,
      version: 6,
      type: "delta",
      delta: { id: "g", text: value },
    });

    const client = new SyncClient(null);
    await client.init();

    const original = text("original", "original", 1);
    const older = text("older", "older", 2);
    const latest = text("latest", "latest", 3);
    const disableLatest = {
      hlcTimestamp: at(4),
      id: "disable-latest",
      version: 6,
      type: "disable",
      opId: latest.id,
    } as AnyOp;
    const enableLatest = {
      hlcTimestamp: at(5),
      id: "enable-latest",
      version: 6,
      type: "enable",
      opId: latest.id,
    } as AnyOp;

    // A later revision arrives before an older remote op. Applying the late
    // older op incrementally would incorrectly overwrite the visible title.
    await client.applyOps([original, latest]);
    await client.applyOps([older]);
    expect(client.getGoals().get("g")!.text).toBe("latest");

    // Undo/redo operations alter the effective log of working ops, so they
    // take effect even after their target was applied.
    await client.applyOps([disableLatest]);
    expect(client.getGoals().get("g")!.text).toBe("older");
    await client.applyOps([enableLatest]);
    expect(client.getGoals().get("g")!.text).toBe("latest");
  });
});

describe("working-op projection — relationships", () => {
  const at = (timestamp: number) =>
    new HLC(timestamp, 0, "edge-client").pack();
  const create = (goalId: string, timestamp: number): DeltaOp => ({
    hlcTimestamp: at(timestamp),
    id: `create-${goalId}`,
    version: 6,
    type: "delta",
    delta: { id: goalId, text: goalId },
  });
  const setParent = {
    hlcTimestamp: at(2),
    id: "set-parent-op",
    version: 6,
    type: "delta",
    delta: {
      id: "c",
      logEntry: {
        id: "set-parent-entry",
        creationTime: 2,
        type: "setParent",
        parentId: "p",
      } as unknown as LogEntry,
    },
  } as DeltaOp;

  // Like the Dart, a projection replays working ops in HLC order. A parent
  // created after (in HLC order) an edge to it does not get the down edge;
  // the child keeps its up edge. Redelivery replays the same order.
  it("keeps the up edge only when the parent is created after the edge, even on redelivery", async () => {
    const client = new SyncClient(null);
    await client.init();

    await client.applyOps([create("c", 1)]);
    await client.applyOps([setParent]);
    await client.applyOps([create("p", 3)]);
    await client.applyOps([setParent]);

    const goals = client.getGoals();
    expect([...goals.get("c")!.superGoalIds]).toEqual(["p"]);
    expect([...goals.get("p")!.subGoalIds]).toEqual([]);
  });

  it("gives the same result whether the ops arrive one by one or together", async () => {
    const incremental = new SyncClient(null);
    await incremental.init();
    await incremental.applyOps([create("c", 1)]);
    await incremental.applyOps([setParent]);
    await incremental.applyOps([create("p", 3)]);

    const batch = await applied([create("c", 1), setParent, create("p", 3)]);

    for (const goals of [incremental.getGoals(), batch]) {
      expect([...goals.get("c")!.superGoalIds]).toEqual(["p"]);
      expect([...goals.get("p")!.subGoalIds]).toEqual([]);
    }
  });

  it("rejects a cycle-closing relationship against a one-sided earlier edge", async () => {
    // b is placed under a before a exists (up edge only); then a is placed
    // under b, which the guard sees as a cycle through b's up edge.
    const aUnderB = {
      hlcTimestamp: at(4),
      id: "a-under-b",
      version: 6,
      type: "delta",
      delta: {
        id: "a",
        logEntry: {
          id: "a-under-b-entry",
          creationTime: 4,
          type: "setParent",
          parentId: "b",
        } as unknown as LogEntry,
      },
    } as DeltaOp;
    const bUnderA = {
      hlcTimestamp: at(2),
      id: "b-under-a",
      version: 6,
      type: "delta",
      delta: {
        id: "b",
        logEntry: {
          id: "b-under-a-entry",
          creationTime: 2,
          type: "setParent",
          parentId: "a",
        } as unknown as LogEntry,
      },
    } as DeltaOp;

    const goals = await applied([
      create("b", 1),
      bUnderA,
      create("a", 3),
      aUnderB,
    ]);

    expect([...goals.get("b")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual([]);
    // a under b would close a cycle: both sides rejected.
    expect([...goals.get("a")!.superGoalIds]).toEqual([]);
    expect([...goals.get("b")!.subGoalIds]).toEqual([]);
  });
});
