import { AnyOp } from "@thkp-eng/goals-types";

/** A goal's op index entry: the ids of every op its cold load needs. */
export interface GoalIndexEntry {
  opIds: string[];
}

/**
 * Port of `SyncRepository` in `goals_core/lib/src/sync/sync_repository.dart`:
 * the durable storage behind a `CachingLocalStore`.
 */
export interface SyncRepository {
  init(): Promise<void>;

  clientId: string | null;
  cursor: string | null;
  lastSyncTime: Date | null;
  fullSyncCount: number;
  version: number;

  getUnsyncedOps(): AnyOp[];
  setUnsyncedOps(ops: Iterable<AnyOp>): Promise<void>;

  getAckedOpIds(): Set<string>;
  setAckedOpIds(opIds: Iterable<string>): Promise<void>;

  loadString(key: string): Promise<string | null>;
  storeString(key: string, value: string): Promise<void>;
  storeStrings(values: Map<string, string>): Promise<void>;

  storeGoalIndexEntry(goalId: string, entry: GoalIndexEntry): Promise<void>;
  storeGoalIndexEntries(entries: Map<string, GoalIndexEntry>): Promise<void>;
  loadGoalIndexEntry(goalId: string): Promise<GoalIndexEntry | null>;
  loadGoalIndexEntries(
    goalIds: Iterable<string>,
  ): Promise<Map<string, GoalIndexEntry | null>>;

  loadOps(opIds: Iterable<string>): Promise<Array<AnyOp | null>>;
  storeSyncedOps(ops: Iterable<AnyOp>): Promise<void>;
  loadAllSyncedOps(): Promise<AnyOp[]>;

  getIndexGoalIds(key: string): Set<string>;
  setIndexGoalIds(key: string, goalIds: Set<string>): Promise<void>;

  loadSearchIndex(indexKey: string): string | null;
  setSearchIndex(indexKey: string, indexData: string): Promise<void>;

  clear(): Promise<void>;
}

/** Port of `MemorySyncRepository`. */
export class MemorySyncRepository implements SyncRepository {
  clientId: string | null = null;
  cursor: string | null = null;
  lastSyncTime: Date | null = null;
  fullSyncCount = 0;
  version = 0;
  private unsyncedOps: AnyOp[] = [];
  private ackedOpIds = new Set<string>();
  private strings = new Map<string, string>();
  private goalIndex = new Map<string, GoalIndexEntry>();
  private syncedOps = new Map<string, AnyOp>();
  private indexGoalIds = new Map<string, Set<string>>();
  private searchIndices = new Map<string, string>();

  async init(): Promise<void> {}

  getUnsyncedOps(): AnyOp[] {
    return [...this.unsyncedOps];
  }

  async setUnsyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    this.unsyncedOps = [...ops];
  }

  getAckedOpIds(): Set<string> {
    return new Set(this.ackedOpIds);
  }

  async setAckedOpIds(opIds: Iterable<string>): Promise<void> {
    this.ackedOpIds = new Set(opIds);
  }

  async loadString(key: string): Promise<string | null> {
    return this.strings.get(key) ?? null;
  }

  async storeString(key: string, value: string): Promise<void> {
    this.strings.set(key, value);
  }

  async storeStrings(values: Map<string, string>): Promise<void> {
    for (const [key, value] of values) this.strings.set(key, value);
  }

  async storeGoalIndexEntry(goalId: string, entry: GoalIndexEntry): Promise<void> {
    this.goalIndex.set(goalId, { opIds: [...entry.opIds] });
  }

  async storeGoalIndexEntries(entries: Map<string, GoalIndexEntry>): Promise<void> {
    for (const [goalId, entry] of entries) {
      this.goalIndex.set(goalId, { opIds: [...entry.opIds] });
    }
  }

  async loadGoalIndexEntry(goalId: string): Promise<GoalIndexEntry | null> {
    return this.goalIndex.get(goalId) ?? null;
  }

  async loadGoalIndexEntries(
    goalIds: Iterable<string>,
  ): Promise<Map<string, GoalIndexEntry | null>> {
    const result = new Map<string, GoalIndexEntry | null>();
    for (const goalId of goalIds) {
      result.set(goalId, this.goalIndex.get(goalId) ?? null);
    }
    return result;
  }

  async loadOps(opIds: Iterable<string>): Promise<Array<AnyOp | null>> {
    return [...opIds].map((opId) => this.syncedOps.get(opId) ?? null);
  }

  async storeSyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    for (const op of ops) this.syncedOps.set(op.id, op);
  }

  async loadAllSyncedOps(): Promise<AnyOp[]> {
    return [...this.syncedOps.values()];
  }

  getIndexGoalIds(key: string): Set<string> {
    return new Set(this.indexGoalIds.get(key) ?? []);
  }

  async setIndexGoalIds(key: string, goalIds: Set<string>): Promise<void> {
    this.indexGoalIds.set(key, new Set(goalIds));
  }

  loadSearchIndex(indexKey: string): string | null {
    return this.searchIndices.get(indexKey) ?? null;
  }

  async setSearchIndex(indexKey: string, indexData: string): Promise<void> {
    this.searchIndices.set(indexKey, indexData);
  }

  async clear(): Promise<void> {
    this.clientId = null;
    this.cursor = null;
    this.lastSyncTime = null;
    this.fullSyncCount = 0;
    this.version = 0;
    this.unsyncedOps = [];
    this.ackedOpIds.clear();
    this.strings.clear();
    this.goalIndex.clear();
    this.syncedOps.clear();
    this.indexGoalIds.clear();
    this.searchIndices.clear();
  }
}
