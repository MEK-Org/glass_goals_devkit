import {
  AnyOp,
  DeltaOp,
  DisableOp,
  EnableOp,
  GoalDelta,
  GoalLogEntry,
  LogEntry,
  compressOp,
  expandOp,
} from "@thkp-eng/goals-types";
import { Cupid } from "./cupid";
import { GoalSubjectRegistry } from "./goal-subject-registry";
import { HLC } from "./hlc";
import { CachingLocalStore, LocalStore, MemoryLocalStore } from "./local-store";
import { Goal, GoalInstance, GoalStatus } from "./model";
import {
  byHlc,
  compareHlc,
  getAffectedGoalIdsFromDeltaOp,
  isDeltaOp,
  isDisableOp,
  isEnableOp,
} from "./op-utils";
import { LoadOpsResp, PersistenceService } from "./persistence";
import { BehaviorSubject } from "./subject";

// Kept so existing imports of these from "./sync-client" keep working.
export { CachingLocalStore, MemoryLocalStore } from "./local-store";
export type { LocalStore } from "./local-store";

export type SyncStateCallback = (state: Map<string, Goal>) => void;

export interface SyncClientOptions {
  /**
   * Past this many resident goals, the least recently used unpinned goals are
   * evicted from memory. They are reloaded from the local store on demand.
   */
  residentSoftCap?: number;
  /** Receives errors from background work: remote batches, op storage, push. */
  onError?: (error: unknown) => void;
}

enum GoalLoadState {
  loading,
  fullyLoaded,
}

const GOAL_NAMES_INDEX_KEY = "goalNamesIndex";
const TEXT_ENTRY_TYPES = new Set(["note", "documentContents"]);

type ParentEntry = LogEntry & { parentId?: string | null; isSlice?: boolean };

/**
 * Port of the Dart `SyncClient` (`goals_core/lib/src/sync/sync_client.dart`).
 *
 * Goals are loaded lazily. [loadGoal] reads one goal's indexed ops from the
 * local store. Ops at or before the base cursor (the local store's cursor when
 * the client started) are folded into a per-goal base state. Later ops, and
 * every op received or created this session, are working ops, replayed over a
 * copy-on-write view of the base for each projection. Unpinned goals past
 * `residentSoftCap` are evicted least recently used first; [loadGoalRef] and
 * [watchGoals] pin goals.
 *
 * `stateSubject.value` holds the loaded goals only. It is not the whole graph.
 *
 * Behavior intentionally matches the Dart, including its known in-session
 * divergences (see SYNC_PARITY.md): a late op older than the base cursor, and
 * an Enable/Disable whose target is at or before the base cursor, are not
 * reflected until the client restarts.
 */
export class SyncClient {
  readonly stateSubject = new BehaviorSubject<Map<string, Goal>>(new Map());
  readonly syncSubject = new BehaviorSubject<string | null>(null);
  hlc!: HLC;
  syncFuture: Promise<void> = Promise.resolve();
  readonly residentSoftCap: number;

  /** TS-only diagnostics: delta ops applied while computing projections. */
  readonly stats = { appliedDeltaOps: 0 };

  readonly modificationMap = new Map<string, Set<string>>();
  undoStack: string[] = [];
  redoStack: string[] = [];

  private baseState = new Map<string, Goal>();
  private baseStateCursor: string | null = null;
  private lastEmittedStateOpCount: number | null = null;
  private readonly loadedSinceEmit = new Set<string>();
  private readonly emittedBaseStateOpIds = new Set<string>();
  private readonly emittedWorkingStateOpIds = new Set<string>();
  private readonly workingOps = new Map<string, AnyOp>();
  private readonly pushingOpIds = new Set<string>();
  private readonly goalLoadState = new Map<string, GoalLoadState>();
  private readonly pinCount = new Map<string, number>();
  /** Loads in flight per goal; their base entries must not be evicted. */
  private readonly loadingCount = new Map<string, number>();
  // The Dart records DateTime.now(); a monotonic counter gives the same order
  // without ties between touches in the same clock tick.
  private readonly lastAccessed = new Map<string, number>();
  private accessClock = 0;
  /** @internal */
  readonly goalSubjects = new GoalSubjectRegistry();
  private readonly indexers = new Map<string, (goal: Goal) => boolean>();
  private goalNamesIndex = new Map<string, string>();
  private unsubscribePersistence: (() => void) | null = null;
  private readonly onError: (error: unknown) => void;

  constructor(
    readonly persistenceService: PersistenceService | null = null,
    readonly localStore: LocalStore = new MemoryLocalStore(),
    { residentSoftCap = 2000, onError }: SyncClientOptions = {},
  ) {
    this.residentSoftCap = residentSoftCap;
    this.onError =
      onError ?? ((error) => console.error("[SyncClient]", error));
  }

  async init(): Promise<void> {
    await this.localStore.init();
    this.hlc = HLC.now(this.localStore.clientId);

    this.indexers.set("rootGoals", (goal) => this.isRootGoal(goal));
    this.indexers.set("statusGoals", (goal) => this.isStatusGoal(goal));

    await this.loadGoalNamesIndex();

    this.baseStateCursor = this.localStore.cursor;
    await this.sync();
    this.baseStateCursor = this.localStore.cursor;

    await Promise.all(
      [...this.getRootGoalIds()].map((goalId) => this.loadGoal(goalId)),
    );

    if (this.persistenceService) {
      this.unsubscribePersistence = this.persistenceService.subscribeJSON(
        this.localStore.cursor,
        (ops, cursor) => {
          this.handleRemoteOps(ops, cursor).catch(this.onError);
        },
      );
    }
  }

  private async handleRemoteOps(ops: AnyOp[], cursor: string): Promise<void> {
    this.localStore.cursor = cursor;
    for (const op of ops) {
      this.workingOps.set(op.id, op);
    }
    await this.persistOps(ops);
    const affectedIds = await this.computeAffectedGoalIds(ops);
    this.computeAndEmitUnsyncedState("remote ops received", affectedIds);
  }

  dispose(): void {
    this.stateSubject.close();
    this.syncSubject.close();
    this.goalSubjects.closeAll();
    this.unsubscribePersistence?.();
    this.unsubscribePersistence = null;
  }

  /**
   * Calls [callback] now with the current (loaded-goal) state, then with each
   * state the client emits. Returns a function that ends the subscription.
   */
  subscribe(callback: SyncStateCallback): () => void {
    callback(this.stateSubject.value);
    return this.stateSubject.subscribe(callback, false);
  }

  /** A copy of the current state: the loaded goals, not the whole graph. */
  getGoals(): Map<string, Goal> {
    return new Map(this.stateSubject.value);
  }

  /**
   * Applies already-synced ops as if they had arrived from the server, without
   * moving the cursor. Intended for tests and for clients with no
   * persistence service.
   */
  async applyOps(ops: AnyOp[]): Promise<void> {
    if (ops.length === 0) return;
    for (const op of ops) {
      this.workingOps.set(op.id, op);
    }
    await this.persistOps(ops);
    const affectedIds = await this.computeAffectedGoalIds(ops);
    this.computeAndEmitUnsyncedState("ops applied", affectedIds);
  }

  async modifyGoal(delta: GoalDelta): Promise<void> {
    await this.modifyGoalsInternal([delta]);
  }

  async modifyGoals(deltas: GoalDelta[]): Promise<void> {
    await this.modifyGoalsInternal(deltas);
  }

  async debugAddUnsyncedOps(ops: string[]): Promise<void> {
    const allOps = await this.localStore.getAllOps();
    const knownOps = new Set(allOps.map((op) => op.id));
    const opMap = new Map<string, AnyOp>();
    for (const op of ops) {
      const parsedOp = expandOp(JSON.parse(op));
      if (knownOps.has(parsedOp.id)) {
        continue;
      }
      opMap.set(parsedOp.hlcTimestamp, parsedOp);
    }
    void this.localStore.setUnsyncedOps([
      ...this.localStore.getUnsyncedOps(),
      ...opMap.values(),
    ]);
    void this.push();
  }

  get numUnsyncedOps(): number {
    return this.localStore.getUnsyncedOps().length;
  }

  get numResidentGoals(): number {
    return this.baseState.size;
  }

  get numPinnedGoals(): number {
    return this.pinCount.size;
  }

  /** @internal */
  _pin(goalId: string): void {
    this.pinCount.set(goalId, (this.pinCount.get(goalId) ?? 0) + 1);
    this.touch(goalId);
  }

  /** @internal */
  _unpin(goalId: string): void {
    const current = this.pinCount.get(goalId);
    if (current == null) {
      return;
    }
    if (current <= 1) {
      this.pinCount.delete(goalId);
    } else {
      this.pinCount.set(goalId, current - 1);
    }
  }

  /** @internal */
  _pinCountOf(goalId: string): number {
    return this.pinCount.get(goalId) ?? 0;
  }

  private touch(goalId: string): void {
    this.lastAccessed.set(goalId, ++this.accessClock);
  }

  private evict(goalId: string): void {
    this.baseState.delete(goalId);
    this.goalLoadState.delete(goalId);
    this.lastAccessed.delete(goalId);
  }

  private maybeEvict(): void {
    const overage = this.baseState.size - this.residentSoftCap;
    if (overage <= 0) return;
    const evictable = [...this.baseState.keys()]
      .filter(
        (id) =>
          (this.pinCount.get(id) ?? 0) === 0 && !this.loadingCount.has(id),
      )
      .sort((a, b) => {
        const aTime = this.lastAccessed.get(a);
        const bTime = this.lastAccessed.get(b);
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return -1;
        if (bTime == null) return 1;
        return aTime - bTime;
      });
    for (const id of evictable.slice(0, overage)) {
      this.evict(id);
    }
  }

  private isRootGoal(goal: Goal): boolean {
    return goal.superGoalIds.size === 0;
  }

  private isStatusGoal(goal: Goal): boolean {
    const now = Date.now();
    for (const entry of goal.log as Array<GoalLogEntry & Record<string, any>>) {
      if (entry.type === "clearStatus") {
        return false;
      }
      if (entry.type !== "status") {
        continue;
      }
      const { startTime, endTime, status } = entry;
      if (status === GoalStatus.Archived) {
        continue;
      }
      if (endTime == null) {
        if (status === GoalStatus.Active) {
          return true;
        }
        continue;
      }
      if (startTime == null) {
        if (endTime > now) {
          return true;
        }
        continue;
      }
      if (startTime > now || endTime > now) {
        return true;
      }
    }
    return false;
  }

  /**
   * The ids of every root goal: the store's root index, adjusted for working
   * and unsynced ops. Unlike the state, this covers goals that are not loaded.
   */
  getRootGoalIds(): Set<string> {
    const rootGoalIds = new Set(this.localStore.getIndexGoalIds("rootGoals"));
    for (const [goalId, goal] of this.projectUnsyncedOps()) {
      if (this.isRootGoal(goal)) {
        rootGoalIds.add(goalId);
      } else {
        rootGoalIds.delete(goalId);
      }
    }
    return rootGoalIds;
  }

  getStatusGoalIds(): string[] {
    const statusGoalIds = new Set(
      this.localStore.getIndexGoalIds("statusGoals"),
    );
    for (const [goalId, goal] of this.projectUnsyncedOps()) {
      if (this.isStatusGoal(goal)) {
        statusGoalIds.add(goalId);
      } else {
        statusGoalIds.delete(goalId);
      }
    }
    return [...statusGoalIds];
  }

  /** The goals the unsynced ops modify, as they would be with those ops. */
  private projectUnsyncedOps(): Map<string, Goal> {
    const clonedBase = new Map<string, Goal>();
    const workingState = this.computeStateFromBase(this.workingOps.values());
    for (const [id, goal] of workingState) {
      clonedBase.set(id, goal.clone());
    }
    const modifiedGoalIds = new Set<string>();
    const sortedOps = [...this.localStore.getUnsyncedOps()].sort(byHlc);
    const disabledOps = this.computeDisabledOps(sortedOps);
    for (const op of sortedOps) {
      if (!isDeltaOp(op) || disabledOps.has(op.id)) {
        continue;
      }
      for (const id of this.applyDeltaOp(clonedBase, op)) {
        modifiedGoalIds.add(id);
      }
    }
    const result = new Map<string, Goal>();
    for (const goalId of modifiedGoalIds) {
      const goal = clonedBase.get(goalId);
      if (goal) result.set(goalId, goal);
    }
    return result;
  }

  get cursor(): string | null {
    return this.localStore.cursor;
  }

  get fullSyncCount(): number {
    return this.localStore.fullSyncCount;
  }

  get lastSyncTime(): Date | null {
    return this.localStore.lastSyncTime;
  }

  getUnsyncedOpStrings(): string[] {
    return this.localStore
      .getUnsyncedOps()
      .map((op) => JSON.stringify(compressOp(op)));
  }

  async loadString(key: string): Promise<string | null> {
    const localString = await this.localStore.loadString(key);
    if (localString != null) {
      return localString;
    }
    if (this.persistenceService == null) {
      return null;
    }
    const remoteString = await this.persistenceService.loadString(key);
    if (remoteString == null) {
      return null;
    }
    void this.localStore.setString(key, remoteString);
    return remoteString;
  }

  async getAllOpStrings(
    handleChunk: (chunk: string[]) => Promise<void>,
  ): Promise<void> {
    const ops = await this.localStore.getAllOps();
    let result: string[] = [];
    const chunkSize = 1000;
    for (const op of ops) {
      const entry = isDeltaOp(op) ? op.delta.logEntry : undefined;
      if (entry == null || !TEXT_ENTRY_TYPES.has(entry.type)) {
        result.push(JSON.stringify(compressOp(op)));
        continue;
      }
      const wire = compressOp(op) as any;
      wire.d.l.te = await this.loadString(entry.id);
      result.push(JSON.stringify(wire));
      if (result.length >= chunkSize) {
        await handleChunk(result);
        result = [];
      }
    }
    if (result.length > 0) {
      await handleChunk(result);
    }
  }

  private processDeltas(deltas: Iterable<GoalDelta>): DeltaOp[] {
    const actionOpIds = new Set<string>();
    const deltaOps: DeltaOp[] = [];
    for (const delta of deltas) {
      this.hlc = this.hlc.increment();
      const op: DeltaOp = {
        id: Cupid.random().encode(),
        hlcTimestamp: this.hlc.pack(),
        version: 6,
        type: "delta",
        delta: { ...delta },
      };
      deltaOps.push(op);
      actionOpIds.add(op.id);
    }
    if (deltaOps.length === 0) {
      return [];
    }
    const actionId = Cupid.random().encode();
    this.modificationMap.set(actionId, actionOpIds);
    this.undoStack.push(actionId);
    this.redoStack = [];
    return deltaOps;
  }

  private async handleNewUnsyncedOps(newOps: AnyOp[]): Promise<void> {
    const unsyncedOps = this.localStore.getUnsyncedOps();
    void this.localStore.setUnsyncedOps([...unsyncedOps, ...newOps]);

    await this.push();

    const affectedGoalIds = await this.computeAffectedGoalIds(newOps);
    for (const goalId of affectedGoalIds) {
      if (this.goalLoadState.get(goalId) === GoalLoadState.fullyLoaded) {
        continue;
      }
      await this.loadGoal(goalId);
    }

    this.computeAndEmitUnsyncedState(
      "new unsynced ops, after goal loads",
      affectedGoalIds,
    );

    // Let listeners see the emission before goals are evicted.
    await Promise.resolve();
    this.maybeEvict();
  }

  private async computeAffectedGoalIds(
    ops: Iterable<AnyOp>,
  ): Promise<Set<string>> {
    const result = new Set<string>();

    const addDelta = (op: DeltaOp, restoring = false) => {
      for (const id of getAffectedGoalIdsFromDeltaOp(op)) result.add(id);
      if (op.delta.logEntry?.type === "setParent") {
        const goal = this.stateSubject.value.get(op.delta.id);
        for (const id of goal?.superGoalIds ?? []) result.add(id);
        if (restoring && goal) {
          for (const entry of goal.log as ParentEntry[]) {
            if (entry.type === "addParent" && entry.parentId != null) {
              result.add(entry.parentId);
            }
            if (entry.type === "setParent" && entry.parentId != null) {
              result.add(entry.parentId);
            }
          }
        }
      }
    };

    for (const op of ops) {
      if (isDeltaOp(op)) {
        addDelta(op);
      } else if (isEnableOp(op) || isDisableOp(op)) {
        let affectedOp = this.lookupOpInMemory(op.opId);
        affectedOp ??= (await this.localStore.loadOpsById([op.opId]))[0];
        if (affectedOp == null || !isDeltaOp(affectedOp)) {
          continue;
        }
        addDelta(affectedOp, true);
      }
    }
    return result;
  }

  private lookupOpInMemory(opId: string): AnyOp | null {
    const working = this.workingOps.get(opId);
    if (working) return working;
    for (const op of this.localStore.getUnsyncedOps()) {
      if (op.id === opId) return op;
    }
    return null;
  }

  private computeAndEmitUnsyncedState(
    _trigger: string,
    affectedGoalIds?: Set<string>,
  ): Map<string, Goal> {
    const opsToApply = [
      ...this.workingOps.values(),
      ...this.localStore.getUnsyncedOps(),
    ];
    const clonedBase = this.computeStateFromBase(opsToApply);
    for (const op of opsToApply) {
      this.emittedWorkingStateOpIds.add(op.id);
    }
    this.emitState(clonedBase, affectedGoalIds);
    return clonedBase;
  }

  /**
   * Returns the goal [goalId] in [goalMap], cloning it first if it is still
   * the base state's instance, so projections never mutate the base.
   */
  private ensureMutable(
    goalMap: Map<string, Goal>,
    goalId: string,
  ): Goal | null {
    const existing = goalMap.get(goalId);
    if (existing == null) return null;
    if (this.baseState.get(goalId) === existing) {
      const cloned = existing.clone();
      goalMap.set(goalId, cloned);
      return cloned;
    }
    return existing;
  }

  private computeStateFromBase(ops: Iterable<AnyOp>): Map<string, Goal> {
    const workingState = new Map(this.baseState);
    const effectiveOps = this.applyEnableAndDisableOps(ops);
    const sortedOps = [...effectiveOps].filter(isDeltaOp).sort(byHlc);
    const handledOpIds = new Set<string>();
    for (const op of sortedOps) {
      if (handledOpIds.has(op.id)) {
        continue;
      }
      handledOpIds.add(op.id);
      this.applyDeltaOp(workingState, op);
      this.stats.appliedDeltaOps++;
    }
    return workingState;
  }

  private emitState(
    newState: Map<string, Goal>,
    affectedGoalIds?: Set<string>,
  ): void {
    if (this.stateSubject.isClosed) return;
    const emittedStateOpCount =
      this.emittedBaseStateOpIds.size + this.emittedWorkingStateOpIds.size;
    const opsAdvanced = this.lastEmittedStateOpCount !== emittedStateOpCount;
    const stateAdvanced =
      opsAdvanced ||
      [...(affectedGoalIds ?? newState.keys())].some((id) =>
        this.loadedSinceEmit.has(id),
      );
    if (stateAdvanced) {
      this.lastEmittedStateOpCount = emittedStateOpCount;
      this.loadedSinceEmit.clear();
      this.stateSubject.add(newState);
    }

    const fanOutIds = affectedGoalIds ?? new Set(this.goalSubjects.subjectIds);
    for (const id of fanOutIds) {
      const subject = this.goalSubjects.get(id);
      if (subject == null) continue;
      const newValue = newState.get(id) ?? null;
      if (subject.value === newValue) continue;
      subject.add(newValue);
    }

    if (!stateAdvanced) return;
    const stateCursor = `${this.baseStateCursor}:${String(
      this.emittedWorkingStateOpIds.size,
    ).padStart(5, "0")}`;
    if (this.syncSubject.value === stateCursor) {
      return;
    }
    this.syncSubject.add(stateCursor);
  }

  private async modifyGoalsInternal(deltas: GoalDelta[]): Promise<void> {
    if (deltas.length === 0) {
      return;
    }
    const newOps = this.processDeltas(deltas);
    await this.handleNewUnsyncedOps(newOps);
  }

  async undo(): Promise<void> {
    const actionToUndo = this.undoStack.pop();
    if (actionToUndo == null) {
      return;
    }
    await this.undoAction(actionToUndo);
    this.redoStack.push(actionToUndo);
  }

  async redo(): Promise<void> {
    const actionToRedo = this.redoStack.pop();
    if (actionToRedo == null) {
      return;
    }
    await this.redoAction(actionToRedo);
    this.undoStack.push(actionToRedo);
  }

  private async undoAction(actionId: string): Promise<void> {
    const actionOpIds = this.modificationMap.get(actionId);
    if (actionOpIds == null) {
      throw new Error(`Action not found: ${actionId}`);
    }
    const newOps: AnyOp[] = [];
    for (const opId of actionOpIds) {
      this.hlc = this.hlc.increment();
      const op: DisableOp = {
        id: Cupid.random().encode(),
        hlcTimestamp: this.hlc.pack(),
        version: 6,
        type: "disable",
        opId,
      };
      newOps.push(op);
    }
    await this.handleNewUnsyncedOps(newOps);
  }

  private async redoAction(actionId: string): Promise<void> {
    const actionOpIds = this.modificationMap.get(actionId);
    if (actionOpIds == null) {
      throw new Error(`Action not found: ${actionId}`);
    }
    const newOps: AnyOp[] = [];
    for (const opId of actionOpIds) {
      this.hlc = this.hlc.increment();
      const op: EnableOp = {
        id: Cupid.random().encode(),
        hlcTimestamp: this.hlc.pack(),
        version: 6,
        type: "enable",
        opId,
      };
      newOps.push(op);
    }
    await this.handleNewUnsyncedOps(newOps);
  }

  /**
   * Walks the `superGoalIds` frontier upward looking for [goalId]; returns
   * true if reaching it means the prospective edge would close a cycle.
   *
   * A frontier parent that is not loaded fails open: the Dart allows the edge
   * rather than dropping a legitimate one. Do not "harden" that.
   */
  private checkCycles(
    goalMap: Map<string, Goal>,
    goalId: string,
    frontierIds: Set<string>,
    seenIds: Set<string>,
  ): boolean {
    if (frontierIds.size === 0) {
      return false;
    }
    if (frontierIds.has(goalId)) {
      return true;
    }
    const newFrontierIds = new Set<string>();
    for (const parentId of frontierIds) {
      const parent = goalMap.get(parentId);
      if (parent == null) {
        return false;
      }
      for (const superGoalId of parent.superGoalIds) {
        if (superGoalId === goalId) {
          return true;
        }
        if (!seenIds.has(superGoalId)) {
          newFrontierIds.add(superGoalId);
          seenIds.add(superGoalId);
        }
      }
    }
    return this.checkCycles(goalMap, goalId, newFrontierIds, seenIds);
  }

  private evaluateSuperGoals(
    goalMap: Map<string, Goal>,
    goal: Goal,
    entry: LogEntry | undefined,
  ): Set<string> {
    const modifiedGoalIds = new Set<string>();
    const relationship = entry as ParentEntry | undefined;
    if (relationship?.type === "setParent") {
      const priorSuperGoalIds = [...goal.superGoalIds];
      for (const superGoalId of priorSuperGoalIds) {
        this.ensureMutable(goalMap, superGoalId)?.removeSubGoal(goal.id);
        modifiedGoalIds.add(superGoalId);
      }
      goal.superGoalRelationships.clear();
      modifiedGoalIds.add(goal.id);

      const newParentId = relationship.parentId;
      if (newParentId == null) {
        return modifiedGoalIds;
      }
      const newSuperGoal = this.ensureMutable(goalMap, newParentId);
      if (
        newSuperGoal != null &&
        this.checkCycles(
          goalMap,
          goal.id,
          new Set([newSuperGoal.id]),
          new Set([newSuperGoal.id]),
        )
      ) {
        // Reject both sides of an edge that would close a cycle.
        return modifiedGoalIds;
      }
      goal.addSuperGoal(newParentId, relationship as any);
      newSuperGoal?.addSubGoal(goal.id, relationship as any);
      modifiedGoalIds.add(newParentId);
    } else if (relationship?.type === "addParent") {
      const parentId = relationship.parentId!;
      const childId = relationship.isSlice ? relationship.id : goal.id;
      const newSuperGoal = this.ensureMutable(goalMap, parentId);
      if (
        newSuperGoal != null &&
        this.checkCycles(
          goalMap,
          childId,
          new Set([newSuperGoal.id]),
          new Set([newSuperGoal.id]),
        )
      ) {
        return modifiedGoalIds;
      }
      goal.addSuperGoal(parentId, relationship as any);
      newSuperGoal?.addSubGoal(goal.id, relationship as any);
      modifiedGoalIds.add(goal.id);
      modifiedGoalIds.add(parentId);
    } else if (relationship?.type === "removeParent") {
      const parentId = relationship.parentId!;
      goal.removeSuperGoal(parentId);
      modifiedGoalIds.add(goal.id);
      this.ensureMutable(goalMap, parentId)?.removeSubGoal(goal.id);
      modifiedGoalIds.add(parentId);
    }
    return modifiedGoalIds;
  }

  private applyDeltaOp(goalMap: Map<string, Goal>, op: DeltaOp): Set<string> {
    const modifiedGoalIds = new Set<string>();
    const opHlc = HLC.unpack(op.hlcTimestamp);
    this.hlc = this.hlc.receive(opHlc);
    this.touch(op.delta.id);

    let goal = goalMap.get(op.delta.id);
    if (goal == null) {
      goal = new Goal(
        op.delta.id,
        op.delta.text ?? undefined,
        new Date(opHlc.timestamp),
      );
      modifiedGoalIds.add(op.delta.id);
      goalMap.set(op.delta.id, goal);
    } else {
      goal = this.ensureMutable(goalMap, op.delta.id)!;
    }

    if (op.delta.text != null && goal.text !== op.delta.text) {
      goal.text = op.delta.text;
      modifiedGoalIds.add(op.delta.id);
    }

    const entry = op.delta.logEntry;
    if (entry != null) {
      // Dedup on (id, type), like the Dart's (id, runtimeType).
      if (!goal.log.some((e) => e.id === entry.id && e.type === entry.type)) {
        goal.prependEntry(entry as any);
        modifiedGoalIds.add(op.delta.id);
        if (entry.type === "createInstance") {
          goalMap.set(
            entry.id,
            new GoalInstance(goal, entry.id, new Date(entry.creationTime)),
          );
          modifiedGoalIds.add(entry.id);
        }
      }
      // Evaluate parents even for a known entry: an Enable can re-apply it.
      for (const id of this.evaluateSuperGoals(goalMap, goal, entry)) {
        modifiedGoalIds.add(id);
      }
    }
    return modifiedGoalIds;
  }

  private computeDisabledOps(ops: Iterable<AnyOp> = []): Map<string, string> {
    const disabledOps = new Map<string, string>();
    const allOps = [
      ...ops,
      ...this.workingOps.values(),
      ...this.localStore.getUnsyncedOps(),
    ].sort(byHlc);
    for (const op of allOps) {
      if (isDisableOp(op)) {
        disabledOps.set(op.opId, op.id);
      } else if (isEnableOp(op)) {
        disabledOps.delete(op.opId);
      }
    }
    return disabledOps;
  }

  /**
   * Loads the goals [newSyncedOps] affect, applies the ops, updates the root,
   * status and name indices, and queues the ops for local storage. Returns the
   * state with the working ops and [newSyncedOps] applied.
   */
  private async persistOps(
    newSyncedOps: AnyOp[],
    loadAffectedGoals = true,
  ): Promise<Map<string, Goal>> {
    if (newSyncedOps.length === 0) {
      return this.computeStateFromBase(this.workingOps.values());
    }

    const affectedGoalIds = await this.computeAffectedGoalIds(newSyncedOps);
    for (const goalId of affectedGoalIds) {
      this.touch(goalId);
    }

    if (loadAffectedGoals) {
      const loads: Promise<unknown>[] = [];
      for (const goalId of affectedGoalIds) {
        if (this.goalLoadState.get(goalId) === GoalLoadState.fullyLoaded) {
          continue;
        }
        this.goalLoadState.set(goalId, GoalLoadState.loading);
        loads.push(this.loadGoal(goalId));
      }
      await Promise.all(loads);
    } else {
      for (const goalId of affectedGoalIds) {
        this.goalLoadState.set(goalId, GoalLoadState.fullyLoaded);
      }
    }

    const state = this.computeStateFromBase(
      this.workingOps.size === 0
        ? newSyncedOps
        : [...this.workingOps.values(), ...newSyncedOps],
    );

    const newIndexValues = new Map<string, Set<string>>();
    for (const indexKey of this.indexers.keys()) {
      newIndexValues.set(indexKey, this.localStore.getIndexGoalIds(indexKey));
    }
    for (const goalId of affectedGoalIds) {
      for (const [indexKey, indexer] of this.indexers) {
        const goal = state.get(goalId);
        const index = newIndexValues.get(indexKey)!;
        if (goal == null) {
          index.delete(goalId);
          continue;
        }
        if (indexer(goal)) {
          index.add(goal.id);
        } else {
          index.delete(goal.id);
        }
      }
    }
    for (const [indexKey, goalIds] of newIndexValues) {
      this.localStore.setIndexGoalIds(indexKey, goalIds);
    }

    for (const goalId of affectedGoalIds) {
      const goal = state.get(goalId);
      if (goal == null) {
        this.removeGoalName(goalId);
      } else {
        const normalizedText = goal.text.toLowerCase();
        if (normalizedText.length > 0) {
          this.removeGoalName(goalId);
          this.goalNamesIndex.set(normalizedText, goalId);
        }
      }
    }
    if (affectedGoalIds.size > 0) {
      this.saveGoalNamesIndex().catch(this.onError);
    }

    this.acknowledgeReceivedOps(newSyncedOps);
    this.localStore.storeSyncedOps(newSyncedOps).catch(this.onError);
    this.maybeEvict();
    return state;
  }

  private removeGoalName(goalId: string): void {
    for (const [name, id] of this.goalNamesIndex) {
      if (id === goalId) this.goalNamesIndex.delete(name);
    }
  }

  /**
   * Loads one goal from its indexed ops in the local store, unless it is
   * already loaded. Returns the goal, or null if the store has no ops for it.
   */
  async loadGoal(goalId: string): Promise<Goal | null> {
    if (this.goalLoadState.get(goalId) === GoalLoadState.fullyLoaded) {
      this.touch(goalId);
      return this.stateSubject.value.get(goalId) ?? null;
    }

    // Another load's eviction must not drop this goal's base entry between
    // installing it and marking the goal fully loaded.
    this.loadingCount.set(goalId, (this.loadingCount.get(goalId) ?? 0) + 1);
    let loading = true;
    const unprotect = () => {
      if (!loading) return;
      loading = false;
      const count = this.loadingCount.get(goalId)!;
      if (count <= 1) {
        this.loadingCount.delete(goalId);
      } else {
        this.loadingCount.set(goalId, count - 1);
      }
    };
    try {
      return await this.loadUnloadedGoal(goalId, unprotect);
    } finally {
      unprotect();
    }
  }

  private async loadUnloadedGoal(
    goalId: string,
    unprotect: () => void,
  ): Promise<Goal | null> {
    const baseStateCursor = this.baseStateCursor;
    const opsToApply = await this.localStore.loadOpsForGoal(goalId);
    if (opsToApply.length === 0) {
      this.goalLoadState.set(goalId, GoalLoadState.fullyLoaded);
      this.touch(goalId);
      return null;
    }

    const baseOps: AnyOp[] = [];
    const workingOps: AnyOp[] = [];
    for (const op of opsToApply) {
      if (
        baseStateCursor != null &&
        compareHlc(op.hlcTimestamp, baseStateCursor) <= 0
      ) {
        baseOps.push(op);
      } else {
        workingOps.push(op);
      }
    }

    if (baseOps.length > 0) {
      const newGoalBase = this.computeStateFromBase(baseOps);
      const loadedGoal = newGoalBase.get(goalId);
      if (loadedGoal != null) {
        this.baseState.set(goalId, loadedGoal);
        this.loadedSinceEmit.add(goalId);
        for (const op of baseOps) this.emittedBaseStateOpIds.add(op.id);
      }
    }

    for (const op of workingOps) {
      this.workingOps.set(op.id, op);
    }
    if (this.localStore instanceof CachingLocalStore && baseStateCursor != null) {
      this.localStore.evictCachedOps(baseStateCursor);
    }

    const affectedIds = await this.computeAffectedGoalIds(opsToApply);
    affectedIds.add(goalId);
    const newState = this.computeAndEmitUnsyncedState("loadGoal", affectedIds);
    this.goalLoadState.set(goalId, GoalLoadState.fullyLoaded);
    this.touch(goalId);
    unprotect();
    this.maybeEvict();
    return newState.get(goalId) ?? null;
  }

  /** Loads [goalId] and pins it until the returned ref is disposed. */
  async loadGoalRef(goalId: string): Promise<GoalRef> {
    await this.loadGoal(goalId);
    this._pin(goalId);
    return new GoalRef(this, goalId);
  }

  /** Watches, pins and loads [goalIds], and any children they gain later. */
  watchGoals(goalIds: Iterable<string>): WatchedGoalSet {
    return new WatchedGoalSet(this, goalIds);
  }

  private reHlcOps(ops: AnyOp[]): AnyOp[] {
    const result: AnyOp[] = [];
    for (const op of ops) {
      if (!isDeltaOp(op) && !isDisableOp(op) && !isEnableOp(op)) {
        throw new Error(`Unknown op type encountered in reHlcOps: ${op.type}`);
      }
      result.push({ ...op, hlcTimestamp: this.hlc.pack() });
      this.hlc = this.hlc.increment();
    }
    return result;
  }

  /**
   * Drops disabled ops. Note the Dart keys a re-enabled op by the Enable op's
   * HLC, so an op that is disabled and enabled again is applied once more.
   */
  private applyEnableAndDisableOps(ops: Iterable<AnyOp>): AnyOp[] {
    const opMap = new Map<string, AnyOp>();
    const disabledOpMap = new Map<string, AnyOp>();
    for (const op of [...ops].sort(byHlc)) {
      opMap.set(op.id, op);
      if (isDisableOp(op)) {
        const opToDisable = opMap.get(op.opId);
        if (opToDisable != null) {
          disabledOpMap.set(op.opId, opToDisable);
          opMap.delete(op.opId);
        }
      } else if (isEnableOp(op)) {
        const opToEnable = disabledOpMap.get(op.opId);
        if (opToEnable != null) {
          disabledOpMap.delete(op.opId);
          opMap.set(op.hlcTimestamp, opToEnable);
        }
      }
    }
    return [...opMap.values()];
  }

  private async pull(): Promise<void> {
    if (this.persistenceService == null) {
      return;
    }
    let result: LoadOpsResp;
    let latestCursor = this.pullStartCursor();
    const batchSize = 4000;
    do {
      result = await this.persistenceService.load({
        cursor: latestCursor,
        limit: batchSize,
      });
      for (const op of result.ops) {
        this.hlc = this.hlc.receive(HLC.unpack(op.hlcTimestamp));
      }
      this.baseState = await this.persistOps(result.ops);
      if (
        result.cursor != null &&
        (latestCursor == null || compareHlc(result.cursor, latestCursor) > 0)
      ) {
        latestCursor = result.cursor;
      }
    } while (result.ops.length >= batchSize);
    this.localStore.lastSyncTime = new Date();
  }

  /**
   * Starts the pull before the oldest acked-but-unreceived op, so a push the
   * server accepted but never echoed is fetched again.
   */
  private pullStartCursor(): string | null {
    const cursor = this.localStore.cursor;
    const ackedOpIds = this.localStore.getAckedOpIds();
    if (cursor == null || ackedOpIds.size === 0) {
      return cursor;
    }
    let oldest: string | null = null;
    for (const op of this.localStore.getUnsyncedOps()) {
      if (!ackedOpIds.has(op.id)) continue;
      if (oldest == null || compareHlc(op.hlcTimestamp, oldest) < 0) {
        oldest = op.hlcTimestamp;
      }
    }
    if (oldest == null || compareHlc(oldest, cursor) > 0) {
      return cursor;
    }
    const oldestHlc = HLC.unpack(oldest);
    return new HLC(oldestHlc.timestamp - 1, 0, oldestHlc.clientId).pack();
  }

  private acknowledgeReceivedOps(ops: AnyOp[]): void {
    const receivedIds = new Set(ops.map((op) => op.id));
    const unsyncedOps = this.localStore.getUnsyncedOps();
    if (unsyncedOps.some((op) => receivedIds.has(op.id))) {
      void this.localStore.setUnsyncedOps(
        unsyncedOps.filter((op) => !receivedIds.has(op.id)),
      );
    }
    const ackedOpIds = this.localStore.getAckedOpIds();
    if ([...ackedOpIds].some((id) => receivedIds.has(id))) {
      void this.localStore.setAckedOpIds(
        [...ackedOpIds].filter((id) => !receivedIds.has(id)),
      );
    }
  }

  private async push(): Promise<void> {
    if (this.persistenceService == null) {
      return;
    }
    const ackedOpIds = this.localStore.getAckedOpIds();
    const sortedUnsyncedOps = this.localStore
      .getUnsyncedOps()
      .filter((op) => !ackedOpIds.has(op.id) && !this.pushingOpIds.has(op.id))
      .sort(byHlc);
    if (sortedUnsyncedOps.length === 0) {
      return;
    }
    const batches: AnyOp[][] = [];
    for (let i = 0; i < sortedUnsyncedOps.length; i += 1000) {
      batches.push(sortedUnsyncedOps.slice(i, i + 1000));
    }
    const pushingOpIds = sortedUnsyncedOps.map((op) => op.id);
    for (const id of pushingOpIds) this.pushingOpIds.add(id);
    try {
      for (const batch of batches) {
        const mappedOps = this.reHlcOps(batch);
        await this.persistenceService.save(mappedOps);
        const pushedOps = new Map(mappedOps.map((op) => [op.id, op]));
        const unsyncedOps = this.localStore.getUnsyncedOps();
        const unsyncedIds = new Set(unsyncedOps.map((op) => op.id));
        const ackedIds = [...pushedOps.keys()].filter((id) =>
          unsyncedIds.has(id),
        );
        await Promise.all([
          this.localStore.setAckedOpIds(
            new Set([
              ...[...this.localStore.getAckedOpIds()].filter((id) =>
                unsyncedIds.has(id),
              ),
              ...ackedIds,
            ]),
          ),
          this.localStore.setUnsyncedOps(
            unsyncedOps.map((op) => pushedOps.get(op.id) ?? op),
          ),
        ]);
      }
    } catch (error) {
      // Like the Dart, a failed push is logged; the ops stay unsynced and are
      // pushed again by the next sync.
      this.onError(error);
    } finally {
      for (const id of pushingOpIds) this.pushingOpIds.delete(id);
    }
  }

  /** Pulls then pushes; concurrent calls run one after another. */
  async sync(): Promise<void> {
    const currentSyncFuture = this.syncFuture;
    let complete!: () => void;
    this.syncFuture = new Promise((resolve) => (complete = resolve));
    try {
      await currentSyncFuture;
      if (this.persistenceService != null) {
        await this.pull();
        await this.push();
      }
      this.computeAndEmitUnsyncedState("sync");
    } finally {
      complete();
    }
  }

  async logOut(): Promise<void> {
    try {
      await this.localStore.clear();
    } catch (error) {
      this.onError(error);
    }
    this.undoStack = [];
    this.redoStack = [];
    this.baseState = new Map();
    this.loadedSinceEmit.clear();
    this.pinCount.clear();
    this.lastAccessed.clear();
    this.goalSubjects.closeAll();
    this.goalNamesIndex.clear();
    this.hlc = HLC.now(this.localStore.clientId);
    this.stateSubject.add(new Map());
    this.syncSubject.add(null);
    this.syncFuture = Promise.resolve();
  }

  private async loadGoalNamesIndex(): Promise<void> {
    const indexData = await this.localStore.loadSearchIndex(
      GOAL_NAMES_INDEX_KEY,
    );
    this.goalNamesIndex = new Map();
    if (indexData == null) return;
    try {
      this.goalNamesIndex = new Map(Object.entries(JSON.parse(indexData)));
    } catch (error) {
      this.onError(error);
    }
  }

  private async saveGoalNamesIndex(): Promise<void> {
    await this.localStore.setSearchIndex(
      GOAL_NAMES_INDEX_KEY,
      JSON.stringify(Object.fromEntries(this.goalNamesIndex)),
    );
  }

  /** Ids of goals whose lowercased title contains [searchText]. */
  searchGoalsByName(searchText: string): string[] {
    if (searchText.length === 0) {
      return [];
    }
    const normalizedSearch = searchText.toLowerCase();
    const matchingGoalIds: string[] = [];
    for (const [goalName, goalId] of this.goalNamesIndex) {
      if (goalName.includes(normalizedSearch)) {
        matchingGoalIds.push(goalId);
      }
    }
    return matchingGoalIds;
  }
}

/** A pinned goal: kept resident until [dispose] is called. */
export class GoalRef {
  private disposed = false;

  /** @internal */
  constructor(
    private readonly client: SyncClient,
    readonly goalId: string,
  ) {}

  get goal(): Goal | null {
    return this.client.stateSubject.value.get(this.goalId) ?? null;
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    this.client._unpin(this.goalId);
  }
}

/**
 * A pinned, loaded set of goals that follows their changes. A watched goal
 * that gains a child starts watching the child too.
 */
export class WatchedGoalSet {
  private readonly ids = new Set<string>();
  private readonly subs = new Map<string, () => void>();
  private readonly current = new Map<string, Goal>();
  private readonly output = new BehaviorSubject<Map<string, Goal>>(new Map());
  private disposed = false;

  /** @internal */
  constructor(
    private readonly client: SyncClient,
    initialIds: Iterable<string>,
  ) {
    this.setIds(initialIds);
  }

  /** Emits the current goals, then each change. */
  get stream(): BehaviorSubject<Map<string, Goal>> {
    return this.output;
  }

  get currentValue(): ReadonlyMap<string, Goal> {
    return new Map(this.current);
  }

  get watchedIds(): ReadonlySet<string> {
    return new Set(this.ids);
  }

  setIds(newIds: Iterable<string>): void {
    if (this.disposed) return;
    const newSet = new Set(newIds);
    const currentIds = new Set(this.ids);
    for (const id of newSet) {
      if (!currentIds.has(id)) this.addId(id);
    }
    for (const id of currentIds) {
      if (!newSet.has(id)) this.removeId(id);
    }
  }

  add(id: string): void {
    if (this.disposed || this.ids.has(id)) return;
    this.addId(id);
  }

  remove(id: string): void {
    if (this.disposed || !this.ids.has(id)) return;
    this.removeId(id);
  }

  private addId(id: string): void {
    this.ids.add(id);
    this.client._pin(id);
    const subject = this.client.goalSubjects.getOrCreate(
      id,
      () => this.client.stateSubject.value.get(id) ?? null,
    );
    const seed = subject.value;
    if (seed != null) {
      this.current.set(id, seed);
    }
    this.subs.set(
      id,
      subject.subscribe((goal) => {
        if (this.disposed) return;
        const previous = this.current.get(id);
        if (goal != null) {
          this.current.set(id, goal);
        } else {
          this.current.delete(id);
        }
        if (goal != null && previous != null) {
          const previousChildren = previous.subGoalIds;
          for (const childId of goal.subGoalIds) {
            if (!previousChildren.has(childId) && !this.ids.has(childId)) {
              this.addId(childId);
            }
          }
        }
        this.emit();
      }),
    );
    this.client.loadGoal(id).catch((error) => {
      console.error("[WatchedGoalSet] loadGoal failed", error);
    });
  }

  private removeId(id: string): void {
    this.ids.delete(id);
    this.subs.get(id)?.();
    this.subs.delete(id);
    this.current.delete(id);
    this.client._unpin(id);
    if (this.client._pinCountOf(id) === 0) {
      this.client.goalSubjects.close(id);
    }
    if (!this.disposed) {
      this.emit();
    }
  }

  private emit(): void {
    if (this.output.isClosed) return;
    this.output.add(new Map(this.current));
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    for (const id of [...this.ids]) {
      this.removeId(id);
    }
    this.output.close();
  }
}
