import {
  AnyOp,
  DeltaOp,
  DisableOp,
  EnableOp,
  LogEntry,
} from "@thkp-eng/goals-types";

/**
 * Orders two packed HLC strings the way the Dart source of truth does.
 *
 * The Dart sync code sorts with `a.hlcTimestamp.compareTo(b.hlcTimestamp)`,
 * and Dart's `String.compareTo` compares by UTF-16 code unit. JavaScript's
 * `<`/`>` on strings is the same code-unit comparison.
 *
 * `String.prototype.localeCompare` is ICU collation instead, and it can
 * disagree with code-unit order on the `clientId` tail of two ops that share a
 * timestamp and counter. When it disagrees, Dart and TS clients fold the same
 * log in different orders. Keep this code-unit; do not "improve" it back to
 * `localeCompare`. Refs MEK-Org/meta-coder#1174.
 */
export function compareHlc(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function byHlc(a: AnyOp, b: AnyOp): number {
  return compareHlc(a.hlcTimestamp, b.hlcTimestamp);
}

export function isDeltaOp(op: AnyOp): op is DeltaOp {
  return op.type === "delta";
}

export function isDisableOp(op: AnyOp): op is DisableOp {
  return op.type === "disable";
}

export function isEnableOp(op: AnyOp): op is EnableOp {
  return op.type === "enable";
}

/** The parent a relationship entry names, if it is one. */
export function relationshipParentId(
  entry: LogEntry | undefined,
): string | null {
  switch (entry?.type) {
    case "setParent":
    case "addParent":
    case "removeParent":
      return (entry as { parentId?: string | null }).parentId ?? null;
    default:
      return null;
  }
}

/** Port of `getAffectedGoalIdsFromDeltaOp` in goals_types `op.dart`. */
export function getAffectedGoalIdsFromDeltaOp(op: DeltaOp): string[] {
  const affectedGoalIds = [op.delta.id];
  const parentId = relationshipParentId(op.delta.logEntry);
  if (parentId != null) {
    affectedGoalIds.unshift(parentId);
  }
  return affectedGoalIds;
}

/**
 * Port of `Op.extractEntryTextField`, without mutating [op]: returns the
 * entry id and text of a text log entry, plus a copy of the op with that text
 * removed, or null when the op carries no entry text.
 */
export function extractEntryTextField(
  op: AnyOp,
): { entryId: string; text: string; stripped: AnyOp } | null {
  if (!isDeltaOp(op)) return null;
  const entry = op.delta.logEntry as (LogEntry & { text?: string | null }) | undefined;
  if (entry?.text == null) return null;
  const stripped: DeltaOp = {
    ...op,
    delta: { ...op.delta, logEntry: { ...entry, text: null } as LogEntry },
  };
  return { entryId: entry.id, text: entry.text, stripped };
}
