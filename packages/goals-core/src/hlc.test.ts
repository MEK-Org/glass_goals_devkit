import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { MemoryLocalStore } from "./sync-client";

/**
 * Characterization tests for the packed HLC wire format, pinned to the Dart
 * `hlc` package (`~/.pub-cache/.../hlc-1.0.4/lib/hlc.dart`) that Glass Goals'
 * Dart clients use:
 *
 *   pack:   timestamp.padLeft(15) : count.toRadixString(36).padLeft(5) : node
 *   unpack: int.parse(ts) : int.parse(count, radix: 36) : sublist(2).join(':')
 *
 * The TS port packed/parsed the counter in radix 16 and split the clientId off
 * with a plain destructure. Radices 16 and 36 agree only for counters 0..15;
 * beyond that the TS and Dart wire formats disagree, so an op written by one
 * deserializes to the wrong counter (and sorts wrong) in the other.
 *
 * Refs MEK-Org/meta-coder#1174.
 */

const TS = 1_700_000_000_000;

function counterSegment(packed: string): string {
  return packed.split(":")[1];
}

describe("HLC wire format — counter is radix 36, matching the Dart", () => {
  it("packs a counter >= 16 in base 36, not base 16", () => {
    // 20 → 'k' in base 36 ("0000k"); base 16 would have been "00014".
    expect(counterSegment(new HLC(TS, 20, "node").pack())).toBe("0000k");
    // 35 → 'z', the largest single base-36 digit; base 16 would be "00023".
    expect(counterSegment(new HLC(TS, 35, "node").pack())).toBe("0000z");
  });

  it("round-trips counters that would be mis-parsed under base 16", () => {
    for (const counter of [16, 17, 20, 35, 36, 1000]) {
      const round = HLC.unpack(new HLC(TS, counter, "node").pack());
      expect(round.counter).toBe(counter);
      expect(round.timestamp).toBe(TS);
      expect(round.clientId).toBe("node");
    }
  });

  it("still agrees with base 16 for counters 0..15", () => {
    // These are the values for which the old and new formats are identical, so
    // no already-written low-counter op changes meaning.
    for (const counter of [0, 1, 9, 10, 15]) {
      expect(counterSegment(new HLC(TS, counter, "node").pack())).toBe(
        counter.toString(16).padStart(5, "0"),
      );
    }
  });

  it("round-trips a clientId that contains the ':' delimiter", () => {
    // Faithfulness insurance: Dart rejoins sublist(2), so a delimiter in the
    // node survives. (base64url clientIds don't contain ':' today.)
    const round = HLC.unpack(new HLC(TS, 5, "cli:ent:id").pack());
    expect(round.clientId).toBe("cli:ent:id");
    expect(round.counter).toBe(5);
  });
});

describe("MemoryLocalStore.storeSyncedOps — cursor advances via a faithful unpack", () => {
  function op(counter: number): DeltaOp {
    return {
      hlcTimestamp: new HLC(TS, counter, "node").pack(),
      id: `op-${counter}`,
      version: 6,
      type: "delta",
      delta: { id: "g", text: "g" },
    } as DeltaOp;
  }

  it("picks the true-latest op when counters exceed the base-16 range", async () => {
    // Same timestamp; counter 17 ("0000h") is genuinely later than 3 ("00003").
    // Under the old base-16 unpack, counter 17 mis-parsed to 0 and the cursor
    // would have stuck at the counter-3 op. Store them out of order to force the
    // comparison to do the work.
    const later = op(17);
    const earlier = op(3);

    const store = new MemoryLocalStore();
    await store.init();
    await store.storeSyncedOps([earlier, later] as AnyOp[]);

    expect(store.cursor).toBe(later.hlcTimestamp);
  });
});
