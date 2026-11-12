import { describe, expect, it } from "vitest";
import {
  AnyOp,
  DeltaOp,
  WireOp,
  compressOp,
  expandOp,
} from "@thkp-eng/goals-types";
import {
  DocNoteKind,
  DocNoteLogEntry,
  getDocNoteEntry,
  getDocNoteEntryFromLog,
} from "./doc-note-metadata";
import { SyncClient } from "./sync-client";

/**
 * Operation-level coverage for DocNoteLogEntry: the normal goals-types
 * `compressOp`/`expandOp` boundary is what SyncClient uses for import, export
 * and unsynced-op strings, so note configuration has to survive it.
 */

const KINDS: DocNoteKind[] = ["footnote", "endnote", "omittedFromExport"];
const DISPLAY_VALUES = ["", "#", "Note A"];
const PATH = ["parent-goal", "note-goal"];

function docNoteOp(kind: DocNoteKind, displayValue: string): DeltaOp {
  return {
    hlcTimestamp: "1700000000000:0000:test",
    id: `op-${kind}-${displayValue || "blank"}`,
    version: 6,
    type: "delta",
    delta: {
      id: "note-goal",
      logEntry: {
        id: `entry-${kind}-${displayValue || "blank"}`,
        creationTime: 1700000000000,
        path: PATH,
        type: "docNote",
        kind,
        displayValue,
      } as DocNoteLogEntry,
    },
  };
}

/** The wire shape Dart's DocNoteLogEntry.toJsonMap writes inside a DeltaOp. */
function dartWireOp(kind: DocNoteKind, displayValue: string): WireOp {
  return {
    h: "1700000000000:0000:dart",
    i: `dart-op-${kind}-${displayValue || "blank"}`,
    v: 6,
    t: "d",
    d: {
      i: "note-goal",
      lE: {
        i: `dart-entry-${kind}-${displayValue || "blank"}`,
        cT: 1700000000000,
        p: PATH,
        t: "docNote",
        k: kind,
        dV: displayValue,
      },
    },
  } as unknown as WireOp;
}

function logEntryOf(op: AnyOp): DocNoteLogEntry {
  return (op as DeltaOp).delta.logEntry as DocNoteLogEntry;
}

describe("DocNoteLogEntry through compressOp/expandOp", () => {
  for (const kind of KINDS) {
    for (const displayValue of DISPLAY_VALUES) {
      const label = `${kind} × ${JSON.stringify(displayValue)}`;

      it(`round-trips ${label} with its path`, () => {
        const op = docNoteOp(kind, displayValue);
        const wire = compressOp(op) as any;
        expect(wire.d.lE).toEqual({
          i: op.delta.logEntry!.id,
          cT: 1700000000000,
          p: PATH,
          t: "docNote",
          k: kind,
          dV: displayValue,
        });

        // Through a JSON string, as SyncClient import/export does.
        const restored = expandOp(JSON.parse(JSON.stringify(wire)));
        expect(restored).toEqual(op);
        expect(getDocNoteEntryFromLog([logEntryOf(restored)])).toEqual(
          op.delta.logEntry,
        );
      });

      it(`reads the Dart wire entry for ${label}`, () => {
        const wire = dartWireOp(kind, displayValue);
        const restored = expandOp(JSON.parse(JSON.stringify(wire)));
        expect(logEntryOf(restored)).toEqual({
          id: `dart-entry-${kind}-${displayValue || "blank"}`,
          creationTime: 1700000000000,
          path: PATH,
          type: "docNote",
          kind,
          displayValue,
        });
        // And writes it back byte-for-byte in the Dart shape.
        expect(compressOp(restored)).toEqual(wire);
      });
    }
  }

  it("normalises the omit alias to omittedFromExport on the wire", () => {
    const op = docNoteOp("omit", "x");
    const wire = compressOp(op) as any;
    expect(wire.d.lE.k).toBe("omittedFromExport");
    expect(logEntryOf(expandOp(wire)).kind).toBe("omittedFromExport");
  });

  it("leaves a goal with no docNote entry unconfigured (legacy fallback)", () => {
    const op: DeltaOp = {
      hlcTimestamp: "1700000000000:0000:test",
      id: "op-note",
      version: 6,
      type: "delta",
      delta: {
        id: "note-goal",
        logEntry: {
          id: "plain-note",
          creationTime: 1700000000000,
          type: "note",
          text: "body",
        },
      },
    };
    const restored = expandOp(JSON.parse(JSON.stringify(compressOp(op))));
    expect(restored).toEqual(op);
    expect(getDocNoteEntryFromLog([logEntryOf(restored)])).toBeNull();
  });
});

describe("DocNoteLogEntry through SyncClient undo/redo and restart", () => {
  function configure(
    id: string,
    kind: DocNoteKind,
    displayValue: string,
    creationTime: number,
  ) {
    return {
      id: "note-goal",
      logEntry: {
        id,
        creationTime,
        type: "docNote",
        kind,
        displayValue,
      } as DocNoteLogEntry,
    };
  }

  /** Re-opens the exported op strings in a fresh client, as a restart would. */
  async function reopen(opStrings: string[]) {
    const client = new SyncClient(null);
    await client.init();
    await client.applyOps(opStrings.map((s) => expandOp(JSON.parse(s))));
    await client.loadGoal("note-goal");
    const goal = client.getGoals().get("note-goal")!;
    client.dispose();
    return getDocNoteEntry(goal);
  }

  it("keeps the latest effective configuration across Disable, Enable and restart", async () => {
    const client = new SyncClient(null);
    await client.init();
    await client.modifyGoal({ id: "note-goal", text: "Note" });
    await client.modifyGoal(configure("cfg-1", "endnote", "#", 1000));
    await client.modifyGoal(configure("cfg-2", "omittedFromExport", "Lit", 2000));

    const current = () => getDocNoteEntry(client.getGoals().get("note-goal")!);
    expect(current()).toMatchObject({ kind: "omittedFromExport", displayValue: "Lit" });

    // Undo issues a DisableOp for cfg-2: cfg-1 becomes effective again.
    await client.undo();
    expect(current()).toMatchObject({ id: "cfg-1", kind: "endnote", displayValue: "#" });
    const afterUndo = client.getUnsyncedOpStrings();
    expect(afterUndo.map((s) => JSON.parse(s).t)).toContain("dO");
    expect(await reopen(afterUndo)).toMatchObject({
      id: "cfg-1",
      kind: "endnote",
      displayValue: "#",
    });

    // Redo issues an EnableOp for cfg-2.
    await client.redo();
    expect(current()).toMatchObject({ id: "cfg-2", kind: "omittedFromExport", displayValue: "Lit" });
    const afterRedo = client.getUnsyncedOpStrings();
    expect(afterRedo.map((s) => JSON.parse(s).t)).toContain("eO");
    expect(await reopen(afterRedo)).toMatchObject({
      id: "cfg-2",
      kind: "omittedFromExport",
      displayValue: "Lit",
    });

    // Undoing the first configuration leaves the goal unconfigured.
    await client.undo();
    await client.undo();
    expect(current()).toBeNull();
    expect(await reopen(client.getUnsyncedOpStrings())).toBeNull();
    client.dispose();
  });
});
