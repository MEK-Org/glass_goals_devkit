import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, LogEntry } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { MemoryLocalStore, SyncClient } from "./sync-client";

/**
 * Characterization test for the op-log sort order in `applyOpsToState` and
 * `MemoryLocalStore.getAllOps`.
 *
 * The reference Dart `SyncClient` sorts its op log with
 * `a.hlcTimestamp.compareTo(b.hlcTimestamp)`, and Dart's `String.compareTo`
 * compares by UTF-16 code unit. The TS port sorted with
 * `String.prototype.localeCompare`, which is ICU collation. For two ops that
 * share a timestamp and counter and differ only in `clientId`, ICU and
 * code-unit order can disagree — and when they do, Dart and TS clients fold the
 * same log in different orders. That breaks the convergence argument the cycle
 * guard depends on: the guard skips the edge whose op is applied *later* in log
 * order, so if the two populations disagree on "later" they skip different
 * edges and diverge. This pins the code to the Dart's code-unit order.
 *
 * Refs MEK-Org/meta-coder#1174.
 */

// A pair of clientIds on which the two orderings genuinely disagree:
//   code-unit: 'Z' (0x5A) < 'a' (0x61)  ⇒  "Zebra" sorts before "apple"
//   ICU:       case-insensitive primary  ⇒  "apple" sorts before "Zebra"
const CLIENT_EARLY_BY_CODE_UNIT = "Zebra";
const CLIENT_LATE_BY_CODE_UNIT = "apple";

const SHARED_TS = 1_700_000_000_000;
const SHARED_COUNTER = 0;

function packedHlc(clientId: string): string {
  return new HLC(SHARED_TS, SHARED_COUNTER, clientId).pack();
}

function setParentOp(goalId: string, parentId: string, hlc: string): DeltaOp {
  const entry = {
    id: `sp-${parentId}`,
    creationTime: 1,
    type: "setParent",
    parentId,
  } as unknown as LogEntry;
  return {
    hlcTimestamp: hlc,
    id: `op-${goalId}-${parentId}`,
    version: 6,
    type: "delta",
    delta: { id: goalId, logEntry: entry },
  } as DeltaOp;
}

async function applied(ops: AnyOp[]) {
  const client = new SyncClient(null);
  await client.init();
  await client.applyOps(ops);
  return client.getGoals();
}

describe("op-log sort — code-unit order, not ICU collation", () => {
  it("the chosen clientIds actually disagree between code-unit and ICU order", () => {
    const early = packedHlc(CLIENT_EARLY_BY_CODE_UNIT);
    const late = packedHlc(CLIENT_LATE_BY_CODE_UNIT);

    // Code-unit (the Dart / correct order): "Zebra" packed string sorts first.
    expect(early < late).toBe(true);

    // ICU collation (the old port's order): the sign flips — "apple" first.
    // If this premise ever stops holding the test is meaningless, so pin it.
    expect(early.localeCompare(late)).toBeGreaterThan(0);
  });

  it("applies the code-unit-later op last for same-(timestamp,counter) ops", async () => {
    // Two setParent ops on the same goal, identical timestamp and counter,
    // differing only in clientId. setParent clears and resets the parent, so
    // the goal's final parent is whichever op is applied *last*.
    //
    // Code-unit order: CLIENT_EARLY ("Zebra") < CLIENT_LATE ("apple"), so the
    // "apple" op is last and its parent ("p-late") wins. Under the old
    // localeCompare, "apple" sorted first and "p-early" would have won instead.
    const opEarly = setParentOp(
      "c",
      "p-early",
      packedHlc(CLIENT_EARLY_BY_CODE_UNIT),
    );
    const opLate = setParentOp(
      "c",
      "p-late",
      packedHlc(CLIENT_LATE_BY_CODE_UNIT),
    );

    // Feed them in the order that would give the wrong answer if the sort were
    // a no-op, so the sort is doing real work here.
    const goals = await applied([opLate, opEarly]);

    expect([...goals.get("c")!.superGoalIds]).toEqual(["p-late"]);
  });

  it("MemoryLocalStore.getAllOps returns code-unit order for same-key ops", async () => {
    // The second sort site, in isolation. Store the two same-key ops in the
    // order that would be wrong if unsorted, then assert getAllOps hands them
    // back in code-unit order ("Zebra" op before "apple" op).
    const opEarly = setParentOp(
      "c",
      "p-early",
      packedHlc(CLIENT_EARLY_BY_CODE_UNIT),
    );
    const opLate = setParentOp(
      "c",
      "p-late",
      packedHlc(CLIENT_LATE_BY_CODE_UNIT),
    );

    const store = new MemoryLocalStore();
    await store.init();
    await store.storeSyncedOps([opLate, opEarly]);
    const reread = await store.getAllOps();

    expect(reread.map((op) => op.hlcTimestamp)).toEqual([
      packedHlc(CLIENT_EARLY_BY_CODE_UNIT),
      packedHlc(CLIENT_LATE_BY_CODE_UNIT),
    ]);
  });
});
