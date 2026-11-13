import { describe, expect, it } from "vitest";
import { compressLogEntry, expandLogEntry } from "@thkp-eng/goals-types";
import { extractEntryTextField } from "./op-utils";

describe("wire log-entry preservation", () => {
  it.each([
    { t: "case", n: "Example v. Example", c: "Court", y: 2026 },
    { t: "rep", r: "F.3d", sP: 10, rI: 0, cGI: "case-id" },
    { t: "cM", tGI: ["topic-1", "topic-2"] },
    { t: "rA", tGI: "topic-1", sP: 10, eP: 20 },
    { t: "future-type", data: { nested: [1, null, "value"] } },
    { t: "__proto__", data: "ordinary type name" },
    { t: "toString", data: "ordinary type name" },
    { t: "docNote", k: "endnote", dV: "*", extension: true },
    { t: "n", te: "Note", extension: { value: 1 } },
  ])("round-trips $t without dropping extension fields", (fields) => {
    const wire = { i: "entry-id", cT: 123, p: ["goal", "entry-id"], ...fields };
    expect(compressLogEntry(expandLogEntry(wire))).toEqual(wire);
  });

  it("lets edits and text stripping override the original wire fields", () => {
    const wire = {
      i: "entry-id", cT: 123, t: "d", te: "Original", extra: 42,
    };
    const entry = expandLogEntry(wire);
    const stripped = { ...entry, text: null, id: "new-id" };
    expect(compressLogEntry(stripped)).toEqual({
      i: "new-id", cT: 123, t: "d", te: null, extra: 42,
    });
  });

  it.each(["su", "pCC", "future-type"])(
    "extracts %s text through the shared string-storage path",
    (type) => {
      const wire = { i: "text-entry", cT: 123, t: type, te: "Exact text", pI: "parent" };
      const op = {
        id: "op", hlcTimestamp: "hlc", version: 6, type: "delta" as const,
        delta: { id: "goal", logEntry: expandLogEntry(wire) },
      };
      const extracted = extractEntryTextField(op)!;
      expect(extracted.text).toBe("Exact text");
      const stripped = extracted.stripped as typeof op;
      expect(compressLogEntry(stripped.delta.logEntry)).toEqual({ ...wire, te: null });
    },
  );
});
