export interface GoalLogEntry {
  id: string;
  creationTime: number;
  path?: string[];
  type: string;
}

export interface TextGoalLogEntry extends GoalLogEntry {
  text?: string | null;
}

export interface NoteLogEntry extends TextGoalLogEntry {
  type: "note";
  updateNoteEntryId?: string | null;
}

export interface PriorityLogEntry extends GoalLogEntry {
  type: "priority";
  priority?: number | null;
}

export interface SetParentLogEntry extends GoalLogEntry {
  type: "setParent";
  parentId?: string | null;
}

export interface AddParentLogEntry extends GoalLogEntry {
  type: "addParent";
  parentId: string;
  isSlice?: boolean;
  displayedChildPath?: string[];
}

export interface RemoveParentLogEntry extends GoalLogEntry {
  type: "removeParent";
  parentId: string;
}

export interface StatusLogEntry extends GoalLogEntry {
  type: "status";
  status?: string | null;
  startTime?: number | null;
  endTime?: number | null;
}

export interface ArchiveNoteLogEntry extends GoalLogEntry {
  type: "archiveNote";
}

export interface ArchiveStatusLogEntry extends GoalLogEntry {
  type: "archiveStatus";
}

export interface ClearStatusLogEntry extends GoalLogEntry {
  type: "clearStatus";
}

export interface MakeAnchorLogEntry extends GoalLogEntry {
  type: "makeAnchor";
}

export interface ClearAnchorLogEntry extends GoalLogEntry {
  type: "clearAnchor";
}

export interface CreateInstanceLogEntry extends GoalLogEntry {
  type: "createInstance";
}

export interface DocumentContentsLogEntry extends TextGoalLogEntry {
  type: "documentContents";
}

export interface ClearDocumentContentsLogEntry extends GoalLogEntry {
  type: "clearDocumentContents";
}

export type LogEntry =
  | NoteLogEntry
  | PriorityLogEntry
  | SetParentLogEntry
  | AddParentLogEntry
  | RemoveParentLogEntry
  | StatusLogEntry
  | ArchiveNoteLogEntry
  | ArchiveStatusLogEntry
  | ClearStatusLogEntry
  | MakeAnchorLogEntry
  | ClearAnchorLogEntry
  | CreateInstanceLogEntry
  | DocumentContentsLogEntry
  | ClearDocumentContentsLogEntry
  | GoalLogEntry;

export interface Op {
  hlcTimestamp: string;
  id: string;
  version: number;
  type: string;
}

export interface DeltaOp extends Op {
  type: "delta";
  delta: {
    id: string;
    text?: string | null;
    logEntry?: LogEntry;
  };
}

export interface DisableOp extends Op {
  type: "disable";
  opId: string;
}

export interface EnableOp extends Op {
  type: "enable";
  opId: string;
}

export interface GoalDelta {
  id: string;
  text?: string | null;
  logEntry?: LogEntry;
}

export type AnyOp = DeltaOp | DisableOp | EnableOp | Op;
