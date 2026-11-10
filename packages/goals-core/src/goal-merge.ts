import type {AnyOp, GoalDelta, GoalLogEntry, LogEntry} from "@thkp-eng/goals-types";
import {Cupid} from "./cupid";
import {Goal, GoalStatus} from "./model";
import {compareHlc, isDeltaOp, isDisableOp, isEnableOp} from "./op-utils";

export enum DocumentContentsMergeStrategy {
  Combine = "combine",
  KeepOldest = "keep_oldest",
  KeepNewest = "keep_newest",
  KeepGoalId = "keep_goal_id",
}

export interface GoalMergePlan {
  survivingGoalId: string;
  archivedGoalIds: string[];
  chosenName: string;
  deltas: GoalDelta[];
  movedChildrenCount: number;
  copiedLogEntriesCount: number;
}

export interface GoalMergePlanInput {
  goals: Goal[];
  documentContents?: ReadonlyMap<string, string>;
  opsByGoal?: ReadonlyMap<string, Iterable<AnyOp>>;
  documentContentsStrategy?: DocumentContentsMergeStrategy;
  documentContentsGoalId?: string;
  now?: number;
  newId?: () => string;
}

function structuralOrStatusOrDocument(entry: GoalLogEntry): boolean {
  return new Set([
    "setParent",
    "addParent",
    "removeParent",
    "status",
    "archiveStatus",
    "clearStatus",
    "priority",
    "makeAnchor",
    "clearAnchor",
    "createInstance",
    "documentContents",
    "clearDocumentContents",
  ]).has(entry.type);
}

function latestTextOp(
  operations: Iterable<AnyOp>,
): {text: string; timestamp: string} | undefined {
  const ordered = [...operations].sort((left, right) =>
    compareHlc(left.hlcTimestamp, right.hlcTimestamp),
  );
  const disabled = new Set<string>();
  for (const operation of ordered) {
    if (isDisableOp(operation)) disabled.add(operation.opId);
    else if (isEnableOp(operation)) disabled.delete(operation.opId);
  }
  let latest: {text: string; timestamp: string} | undefined;
  for (const operation of ordered) {
    if (
      !isDeltaOp(operation) ||
      operation.delta.text == null ||
      disabled.has(operation.id)
    ) {
      continue;
    }
    if (!latest || compareHlc(operation.hlcTimestamp, latest.timestamp) > 0) {
      latest = {text: operation.delta.text, timestamp: operation.hlcTimestamp};
    }
  }
  return latest;
}

function rewrittenPath(
  relationship: GoalLogEntry | undefined,
  archivedIds: ReadonlySet<string>,
  survivingGoalId: string,
): string[] | undefined {
  if (relationship?.type !== "addParent") return undefined;
  const path = (relationship as {displayedChildPath?: string[]})
    .displayedChildPath;
  return path?.map((segment) =>
    archivedIds.has(segment) ? survivingGoalId : segment,
  );
}

function entry(
  newId: () => string,
  creationTime: number,
  fields: Record<string, unknown>,
): LogEntry {
  return {id: newId(), creationTime, ...fields} as LogEntry;
}

/**
 * Plans a merge of at least two goals into their oldest member without
 * mutating state. Consumers apply the returned deltas in one sync batch.
 */
export function planGoalMerge(input: GoalMergePlanInput): GoalMergePlan {
  const ids = new Set<string>();
  for (const goal of input.goals) {
    if (ids.has(goal.id)) throw new Error("Goal ids must be distinct");
    ids.add(goal.id);
  }
  if (input.goals.length < 2) throw new Error("At least two goals must be merged");

  const goals = [...input.goals].sort(
    (left, right) =>
      left.creationTime.getTime() - right.creationTime.getTime() ||
      (left.id < right.id ? -1 : left.id > right.id ? 1 : 0),
  );
  const survivingGoal = goals[0];
  const archivedGoals = goals.slice(1);
  const archivedIds = new Set(archivedGoals.map((goal) => goal.id));
  const mergedIds = new Set(goals.map((goal) => goal.id));
  const documents = input.documentContents ?? new Map<string, string>();
  const operations = input.opsByGoal ?? new Map<string, Iterable<AnyOp>>();
  const now = input.now ?? Date.now();
  const newId = input.newId ?? (() => Cupid.random().encode());

  let chosenName = goals.at(-1)!.text;
  let latest: {text: string; timestamp: string} | undefined;
  let timestampTie = false;
  for (const goal of goals) {
    const candidate = latestTextOp(operations.get(goal.id) ?? []);
    if (!candidate) continue;
    if (!latest) latest = candidate;
    else {
      const compared = compareHlc(candidate.timestamp, latest.timestamp);
      if (compared > 0) {
        latest = candidate;
        timestampTie = false;
      } else if (compared === 0) timestampTie = true;
    }
  }
  if (latest && !timestampTie) chosenName = latest.text;

  const deltas: GoalDelta[] = [];
  if (survivingGoal.text !== chosenName) {
    deltas.push({id: survivingGoal.id, text: chosenName});
  }

  const nonEmptyDocuments = goals
    .map((goal) => ({goal, text: documents.get(goal.id) ?? ""}))
    .filter(({text}) => text.length > 0);
  let mergedDocument: string | undefined;
  switch (
    input.documentContentsStrategy ?? DocumentContentsMergeStrategy.Combine
  ) {
    case DocumentContentsMergeStrategy.Combine:
      mergedDocument = nonEmptyDocuments.length
        ? nonEmptyDocuments.map(({text}) => text.trim()).join("\n\n")
        : undefined;
      break;
    case DocumentContentsMergeStrategy.KeepOldest:
      mergedDocument = documents.get(survivingGoal.id);
      break;
    case DocumentContentsMergeStrategy.KeepNewest:
      mergedDocument = documents.get(goals.at(-1)!.id);
      break;
    case DocumentContentsMergeStrategy.KeepGoalId:
      if (!input.documentContentsGoalId || !mergedIds.has(input.documentContentsGoalId)) {
        throw new Error("A selected document goal id is required");
      }
      mergedDocument = documents.get(input.documentContentsGoalId);
      break;
  }
  const existingDocument = documents.get(survivingGoal.id) ?? "";
  if (mergedDocument && mergedDocument !== existingDocument) {
    deltas.push({
      id: survivingGoal.id,
      logEntry: entry(newId, now, {type: "documentContents", text: mergedDocument}),
    });
  }

  let copiedLogEntriesCount =
    mergedDocument && mergedDocument !== existingDocument ? 1 : 0;
  for (const archivedGoal of archivedGoals) {
    for (const logEntry of [...archivedGoal.log].reverse()) {
      if (structuralOrStatusOrDocument(logEntry)) continue;
      deltas.push({id: survivingGoal.id, logEntry});
      copiedLogEntriesCount++;
    }
  }

  const parentIds = new Set(survivingGoal.superGoalIds);
  for (const archivedGoal of archivedGoals) {
    for (const parentId of archivedGoal.superGoalIds) {
      const relationship = archivedGoal.superGoalRelationships.get(parentId);
      if (!mergedIds.has(parentId) && !parentIds.has(parentId)) {
        parentIds.add(parentId);
        const isSlice =
          (relationship as {isSlice?: boolean} | undefined)?.isSlice === true;
        const displayedChildPath = rewrittenPath(
          relationship,
          archivedIds,
          survivingGoal.id,
        );
        deltas.push({
          id: survivingGoal.id,
          logEntry: entry(newId, now, {
            type: "addParent",
            parentId,
            ...(isSlice ? {isSlice: true} : {}),
            ...(displayedChildPath ? {displayedChildPath} : {}),
          }),
        });
      }
      deltas.push({
        id: archivedGoal.id,
        logEntry: entry(newId, now, {type: "removeParent", parentId}),
      });
    }
  }

  const childIds = new Set(survivingGoal.subGoalIds);
  let movedChildrenCount = 0;
  for (const archivedGoal of archivedGoals) {
    for (const childId of archivedGoal.subGoalIds) {
      if (mergedIds.has(childId)) continue;
      const relationship = archivedGoal.subGoalRelationships.get(childId);
      if (!childIds.has(childId)) {
        childIds.add(childId);
        movedChildrenCount++;
        const isSlice =
          (relationship as {isSlice?: boolean} | undefined)?.isSlice === true;
        const displayedChildPath = rewrittenPath(
          relationship,
          archivedIds,
          survivingGoal.id,
        );
        deltas.push({
          id: childId,
          logEntry: entry(newId, now, {
            type: "addParent",
            parentId: survivingGoal.id,
            ...(isSlice ? {isSlice: true} : {}),
            ...(displayedChildPath ? {displayedChildPath} : {}),
          }),
        });
      }
      deltas.push({
        id: childId,
        logEntry: entry(newId, now, {
          type: "removeParent",
          parentId: archivedGoal.id,
        }),
      });
    }
  }

  for (const archivedGoal of archivedGoals) {
    deltas.push({
      id: archivedGoal.id,
      logEntry: entry(newId, now, {
        type: "status",
        status: GoalStatus.Archived,
        startTime: now,
        endTime: null,
      }),
    });
  }

  return {
    survivingGoalId: survivingGoal.id,
    archivedGoalIds: archivedGoals.map((goal) => goal.id),
    chosenName,
    deltas,
    movedChildrenCount,
    copiedLogEntriesCount,
  };
}
