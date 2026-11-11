import {describe, expect, it} from "vitest";
import type {
  AddParentLogEntry,
  DeltaOp,
  DocumentContentsLogEntry,
  LogEntry,
} from "@thkp-eng/goals-types";
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

type NonEmptyDocumentContentsLogEntry = DocumentContentsLogEntry & {
  text: string;
};

const isDocumentContentsLogEntry = (
  entry: LogEntry | undefined,
): entry is NonEmptyDocumentContentsLogEntry =>
  entry?.type === "documentContents" &&
  "text" in entry &&
  typeof entry.text === "string";

const isAddParentLogEntry = (
  entry: LogEntry | undefined,
): entry is AddParentLogEntry =>
  entry?.type === "addParent" &&
  "parentId" in entry &&
  typeof entry.parentId === "string";

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
    const combinedDocument = plan.deltas
      .map((delta) => delta.logEntry)
      .find(isDocumentContentsLogEntry);
    if (combinedDocument === undefined) {
      throw new Error("Expected a document contents delta");
    }
    expect(combinedDocument.text).toBe(
      "Old document\n\nMiddle document\n\nNewest document",
    );
    expect(
      plan.deltas.filter((delta) => delta.logEntry?.type === "note"),
    ).toHaveLength(1);
    const copiedParent = plan.deltas
      .map((delta) => delta.logEntry)
      .filter(isAddParentLogEntry)
      .find((logEntry) => logEntry.parentId === "parent");
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

    const keptDocument = plan.deltas
      .map((delta) => delta.logEntry)
      .find(isDocumentContentsLogEntry);
    if (keptDocument === undefined) {
      throw new Error("Expected a document contents delta");
    }
    expect(keptDocument.text).toBe("B prose");
  });
  it.each([
    {
      name: "keep_newest with an empty newest document",
      strategy: DocumentContentsMergeStrategy.KeepNewest,
      documentContentsGoalId: undefined,
      documents: new Map([["a", "A prose"]]),
    },
    {
      name: "keep_goal_id with an absent selected document",
      strategy: DocumentContentsMergeStrategy.KeepGoalId,
      documentContentsGoalId: "b",
      documents: new Map([["a", "A prose"]]),
    },
    {
      name: "keep_goal_id with an explicitly empty selected document",
      strategy: DocumentContentsMergeStrategy.KeepGoalId,
      documentContentsGoalId: "b",
      documents: new Map([
        ["a", "A prose"],
        ["b", ""],
      ]),
    },
  ])("clears the survivor document for $name", (testCase) => {
    const plan = planGoalMerge({
      goals: [goal("a", 10, "A"), goal("b", 20, "B")],
      documentContents: testCase.documents,
      documentContentsStrategy: testCase.strategy,
      documentContentsGoalId: testCase.documentContentsGoalId,
      now: 100,
      newId: () => "generated",
    });

    const documentDeltas = plan.deltas.filter(
      (delta) =>
        delta.logEntry?.type === "documentContents" ||
        delta.logEntry?.type === "clearDocumentContents",
    );
    expect(documentDeltas).toHaveLength(1);
    expect(documentDeltas[0]?.id).toBe("a");
    expect(documentDeltas[0]?.logEntry?.type).toBe("clearDocumentContents");
    expect(plan.copiedLogEntriesCount).toBe(1);
  });

  it("keeps an empty oldest document without emitting a document delta", () => {
    const plan = planGoalMerge({
      goals: [goal("a", 10, "A"), goal("b", 20, "B")],
      documentContents: new Map([["b", "B prose"]]),
      documentContentsStrategy: DocumentContentsMergeStrategy.KeepOldest,
      now: 100,
      newId: () => "generated",
    });

    expect(
      plan.deltas.filter(
        (delta) =>
          delta.logEntry?.type === "documentContents" ||
          delta.logEntry?.type === "clearDocumentContents",
      ),
    ).toHaveLength(0);
    expect(plan.copiedLogEntriesCount).toBe(0);
  });

  it("removes edges between merged goals in both directions", () => {
    const child = goal("child", 10, "Oldest child");
    const parent = goal("parent", 20, "Newer parent");
    const grandchild = goal("grandchild", 30, "Newest grandchild");
    const parentEdge: LogEntry = {
      id: "child-under-parent",
      creationTime: 20,
      type: "addParent",
      parentId: "parent",
    };
    child.addSuperGoal("parent", parentEdge);
    parent.addSubGoal("child", parentEdge);
    const grandchildEdge: LogEntry = {
      id: "grandchild-under-child",
      creationTime: 30,
      type: "addParent",
      parentId: "child",
    };
    grandchild.addSuperGoal("child", grandchildEdge);
    child.addSubGoal("grandchild", grandchildEdge);
    const externalEdge: LogEntry = {
      id: "child-under-external",
      creationTime: 15,
      type: "addParent",
      parentId: "external",
    };
    child.addSuperGoal("external", externalEdge);

    let serial = 0;
    const plan = planGoalMerge({
      goals: [parent, grandchild, child],
      now: 100,
      newId: () => `generated-${serial++}`,
    });

    expect(plan.survivingGoalId).toBe("child");
    const removals = plan.deltas.flatMap((delta) =>
      delta.logEntry?.type === "removeParent"
        ? [
            `${delta.id}<-${(delta.logEntry as {parentId: string}).parentId}`,
          ]
        : [],
    );
    expect(removals).toContain("child<-parent");
    expect(removals).toContain("grandchild<-child");
    expect(removals).not.toContain("child<-external");
    const mergedIds = [...plan.archivedGoalIds, plan.survivingGoalId];
    expect(
      plan.deltas.filter(
        (delta) =>
          delta.logEntry?.type === "addParent" &&
          mergedIds.includes(delta.id) &&
          mergedIds.includes((delta.logEntry as {parentId: string}).parentId),
      ),
    ).toHaveLength(0);
  });
});
