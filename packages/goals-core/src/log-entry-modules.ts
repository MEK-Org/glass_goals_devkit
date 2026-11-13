import {
  registerLogEntryModule,
  type LogEntry,
  type WireGoalLogEntry,
} from "@thkp-eng/goals-types";
import {
  bookSectionLogEntryFromWire, bookSectionLogEntryToWire,
  type BookSectionLogEntry,
} from "./book-metadata";
import {
  caseGoalLogEntryFromWire, caseGoalLogEntryToWire,
  reporterGoalLogEntryFromWire, reporterGoalLogEntryToWire,
  type CaseGoalLogEntry, type ReporterGoalLogEntry,
} from "./case-metadata";

let registered = false;

/** Install the same book, case and course extensions used by the Dart app. */
export function registerCoreLogEntryModules(): void {
  if (registered) return;
  registerLogEntryModule({
    wireTypes: ["b", "bS"], types: ["b", "bS"],
    fromWire: (wire) => (wire as { t?: string }).t === "bS"
      ? bookSectionLogEntryFromWire(wire)!
      : { id: wire.i, creationTime: wire.cT, type: "b", ...(wire.p ? { path: wire.p } : {}) },
    toWire: (entry) => entry.type === "bS"
      ? bookSectionLogEntryToWire(entry as BookSectionLogEntry)
      : { i: entry.id, cT: entry.creationTime, t: "b", ...(entry.path ? { p: entry.path } : {}) },
  });
  registerLogEntryModule({
    wireTypes: ["case", "rep"], types: ["case", "rep"],
    fromWire: (wire) => caseGoalLogEntryFromWire(wire) ?? reporterGoalLogEntryFromWire(wire)!,
    toWire: (entry) => entry.type === "case"
      ? caseGoalLogEntryToWire(entry as CaseGoalLogEntry)
      : reporterGoalLogEntryToWire(entry as ReporterGoalLogEntry),
  });
  const courseFields = {
    classesFolderGoalId: "cfGI", textbookGoalId: "tGI",
    classMapping: "cM", assetFilename: "aF",
  };
  registerLogEntryModule({
    wireTypes: ["sPR"], types: ["sPR"],
    fromWire: (wire) => {
      const entry: LogEntry & Record<string, unknown> = {
        id: wire.i, creationTime: wire.cT, type: "sPR", ...(wire.p ? { path: wire.p } : {}),
      };
      for (const [field, key] of Object.entries(courseFields)) {
        entry[field] = (wire as unknown as Record<string, unknown>)[key];
      }
      return entry;
    },
    toWire: (entry) => {
      const wire: WireGoalLogEntry & Record<string, unknown> = {
        i: entry.id, cT: entry.creationTime, t: "sPR", ...(entry.path ? { p: entry.path } : {}),
      };
      for (const [field, key] of Object.entries(courseFields)) {
        const value = (entry as unknown as Record<string, unknown>)[field];
        if (value !== undefined) wire[key] = value;
      }
      return wire;
    },
  });
  registered = true;
}
