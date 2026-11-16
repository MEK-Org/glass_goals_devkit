import { describe, expect, it } from "vitest";
import {
  DOC_NOTE_ENTRY_TYPE,
  docNoteLogEntryFromWire,
  docNoteLogEntryToWire,
  getDocNoteEntry,
} from "./doc-note-metadata";
import { Goal } from "./model";

describe("DocNoteLogEntry", () => {
  it("converts between wire and pretty format across note kinds and display values", () => {
    // Footnote with custom display value
    const wireFootnote = {
      i: "note-1",
      cT: 1700000000000,
      t: DOC_NOTE_ENTRY_TYPE,
      k: "footnote",
      dV: "[1]",
    };
    const prettyFootnote = docNoteLogEntryFromWire(wireFootnote);
    expect(prettyFootnote).toEqual({
      id: "note-1",
      creationTime: 1700000000000,
      path: undefined,
      type: DOC_NOTE_ENTRY_TYPE,
      kind: "footnote",
      displayValue: "[1]",
    });
    expect(docNoteLogEntryToWire(prettyFootnote!)).toEqual(wireFootnote);

    // Endnote with blank chip
    const wireEndnote = {
      i: "note-2",
      cT: 1700000001000,
      t: DOC_NOTE_ENTRY_TYPE,
      k: "endnote",
      dV: "",
    };
    const prettyEndnote = docNoteLogEntryFromWire(wireEndnote);
    expect(prettyEndnote).toEqual({
      id: "note-2",
      creationTime: 1700000001000,
      path: undefined,
      type: DOC_NOTE_ENTRY_TYPE,
      kind: "endnote",
      displayValue: "",
    });
    expect(docNoteLogEntryToWire(prettyEndnote!)).toEqual(wireEndnote);

    // Omitted from export with # auto-numbering
    const wireOmit = {
      i: "note-3",
      cT: 1700000002000,
      t: DOC_NOTE_ENTRY_TYPE,
      k: "omittedFromExport",
      dV: "#",
    };
    const prettyOmit = docNoteLogEntryFromWire(wireOmit);
    expect(prettyOmit).toEqual({
      id: "note-3",
      creationTime: 1700000002000,
      path: undefined,
      type: DOC_NOTE_ENTRY_TYPE,
      kind: "omittedFromExport",
      displayValue: "#",
    });
    expect(docNoteLogEntryToWire(prettyOmit!)).toEqual(wireOmit);
  });

  it("handles wire aliases and variations", () => {
    // dN wire type and 'omit' alias
    const wire1 = {
      i: "note-wire-1",
      cT: 1700000000000,
      t: "dN",
      k: "omit",
      dV: "#",
    };
    const pretty1 = docNoteLogEntryFromWire(wire1);
    expect(pretty1?.kind).toBe("omittedFromExport");
    expect(pretty1?.displayValue).toBe("#");

    // long keys fallback
    const wire2 = {
      id: "note-wire-2",
      creationTime: 1700000000000,
      type: DOC_NOTE_ENTRY_TYPE,
      kind: "endnote",
      displayValue: "custom",
    };
    const pretty2 = docNoteLogEntryFromWire(wire2);
    expect(pretty2?.id).toBe("note-wire-2");
    expect(pretty2?.kind).toBe("endnote");
    expect(pretty2?.displayValue).toBe("custom");
  });

  it("preserves exact display strings", () => {
    const rawStrings = [
      "",
      "#",
      "   leading and trailing spaces   ",
      "§ 4.2",
      "a & b < c > \"d\"",
      "^footnote-1",
    ];

    for (const dV of rawStrings) {
      const wire = {
        i: "note-exact",
        cT: 1700000000000,
        t: DOC_NOTE_ENTRY_TYPE,
        k: "footnote",
        dV,
      };
      const pretty = docNoteLogEntryFromWire(wire);
      expect(pretty?.displayValue).toBe(dV);
      expect(docNoteLogEntryToWire(pretty!).dV).toBe(dV);
    }
  });

  describe("getDocNoteEntry query and undo ordering", () => {
    it("returns null when goal has no doc note entry (legacy absence)", () => {
      const goal = new Goal("g1", "Goal 1", new Date(1000));
      expect(getDocNoteEntry(goal)).toBeNull();
    });

    it("selects currently effective entry and respects undo / log ordering", () => {
      const goal = new Goal("g1", "Goal 1", new Date(1000));

      const entry1 = {
        id: "e1",
        creationTime: 1000,
        type: DOC_NOTE_ENTRY_TYPE,
        kind: "footnote" as const,
        displayValue: "",
      };
      const entry2 = {
        id: "e2",
        creationTime: 2000,
        type: DOC_NOTE_ENTRY_TYPE,
        kind: "endnote" as const,
        displayValue: "#",
      };
      const entry3 = {
        id: "e3",
        creationTime: 3000,
        type: DOC_NOTE_ENTRY_TYPE,
        kind: "omittedFromExport" as const,
        displayValue: "omitted",
      };

      goal.prependEntry(entry1);
      expect(getDocNoteEntry(goal)).toEqual(entry1);

      goal.prependEntry(entry2);
      expect(getDocNoteEntry(goal)).toEqual(entry2);

      goal.prependEntry(entry3);
      expect(getDocNoteEntry(goal)).toEqual(entry3);

      // Undo entry3
      goal.log.shift();
      expect(getDocNoteEntry(goal)).toEqual(entry2);

      // Undo entry2
      goal.log.shift();
      expect(getDocNoteEntry(goal)).toEqual(entry1);

      // Undo entry1
      goal.log.shift();
      expect(getDocNoteEntry(goal)).toBeNull();
    });
  });
});
