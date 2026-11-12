import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp, LogEntry } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { MemoryLocalStore } from "./local-store";
import { MemoryPersistenceService } from "./persistence";
import { SyncClient } from "./sync-client";

// Regressions for glass_goals_devkit#38: an op restored by an Enable op must
// keep its own id, so a later Disable of that op (the next Undo) finds it.
// The Dart suite (goals_core/test/sync/sync_client_undo_redo_test.dart)
// covers the same cases against the Dart SyncClient.

async function freshClient(): Promise<SyncClient> {
  const client = new SyncClient(null);
  await client.init();
  return client;
}

const textOf = (client: SyncClient, goalId: string) =>
  client.getGoals().get(goalId)?.text;

const noteTexts = (client: SyncClient, goalId: string) =>
  (client.getGoals().get(goalId)?.log ?? [])
    .filter((e) => e.type === "note")
    .map((e) => (e as unknown as { text: string }).text);

describe("SyncClient undo/redo keeps op identity (#38)", () => {
  it("undo after redo restores the earlier value", async () => {
    const client = await freshClient();
    await client.modifyGoal({ id: "g", text: "Original" });
    await client.modifyGoal({ id: "g", text: "Changed" });

    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
    await client.redo();
    expect(textOf(client, "g")).toBe("Changed");
    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
  });

  it("survives repeated undo/redo cycles", async () => {
    const client = await freshClient();
    await client.modifyGoal({ id: "g", text: "Original" });
    await client.modifyGoal({ id: "g", text: "Changed" });

    for (let cycle = 0; cycle < 4; cycle++) {
      await client.undo();
      expect(textOf(client, "g"), `undo, cycle ${cycle}`).toBe("Original");
      await client.redo();
      expect(textOf(client, "g"), `redo, cycle ${cycle}`).toBe("Changed");
    }

    // Unwind past the creation, then rewind both actions.
    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
    await client.undo();
    expect(client.getGoals().has("g")).toBe(false);
    await client.redo();
    expect(textOf(client, "g")).toBe("Original");
    await client.redo();
    expect(textOf(client, "g")).toBe("Changed");
    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
  });

  it("unwinds and rewinds interleaved edits to several goals", async () => {
    const client = await freshClient();
    await client.modifyGoal({ id: "a", text: "a1" });
    await client.modifyGoal({ id: "b", text: "b1" });
    await client.modifyGoal({ id: "a", text: "a2" });
    await client.modifyGoals([
      { id: "a", text: "a3" },
      { id: "b", text: "b2" },
    ]);

    const state = () => [textOf(client, "a") ?? null, textOf(client, "b") ?? null];
    const history: Array<Array<string | null>> = [
      ["a1", null],
      ["a1", "b1"],
      ["a2", "b1"],
      ["a3", "b2"],
    ];
    expect(state()).toEqual(history[3]);

    // Two full unwind/rewind passes: the second only works when every
    // re-enabled op is still addressable by its own id.
    for (let pass = 0; pass < 2; pass++) {
      for (let i = 2; i >= 0; i--) {
        await client.undo();
        expect(state(), `pass ${pass} undo to ${i}`).toEqual(history[i]);
      }
      await client.undo();
      expect(client.getGoals().has("a"), `pass ${pass} all undone`).toBe(false);
      for (let i = 0; i <= 3; i++) {
        await client.redo();
        expect(state(), `pass ${pass} redo to ${i}`).toEqual(history[i]);
      }
    }

    // A partial zig-zag in the middle of the stack.
    await client.undo();
    await client.undo();
    expect(state()).toEqual(history[1]);
    await client.redo();
    expect(state()).toEqual(history[2]);
    await client.undo();
    expect(state()).toEqual(history[1]);
    await client.redo();
    await client.redo();
    expect(state()).toEqual(history[3]);
  });

  it("toggles a metadata log entry through repeated undo/redo", async () => {
    const client = await freshClient();
    await client.modifyGoal({ id: "g", text: "Doc" });
    await client.modifyGoal({
      id: "g",
      logEntry: {
        id: "note-1",
        creationTime: 1,
        type: "note",
        text: "a note",
      } as unknown as LogEntry,
    });
    expect(noteTexts(client, "g")).toEqual(["a note"]);

    for (let cycle = 0; cycle < 3; cycle++) {
      await client.undo();
      expect(noteTexts(client, "g"), `undo, cycle ${cycle}`).toEqual([]);
      await client.redo();
      expect(noteTexts(client, "g"), `redo, cycle ${cycle}`).toEqual(["a note"]);
    }
    await client.undo();
    expect(noteTexts(client, "g")).toEqual([]);
    expect(textOf(client, "g")).toBe("Doc");
  });
});

describe("Enable/Disable of working ops keeps HLC order and identity (#38)", () => {
  const at = (timestamp: number) => new HLC(timestamp, 0, "remote").pack();
  const text = (id: string, value: string, timestamp: number): DeltaOp => ({
    hlcTimestamp: at(timestamp),
    id,
    version: 6,
    type: "delta",
    delta: { id: "g", text: value },
  });
  const toggle = (
    type: "disable" | "enable",
    id: string,
    opId: string,
    timestamp: number,
  ) => ({ hlcTimestamp: at(timestamp), id, version: 6, type, opId }) as AnyOp;

  it("applies a re-enabled op at its own HLC and lets it be disabled again", async () => {
    const client = await freshClient();
    await client.applyOps([
      text("zero", "zero", 1),
      text("one", "one", 2),
      text("two", "two", 3),
    ]);
    expect(textOf(client, "g")).toBe("two");

    // Re-enabling an older op while a newer one is live: the older op keeps
    // its place in HLC order, so the newer op still wins.
    await client.applyOps([toggle("disable", "d1", "one", 4)]);
    expect(textOf(client, "g")).toBe("two");
    await client.applyOps([toggle("enable", "e1", "one", 5)]);
    expect(textOf(client, "g")).toBe("two");

    await client.applyOps([toggle("disable", "d2", "two", 6)]);
    expect(textOf(client, "g")).toBe("one");
    // The re-enabled op must still be found by its own id.
    await client.applyOps([toggle("disable", "d3", "one", 7)]);
    expect(textOf(client, "g")).toBe("zero");
    await client.applyOps([toggle("enable", "e2", "two", 8)]);
    expect(textOf(client, "g")).toBe("two");
    await client.applyOps([toggle("enable", "e3", "one", 9)]);
    expect(textOf(client, "g")).toBe("two");
    await client.applyOps([toggle("disable", "d4", "two", 10)]);
    expect(textOf(client, "g")).toBe("one");
  });

  it("gives the same result when the toggles arrive in one batch", async () => {
    const ops = [
      text("zero", "zero", 1),
      text("one", "one", 2),
      text("two", "two", 3),
      toggle("disable", "d1", "one", 4),
      toggle("enable", "e1", "one", 5),
      toggle("disable", "d2", "two", 6),
      toggle("disable", "d3", "one", 7),
    ];
    const inOrder = await freshClient();
    await inOrder.applyOps(ops);
    const reversed = await freshClient();
    await reversed.applyOps([...ops].reverse());
    expect(textOf(inOrder, "g")).toBe("zero");
    expect(textOf(reversed, "g")).toBe("zero");
  });
});

describe("undo/redo replays the same after a restart (#38)", () => {
  async function restarted(
    persistence: MemoryPersistenceService,
    store: MemoryLocalStore,
  ): Promise<SyncClient> {
    await persistence.settled();
    const client = new SyncClient(persistence, store);
    await client.init();
    await client.loadGoal("g");
    return client;
  }

  /**
   * A fresh client that pulls the whole recorded history from a new server.
   * The memory server keeps only its latest saved batch, so it is seeded
   * from every op the first client stored.
   */
  async function replayedFromScratch(
    store: MemoryLocalStore,
  ): Promise<SyncClient> {
    const history = new MemoryPersistenceService(await store.getAllOps());
    return restarted(history, new MemoryLocalStore());
  }

  it("keeps undo after redo undone across a restart", async () => {
    const persistence = new MemoryPersistenceService();
    const store = new MemoryLocalStore();
    const client = new SyncClient(persistence, store);
    await client.init();
    await client.modifyGoal({ id: "g", text: "Original" });
    await client.modifyGoal({ id: "g", text: "Changed" });
    await client.undo();
    await client.redo();
    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
    await client.redo();
    await client.undo();
    expect(textOf(client, "g")).toBe("Original");
    await persistence.settled();
    await client.dispose();

    const reopened = await restarted(persistence, store);
    expect(textOf(reopened, "g")).toBe("Original");
    await reopened.dispose();

    // A fresh store replays the full history from the server.
    const replayed = await replayedFromScratch(store);
    expect(textOf(replayed, "g")).toBe("Original");
    await replayed.dispose();
  });

  it("keeps a redone value across a restart after repeated cycles", async () => {
    const persistence = new MemoryPersistenceService();
    const store = new MemoryLocalStore();
    const client = new SyncClient(persistence, store);
    await client.init();
    await client.modifyGoal({ id: "g", text: "Original" });
    await client.modifyGoal({ id: "g", text: "Changed" });
    for (let cycle = 0; cycle < 3; cycle++) {
      await client.undo();
      await client.redo();
    }
    expect(textOf(client, "g")).toBe("Changed");
    await persistence.settled();
    await client.dispose();

    const reopened = await restarted(persistence, store);
    expect(textOf(reopened, "g")).toBe("Changed");
    await reopened.dispose();

    const replayed = await replayedFromScratch(store);
    expect(textOf(replayed, "g")).toBe("Changed");
    await replayed.dispose();
  });
});
