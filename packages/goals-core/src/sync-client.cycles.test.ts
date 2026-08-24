import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, LogEntry } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { SyncClient } from "./sync-client";

/**
 * Characterization tests for the cycle guard in `evaluateSuperGoals`.
 *
 * The reference implementation is the Dart original,
 * `goals_core/lib/src/sync/sync_client.dart`:
 *   - `_checkCycles` (:818), including its fail-open on an unloaded parent
 *     (:829-832)
 *   - the two guarded parent branches, `SetParentLogEntry` (:882) and
 *     `AddParentLogEntry` (:900)
 *
 * These tests exist to pin the Dart's *behaviour*, tolerances included, so a
 * future port or refactor can't quietly tighten it.
 */

let seq = 0;
function nextHlc(): string {
  seq += 1;
  return new HLC(1_700_000_000_000 + seq, 0, "test-client").pack();
}

function deltaOp(goalId: string, entry: LogEntry): DeltaOp {
  return {
    hlcTimestamp: nextHlc(),
    id: `op-${goalId}-${entry.id}`,
    version: 6,
    type: "delta",
    delta: { id: goalId, logEntry: entry },
  } as DeltaOp;
}

function addParent(
  childId: string,
  parentId: string,
  extra: Record<string, unknown> = {},
): DeltaOp {
  seq += 1;
  return deltaOp(childId, {
    id: `entry-${seq}`,
    creationTime: 1_700_000_000_000 + seq,
    type: "addParent",
    parentId,
    ...extra,
  } as unknown as LogEntry);
}

function setParent(childId: string, parentId: string | null): DeltaOp {
  seq += 1;
  return deltaOp(childId, {
    id: `entry-${seq}`,
    creationTime: 1_700_000_000_000 + seq,
    type: "setParent",
    parentId,
  } as unknown as LogEntry);
}

/** Creates the goal without touching parentage. */
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

describe("evaluateSuperGoals cycle guard — addParent", () => {
  it("skips only the down edge of a cycle-closing op, leaving the up edge in place", async () => {
    // a -> b (b is a's parent), then the loop-closing b -> a.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      addParent("a", "b"),
      addParent("b", "a"),
    ]);

    const a = goals.get("a")!;
    const b = goals.get("b")!;

    // The up edge is added before the check and is deliberately NOT reverted.
    expect([...b.superGoalIds]).toEqual(["a"]);
    // The down edge is the one that gets skipped.
    expect([...a.subGoalIds]).toEqual([]);
    expect(a.subGoalRelationships.has("b")).toBe(false);

    // The legitimate first edge is untouched in both directions.
    expect([...a.superGoalIds]).toEqual(["b"]);
    expect([...b.subGoalIds]).toEqual(["a"]);
  });

  it("detects cycles more than one hop up the chain", async () => {
    // a -> b -> c, then the loop-closing c -> a.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      createGoal("c"),
      addParent("a", "b"),
      addParent("b", "c"),
      addParent("c", "a"),
    ]);

    expect([...goals.get("c")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual([]);
  });

  it("treats self-parenting as a cycle", async () => {
    const goals = await applied([createGoal("a"), addParent("a", "a")]);

    expect([...goals.get("a")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual([]);
  });

  it("is decided by log order — the op applied later loses", async () => {
    // Same pair of edges, opposite arrival order. Whichever arrives second is
    // the one whose down edge is dropped. No content-derived tiebreak.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      addParent("b", "a"),
      addParent("a", "b"),
    ]);

    expect([...goals.get("b")!.subGoalIds]).toEqual([]);
    expect([...goals.get("a")!.subGoalIds]).toEqual(["b"]);
  });

  it("leaves acyclic diamonds fully intact", async () => {
    // d -> b, d -> c, b -> a, c -> a. No cycle; nothing should be dropped.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      createGoal("c"),
      createGoal("d"),
      addParent("b", "a"),
      addParent("c", "a"),
      addParent("d", "b"),
      addParent("d", "c"),
    ]);

    expect([...goals.get("d")!.superGoalIds].sort()).toEqual(["b", "c"]);
    expect([...goals.get("b")!.subGoalIds]).toEqual(["d"]);
    expect([...goals.get("c")!.subGoalIds]).toEqual(["d"]);
  });

  it("uses the entry id as the child when the relationship is a slice", async () => {
    // With isSlice, the Dart checks cycles against the entry id rather than the
    // goal id, so a slice edge whose *goal* is an ancestor is still allowed.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      addParent("b", "a"),
      addParent("a", "b", { isSlice: true }),
    ]);

    expect([...goals.get("a")!.superGoalIds]).toEqual(["b"]);
    expect([...goals.get("b")!.subGoalIds]).toEqual(["a"]);
  });
});

describe("evaluateSuperGoals cycle guard — setParent", () => {
  it("skips only the down edge of a cycle-closing setParent", async () => {
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      setParent("a", "b"),
      setParent("b", "a"),
    ]);

    expect([...goals.get("b")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual([]);
  });

  it("still detaches the prior parents before the guard trips", async () => {
    // b starts under p. Re-parenting b under a would close a cycle, so the down
    // edge is skipped — but the detach from p already happened and is not
    // rolled back.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      createGoal("p"),
      setParent("b", "p"),
      addParent("a", "b"),
      setParent("b", "a"),
    ]);

    expect([...goals.get("p")!.subGoalIds]).toEqual([]);
    expect([...goals.get("b")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual([]);
  });
});

describe("_checkCycles fail-open tolerance", () => {
  it("allows the edge when the prospective parent is not loaded yet", async () => {
    // No create op for "missing": the parent goal simply isn't in the map, so
    // the down edge has nothing to attach to and the up edge stands.
    const goals = await applied([createGoal("a"), addParent("a", "missing")]);

    expect([...goals.get("a")!.superGoalIds]).toEqual(["missing"]);
  });

  it("allows the edge when a goal partway up the frontier is not loaded", async () => {
    // a -> b, b -> gap (gap never created), then c -> a with a's chain
    // unresolvable. The Dart returns false — allow — rather than dropping a
    // possibly-legitimate edge. This tolerance is deliberate: do not tighten.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      createGoal("c"),
      addParent("a", "b"),
      addParent("b", "gap"),
      addParent("c", "a"),
    ]);

    expect([...goals.get("c")!.superGoalIds]).toEqual(["a"]);
    expect([...goals.get("a")!.subGoalIds]).toEqual(["c"]);
  });

  it("terminates on a pre-existing cycle in the loaded graph", async () => {
    // The guard prevents cycles from forming through this path, but the seen
    // set must still make the walk terminate if one exists by other means.
    const goals = await applied([
      createGoal("a"),
      createGoal("b"),
      createGoal("c"),
      addParent("a", "b"),
      addParent("b", "c"),
      addParent("c", "a"),
      addParent("a", "c"),
    ]);

    expect(goals.size).toBe(3);
  });
});
