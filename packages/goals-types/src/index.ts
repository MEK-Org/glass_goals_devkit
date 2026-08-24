export interface WireGoalLogEntry {
  /**
   * The unique id of the log entry (GoalLogEntry.id in Dart)
   */
  i: string;
  /**
   * Creation time as an integer timestamp (GoalLogEntry.creationTime in Dart)
   */
  cT: number;
  /**
   * Full path to this note including the id of the note itself (GoalLogEntry.path in Dart)
   */
  p?: string[];
}
/**
 * This interface was referenced by `OpSchema`'s JSON-Schema
 * via the `definition` "Op".
 */
export interface WireOp {
  /**
   * HLC timestamp (Op.hlcTimestamp in Dart)
   */
  h: string;
  /**
   * Unique id of the op (Op.id in Dart)
   */
  i: string;
  /**
   * Version of the op (Op.version in Dart)
   */
  v: number;
  /**
   * Type of the op (OpType, Op.TYPE_JSON_KEY in Dart)
   */
  t: string;
}

export type WireTextGoalLogEntry = WireGoalLogEntry & {
  te?: string | null;
};

export type WirePriorityLogEntry = WireGoalLogEntry & {
  t: "p";
  pr?: number | null;
};

export type WireNoteLogEntry = WireTextGoalLogEntry & {
  t: "n";
  u?: string | null;
};

export type WireSetSummaryEntry = WireTextGoalLogEntry & {
  t: "su";
};

export type WireClearSummaryEntry = WireGoalLogEntry & {
  t: "cSu";
};

export type WireArchiveNoteLogEntry = WireGoalLogEntry & {
  t: "aN";
};

export type WireSetParentLogEntry = WireGoalLogEntry & {
  t: "sP";
  pI?: string | null;
};

export type WireMakeAnchorLogEntry = WireGoalLogEntry & {
  t: "mA";
};

export type WireClearAnchorLogEntry = WireGoalLogEntry & {
  t: "cA";
};

export type WireAddParentLogEntry = WireGoalLogEntry & {
  t: "aP";
  pI: string;
  iS?: boolean;
  dCP?: string[];
};

export type WireCreateInstanceLogEntry = WireGoalLogEntry & {
  t: "cI";
};

export type WireRemoveParentLogEntry = WireGoalLogEntry & {
  t: "rP";
  pI: string;
};

export type WireStatusLogEntry = WireGoalLogEntry & {
  t: "s";
  s?: string | null;
  sT?: number | null;
  eT?: number | null;
};

export type WireArchiveStatusLogEntry = WireGoalLogEntry & {
  t: "aS";
};

export type WireClearStatusLogEntry = WireGoalLogEntry & {
  t: "cS";
};

export type WireDocumentContentsLogEntry = WireTextGoalLogEntry & {
  t: "d";
};

export type WireClearDocumentContentsLogEntry = WireGoalLogEntry & {
  t: "cD";
};

export type WireDeltaOp = WireOp & {
  t: "d";
  d: WireGoalDelta;
};

export type WireDisableOp = WireOp & {
  t: "dO";
  oI: string;
};

export type WireEnableOp = WireOp & {
  t: "eO";
  oI: string;
};

export interface WireGoalDelta {
  i: string;
  t?: string | null;
  lE?: WireGoalLogEntry;
}

export type WireLongRunningOperationEntry = WireGoalLogEntry & {
  t: "lRO";
  oId: string;
  oT: string;
  s: "p" | "r" | "c" | "f";
  eM?: string;
  rD?: Record<string, unknown>;
};

export type WireCourseMetadataLogEntry = WireGoalLogEntry & {
  t: "cM";
  tGI: string[];
};

export type WireReadingAssignmentLogEntry = WireGoalLogEntry & {
  t: "rA";
  tGI: string;
  sP: number;
  eP: number;
  sPF?: "arabic" | "roman";
  ePF?: "arabic" | "roman";
};

export interface WireClassMapping {
  cN: number;
  gI: string;
  d?: string;
  tp: string;
}

export type WireSyllabusParseResultLogEntry = WireGoalLogEntry & {
  t: "sPR";
  cfGI: string;
  tGI: string;
  cM: WireClassMapping[];
  aF: string;
};

export * from "./types.js";
export * from "./conversion.js";
