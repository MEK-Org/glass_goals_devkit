import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import {
  byHlc,
  compareHlc,
  extractEntryTextField,
  getAffectedGoalIdsFromDeltaOp,
  isDeltaOp,
  isDisableOp,
  isEnableOp,
  relationshipParentId,
} from "./op-utils";
import {
  GoalIndexEntry,
  MemorySyncRepository,
  SyncRepository,
} from "./sync-repository";

/**
 * Port of `LocalStore` in `goals_core/lib/src/sync/local_store.dart`: the
 * client's local op storage, indexed per goal so a goal can be loaded without
 * reading the full history.
 */
export interface LocalStore {
  cursor: string | null;
  lastSyncTime: Date | null;
  readonly clientId: string;
  /**
   * The number of times we've had to do a full sync because we were missing
   * ops; should be 0 in normal operation.
   */
  readonly fullSyncCount: number;

  init(): Promise<void>;
  incrementFullSyncCount(): void;

  setUnsyncedOps(ops: Iterable<AnyOp>): Promise<void>;
  /** Unsynced ops, deduped by id and sorted by HLC. */
  getUnsyncedOps(): AnyOp[];

  /**
   * Ids of unsynced ops whose push the server accepted. They remain unsynced
   * until the server sends them back, and are not pushed again.
   */
  getAckedOpIds(): Set<string>;
  setAckedOpIds(opIds: Iterable<string>): Promise<void>;

  storeSyncedOps(ops: Iterable<AnyOp>): Promise<void>;

  getIndexGoalIds(key: string): Set<string>;
  setIndexGoalIds(key: string, goalIds: Set<string>): void;

  loadSearchIndex(indexKey: string): Promise<string | null>;
  setSearchIndex(indexKey: string, indexData: string): Promise<void>;

  getAllOps(): Promise<AnyOp[]>;

  getOpsById(opIds: Iterable<string>): AnyOp[];
  loadOpsById(opIds: Iterable<string>): Promise<Array<AnyOp | null>>;

  loadString(key: string): Promise<string | null>;
  setString(key: string, value: string): Promise<void>;

  clear(): Promise<void>;

  loadOpsForGoal(goalId: string): Promise<AnyOp[]>;
}

export class CacheMissException extends Error {
  constructor(message: string) {
    super(`CacheMissException: ${message}`);
    this.name = "CacheMissException";
  }
}

/**
 * Port of the Dart `LruCache` (`goals_core/lib/src/util/lru_cache.dart`).
 * Reads and writes renew an entry's expiry. Once the cache holds more than
 * [cullingThreshold] entries, entries whose expiry has passed are dropped,
 * oldest first; unexpired entries are kept even past the threshold.
 */
class LruCache<V> {
  // Insertion order is expiry order: every touch re-inserts with a later one.
  private readonly entries = new Map<string, { value: V; expiry: number }>();

  constructor(
    private readonly cullingThreshold: number,
    private readonly maxAgeMs: number,
  ) {}

  get(key: string): V | null {
    const entry = this.entries.get(key);
    if (entry != null) {
      this.entries.delete(key);
      entry.expiry = Date.now() + this.maxAgeMs;
      this.entries.set(key, entry);
      return entry.value;
    }
    this.cull();
    return null;
  }

  put(key: string, value: V): void {
    this.entries.delete(key);
    this.entries.set(key, { value, expiry: Date.now() + this.maxAgeMs });
    this.cull();
  }

  clear(): void {
    this.entries.clear();
  }

  private cull(): void {
    if (this.entries.size <= this.cullingThreshold) return;
    for (const [key, entry] of this.entries) {
      if (entry.expiry >= Date.now()) break;
      this.entries.delete(key);
    }
  }
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function randomString(length: number): string {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  for (let i = 0; i < length; i++) {
    result += chars[Math.floor(Math.random() * chars.length)];
  }
  return result;
}

/**
 * Port of `CachingLocalStore`: an in-memory op cache and goal index over a
 * [SyncRepository]. Every stored op is indexed for each goal whose cold load
 * needs it: both ends of a relationship op, every historical parent of a
 * SetParent's child, and the goals of an Enable/Disable op's target.
 *
 * Like the Dart, op reads are batched: requests arriving within 10 ms of each
 * other (30 ms at most from the first) share one `repo.loadOps` call, and
 * goal index reads pending together share one `repo.loadGoalIndexEntries`
 * call. Concurrent requests for the same id share one read.
 */
export class CachingLocalStore implements LocalStore {
  protected readonly goalOpsIndexCache = new Map<string, GoalIndexEntry>();
  protected readonly opCache = new Map<string, AnyOp>();
  private readonly stringCache = new LruCache<string>(1000, 10 * 60 * 1000);
  /** Serializes op storage, like the Dart's `_opStorageQueue`. */
  private opStorageQueue: Promise<void> = Promise.resolve();
  private pendingStorage = 0;
  /** Serializes batched op reads, like the Dart's `_opReadQueue`. */
  private opReadQueue: Promise<void> = Promise.resolve();
  private readonly opLoadRequests = new Map<string, Deferred<AnyOp | null>>();
  private batchTimer: ReturnType<typeof setTimeout> | null = null;
  private batchStartTime: number | null = null;
  /** Serializes goal index reads, like the Dart's `_goalIndexReadQueue`. */
  private goalIndexReadQueue: Promise<void> = Promise.resolve();
  private readonly goalIndexLoadRequests = new Map<
    string,
    Deferred<GoalIndexEntry | null>
  >();

  constructor(readonly repo: SyncRepository) {}

  clearCaches(): void {
    this.stringCache.clear();
    this.opCache.clear();
    this.goalOpsIndexCache.clear();
  }

  evictCachedOps(before?: string | null): void {
    if (before == null) {
      this.opCache.clear();
      return;
    }
    for (const [id, op] of this.opCache) {
      if (compareHlc(op.hlcTimestamp, before) < 0) this.opCache.delete(id);
    }
  }

  get clientId(): string {
    let clientId = this.repo.clientId;
    if (clientId == null) {
      clientId = randomString(4);
      this.repo.clientId = clientId;
    }
    return clientId;
  }

  get cursor(): string | null {
    return this.repo.cursor;
  }

  set cursor(value: string | null) {
    if (value !== this.repo.cursor) {
      this.repo.cursor = value;
    }
  }

  get fullSyncCount(): number {
    return this.repo.fullSyncCount;
  }

  get lastSyncTime(): Date | null {
    return this.repo.lastSyncTime;
  }

  set lastSyncTime(value: Date | null) {
    this.repo.lastSyncTime = value;
  }

  incrementFullSyncCount(): void {
    this.repo.fullSyncCount++;
  }

  getUnsyncedOps(): AnyOp[] {
    return this.repo.getUnsyncedOps();
  }

  getAckedOpIds(): Set<string> {
    return this.repo.getAckedOpIds();
  }

  setAckedOpIds(opIds: Iterable<string>): Promise<void> {
    return this.repo.setAckedOpIds(opIds);
  }

  async init(): Promise<void> {
    await this.repo.init();
  }

  async setUnsyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    const opMap = new Map<string, AnyOp>();
    for (const op of ops) {
      opMap.set(op.id, op);
      // Eagerly store the text in the string box
      const text = extractEntryTextField(op);
      if (text) {
        this.stringCache.put(text.entryId, text.text);
        void this.repo.storeString(text.entryId, text.text);
      }
    }
    await this.repo.setUnsyncedOps([...opMap.values()].sort(byHlc));
  }

  private async getGoalIndexBatch(): Promise<void> {
    // Answer requests whose entry was cached after they were made.
    for (const [goalId, request] of [...this.goalIndexLoadRequests]) {
      const cached = this.goalOpsIndexCache.get(goalId);
      if (cached) {
        this.goalIndexLoadRequests.delete(goalId);
        request.resolve(cached);
      }
    }

    const goalIdsToLoad = [...this.goalIndexLoadRequests.keys()];
    if (goalIdsToLoad.length === 0) {
      return;
    }

    let entries: Map<string, GoalIndexEntry | null>;
    try {
      entries = await this.repo.loadGoalIndexEntries(goalIdsToLoad);
    } catch (error) {
      for (const goalId of goalIdsToLoad) {
        this.goalIndexLoadRequests.get(goalId)?.reject(error);
        this.goalIndexLoadRequests.delete(goalId);
      }
      return;
    }

    for (const goalId of goalIdsToLoad) {
      // Defensive, unlike the Dart: never replace an entry indexed while the
      // read was pending, since the repository copy may predate it.
      const entry =
        this.goalOpsIndexCache.get(goalId) ?? entries.get(goalId) ?? null;
      if (entry) {
        this.goalOpsIndexCache.set(goalId, entry);
      }
      this.goalIndexLoadRequests.get(goalId)?.resolve(entry);
      this.goalIndexLoadRequests.delete(goalId);
    }
  }

  private queuedGoalIndexGet(goalId: string): Promise<GoalIndexEntry | null> {
    const existing = this.goalIndexLoadRequests.get(goalId);
    if (existing) {
      return existing.promise;
    }
    const request = deferred<GoalIndexEntry | null>();
    this.goalIndexLoadRequests.set(goalId, request);
    this.goalIndexReadQueue = this.goalIndexReadQueue.then(() =>
      this.getGoalIndexBatch(),
    );
    return request.promise;
  }

  private async getGoalIndexEntry(goalId: string): Promise<GoalIndexEntry | null> {
    const cached = this.goalOpsIndexCache.get(goalId);
    if (cached) return cached;
    const entry = await this.queuedGoalIndexGet(goalId);
    // Another load may have indexed this goal while the read was pending.
    const current = this.goalOpsIndexCache.get(goalId);
    if (current) return current;
    if (entry) {
      this.goalOpsIndexCache.set(goalId, entry);
    }
    return entry;
  }

  private async computeNewGoalIndexEntry(
    goalId: string,
    op: AnyOp,
  ): Promise<GoalIndexEntry | null> {
    const currEntry = await this.getGoalIndexEntry(goalId);
    const indexedOpIds = new Set(currEntry?.opIds ?? []);
    if (indexedOpIds.has(op.id)) {
      return null;
    }
    indexedOpIds.add(op.id);
    return { opIds: [...indexedOpIds] };
  }

  /**
   * When a parent relationship is introduced out of order or late (e.g.
   * AddParent arrives after a subsequent SetParent was already stored), ensure
   * any later SetParent operations (and their EnableOp/DisableOp) targeting
   * this child are also indexed for [parentId] so cold reload of [parentId]
   * observes the detach.
   */
  private async indexLaterSetParentsForParent(
    parentId: string,
    childId: string,
    afterHlc: string,
    goalIndexEntriesToWrite: Map<string, GoalIndexEntry>,
  ): Promise<void> {
    const childOps = await this.loadOpsForGoal(childId);
    const laterSetParentOps = childOps.filter(
      (childOp): childOp is DeltaOp =>
        isDeltaOp(childOp) &&
        childOp.delta.logEntry?.type === "setParent" &&
        compareHlc(childOp.hlcTimestamp, afterHlc) > 0,
    );
    if (laterSetParentOps.length === 0) {
      return;
    }

    const laterSetParentOpIds = new Set(laterSetParentOps.map((o) => o.id));
    const opsToIndex: AnyOp[] = [...laterSetParentOps];
    for (const childOp of childOps) {
      if (
        (isEnableOp(childOp) || isDisableOp(childOp)) &&
        laterSetParentOpIds.has(childOp.opId)
      ) {
        opsToIndex.push(childOp);
      }
    }

    for (const opToIndex of opsToIndex) {
      const newEntry = await this.computeNewGoalIndexEntry(parentId, opToIndex);
      if (newEntry) {
        this.goalOpsIndexCache.set(parentId, newEntry);
        goalIndexEntriesToWrite.set(parentId, newEntry);
      }
    }
  }

  /**
   * Returns every goal whose cold load needs [op]. A SetParent records the
   * replacement parent but detaches all earlier parents. Keep it indexed for
   * each historical parent of its child so loading one of those old parents
   * can replay the detach instead of resurrecting a stale child row.
   */
  private async indexGoalIdsForSetParent(op: DeltaOp): Promise<Set<string>> {
    const goalIds = new Set(getAffectedGoalIdsFromDeltaOp(op));
    const childOps = await this.loadOpsForGoal(op.delta.id);
    for (const childOp of childOps) {
      if (!isDeltaOp(childOp)) continue;
      const parentId = relationshipParentId(childOp.delta.logEntry);
      if (parentId != null) goalIds.add(parentId);
    }
    return goalIds;
  }

  async loadOpsForGoal(goalId: string): Promise<AnyOp[]> {
    const entry = await this.getGoalIndexEntry(goalId);
    const indexedOpIds = entry?.opIds ?? [];
    if (indexedOpIds.length === 0) {
      return [];
    }
    const ops = await Promise.all(indexedOpIds.map((opId) => this.getOp(opId)));
    for (const op of ops) {
      if (op == null) {
        throw new CacheMissException(
          `Op not found in cache or repo for goal ${goalId}`,
        );
      }
    }
    return ops as AnyOp[];
  }

  private async getOpBatch(): Promise<void> {
    // Answer requests whose op was cached after they were made.
    for (const [opId, request] of [...this.opLoadRequests]) {
      const cached = this.opCache.get(opId);
      if (cached) {
        this.opLoadRequests.delete(opId);
        request.resolve(cached);
      }
    }

    const opsToLoad = [...this.opLoadRequests.keys()];
    if (opsToLoad.length === 0) {
      return;
    }

    let ops: Array<AnyOp | null>;
    try {
      ops = await this.repo.loadOps(opsToLoad);
    } catch (error) {
      for (const opId of opsToLoad) {
        this.opLoadRequests.get(opId)?.reject(error);
        this.opLoadRequests.delete(opId);
      }
      return;
    }

    opsToLoad.forEach((opId, i) => {
      this.opLoadRequests.get(opId)?.resolve(ops[i] ?? null);
      this.opLoadRequests.delete(opId);
    });
  }

  private executeBatch(): void {
    this.batchTimer = null;
    this.batchStartTime = null;
    this.opReadQueue = this.opReadQueue.then(() => this.getOpBatch());
  }

  private scheduleBatch(): void {
    this.batchStartTime ??= Date.now();
    if (this.batchTimer != null) clearTimeout(this.batchTimer);
    const elapsed = Date.now() - this.batchStartTime;
    const delay = Math.max(0, Math.min(10, 30 - elapsed));
    this.batchTimer = setTimeout(() => this.executeBatch(), delay);
  }

  private queuedOpGet(opId: string): Promise<AnyOp | null> {
    const existing = this.opLoadRequests.get(opId);
    if (existing) {
      return existing.promise;
    }
    const request = deferred<AnyOp | null>();
    this.opLoadRequests.set(opId, request);
    this.scheduleBatch();
    return request.promise;
  }

  private async getOp(opId: string): Promise<AnyOp | null> {
    const cached = this.opCache.get(opId);
    if (cached) return cached;
    const op = await this.queuedOpGet(opId);
    if (op == null) return null;
    this.opCache.set(opId, op);
    return op;
  }

  async storeSyncedOps(ops: Iterable<AnyOp>): Promise<void> {
    const batch = [...ops];
    // Synchronously update the caches.
    for (const op of batch) {
      this.opCache.set(op.id, op);
      const text = extractEntryTextField(op);
      if (text) this.stringCache.put(text.entryId, text.text);
    }

    // Queue storage behind any earlier batch.
    this.pendingStorage++;
    const run = this.opStorageQueue.then(() => this.doOpStorage(batch));
    this.opStorageQueue = run
      .catch(() => {})
      .finally(() => {
        this.pendingStorage--;
      });
    await run;
  }

  async getAllOps(): Promise<AnyOp[]> {
    const opMap = new Map<string, AnyOp>();
    const allOps = [
      ...(await this.repo.loadAllSyncedOps()),
      ...this.repo.getUnsyncedOps(),
    ];
    for (const op of allOps) {
      opMap.set(op.hlcTimestamp, op);
    }
    return [...opMap.values()];
  }

  async loadString(key: string): Promise<string | null> {
    return this.stringCache.get(key) ?? (await this.repo.loadString(key));
  }

  async setString(key: string, value: string): Promise<void> {
    this.stringCache.put(key, value);
    await this.repo.storeString(key, value);
  }

  /**
   * TS only: resolves once every op batch queued by [storeSyncedOps] so far
   * has been written to the repository, including batches queued while
   * waiting. The Dart has no equivalent; `SyncClient` does not await storage.
   */
  async settled(): Promise<void> {
    let queue: Promise<void>;
    do {
      queue = this.opStorageQueue;
      await queue;
    } while (queue !== this.opStorageQueue);
  }

  private async doOpStorage(ops: AnyOp[]): Promise<void> {
    const sortedOps = [...ops].sort(byHlc);
    const stringsToWrite = new Map<string, string>();
    const goalIndexEntriesToWrite = new Map<string, GoalIndexEntry>();
    const opsToWrite: AnyOp[] = [];
    let maxHlc: string | null = null;
    for (const op of sortedOps) {
      if (maxHlc == null || compareHlc(op.hlcTimestamp, maxHlc) > 0) {
        maxHlc = op.hlcTimestamp;
      }

      // Remove the op from unsyncedOps one at a time to avoid clobbering
      // other updates to unsyncedOps that may have happened while this
      // function was running.
      const unsyncedOps = this.repo.getUnsyncedOps();
      const index = unsyncedOps.findIndex((unsynced) => unsynced.id === op.id);
      if (index !== -1) {
        unsyncedOps.splice(index, 1);
        void this.setUnsyncedOps(unsyncedOps);
      }

      const text = extractEntryTextField(op);
      if (text) {
        stringsToWrite.set(text.entryId, text.text);
        opsToWrite.push(text.stripped);
      } else {
        opsToWrite.push(op);
      }
    }

    if (maxHlc != null) {
      this.repo.cursor = maxHlc;
    }

    await this.repo.storeStrings(stringsToWrite);
    await this.repo.storeSyncedOps(opsToWrite);

    // Index the ops for their goals
    for (const op of sortedOps) {
      if (isDeltaOp(op)) {
        const isSetParent = op.delta.logEntry?.type === "setParent";
        if (isSetParent) {
          const goalsWithSetParents = this.repo.getIndexGoalIds("goalsWithSetParents");
          if (!goalsWithSetParents.has(op.delta.id)) {
            goalsWithSetParents.add(op.delta.id);
            await this.repo.setIndexGoalIds("goalsWithSetParents", goalsWithSetParents);
          }
        }

        const affectedGoalIds = isSetParent
          ? await this.indexGoalIdsForSetParent(op)
          : getAffectedGoalIdsFromDeltaOp(op);
        for (const goalId of affectedGoalIds) {
          const newEntry = await this.computeNewGoalIndexEntry(goalId, op);
          if (newEntry) {
            this.goalOpsIndexCache.set(goalId, newEntry);
            goalIndexEntriesToWrite.set(goalId, newEntry);
          }
        }

        const entryType = op.delta.logEntry?.type;
        const introducedParentId =
          entryType === "addParent" || entryType === "setParent"
            ? relationshipParentId(op.delta.logEntry)
            : null;
        if (
          introducedParentId != null &&
          this.repo.getIndexGoalIds("goalsWithSetParents").has(op.delta.id)
        ) {
          await this.indexLaterSetParentsForParent(
            introducedParentId,
            op.delta.id,
            op.hlcTimestamp,
            goalIndexEntriesToWrite,
          );
        }
      } else if (isEnableOp(op) || isDisableOp(op)) {
        const affectedOp = await this.getOp(op.opId);
        if (affectedOp == null || !isDeltaOp(affectedOp)) {
          throw new Error(
            `Expected Enable/Disable Op to be a DeltaOp, but got: ${affectedOp?.type ?? null}`,
          );
        }
        const affectedGoalIds =
          affectedOp.delta.logEntry?.type === "setParent"
            ? await this.indexGoalIdsForSetParent(affectedOp)
            : getAffectedGoalIdsFromDeltaOp(affectedOp);
        for (const goalId of affectedGoalIds) {
          const newEntry = await this.computeNewGoalIndexEntry(goalId, op);
          if (newEntry) {
            this.goalOpsIndexCache.set(goalId, newEntry);
            goalIndexEntriesToWrite.set(goalId, newEntry);
          }
        }
      }
    }

    await this.repo.storeGoalIndexEntries(goalIndexEntriesToWrite);
  }

  async clear(): Promise<void> {
    if (this.pendingStorage > 0) {
      await this.opStorageQueue;
    }
    await this.repo.clear();
    this.stringCache.clear();
    this.opCache.clear();
  }

  async loadOpsById(opIds: Iterable<string>): Promise<Array<AnyOp | null>> {
    return Promise.all([...opIds].map((opId) => this.getOp(opId)));
  }

  getIndexGoalIds(key: string): Set<string> {
    return this.repo.getIndexGoalIds(key);
  }

  setIndexGoalIds(key: string, goalIds: Set<string>): void {
    void this.repo.setIndexGoalIds(key, goalIds);
  }

  async loadSearchIndex(indexKey: string): Promise<string | null> {
    return this.repo.loadSearchIndex(indexKey);
  }

  async setSearchIndex(indexKey: string, indexData: string): Promise<void> {
    await this.repo.setSearchIndex(indexKey, indexData);
  }

  getOpsById(opIds: Iterable<string>): AnyOp[] {
    return [...opIds].map((id) => {
      const op = this.opCache.get(id);
      if (!op) throw new CacheMissException(`Op ${id} is not cached`);
      return op;
    });
  }
}

/** Port of `MemoryLocalStore`: a caching store over a memory repository. */
export class MemoryLocalStore extends CachingLocalStore {
  constructor() {
    super(new MemorySyncRepository());
  }

  get cachedOps(): ReadonlyMap<string, AnyOp> {
    return this.opCache;
  }

  get goalIndex(): ReadonlyMap<string, GoalIndexEntry> {
    return this.goalOpsIndexCache;
  }

  get goalNameIndex(): Record<string, string> {
    return JSON.parse(this.repo.loadSearchIndex("goalNamesIndex") ?? "{}");
  }
}
