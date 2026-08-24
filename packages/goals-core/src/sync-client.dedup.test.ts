import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, LogEntry } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { SyncClient } from "./sync-client";

/**
 * Characterization tests for two coupled behaviours in `applyOpsToState`, both
 * of which the reference Dart `_applyDeltaOp`
 * (`goals_core/lib/src/sync/sync_client.dart:920`) has and the TS port had
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

describe("applyOpsToState — log entry dedup keys on (id, type)", () => {
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

describe("applyOpsToState — evaluateSuperGoals runs for already-logged entries", () => {
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
