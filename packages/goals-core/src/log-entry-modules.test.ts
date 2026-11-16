import { describe, expect, it } from "vitest";
import { compressLogEntry, expandLogEntry, isKnownLogEntryType, registerLogEntryModule } from "@thkp-eng/goals-types";
import { registerCoreLogEntryModules } from "./log-entry-modules";

registerCoreLogEntryModules();

describe("registered log-entry converters", () => {
  it.each([
    [{ t: "b" }, { type: "b" }],
    [{ t: "bS", sP: 10, sPF: "arabic", bI: "book" }, { startPage: 10, bookGoalId: "book" }],
    [{ t: "case", n: "Example v. Example", y: 2026 }, { name: "Example v. Example", year: 2026 }],
    [{ t: "rep", r: "F.3d", sP: 10, rI: 0 }, { reporter: "F.3d", startPage: 10, reporterIndex: 0 }],
    [{ t: "sPR", cfGI: "classes", tGI: "book", cM: [], aF: "syllabus.pdf" }, { classesFolderGoalId: "classes", textbookGoalId: "book" }],
  ])("decodes and recompresses %j with typed metadata", (fields, expected) => {
    const wire = { i: "entry", cT: 0, ...fields };
    const entry = expandLogEntry(wire);
    expect(entry).toMatchObject({ id: "entry", creationTime: 0, ...expected });
    expect(compressLogEntry(entry)).toEqual(wire);
    if (fields.t === "case") {
      const edited = { ...entry, name: "Edited case" };
      expect(compressLogEntry(edited)).toMatchObject({ n: "Edited case" });
    }
  });

  it("recognizes every Dart built-in and app-registered wire type", () => {
    for (const type of ["n", "aN", "s", "cS", "aS", "aSI", "aSR", "sP", "aP", "rP", "pCC", "p", "mA", "cA", "su", "cSu", "d", "cD", "cI", "lRO", "cM", "rA", "b", "bS", "case", "rep", "sPR", "docNote", "dN"]) {
      expect(isKnownLogEntryType(type), type).toBe(true);
    }
    for (const type of ["future-type", "__proto__", "toString", "note"]) expect(isKnownLogEntryType(type)).toBe(false);
  });

  it("delegates custom module conversion and can unregister it", () => {
    const unregister = registerLogEntryModule({
      wireTypes: ["test-module"], types: ["testModule"],
      fromWire: (wire: any) => ({ id: wire.i, creationTime: wire.cT, type: "testModule", value: wire.v }),
      toWire: (entry: any) => ({ i: entry.id, cT: entry.creationTime, t: "test-module", v: entry.value }),
    });
    try {
      const wire = { i: "test", cT: 123, t: "test-module", v: "typed", extension: true };
      expect(isKnownLogEntryType(wire.t)).toBe(true);
      expect(expandLogEntry(wire)).toMatchObject({ type: "testModule", value: "typed" });
      expect(compressLogEntry(expandLogEntry(wire))).toEqual(wire);
    } finally { unregister(); }
    expect(isKnownLogEntryType("test-module")).toBe(false);
  });
});
