import { describe, expect, it } from "vitest";
import { HLC } from "./hlc";

/**
 * Characterization tests pinning `HLC.increment()` to the Dart source of truth
 * in the `hlc` package (`hlc-1.0.4/lib/hlc.dart`):
 *
 *   HLC increment() => copy(count: count + 1);
 *
 * A pure counter bump: the timestamp is never advanced from the wall clock at
 * increment time. This is the "A4" deviation in the TS-vs-Dart reconciliation —
 * the previous TS `increment()` consulted `Date.now()` and reset to `(now, 0)`
 * whenever the wall clock had advanced, so it diverged from the Dart at every
 * op-creation site.
 *
 * The frozen-timestamp behavior is load-bearing: because local op creation
 * climbs the counter on a frozen timestamp rather than resetting it, a burst of
 * writes drives the counter well past 15 — which is exactly the range where the
 * counter's serialization radix matters (see hlc.test.ts / PR #69: radices 16
 * and 36 agree only for counters 0..15). A4 and the radix fix are coupled: this
 * change makes high counters MORE common, so it must land with or after the
 * base-36 encoding fix, never before.
 *
 * Refs MEK-Org/meta-coder#1174.
 */

describe("HLC.increment", () => {
  it("is a pure count+1 that does NOT advance the timestamp from the wall clock", () => {
    // A timestamp firmly in the past, so the old wall-clock-resetting
    // implementation would have jumped to (Date.now(), 0). The Dart-faithful
    // implementation keeps the frozen timestamp and bumps only the counter.
    const hlc = new HLC(1000, 0, "node-a");
    const next = hlc.increment();

    expect(next.timestamp).toBe(1000);
    expect(next.counter).toBe(1);
    expect(next.clientId).toBe("node-a");
  });

  it("does not mutate the receiver (returns a new HLC)", () => {
    const hlc = new HLC(1000, 4, "node-a");
    const next = hlc.increment();

    expect(hlc.counter).toBe(4); // original untouched
    expect(next.counter).toBe(5);
    expect(next).not.toBe(hlc);
  });

  it("climbs the counter past 15 across a burst on a frozen timestamp", () => {
    // Mirrors the Dart: a burst of local ops between remote folds all share one
    // timestamp with a climbing counter. This is the regime that makes the
    // base-36 vs base-16 encoding disagreement (PR #69) observable.
    let hlc = new HLC(1000, 0, "node-a");
    for (let i = 0; i < 20; i++) {
      hlc = hlc.increment();
    }

    expect(hlc.timestamp).toBe(1000); // never advanced
    expect(hlc.counter).toBe(20); // climbed well past 15
  });

  it("is deterministic — independent of when it is called", () => {
    // No wall-clock read means two increments of equal HLCs are byte-identical
    // once packed, regardless of the time between the calls.
    const a = new HLC(1000, 7, "node-a").increment();
    const b = new HLC(1000, 7, "node-a").increment();

    expect(a.timestamp).toBe(b.timestamp);
    expect(a.counter).toBe(b.counter);
    expect(a.counter).toBe(8);
  });
});
