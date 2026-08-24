import { GoalLogEntry, WireGoalLogEntry } from "@thkp-eng/goals-types";

export const BOOK_SECTION_ENTRY_TYPE = "bS";

// Mimic the Dart constants
export const FIRST_VERSION = 1;
export const START_PAGE_JSON_KEY = "sP";
export const END_PAGE_JSON_KEY = "eP";
export const START_PAGE_FORMAT_JSON_KEY = "sPF";
export const END_PAGE_FORMAT_JSON_KEY = "ePF";
export const BOOK_GOAL_ID_JSON_KEY = "bI";

/**
 * Wire format for Book Section Log Entry
 */
export interface WireBookSectionLogEntry extends WireGoalLogEntry {
  t: typeof BOOK_SECTION_ENTRY_TYPE;
  sP: number | string;
  eP?: number | string | null;
  sPF?: string | null;
  ePF?: string | null;
  bI?: string | null;
}

/**
 * Pretty format for Book Section Log Entry
 */
export interface BookSectionLogEntry extends GoalLogEntry {
  type: typeof BOOK_SECTION_ENTRY_TYPE;
  startPage: number;
  endPage?: number | null;
  startPageFormat: string;
  endPageFormat?: string | null;
  bookGoalId?: string | null;
}

/**
 * Mimic the Dart fromJsonMap equivalent
 */
export function bookSectionLogEntryFromWire(
  wire: any,
): BookSectionLogEntry | null {
  if (wire?.t === BOOK_SECTION_ENTRY_TYPE || wire?.type === BOOK_SECTION_ENTRY_TYPE) {
    const sP = wire[START_PAGE_JSON_KEY] ?? wire.sP;
    return {
      id: wire.i || wire.id,
      creationTime: wire.cT || wire.creationTime,
      path: wire.p || wire.path,
      type: BOOK_SECTION_ENTRY_TYPE,
      startPage: typeof sP === "number" ? sP : parseInt(sP, 10),
      endPage: wire[END_PAGE_JSON_KEY] ?? wire.eP,
      startPageFormat:
        wire[START_PAGE_FORMAT_JSON_KEY] ??
        wire.sPF ??
        wire.pF ?? // Fallback to old key as in Dart
        "arabic",
      endPageFormat: wire[END_PAGE_FORMAT_JSON_KEY] ?? wire.ePF,
      bookGoalId: wire[BOOK_GOAL_ID_JSON_KEY] ?? wire.bI,
    };
  }
  return null;
}

/**
 * Mimic the Dart toJsonMap equivalent
 */
export function bookSectionLogEntryToWire(
  pretty: BookSectionLogEntry,
): WireBookSectionLogEntry {
  const wire: any = {
    i: pretty.id,
    cT: pretty.creationTime,
    t: BOOK_SECTION_ENTRY_TYPE,
    [START_PAGE_JSON_KEY]: pretty.startPage,
    [START_PAGE_FORMAT_JSON_KEY]: pretty.startPageFormat ?? "arabic",
  };

  if (pretty.path) wire.p = pretty.path;
  if (pretty.endPage !== undefined && pretty.endPage !== null) {
    wire[END_PAGE_JSON_KEY] = pretty.endPage;
  }
  if (pretty.endPageFormat !== undefined && pretty.endPageFormat !== null) {
    wire[END_PAGE_FORMAT_JSON_KEY] = pretty.endPageFormat;
  }
  if (pretty.bookGoalId !== undefined && pretty.bookGoalId !== null) {
    wire[BOOK_GOAL_ID_JSON_KEY] = pretty.bookGoalId;
  }

  return wire as WireBookSectionLogEntry;
}
