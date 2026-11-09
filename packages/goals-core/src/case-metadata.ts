import {
  GoalLogEntry,
  WireCaseGoalLogEntry,
  WireReporterGoalLogEntry,
} from "@thkp-eng/goals-types";

export type { WireCaseGoalLogEntry, WireReporterGoalLogEntry };

export const CASE_ENTRY_TYPE = "case";
export const REPORTER_ENTRY_TYPE = "rep";

export const CASE_NAME_JSON_KEY = "n";
export const CASE_COURT_JSON_KEY = "c";
export const CASE_YEAR_JSON_KEY = "y";
export const CASE_DECISION_DATE_JSON_KEY = "dD";

export const REPORTER_NAME_JSON_KEY = "r";
export const REPORTER_START_PAGE_JSON_KEY = "sP";
export const REPORTER_INDEX_JSON_KEY = "rI";
export const REPORTER_CASE_GOAL_ID_JSON_KEY = "cGI";

/**
 * Pretty format for Case Goal Log Entry
 */
export interface CaseGoalLogEntry extends GoalLogEntry {
  type: typeof CASE_ENTRY_TYPE;
  name: string;
  court?: string | null;
  year?: number | null;
  decisionDate?: string | null;
}

export function caseGoalLogEntryFromWire(
  wire: any,
): CaseGoalLogEntry | null {
  if (wire?.t === CASE_ENTRY_TYPE || wire?.type === CASE_ENTRY_TYPE) {
    const rawYear = wire[CASE_YEAR_JSON_KEY] ?? wire.y ?? wire.year;
    let year: number | null = null;
    if (typeof rawYear === "number") {
      year = rawYear;
    } else if (rawYear != null) {
      const parsed = parseInt(String(rawYear), 10);
      year = isNaN(parsed) ? null : parsed;
    }
    return {
      id: wire.i || wire.id,
      creationTime: wire.cT || wire.creationTime,
      path: wire.p || wire.path,
      type: CASE_ENTRY_TYPE,
      name: wire[CASE_NAME_JSON_KEY] ?? wire.n ?? wire.name ?? "",
      court: wire[CASE_COURT_JSON_KEY] ?? wire.c ?? wire.court ?? null,
      year,
      decisionDate: wire[CASE_DECISION_DATE_JSON_KEY] ?? wire.dD ?? wire.decisionDate ?? null,
    };
  }
  return null;
}

export function caseGoalLogEntryToWire(
  pretty: CaseGoalLogEntry,
): WireCaseGoalLogEntry {
  const wire: any = {
    i: pretty.id,
    cT: pretty.creationTime,
    t: CASE_ENTRY_TYPE,
    [CASE_NAME_JSON_KEY]: pretty.name,
  };
  if (pretty.path) wire.p = pretty.path;
  if (pretty.court !== undefined && pretty.court !== null) {
    wire[CASE_COURT_JSON_KEY] = pretty.court;
  }
  if (pretty.year !== undefined && pretty.year !== null) {
    wire[CASE_YEAR_JSON_KEY] = pretty.year;
  }
  if (pretty.decisionDate !== undefined && pretty.decisionDate !== null) {
    wire[CASE_DECISION_DATE_JSON_KEY] = pretty.decisionDate;
  }
  return wire as WireCaseGoalLogEntry;
}

/**
 * Pretty format for Reporter Goal Log Entry
 */
export interface ReporterGoalLogEntry extends GoalLogEntry {
  type: typeof REPORTER_ENTRY_TYPE;
  reporter: string;
  startPage: number;
  reporterIndex: number;
  caseGoalId?: string | null;
}

export function reporterGoalLogEntryFromWire(
  wire: any,
): ReporterGoalLogEntry | null {
  if (wire?.t === REPORTER_ENTRY_TYPE || wire?.type === REPORTER_ENTRY_TYPE) {
    const rawStartPage = wire[REPORTER_START_PAGE_JSON_KEY] ?? wire.sP ?? wire.startPage;
    const rawReporterIndex = wire[REPORTER_INDEX_JSON_KEY] ?? wire.rI ?? wire.reporterIndex;
    return {
      id: wire.i || wire.id,
      creationTime: wire.cT || wire.creationTime,
      path: wire.p || wire.path,
      type: REPORTER_ENTRY_TYPE,
      reporter: wire[REPORTER_NAME_JSON_KEY] ?? wire.r ?? wire.reporter ?? "",
      startPage: typeof rawStartPage === "number" ? rawStartPage : parseInt(String(rawStartPage), 10),
      reporterIndex: typeof rawReporterIndex === "number" ? rawReporterIndex : parseInt(String(rawReporterIndex), 10),
      caseGoalId: wire[REPORTER_CASE_GOAL_ID_JSON_KEY] ?? wire.cGI ?? wire.caseGoalId ?? null,
    };
  }
  return null;
}

export function reporterGoalLogEntryToWire(
  pretty: ReporterGoalLogEntry,
): WireReporterGoalLogEntry {
  const wire: any = {
    i: pretty.id,
    cT: pretty.creationTime,
    t: REPORTER_ENTRY_TYPE,
    [REPORTER_NAME_JSON_KEY]: pretty.reporter,
    [REPORTER_START_PAGE_JSON_KEY]: pretty.startPage,
    [REPORTER_INDEX_JSON_KEY]: pretty.reporterIndex,
  };
  if (pretty.path) wire.p = pretty.path;
  if (pretty.caseGoalId !== undefined && pretty.caseGoalId !== null) {
    wire[REPORTER_CASE_GOAL_ID_JSON_KEY] = pretty.caseGoalId;
  }
  return wire as WireReporterGoalLogEntry;
}
