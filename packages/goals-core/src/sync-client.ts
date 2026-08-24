import {
  WireOp,
  expandOp,
  AnyOp,
  DeltaOp,
  LogEntry,
  GoalDelta,
} from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { Cupid } from "./cupid";
import { Goal, GoalInstance } from "./model";
import { PersistenceService } from "./persistence";

/**
 * Orders two packed HLC strings the way the Dart source of truth does.
 *
 * The reference `SyncClient` sorts its op log with
 * `a.hlcTimestamp.compareTo(b.hlcTimestamp)` (`sync_client.dart`), and Dart's
 * `String.compareTo` compares by UTF-16 code unit. JavaScript's `<`/`>` on
 * strings is the same code-unit comparison, so this is the faithful analogue.
 *
 * `String.prototype.localeCompare` — which the port used — is ICU collation
 * instead, and it can disagree with code-unit order on the `clientId` tail of
 * two ops that share a timestamp and counter. When it disagrees, Dart and TS
 * clients fold the same log in different orders, which breaks the convergence
 * argument the cycle guard relies on (the op applied later in log order is the
 * one whose edge is skipped). Keep this code-unit; do not "improve" it back to
 * `localeCompare`. Refs MEK-Org/meta-coder#1174.
 */
function compareHlc(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export interface LocalStore {
  clientId: string;
  cursor: string | null;
  init(): Promise<void>;
  getUnsyncedOps(): AnyOp[];
  setUnsyncedOps(ops: AnyOp[]): Promise<void>;
  storeSyncedOps(ops: AnyOp[]): Promise<void>;
  getAllOps(): Promise<AnyOp[]>;
}

export class MemoryLocalStore implements LocalStore {
  public clientId: string = Cupid.random().encode();
  public cursor: string | null = null;
  private unsyncedOps: AnyOp[] = [];
  private syncedOps: Map<string, AnyOp> = new Map();

  async init(): Promise<void> {}

  getUnsyncedOps(): AnyOp[] {
    return [...this.unsyncedOps];
  }

  async setUnsyncedOps(ops: AnyOp[]): Promise<void> {
    this.unsyncedOps = [...ops];
  }

  async storeSyncedOps(ops: AnyOp[]): Promise<void> {
    for (const op of ops) {
      this.syncedOps.set(op.id, op);
      // Remove from unsynced if present
      this.unsyncedOps = this.unsyncedOps.filter(
        (unsynced) => unsynced.id !== op.id,
      );
      if (this.cursor === null || HLC.unpack(op.hlcTimestamp).comesAfter(this.cursor)) {
        this.cursor = op.hlcTimestamp;
      }
    }
  }

  async getAllOps(): Promise<AnyOp[]> {
    const all = [...this.syncedOps.values(), ...this.unsyncedOps];
    return all.sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp));
  }
}

export type SyncStateCallback = (state: Map<string, Goal>) => void;

export class SyncClient {
  private hlc: HLC;
  private baseState: Map<string, Goal> = new Map();
  private callbacks: Set<SyncStateCallback> = new Set();

  constructor(
    private persistenceService: PersistenceService | null,
    private localStore: LocalStore = new MemoryLocalStore(),
  ) {
    this.hlc = new HLC(0, 0, localStore.clientId);
  }

  public async init(): Promise<void> {
    await this.localStore.init();
    this.hlc = HLC.now(this.localStore.clientId);

    const allOps = await this.localStore.getAllOps();
    this.applyOpsToState(allOps);
    this.emitState();

    if (this.persistenceService) {
      this.persistenceService.subscribeJSON(
        this.localStore.cursor,
        (ops, cursor) => {
          this.handleRemoteOps(ops, cursor);
        },
      );
    }
  }

  public subscribe(callback: SyncStateCallback): () => void {
    this.callbacks.add(callback);
    callback(new Map(this.baseState));
    return () => this.callbacks.delete(callback);
  }

  public getGoals(): Map<string, Goal> {
    return new Map(this.baseState);
  }

  public async applyOps(ops: AnyOp[]): Promise<void> {
    this.applyOpsToState(ops);
    this.emitState();
  }

  public async modifyGoal(delta: GoalDelta): Promise<void> {
    this.hlc = this.hlc.increment();
    const prettyOp: DeltaOp = {
      hlcTimestamp: this.hlc.pack(),
      id: Cupid.random().encode(),
      version: 6,
      type: "delta",
      delta: {
        id: delta.id,
        text: delta.text,
        logEntry: delta.logEntry,
      },
    };

    const unsynced = this.localStore.getUnsyncedOps();
    unsynced.push(prettyOp);
    await this.localStore.setUnsyncedOps(unsynced);

    this.applyOpsToState([prettyOp]);
    this.emitState();

    if (this.persistenceService) {
      await this.persistenceService.save([prettyOp]);
    }
  }

  private handleRemoteOps(ops: AnyOp[], cursor: string): void {
    this.localStore.storeSyncedOps(ops);
    this.localStore.cursor = cursor;
    this.applyOpsToState(ops);
    this.emitState();
  }

  private applyOpsToState(ops: AnyOp[]): void {
    // Sort ops by HLC in code-unit order, matching the Dart's
    // `hlcTimestamp.compareTo(...)` (see compareHlc).
    const sortedOps = [...ops].sort((a, b) =>
      compareHlc(a.hlcTimestamp, b.hlcTimestamp),
    );

    for (const op of sortedOps) {
      const opHlc = HLC.unpack(op.hlcTimestamp);
      this.hlc = this.hlc.receive(opHlc);

      if (op.type === "delta") {
        const deltaOp = op as DeltaOp;
        let goal = this.baseState.get(deltaOp.delta.id);
        if (!goal) {
          goal = new Goal(
            deltaOp.delta.id,
            // Pass the raw text (undefined when the delta carries none) so the
            // Dart's `_text ?? 'Untitled'` default in Goal.text manifests,
            // rather than coercing an absent title to "". Refs
            // MEK-Org/meta-coder#1174.
            deltaOp.delta.text ?? undefined,
            new Date(opHlc.timestamp),
          );
          this.baseState.set(deltaOp.delta.id, goal);
        }

        if (deltaOp.delta.text !== undefined && deltaOp.delta.text !== null) {
          goal.text = deltaOp.delta.text;
        }

        const entry = deltaOp.delta.logEntry;
        if (entry) {
          // Dedup on (id, type), matching the Dart's
          // `e.id == entry.id && e.runtimeType == entry.runtimeType` — an id
          // collision across two different entry types must NOT swallow the
          // second entry.
          if (
            !goal.log.some((e) => e.id === entry.id && e.type === entry.type)
          ) {
            goal.prependEntry(entry as any);

            // Handle special entry types
            if (entry.type === "createInstance") {
              this.baseState.set(
                entry.id,
                new GoalInstance(goal, entry.id, new Date(entry.creationTime)),
              );
            } else if (entry.type === "documentContents") {
              // Content derived from log, no field to set
            } else if (entry.type === "clearDocumentContents") {
              // Content derived from log, no field to set
            }
          }

          // We evaluate super goals even if the entry is already in the log
          // because it's possible that we need to update the super goal.
          this.evaluateSuperGoals(this.baseState, goal, entry);
        }
      }
    }
  }

  /**
   * Port of `SyncClient._checkCycles` in
   * `goals_core/lib/src/sync/sync_client.dart`. Walks the `superGoalIds`
   * frontier upward looking for `goalId`; returns true if reaching it means the
   * prospective edge would close a cycle.
   *
   * Note the deliberate fail-open at the missing-parent branch: in a
   * partial-state world the parent may simply not be loaded yet, and the Dart
   * allows the relationship rather than dropping a legitimate edge. Do not
   * "harden" that into a rejection.
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

    const newFrontierIds: Set<string> = new Set();
    for (const parentId of frontierIds) {
      const parent = goalMap.get(parentId);
      if (!parent) {
        // if we don't have the parent, just allow this parent relationship and wait for it to be handled by the async process
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
    entry: LogEntry,
  ): void {
    if (entry.type === "setParent") {
      const setParent = entry as any;
      // Remove existing parents
      for (const parentId of goal.superGoalIds) {
        const parent = goalMap.get(parentId);
        if (parent) parent.removeSubGoal(goal.id);
      }
      // superGoalIds is now derived from superGoalRelationships (matching the
      // Dart), so clearing the relationship map is the whole operation — there
      // is no separate id set to clear. Refs MEK-Org/meta-coder#1174.
      goal.superGoalRelationships.clear();

      if (setParent.parentId) {
        // The up edge is added before the cycle check and is deliberately not
        // reverted when the check trips — only the down edge below is skipped.
        goal.addSuperGoal(setParent.parentId, entry as any);
        const parent = goalMap.get(setParent.parentId);
        if (parent) {
          if (
            this.checkCycles(
              goalMap,
              goal.id,
              new Set([parent.id]),
              new Set([parent.id]),
            )
          ) {
            // silently ignore deltas that would create cycles ¯\_(ツ)_/¯
            return;
          }

          parent.addSubGoal(goal.id, entry as any);
        }
      }
    } else if (entry.type === "addParent") {
      const addParent = entry as any;
      const childId = addParent.isSlice ? addParent.id : goal.id;
      goal.addSuperGoal(addParent.parentId, entry as any);
      const parent = goalMap.get(addParent.parentId);
      if (parent) {
        if (
          this.checkCycles(
            goalMap,
            childId,
            new Set([parent.id]),
            new Set([parent.id]),
          )
        ) {
          // silently ignore deltas that would create cycles ¯\_(ツ)_/¯
          return;
        }

        parent.addSubGoal(goal.id, entry as any);
      }
    } else if (entry.type === "removeParent") {
      const removeParent = entry as any;
      goal.removeSuperGoal(removeParent.parentId);
      const parent = goalMap.get(removeParent.parentId);
      if (parent) parent.removeSubGoal(goal.id);
    }
  }

  private emitState(): void {
    const stateClone = new Map();
    for (const [id, goal] of this.baseState) {
      stateClone.set(id, goal.clone());
    }
    for (const callback of this.callbacks) {
      callback(stateClone);
    }
  }
}
