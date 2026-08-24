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
  GoalLogEntry,
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

const OP_REVERSE_TYPE_MAP = Object.fromEntries(
  Object.entries(OP_TYPE_MAP).map(([k, v]) => [v, k])
);

const LOG_ENTRY_REVERSE_TYPE_MAP = Object.fromEntries(
  Object.entries(LOG_ENTRY_TYPE_MAP).map(([k, v]) => [v, k])
);

export function compressLogEntry(pretty: LogEntry): WireGoalLogEntry {
  const compressed: any = {
    i: pretty.id,
    cT: pretty.creationTime,
  };
  if (pretty.path) compressed.p = pretty.path;
  if (pretty.type) compressed.t = LOG_ENTRY_TYPE_MAP[pretty.type] || pretty.type;

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
  }

  return compressed as WireGoalLogEntry;
}

export function expandLogEntry(compressed: WireGoalLogEntry): LogEntry {
  const c = compressed as any;
  const type = LOG_ENTRY_REVERSE_TYPE_MAP[c.t] || c.t || "unknown";

  const pretty: any = {
    id: c.i,
    creationTime: c.cT,
    type,
  };
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
  }

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
