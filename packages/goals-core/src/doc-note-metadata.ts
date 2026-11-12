import { GoalLogEntry } from "@thkp-eng/goals-types";
import { Goal } from "./model";

export const DOC_NOTE_ENTRY_TYPE = "docNote";
export const DOC_NOTE_KIND_JSON_KEY = "k";
export const KIND_JSON_KEY = "k";
export const DOC_NOTE_DISPLAY_VALUE_JSON_KEY = "dV";
export const DISPLAY_VALUE_JSON_KEY = "dV";

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

export interface DocNoteLogEntry extends GoalLogEntry {
  type: typeof DOC_NOTE_ENTRY_TYPE;
  kind: DocNoteKind;
  displayValue: string;
}

export function docNoteLogEntryFromWire(
  wire: any,
): DocNoteLogEntry | null {
  return null; // Stub for red regression
}

export function docNoteLogEntryToWire(
  pretty: DocNoteLogEntry,
): any {
  return {}; // Stub for red regression
}

export function getDocNoteEntry(goal: Goal): DocNoteLogEntry | null {
  return null; // Stub for red regression
}

export function getDocNoteEntryFromLog(
  log: Iterable<GoalLogEntry>,
): DocNoteLogEntry | null {
  return null; // Stub for red regression
}

export const getDocNoteLogEntry = getDocNoteEntry;
