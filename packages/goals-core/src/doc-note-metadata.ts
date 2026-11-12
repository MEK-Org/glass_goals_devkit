import {
  DocNoteLogEntry,
  GoalLogEntry,
  WireDocNoteLogEntry,
} from "@thkp-eng/goals-types";
import { Goal } from "./model";

// The pretty entry lives in goals-types so the normal compressOp/expandOp
// converters carry kind and displayValue; it is re-exported here for callers.
export type { DocNoteLogEntry, WireDocNoteLogEntry };

export const DOC_NOTE_ENTRY_TYPE = "docNote";
export const DOC_NOTE_ALIAS_ENTRY_TYPE = "dN";

export const DOC_NOTE_KIND_JSON_KEY = "k";
export const KIND_JSON_KEY = "k";
export const NOTE_KIND_JSON_KEY = "k";

export const DOC_NOTE_DISPLAY_VALUE_JSON_KEY = "dV";
export const DISPLAY_VALUE_JSON_KEY = "dV";
export const DISPLAY_JSON_KEY = "dV";

export type DocNoteKind =
  | "footnote"
  | "endnote"
  | "omittedFromExport"
  | "omit";

export const DocNoteKind = {
  Footnote: "footnote" as const,
  Endnote: "endnote" as const,
  OmittedFromExport: "omittedFromExport" as const,
  Omit: "omittedFromExport" as const,
};

export function docNoteLogEntryFromWire(
  wire: any,
): DocNoteLogEntry | null {
  if (
    wire?.t === DOC_NOTE_ENTRY_TYPE ||
    wire?.t === DOC_NOTE_ALIAS_ENTRY_TYPE ||
    wire?.type === DOC_NOTE_ENTRY_TYPE ||
    wire?.type === DOC_NOTE_ALIAS_ENTRY_TYPE
  ) {
    const rawKind =
      wire[DOC_NOTE_KIND_JSON_KEY] ?? wire.k ?? wire.kind ?? wire.noteKind;
    let kind: DocNoteKind = "footnote";
    if (rawKind === "footnote" || rawKind === "Footnote") {
      kind = "footnote";
    } else if (rawKind === "endnote" || rawKind === "Endnote") {
      kind = "endnote";
    } else if (
      rawKind === "omittedFromExport" ||
      rawKind === "omit" ||
      rawKind === "omitted" ||
      rawKind === "omitFromExport" ||
      rawKind === "OmittedFromExport"
    ) {
      kind = "omittedFromExport";
    } else if (typeof rawKind === "string") {
      kind = rawKind as DocNoteKind;
    }

    const rawDisplay =
      wire[DOC_NOTE_DISPLAY_VALUE_JSON_KEY] ??
      wire.dV ??
      wire.displayValue ??
      wire.display ??
      "";

    return {
      id: wire.i || wire.id,
      creationTime: wire.cT || wire.creationTime,
      path: wire.p || wire.path,
      type: DOC_NOTE_ENTRY_TYPE,
      kind,
      displayValue: String(rawDisplay),
    };
  }
  return null;
}

export function docNoteLogEntryToWire(
  pretty: DocNoteLogEntry,
): WireDocNoteLogEntry {
  const wire: any = {
    i: pretty.id,
    cT: pretty.creationTime,
    t: DOC_NOTE_ENTRY_TYPE,
    [DOC_NOTE_KIND_JSON_KEY]: pretty.kind === "omit" ? "omittedFromExport" : pretty.kind,
    [DOC_NOTE_DISPLAY_VALUE_JSON_KEY]: pretty.displayValue,
  };
  if (pretty.path) wire.p = pretty.path;
  return wire as WireDocNoteLogEntry;
}

/**
 * Returns the currently effective DocNoteLogEntry for a goal, or null if none exists.
 */
export function getDocNoteEntry(goal: Goal): DocNoteLogEntry | null {
  return getDocNoteEntryFromLog(goal.log);
}

/**
 * Returns the currently effective DocNoteLogEntry from a log sequence, or null if none exists.
 */
export function getDocNoteEntryFromLog(
  log: Iterable<GoalLogEntry>,
): DocNoteLogEntry | null {
  for (const entry of log) {
    const raw = entry as any;
    const type = entry.type ?? raw?.t;
    if (
      type === DOC_NOTE_ENTRY_TYPE ||
      type === DOC_NOTE_ALIAS_ENTRY_TYPE ||
      type === "docNote" ||
      type === "dN"
    ) {
      if (entry.type === DOC_NOTE_ENTRY_TYPE && "kind" in entry && "displayValue" in entry) {
        return entry as DocNoteLogEntry;
      }
      const parsed = docNoteLogEntryFromWire(entry);
      if (parsed) return parsed;
    }
  }
  return null;
}

export const getDocNoteLogEntry = getDocNoteEntry;
