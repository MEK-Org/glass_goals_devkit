import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import {
  CachingLocalStore,
  compareHlc,
  extractEntryTextField,
  LoadOpsResp,
  MemorySyncRepository,
  PersistenceService,
  SyncClient,
} from "./index";

const CRASH_CURSOR = "001794930789467:0006j: SVB5";
const PARENT_IMPORT_ID = "zYTiFzVSXYM4Sg";
const CORRUPTED_GOAL_ID = "cZoLug5RNb1VQA";
const MAUET_CH9_ID = "Uxy3JtLjb6VHSw";
const ROOT_TEST_GOAL_ID = "UWY6j_uIt4BNRQ";

class AppendServer implements PersistenceService {
  committed: AnyOp[] = [];
  strings = new Map<string, string>();
  failSave = false;
  loadCursors: Array<string | null> = [];
  private listeners = new Set<(ops: AnyOp[], cursor: string) => void>();

  constructor(initialOps: AnyOp[] = []) {
    for (const op of initialOps) {
      this.recordOp(op);
    }
    this.committed.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
  }

  private recordOp(op: AnyOp): void {
    this.committed = this.committed.filter((existing) => existing.id !== op.id);
    this.committed.push(op);
    const extracted = extractEntryTextField(op);
    if (extracted) {
      this.strings.set(extracted.entryId, extracted.text);
    }
  }

  async save(ops: Iterable<AnyOp>): Promise<void> {
    if (this.failSave) {
      throw new Error("offline");
    }
    for (const op of ops) {
      this.recordOp(op);
    }
    this.committed.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
  }

  async load({
    cursor = null,
    limit,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    this.loadCursors.push(cursor);
    const effectiveLimit = limit ?? 4000;
    const filtered = this.committed
      .filter(
        (op) => cursor == null || compareHlc(op.hlcTimestamp, cursor) > 0,
      )
      .sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp))
      .slice(0, effectiveLimit);
    return {
      ops: filtered,
      cursor:
        filtered.length > 0 ? filtered[filtered.length - 1].hlcTimestamp : cursor,
    };
  }

  async loadString(entryId: string): Promise<string | null> {
    return this.strings.get(entryId) ?? null;
  }

  async count(): Promise<number> {
    return this.committed.length;
  }

  subscribeJSON(
    _cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }
}

const titleOp = (
  id: string,
  hlc: string,
  goalId: string,
  text: string,
): DeltaOp => ({
  id,
  hlcTimestamp: hlc,
  version: 6,
  type: "delta",
  delta: { id: goalId, text },
});

const addParentOp = (
  id: string,
  hlc: string,
  goalId: string,
  parentId: string,
  ms: number,
): DeltaOp => ({
  id,
  hlcTimestamp: hlc,
  version: 6,
  type: "delta",
  delta: {
    id: goalId,
    logEntry: {
      type: "addParent",
      id: `parent-${id}`,
      creationTime: ms,
      parentId,
    },
  },
});

const noteOp = (
  id: string,
  hlc: string,
  goalId: string,
  entryId: string,
  text: string,
  ms: number,
): DeltaOp => ({
  id,
  hlcTimestamp: hlc,
  version: 6,
  type: "delta",
  delta: {
    id: goalId,
    logEntry: {
      type: "note",
      id: entryId,
      creationTime: ms,
      text,
    },
  },
});

function buildIncidentCorpus(): AnyOp[] {
  const fillers: AnyOp[] = [];
  for (let i = 0; i < 3998; i++) {
    fillers.push(
      titleOp(
        `op_filler_${i}`,
        `${String(1794930860000 + i).padStart(15, "0")}:00000:SVB5`,
        `filler_goal_${i % 50}`,
        `Filler ${i % 50}`,
      ),
    );
  }
  return [
    titleOp(
      "op_import_root",
      "001794930562329:00021:SVB5",
      PARENT_IMPORT_ID,
      "Test: Copyright and Artificial Intelligence, Part 3",
    ),
    titleOp(
      "op_cZo_old",
      "001794930562329:00022:SVB5",
      CORRUPTED_GOAL_ID,
      "V - LICENSING FOR AI TRAINING",
    ),
    addParentOp(
      "op_cZo_parent",
      "001794930562329:00023:SVB5",
      CORRUPTED_GOAL_ID,
      PARENT_IMPORT_ID,
      1794930562329,
    ),
    noteOp(
      "op_cZo_in_batch",
      "001794930858323:0007m:SVB5",
      CORRUPTED_GOAL_ID,
      "note-cZo-1",
      "Licensing note from SVB5",
      1794930858323,
    ),
    ...fillers,
    titleOp(
      "op_batch1_tail",
      "001794930965354:0004b:SVB5",
      PARENT_IMPORT_ID,
      "Test: Copyright and Artificial Intelligence, Part 3 (updated)",
    ),
    titleOp(
      "op_mauet_ch9",
      "001794934601337:0006q:FXH0",
      MAUET_CH9_ID,
      "Chapter 9 — Closing Arguments",
    ),
    titleOp(
      "JfqMHYUd_aNNRQ",
      "001794935913195:0000i:FXH0",
      ROOT_TEST_GOAL_ID,
      "Sync test — November 17, 17:19 UTC",
    ),
  ];
}

describe("Issue #375 CacheMissException recovery", () => {
  it("resolves incoming batch op already present in goalOpsIndex without CacheMissException", async () => {
    const corpus = buildIncidentCorpus();
    const repo = new MemorySyncRepository();
    repo.clientId = "SVB5";
    repo.cursor = CRASH_CURSOR;
    const preStore = new CachingLocalStore(repo);
    await preStore.storeSyncedOps(corpus.slice(0, 3));
    await preStore.settled();
    repo.cursor = CRASH_CURSOR;
    await repo.storeGoalIndexEntry(CORRUPTED_GOAL_ID, {
      opIds: ["op_cZo_old", "op_cZo_parent", "op_cZo_in_batch"],
    });
    await repo.setIndexGoalIds("rootGoals", new Set([PARENT_IMPORT_ID]));

    const pendingEdit = noteOp(
      "op_local_pending",
      "001794930990000:00001:SVB5",
      "localPendingGoal",
      "local-note-1",
      "Unsynced local note",
      1794930990000,
    );
    const localStore = new CachingLocalStore(repo);
    await localStore.setUnsyncedOps([pendingEdit]);

    const server = new AppendServer(corpus);
    server.failSave = true;
    const client = new SyncClient(server, localStore, { onError: () => {} });

    await client.init();
    await client.loadGoal(CORRUPTED_GOAL_ID);
    await client.loadGoal(MAUET_CH9_ID);
    await client.loadGoal(ROOT_TEST_GOAL_ID);

    expect(client.fullSyncCount).toBe(0);
    expect(client.stateSubject.value.get(CORRUPTED_GOAL_ID)?.text).toBe(
      "V - LICENSING FOR AI TRAINING",
    );
    expect(client.stateSubject.value.get(MAUET_CH9_ID)?.text).toBe(
      "Chapter 9 — Closing Arguments",
    );
    expect(client.stateSubject.value.get(ROOT_TEST_GOAL_ID)?.text).toBe(
      "Sync test — November 17, 17:19 UTC",
    );
    expect(localStore.getUnsyncedOps().map((op) => op.id)).toContain(
      "op_local_pending",
    );
    expect(await localStore.loadString("local-note-1")).toBe(
      "Unsynced local note",
    );
  });

  it("recovers from missing historical op in syncedOps, increments fullSyncCount, preserves unsyncedOps (offline save)", async () => {
    const corpus = buildIncidentCorpus();
    const repo = new MemorySyncRepository();
    repo.clientId = "SVB5";
    repo.cursor = CRASH_CURSOR;
    await repo.storeSyncedOps([corpus[0], corpus[2]]);
    await repo.storeGoalIndexEntry(PARENT_IMPORT_ID, {
      opIds: ["op_import_root", "op_cZo_parent"],
    });
    await repo.storeGoalIndexEntry(CORRUPTED_GOAL_ID, {
      opIds: ["op_cZo_old", "op_cZo_parent"],
    });
    await repo.setIndexGoalIds("rootGoals", new Set([PARENT_IMPORT_ID]));

    const pendingEdit = noteOp(
      "op_local_pending",
      "001794930990000:00001:SVB5",
      "localPendingGoal",
      "local-note-1",
      "Unsynced local note",
      1794930990000,
    );
    const localStore = new CachingLocalStore(repo);
    await localStore.setUnsyncedOps([pendingEdit]);
    await localStore.setAckedOpIds(["acked_unreceived_id"]);

    const server = new AppendServer(corpus);
    server.failSave = true;
    const client = new SyncClient(server, localStore, { onError: () => {} });

    await client.init();
    await client.loadGoal(CORRUPTED_GOAL_ID);
    await client.loadGoal(MAUET_CH9_ID);
    await client.loadGoal(ROOT_TEST_GOAL_ID);

    expect(client.fullSyncCount).toBe(1);
    expect(localStore.clientId).toBe("SVB5");
    expect(localStore.getAckedOpIds().has("acked_unreceived_id")).toBe(true);
    expect(localStore.getUnsyncedOps().map((op) => op.id)).toEqual([
      "op_local_pending",
    ]);
    expect(await localStore.loadString("local-note-1")).toBe(
      "Unsynced local note",
    );
    expect(server.loadCursors).toContain(null);
    expect(client.stateSubject.value.get(CORRUPTED_GOAL_ID)?.text).toBe(
      "V - LICENSING FOR AI TRAINING",
    );
    expect(client.stateSubject.value.get(MAUET_CH9_ID)?.text).toBe(
      "Chapter 9 — Closing Arguments",
    );
    expect(client.stateSubject.value.get(ROOT_TEST_GOAL_ID)?.text).toBe(
      "Sync test — November 17, 17:19 UTC",
    );
  });

  it("recovers from missing historical op and pushes preserved unsyncedOps when online", async () => {
    const corpus = buildIncidentCorpus();
    const repo = new MemorySyncRepository();
    repo.clientId = "SVB5";
    repo.cursor = CRASH_CURSOR;
    await repo.storeSyncedOps([corpus[0]]);
    await repo.storeGoalIndexEntry(CORRUPTED_GOAL_ID, {
      opIds: ["op_cZo_old", "op_cZo_parent"],
    });
    await repo.setIndexGoalIds("rootGoals", new Set([PARENT_IMPORT_ID]));

    const pendingEdit = titleOp(
      "op_local_pending",
      "001794930990000:00001:SVB5",
      "localPendingGoal",
      "Local Pending Title",
    );
    const localStore = new CachingLocalStore(repo);
    await localStore.setUnsyncedOps([pendingEdit]);

    const server = new AppendServer(corpus);
    const client = new SyncClient(server, localStore, { onError: () => {} });

    await client.init();
    await client.loadGoal(CORRUPTED_GOAL_ID);
    await client.loadGoal(MAUET_CH9_ID);
    await client.loadGoal(ROOT_TEST_GOAL_ID);

    expect(client.fullSyncCount).toBe(1);
    expect(server.committed.map((op) => op.id)).toContain("op_local_pending");
    expect(client.stateSubject.value.get("localPendingGoal")?.text).toBe(
      "Local Pending Title",
    );
    expect(client.stateSubject.value.get(ROOT_TEST_GOAL_ID)?.text).toBe(
      "Sync test — November 17, 17:19 UTC",
    );
  });

  it("recovers when CacheMissException occurs on loadGoal after quiet pull and coalesces concurrent loads", async () => {
    const corpus = buildIncidentCorpus();
    const latestCursor = corpus[corpus.length - 1].hlcTimestamp;
    const repo = new MemorySyncRepository();
    repo.clientId = "SVB5";
    repo.cursor = latestCursor;
    await repo.storeGoalIndexEntry(CORRUPTED_GOAL_ID, {
      opIds: ["op_cZo_old"],
    });
    await repo.storeGoalIndexEntry(MAUET_CH9_ID, {
      opIds: ["op_mauet_ch9"],
    });
    await repo.setIndexGoalIds("rootGoals", new Set([PARENT_IMPORT_ID]));

    const pendingEdit = titleOp(
      "op_local_pending",
      "001794930990000:00001:SVB5",
      "localPendingGoal",
      "Local Pending Title",
    );
    const localStore = new CachingLocalStore(repo);
    await localStore.setUnsyncedOps([pendingEdit]);

    const server = new AppendServer(corpus);
    server.failSave = true;
    const client = new SyncClient(server, localStore, { onError: () => {} });

    await client.init();
    const results = await Promise.all([
      client.loadGoal(CORRUPTED_GOAL_ID),
      client.loadGoal(MAUET_CH9_ID),
    ]);

    expect(client.fullSyncCount).toBe(1);
    expect(results[0]?.text).toBe("V - LICENSING FOR AI TRAINING");
    expect(results[1]?.text).toBe("Chapter 9 — Closing Arguments");
    expect(localStore.getUnsyncedOps().map((op) => op.id)).toEqual([
      "op_local_pending",
    ]);
  });

  it("seeds writer HLC from stored cursor and keeps repo.cursor monotonic", async () => {
    const futureMs = Date.now() + 3600_000;
    const futureCursor = `${String(futureMs).padStart(15, "0")}:0006j: SVB5`;
    const olderHlc = `${String(futureMs - 100_000).padStart(15, "0")}:00001:FXH0`;

    const repo = new MemorySyncRepository();
    repo.clientId = "SVB5";
    repo.cursor = futureCursor;
    const store = new CachingLocalStore(repo);
    const client = new SyncClient(null, store);

    await client.init();
    expect(compareHlc(client.hlc.pack(), futureCursor)).toBeGreaterThanOrEqual(
      0,
    );

    await store.storeSyncedOps([
      titleOp("op_older", olderHlc, "g_older", "Older Goal"),
    ]);
    await store.settled();
    expect(repo.cursor).toBe(futureCursor);
  });
});
