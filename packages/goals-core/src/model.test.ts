import { describe, expect, it } from "vitest";
import { GoalLogEntry } from "@thkp-eng/goals-types";
import { Goal, GoalInstance, MergedMap } from "./model";

/**
 * Characterization tests pinning `Goal`, `GoalInstance`, and `MergedMap` to the
 * Dart source of truth in `goals_core/lib/src/model.dart`:
 *
 *  - Goal.text defaults to 'Untitled' (`_text ?? 'Untitled'`).
 *  - subGoalIds / superGoalIds are derived from the relationship maps.
 *  - GoalInstance overrides text (fall back to the backing goal), hasParent
 *    (delegate to the backing goal), log (backing minus status/clearStatus,
 *    merged with self, sorted newest-first), subGoalRelationships (a MergedMap
 *    layered over the backing goal), and clone (returns a GoalInstance).
 *  - MergedMap tombstone semantics.
 *
 * Refs MEK-Org/meta-coder#1174.
 */

function entry(
  id: string,
  type: string,
  creationTime: number,
): GoalLogEntry {
  return { id, type, creationTime } as unknown as GoalLogEntry;
}

const relEntry = entry("rel", "addParent", 1);

describe("Goal", () => {
  it("text defaults to 'Untitled' when no text is set (Dart C1)", () => {
    expect(new Goal("g", undefined, new Date(0)).text).toBe("Untitled");
  });

  it("text returns the set value", () => {
    expect(new Goal("g", "Real title", new Date(0)).text).toBe("Real title");
    const g = new Goal("g", undefined, new Date(0));
    g.text = "later";
    expect(g.text).toBe("later");
  });

  it("subGoalIds / superGoalIds are derived from the relationship maps", () => {
    const g = new Goal("g", "g", new Date(0));
    g.addSubGoal("child", relEntry);
    g.addSuperGoal("parent", relEntry);
    expect([...g.subGoalIds]).toEqual(["child"]);
    expect([...g.superGoalIds]).toEqual(["parent"]);
    expect(g.hasParent("parent")).toBe(true);

    g.removeSubGoal("child");
    g.removeSuperGoal("parent");
    expect([...g.subGoalIds]).toEqual([]);
    expect([...g.superGoalIds]).toEqual([]);
    expect(g.hasParent("parent")).toBe(false);
  });
});

describe("MergedMap", () => {
  it("reads map1 over map2 and unions their keys", () => {
    const m1 = new Map([["a", entry("a", "note", 1)]]);
    const m2 = new Map([
      ["a", entry("a-backing", "note", 1)],
      ["b", entry("b", "note", 1)],
    ]);
    const merged = new MergedMap(m1, m2);

    expect(merged.get("a")!.id).toBe("a"); // map1 wins
    expect(merged.get("b")!.id).toBe("b"); // falls through to map2
    expect([...merged.keys()]).toEqual(["a", "b"]);
    expect(merged.size).toBe(2);
  });

  it("tombstones a backing-only key on delete, and clear tombstones all backing keys", () => {
    const m1 = new Map<string, GoalLogEntry>([["a", entry("a", "note", 1)]]);
    const m2 = new Map<string, GoalLogEntry>([
      ["b", entry("b", "note", 1)],
      ["c", entry("c", "note", 1)],
    ]);
    const merged = new MergedMap(m1, m2);

    expect(merged.delete("b")).toBe(true);
    expect(merged.has("b")).toBe(false);
    expect(merged.get("b")).toBeUndefined();
    expect([...merged.keys()].sort()).toEqual(["a", "c"]);
    expect(m2.has("b")).toBe(true); // backing map is not mutated

    // Re-setting an unwritten (tombstoned) key clears the tombstone.
    merged.set("b", entry("b2", "note", 1));
    expect(merged.get("b")!.id).toBe("b2");

    merged.clear();
    expect([...merged.keys()]).toEqual([]);
    expect(merged.size).toBe(0);
    expect(m2.size).toBe(2); // still not mutated
  });
});

describe("GoalInstance", () => {
  function backing(): Goal {
    const g = new Goal("backing", "Backing title", new Date(0));
    g.addSubGoal("bchild", relEntry);
    g.addSuperGoal("bparent", relEntry);
    return g;
  }

  it("text falls back to the backing goal, then to its own text once set", () => {
    const g = backing();
    const inst = new GoalInstance(g, "inst", new Date(0));
    expect(inst.text).toBe("Backing title");
    inst.text = "Instance title";
    expect(inst.text).toBe("Instance title");
  });

  it("hasParent delegates to the backing goal, not the instance's own super map", () => {
    const g = backing();
    const inst = new GoalInstance(g, "inst", new Date(0));
    // The instance's own super-goal map is empty; parentage comes from backing.
    expect(inst.hasParent("bparent")).toBe(true);
    inst.addSuperGoal("iparent", relEntry);
    expect(inst.hasParent("iparent")).toBe(false); // still delegated
  });

  it("log merges backing (minus status/clearStatus) with self, newest-first, keeping archiveStatus", () => {
    const g = new Goal("backing", "b", new Date(0));
    // prependEntry inserts at the front; give distinct creationTimes.
    g.prependEntry(entry("note-b", "note", 10));
    g.prependEntry(entry("status", "status", 20));
    g.prependEntry(entry("clear", "clearStatus", 30));
    g.prependEntry(entry("arch", "archiveStatus", 40));

    const inst = new GoalInstance(g, "inst", new Date(0));
    inst.prependEntry(entry("note-self", "note", 25));

    const ids = inst.log.map((e) => e.id);
    // status + clearStatus filtered out; archiveStatus kept; sorted desc by time
    // (40 arch, 25 note-self, 10 note-b).
    expect(ids).toEqual(["arch", "note-self", "note-b"]);
    // selfLog is just the instance's own entries.
    expect(inst.selfLog.map((e) => e.id)).toEqual(["note-self"]);
  });

  it("subGoalRelationships is a MergedMap over the backing goal; subGoalIds reflects the merge", () => {
    const g = backing();
    const inst = new GoalInstance(g, "inst", new Date(0));
    inst.addSubGoal("ichild", relEntry);

    expect([...inst.subGoalIds].sort()).toEqual(["bchild", "ichild"]);
    // Adding to the instance does not mutate the backing goal.
    expect([...g.subGoalIds]).toEqual(["bchild"]);
  });

  it("clone returns an independent GoalInstance preserving the backing goal", () => {
    const g = backing();
    const inst = new GoalInstance(g, "inst", new Date(0));
    inst.addSubGoal("ichild", relEntry);
    inst.prependEntry(entry("self", "note", 5));

    const cloned = inst.clone();
    expect(cloned).toBeInstanceOf(GoalInstance);
    expect(cloned.goal).toBe(g);
    expect(cloned.text).toBe("Backing title");
    expect([...cloned.subGoalIds].sort()).toEqual(["bchild", "ichild"]);

    // Mutating the clone must not affect the original.
    cloned.addSubGoal("late", relEntry);
    expect([...inst.subGoalIds].sort()).toEqual(["bchild", "ichild"]);
  });
});
