import { describe, expect, it } from "vitest";
import { compressLogEntry, expandLogEntry } from "@thkp-eng/goals-types";

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
});
