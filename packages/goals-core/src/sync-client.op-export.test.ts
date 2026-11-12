import { describe, expect, it } from "vitest";
import {
  AnyOp,
  DeltaOp,
  LogEntry,
  compressOp,
  expandOp,
} from "@thkp-eng/goals-types";
import { CachingLocalStore, MemoryLocalStore } from "./local-store";
import { MemoryPersistenceService } from "./persistence";
import { MemorySyncRepository } from "./sync-repository";
import { SyncClient } from "./sync-client";

// getAllOpStrings is the full raw-operation export ("Download All Ops"). Each
// op is wire JSON (compressOp); text log entries carry their body, which the
// local store keeps apart from the stripped op. Refs glass_goals_devkit#39.

/** Exercises every quoting/whitespace path JSON has to round-trip. */
const NOTE_BODY =
  'Line one\n\n  indented "quoted" \\ back\tslash — “curly” é 🧪\r\nend';
const DOC_BODY = "# Heading\n\n- item one\n- item two\n\nTrailing  spaces  ";

const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function settle(persistence: MemoryPersistenceService | null) {
  for (let i = 0; i < 3; i++) {
    await persistence?.settled();
    await pause(40);
  }
}

/** Runs the export, keeping each chunk exactly as the callback received it. */
async function exportChunks(client: SyncClient): Promise<string[][]> {
  const chunks: string[][] = [];
  await client.getAllOpStrings(async (chunk) => {
    chunks.push(chunk);
  });
  return chunks;
}

async function exportAll(client: SyncClient): Promise<string[]> {
  return (await exportChunks(client)).flat();
}

type Wire = { i: string; d?: { lE?: { i: string; t: string; te?: string | null } } };

function entryText(strings: string[], entryId: string): string | null | undefined {
  const wire = strings
    .map((s) => JSON.parse(s) as Wire)
    .find((w) => w.d?.lE?.i === entryId);
  expect(wire, `no exported op for entry ${entryId}`).toBeDefined();
  return wire!.d!.lE!.te;
}

const note = (id: string, text: string, extra: Partial<LogEntry> = {}): LogEntry =>
  ({ type: "note", id, creationTime: 1000, text, ...extra }) as LogEntry;
const docContents = (id: string, text: string): LogEntry =>
  ({ type: "documentContents", id, creationTime: 1000, text }) as LogEntry;

describe("SyncClient.getAllOpStrings exports text log entries (#39)", () => {
  it.each([
    ["note", "n", note("entry", NOTE_BODY)],
    ["documentContents", "d", docContents("entry", DOC_BODY)],
  ] as const)(
    "exports a %s entry with its exact body",
    async (_kind, wireType, logEntry) => {
      const client = new SyncClient(null);
      await client.init();
      await client.modifyGoal({ id: "g", text: "Goal" });
      await client.modifyGoal({ id: "g", logEntry });

      const strings = await exportAll(client);

      expect(strings).toHaveLength(2);
      const wire = strings.map((s) => JSON.parse(s)).find((w) => w.d?.lE);
      expect(wire.d.lE.t).toBe(wireType);
      expect(wire.d.lE.te).toBe((logEntry as { text: string }).text);
      const reopened = expandOp(wire) as DeltaOp;
      expect((reopened.delta.logEntry as { text?: string }).text).toBe(
        (logEntry as { text: string }).text,
      );
      client.dispose();
    },
  );

  it("hydrates bodies from the persisted string store after a cold restart", async () => {
    const persistence = new MemoryPersistenceService();
    const repo = new MemorySyncRepository();
    const first = new SyncClient(persistence, new CachingLocalStore(repo));
    await first.init();
    await first.modifyGoal({ id: "g", text: "Goal" });
    await first.modifyGoal({ id: "g", logEntry: note("n1", NOTE_BODY) });
    await first.modifyGoal({ id: "g", logEntry: docContents("d1", DOC_BODY) });
    await settle(persistence);
    first.dispose();

    // The synced ops are stored without their text; only the string store has it.
    const stored = (await repo.loadAllSyncedOps()) as DeltaOp[];
    const storedNote = stored.find((op) => op.delta?.logEntry?.id === "n1");
    expect((storedNote!.delta.logEntry as { text?: string | null }).text).toBeNull();
    expect(await repo.loadString("n1")).toBe(NOTE_BODY);

    // A new store over the same repository starts with an empty string cache.
    const cold = new SyncClient(persistence, new CachingLocalStore(repo));
    await cold.init();
    await settle(persistence);

    const strings = await exportAll(cold);
    expect(strings).toHaveLength(3);
    expect(entryText(strings, "n1")).toBe(NOTE_BODY);
    expect(entryText(strings, "d1")).toBe(DOC_BODY);
    cold.dispose();
  });

  it("fetches a body the local store lacks from the persistence service", async () => {
    // The server holds entry text apart from the op, as the stored op is stripped.
    const goal: DeltaOp = {
      id: "op-goal",
      hlcTimestamp: "000000000001000:00000:srv",
      version: 6,
      type: "delta",
      delta: { id: "g", text: "Goal" },
    };
    const strippedNote: DeltaOp = {
      id: "op-note",
      hlcTimestamp: "000000000002000:00000:srv",
      version: 6,
      type: "delta",
      delta: { id: "g", logEntry: note("n1", null as unknown as string) },
    };
    const persistence = new MemoryPersistenceService();
    await persistence.save([goal, strippedNote]);
    persistence.strings.set("n1", NOTE_BODY);

    const client = new SyncClient(persistence, new MemoryLocalStore());
    await client.init();
    await settle(persistence);
    expect(await client.localStore.loadString("n1")).toBeNull();

    const strings = await exportAll(client);
    expect(strings).toHaveLength(2);
    expect(entryText(strings, "n1")).toBe(NOTE_BODY);
    client.dispose();
  });

  it("round-trips a mixed metadata and text history through export and reopen", async () => {
    const persistence = new MemoryPersistenceService();
    const client = new SyncClient(persistence, new MemoryLocalStore());
    await client.init();
    await client.modifyGoals([
      { id: "root", text: "Root" },
      { id: "a", text: "Alpha" },
      { id: "b", text: "Beta" },
    ]);
    await client.modifyGoal({
      id: "a",
      logEntry: { type: "addParent", id: "ap", creationTime: 1001, parentId: "root" } as LogEntry,
    });
    await client.modifyGoal({ id: "a", logEntry: note("n1", NOTE_BODY) });
    await client.modifyGoal({
      id: "a",
      logEntry: { type: "priority", id: "pr", creationTime: 1002, priority: 3 } as LogEntry,
    });
    await client.modifyGoal({
      id: "a",
      logEntry: note("n1-edit", `${NOTE_BODY} (edited)`, { updateNoteEntryId: "n1" } as Partial<LogEntry>),
    });
    await client.modifyGoal({
      id: "b",
      logEntry: { type: "setParent", id: "sp", creationTime: 1003, parentId: "root" } as LogEntry,
    });
    await client.modifyGoal({ id: "b", logEntry: docContents("d1", DOC_BODY) });
    await client.modifyGoal({
      id: "b",
      logEntry: { type: "status", id: "st", creationTime: 1004, status: "active", startTime: 1004 } as LogEntry,
    });
    await client.modifyGoal({ id: "b", logEntry: note("n2", "") });
    await client.modifyGoal({ id: "b", text: "Beta renamed" });
    await client.undo(); // a disable op in the export
    await settle(persistence);
    // One more op left unsynced-at-export is still exported with its body.
    await client.modifyGoal({ id: "a", logEntry: note("n3", "late note") });

    const ops = await client.localStore.getAllOps();
    const strings = await exportAll(client);

    // Every op is exported once; metadata ops are their wire JSON unchanged.
    expect(strings).toHaveLength(ops.length);
    const bodies: Record<string, string> = {
      n1: NOTE_BODY,
      "n1-edit": `${NOTE_BODY} (edited)`,
      d1: DOC_BODY,
      n2: "",
      n3: "late note",
    };
    const byId = new Map(strings.map((s) => [JSON.parse(s).i as string, s]));
    expect(byId.size).toBe(ops.length);
    for (const op of ops) {
      const wire = compressOp(op) as Wire;
      const entryId = wire.d?.lE?.i;
      if (entryId != null && entryId in bodies) {
        wire.d!.lE!.te = bodies[entryId];
      }
      expect(JSON.parse(byId.get(op.id)!)).toEqual(wire);
      if (entryId == null || !(entryId in bodies)) {
        expect(byId.get(op.id)).toBe(JSON.stringify(compressOp(op)));
      }
    }

    // Reopen: a fresh server and client fed only the exported strings.
    const reopenedOps: AnyOp[] = strings.map((s) => expandOp(JSON.parse(s)));
    const persistence2 = new MemoryPersistenceService();
    await persistence2.save(reopenedOps);
    const reopened = new SyncClient(persistence2, new MemoryLocalStore());
    await reopened.init();
    await settle(persistence2);

    for (const [entryId, body] of Object.entries(bodies)) {
      expect(await reopened.loadString(entryId)).toBe(body);
    }
    for (const goalId of ["root", "a", "b"]) {
      const before = await client.loadGoal(goalId);
      const after = await reopened.loadGoal(goalId);
      expect(after?.text).toBe(before?.text);
      expect(after?.superGoalIds).toEqual(before?.superGoalIds);
      expect(after?.log.map((e) => [e.type, e.id])).toEqual(
        before?.log.map((e) => [e.type, e.id]),
      );
    }
    expect((await reopened.loadGoal("b"))?.text).toBe("Beta");

    // Exporting the reopened history gives back the same strings.
    const reexported = await exportAll(reopened);
    expect([...reexported].sort()).toEqual([...strings].sort());

    client.dispose();
    reopened.dispose();
  });

  it("flushes full chunks of text entries and delivers the final partial chunk", async () => {
    const client = new SyncClient(null);
    await client.init();
    const noteCount = 1500;
    await client.modifyGoal({ id: "g", text: "Goal" });
    await client.modifyGoals(
      Array.from({ length: noteCount }, (_, i) => ({
        id: "g",
        logEntry: note(`n${i}`, `body ${i}\n`),
      })),
    );

    let active = 0;
    let maxActive = 0;
    const chunks: string[][] = [];
    await client.getAllOpStrings(async (chunk) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await pause(1);
      chunks.push(chunk);
      active--;
    });

    // The callback is awaited: one chunk at a time, in order.
    expect(maxActive).toBe(1);
    expect(chunks.map((c) => c.length)).toEqual([1000, noteCount + 1 - 1000]);
    const wires = chunks.flat().map((s) => JSON.parse(s) as Wire);
    expect(new Set(wires.map((w) => w.i)).size).toBe(noteCount + 1);
    const bodies = new Map(
      wires.filter((w) => w.d?.lE).map((w) => [w.d!.lE!.i, w.d!.lE!.te]),
    );
    expect(bodies.size).toBe(noteCount);
    for (let i = 0; i < noteCount; i++) {
      expect(bodies.get(`n${i}`)).toBe(`body ${i}\n`);
    }
    client.dispose();
  });
});
