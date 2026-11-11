import {describe, expect, it} from "vitest";
import type {DeltaOp, LogEntry} from "@thkp-eng/goals-types";
import {Goal} from "./model";
import {
  DocumentContentsMergeStrategy,
  planGoalMerge,
} from "./goal-merge";

const goal = (id: string, createdAt: number, text: string) =>
  new Goal(id, text, new Date(createdAt));

const rename = (
  opId: string,
  goalId: string,
  text: string,
  hlcTimestamp: string,
): DeltaOp => ({
  id: opId,
  version: 6,
  type: "delta",
  hlcTimestamp,
  delta: {id: goalId, text},
});

describe("planGoalMerge", () => {
  it("plans a deterministic n-way merge with documents and relationships", () => {
    const oldest = goal("oldest", 10, "Old title");
    const middle = goal("middle", 20, "Middle title");
    const newest = goal("newest", 30, "Newest title");
    const parentRelationship: LogEntry = {
      id: "middle-parent",
      creationTime: 20,
      type: "addParent",
      parentId: "parent",
      displayedChildPath: ["parent", "middle"],
    };
    const childRelationship: LogEntry = {
      id: "middle-child",
      creationTime: 20,
      type: "addParent",
      parentId: "middle",
      displayedChildPath: ["middle", "child"],
    };
    middle.addSuperGoal("parent", parentRelationship);
    middle.addSubGoal("child", childRelationship);
    const note: LogEntry = {
      id: "note",
      creationTime: 25,
      type: "note",
      text: "Keep this note",
    };
    middle.prependEntry(note);

    let serial = 0;
    const plan = planGoalMerge({
      goals: [newest, middle, oldest],
      documentContents: new Map([
        ["oldest", "Old document"],
        ["middle", "Middle document"],
        ["newest", "Newest document"],
      ]),
      opsByGoal: new Map([
        ["oldest", [rename("old-name", "oldest", "Old title", "001")]],
        ["middle", [rename("middle-name", "middle", "Middle title", "003")]],
        ["newest", [rename("new-name", "newest", "Newest title", "002")]],
      ]),
      now: 100,
      newId: () => `generated-${serial++}`,
    });

    expect(plan.survivingGoalId).toBe("oldest");
    expect(plan.archivedGoalIds).toEqual(["middle", "newest"]);
    expect(plan.chosenName).toBe("Middle title");
    const combinedDocument = plan.deltas.find(
      (delta) => delta.logEntry?.type === "documentContents",
    )?.logEntry;
    expect(combinedDocument?.type).toBe("documentContents");
    if (combinedDocument?.type !== "documentContents") {
      throw new Error("Expected a document contents delta");
    }
    expect(combinedDocument.text).toBe(
      "Old document\n\nMiddle document\n\nNewest document",
    );
    expect(
      plan.deltas.filter((delta) => delta.logEntry?.type === "note"),
    ).toHaveLength(1);
    const copiedParent = plan.deltas.find((delta) => {
      const logEntry = delta.logEntry;
      return logEntry?.type === "addParent" && logEntry.parentId === "parent";
    })?.logEntry;
    expect(copiedParent).toMatchObject({
      displayedChildPath: ["parent", "oldest"],
    });
    expect(
      plan.deltas.filter(
        (delta) => delta.id === "middle" && delta.logEntry?.type === "status",
      ),
    ).toHaveLength(1);
    expect(
      plan.deltas.filter(
        (delta) => delta.id === "newest" && delta.logEntry?.type === "status",
      ),
    ).toHaveLength(1);
  });

  it("keeps a requested goal document instead of concatenating", () => {
    const oldest = goal("a", 10, "A");
    const newest = goal("b", 20, "B");
    const plan = planGoalMerge({
      goals: [oldest, newest],
      documentContents: new Map([
        ["a", "A prose"],
        ["b", "B prose"],
      ]),
      documentContentsStrategy: DocumentContentsMergeStrategy.KeepGoalId,
      documentContentsGoalId: "b",
      now: 100,
      newId: () => "generated",
    });

    const keptDocument = plan.deltas.find(
      (delta) => delta.logEntry?.type === "documentContents",
    )?.logEntry;
    expect(keptDocument?.type).toBe("documentContents");
    if (keptDocument?.type !== "documentContents") {
      throw new Error("Expected a document contents delta");
    }
    expect(keptDocument.text).toBe("B prose");
  });
});
