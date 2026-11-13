import {
  WireOp,
  WireDeltaOp,
  WireDisableOp,
  WireEnableOp,
  WireGoalLogEntry,
  WireNoteLogEntry,
  WirePriorityLogEntry,
  WireSetParentLogEntry,
  WireAddParentLogEntry,
  WireRemoveParentLogEntry,
  WireClearAnchorLogEntry,
  WireDocumentContentsLogEntry,
  WireClearDocumentContentsLogEntry,
  WireStatusLogEntry,
  WireGoalDelta,
} from "./index.js";
import {
  Op,
  DeltaOp,
  DisableOp,
  EnableOp,
  ClearAnchorLogEntry,
  DocumentContentsLogEntry,
  ClearDocumentContentsLogEntry,
  DocNoteLogEntry,
  GoalLogEntry,
  TextGoalLogEntry,
  NoteLogEntry,
  PriorityLogEntry,
  SetParentLogEntry,
  AddParentLogEntry,
  RemoveParentLogEntry,
  StatusLogEntry,
  AnyOp,
  LogEntry,
} from "./types.js";

/**
 * Op and log-entry encodings use overlapping short keys (e.g. "d"), so they
 * must use separate maps to avoid ambiguous reverse lookups.
 */
const OP_TYPE_MAP: Record<string, string> = {
  delta: "d",
  disable: "dO",
  enable: "eO",
};

const LOG_ENTRY_TYPE_MAP: Record<string, string> = {
  note: "n",
  setSummary: "su",
  clearSummary: "cSu",
  makeAnchor: "mA",
  addStatusIntention: "aSI",
  addStatusReflection: "aSR",
  parentContextComment: "pCC",
  longRunningOperation: "lRO",
  courseMetadata: "cM",
  readingAssignment: "rA",
  priority: "p",
  setParent: "sP",
  addParent: "aP",
  removeParent: "rP",
  status: "s",
  archiveNote: "aN",
  archiveStatus: "aS",
  clearStatus: "cS",
  clearAnchor: "cA",
  createInstance: "cI",
  documentContents: "d",
  clearDocumentContents: "cD",
};

/** Dart `DocNoteLogEntryModule` also reads this alias; it writes "docNote". */
const DOC_NOTE_ALIAS_ENTRY_TYPE = "dN";

/**
 * Canonical wire value for a note kind, matching Dart `DocNoteKind.fromWire`
 * aliases. Unrecognised values pass through unchanged rather than being lost.
 */
function canonicalDocNoteKind(kind: unknown): unknown {
  switch (kind) {
    case "footnote":
    case "Footnote":
      return "footnote";
    case "endnote":
    case "Endnote":
      return "endnote";
    case "omittedFromExport":
    case "OmittedFromExport":
    case "omit":
    case "omitted":
    case "omitFromExport":
      return "omittedFromExport";
    default:
      return kind;
  }
}

const OP_REVERSE_TYPE_MAP = Object.fromEntries(
  Object.entries(OP_TYPE_MAP).map(([k, v]) => [v, k])
);

const LOG_ENTRY_REVERSE_TYPE_MAP = Object.fromEntries(
  Object.entries(LOG_ENTRY_TYPE_MAP).map(([k, v]) => [v, k])
);

/** A runtime extension, analogous to Dart's LogEntryModule. */
export interface LogEntryModule {
  wireTypes: readonly string[];
  types: readonly string[];
  fromWire(wire: WireGoalLogEntry): LogEntry;
  toWire(entry: LogEntry): WireGoalLogEntry;
}

const wireModules = new Map<string, LogEntryModule>();
const prettyModules = new Map<string, LogEntryModule>();

/** Register once at application startup, before reading persisted operations. */
export function registerLogEntryModule(module: LogEntryModule): () => void {
  for (const type of module.wireTypes) {
    if (isKnownLogEntryType(type)) throw new Error(`Log-entry wire type already registered: ${type}`);
  }
  for (const type of module.types) {
    if (Object.hasOwn(LOG_ENTRY_TYPE_MAP, type) || type === "docNote" || prettyModules.has(type)) {
      throw new Error(`Log-entry type already registered: ${type}`);
    }
  }
  for (const type of module.wireTypes) wireModules.set(type, module);
  for (const type of module.types) prettyModules.set(type, module);
  return () => {
    for (const type of module.wireTypes) {
      if (wireModules.get(type) === module) wireModules.delete(type);
    }
    for (const type of module.types) {
      if (prettyModules.get(type) === module) prettyModules.delete(type);
    }
  };
}

/** Whether the decoder knows this wire type, including registered modules. */
export function isKnownLogEntryType(type: string): boolean {
  return Object.hasOwn(LOG_ENTRY_REVERSE_TYPE_MAP, type) ||
    type === "docNote" || type === DOC_NOTE_ALIAS_ENTRY_TYPE || wireModules.has(type);
}

// Remaining built-ins use the same scalar/list field mapping as Dart.
const LOG_ENTRY_FIELDS: Record<string, Record<string, string>> = {
  addStatusIntention: { intentionText: "iT", statusId: "sI" },
  addStatusReflection: { reflectionText: "rT", statusId: "sI" },
  parentContextComment: { parentId: "pI" },
  longRunningOperation: { operationId: "oId", operationType: "oT", status: "s", errorMessage: "eM", resultData: "rD" },
  courseMetadata: { textbookGoalIds: "tGI" },
  readingAssignment: { textbookGoalId: "tGI", startPage: "sP", endPage: "eP", startPageFormat: "sPF", endPageFormat: "ePF" },
};

export function compressLogEntry(pretty: LogEntry): WireGoalLogEntry {
  const compressed: any = {
    ...pretty.wireExtras,
    i: pretty.id,
    cT: pretty.creationTime,
  };
  if (pretty.path) compressed.p = pretty.path;
  if (pretty.type) compressed.t = Object.hasOwn(LOG_ENTRY_TYPE_MAP, pretty.type)
    ? LOG_ENTRY_TYPE_MAP[pretty.type] : pretty.type;

  const module = prettyModules.get(pretty.type);
  if (module) Object.assign(compressed, module.toWire(pretty));
  for (const [field, key] of Object.entries(LOG_ENTRY_FIELDS[pretty.type] ?? {})) {
    const value = (pretty as unknown as Record<string, unknown>)[field];
    if (value !== undefined) compressed[key] = value;
  }

  // Type-specific fields
  switch (pretty.type) {
    case "note":
      const note = pretty as NoteLogEntry;
      if (note.text !== undefined) compressed.te = note.text;
      if (note.updateNoteEntryId) compressed.u = note.updateNoteEntryId;
      break;
    case "priority":
      const priority = pretty as PriorityLogEntry;
      if (priority.priority !== undefined) compressed.pr = priority.priority;
      break;
    case "setParent":
      const setParent = pretty as SetParentLogEntry;
      if (setParent.parentId !== undefined) compressed.pI = setParent.parentId;
      break;
    case "addParent":
      const addParent = pretty as AddParentLogEntry;
      compressed.pI = addParent.parentId;
      if (addParent.isSlice !== undefined) compressed.iS = addParent.isSlice;
      if (addParent.displayedChildPath) compressed.dCP = addParent.displayedChildPath;
      break;
    case "removeParent":
      const removeParent = pretty as RemoveParentLogEntry;
      compressed.pI = removeParent.parentId;
      break;
    case "status":
      const status = pretty as StatusLogEntry;
      if (status.status !== undefined) compressed.s = status.status;
      if (status.startTime !== undefined) compressed.sT = status.startTime;
      if (status.endTime !== undefined) compressed.eT = status.endTime;
      break;
    case "archiveNote":
    case "archiveStatus":
    case "clearStatus":
    case "makeAnchor":
    case "clearAnchor":
    case "createInstance":
    case "clearDocumentContents":
      // No extra fields
      break;
    case "documentContents":
      (compressed as WireDocumentContentsLogEntry).te = (pretty as DocumentContentsLogEntry).text;
      break;
    case "docNote":
      const docNote = pretty as DocNoteLogEntry;
      if (docNote.kind !== undefined) compressed.k = canonicalDocNoteKind(docNote.kind);
      if (docNote.displayValue !== undefined) compressed.dV = docNote.displayValue;
      break;
  }

  // `te` is the shared text field even for module/extension entry types.
  // Keep it in the normal text-extraction path rather than wireExtras.
  if (Object.hasOwn(pretty, "text")) {
    compressed.te = (pretty as TextGoalLogEntry).text;
  }

  return compressed as WireGoalLogEntry;
}

export function expandLogEntry(compressed: WireGoalLogEntry): LogEntry {
  const c = compressed as any;
  const type =
    c.t === DOC_NOTE_ALIAS_ENTRY_TYPE
      ? "docNote"
      : Object.hasOwn(LOG_ENTRY_REVERSE_TYPE_MAP, c.t)
        ? LOG_ENTRY_REVERSE_TYPE_MAP[c.t] : c.t || "unknown";

  const pretty: any = wireModules.get(c.t)?.fromWire(compressed) ?? {
    id: c.i,
    creationTime: c.cT,
    type,
  };
  for (const [field, key] of Object.entries(LOG_ENTRY_FIELDS[type] ?? {})) {
    if (c[key] !== undefined) pretty[field] = c[key];
  }
  if (c.p) pretty.path = c.p;

  switch (type) {
    case "note":
      if (c.te !== undefined) pretty.text = c.te;
      if (c.u) pretty.updateNoteEntryId = c.u;
      break;
    case "documentContents":
      pretty.text = (c as WireNoteLogEntry | WireDocumentContentsLogEntry).te;
      break;
    case "priority":
      if (c.pr !== undefined) pretty.priority = c.pr;
      break;
    case "setParent":
      if (c.pI !== undefined) pretty.parentId = c.pI;
      break;
    case "addParent":
      pretty.parentId = c.pI;
      if (c.iS !== undefined) pretty.isSlice = c.iS;
      if (c.dCP) pretty.displayedChildPath = c.dCP;
      break;
    case "removeParent":
      pretty.parentId = c.pI;
      break;
    case "status":
      if (c.s !== undefined) pretty.status = c.s;
      if (c.sT !== undefined) pretty.startTime = c.sT;
      if (c.eT !== undefined) pretty.endTime = c.eT;
      break;
    case "docNote":
      if (c.k !== undefined) pretty.kind = canonicalDocNoteKind(c.k);
      if (c.dV !== undefined) pretty.displayValue = c.dV;
      break;
  }

  if (typeof c.te === "string" || c.te === null) pretty.text = c.te;

  // Keep fields the typed converter does not understand. Known fields stay
  // in their pretty form so later edits (especially extracted text) win.
  const extras = { ...c };
  for (const key of Object.keys(compressLogEntry(pretty))) delete extras[key];
  if (Object.keys(extras).length > 0) pretty.wireExtras = extras;

  return pretty as LogEntry;
}

export function compressOp(pretty: AnyOp): WireOp {
  const type = OP_TYPE_MAP[pretty.type] || pretty.type;
  const base: WireOp = {
    h: pretty.hlcTimestamp,
    i: pretty.id,
    v: pretty.version,
    t: type,
  };

  switch (pretty.type) {
    case "delta":
      const deltaOp = pretty as DeltaOp;
      return {
        ...base,
        d: {
          i: deltaOp.delta.id,
          ...(deltaOp.delta.text !== undefined ? { t: deltaOp.delta.text } : {}),
          ...(deltaOp.delta.logEntry ? { lE: compressLogEntry(deltaOp.delta.logEntry) } : {}),
        },
      } as WireDeltaOp;
    case "disable":
      const disableOp = pretty as DisableOp;
      return { ...base, oI: disableOp.opId } as WireDisableOp;
    case "enable":
      const enableOp = pretty as EnableOp;
      return { ...base, oI: enableOp.opId } as WireEnableOp;
    default:
      return base;
  }
}

export function expandOp(compressed: WireOp): AnyOp {
  const type = OP_REVERSE_TYPE_MAP[compressed.t] || compressed.t;
  const base: Op = {
    hlcTimestamp: compressed.h,
    id: compressed.i,
    version: compressed.v,
    type,
  };

  switch (type) {
    case "delta":
      const deltaOp = compressed as WireDeltaOp;
      return {
        ...base,
        delta: {
          id: deltaOp.d.i,
          ...(deltaOp.d.t !== undefined ? { text: deltaOp.d.t } : {}),
          ...(deltaOp.d.lE ? { logEntry: expandLogEntry(deltaOp.d.lE) } : {}),
        },
      } as DeltaOp;
    case "disable":
      const disableOp = compressed as WireDisableOp;
      return { ...base, opId: disableOp.oI } as DisableOp;
    case "enable":
      const enableOp = compressed as WireEnableOp;
      return { ...base, opId: enableOp.oI } as EnableOp;
    default:
      return base;
  }
}
