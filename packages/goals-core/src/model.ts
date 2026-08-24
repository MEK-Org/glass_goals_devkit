import { GoalLogEntry } from "@thkp-eng/goals-types";

export enum GoalStatus {
  Pending = "p",
  Active = "a",
  Done = "d",
  Archived = "ar",
}

/**
 * A layered view over two maps, mirroring the Dart `MergedMap`
 * (`goals_core/lib/src/model.dart`). Reads prefer `map1`; a key absent from
 * `map1` falls through to `map2` unless it has been tombstoned by a prior
 * `delete`/`clear`. Writes land in `map1`. `GoalInstance` uses it to layer an
 * instance's own subgoal relationships over the backing goal's without
 * mutating the backing goal.
 *
 * Ported to match the Dart's semantics exactly, including the tombstone set
 * (`_removedKeys`): deleting a key that exists only in `map2` records a
 * tombstone so it stops appearing, and `clear()` tombstones every `map2` key.
 * Refs MEK-Org/meta-coder#1174.
 */
export class MergedMap<K, V> implements Map<K, V> {
  private readonly removedKeys: Set<K> = new Set();

  constructor(
    private readonly map1: Map<K, V>,
    private readonly map2: Map<K, V>,
  ) {}

  get(key: K): V | undefined {
    if (this.map1.has(key)) {
      return this.map1.get(key);
    }
    if (this.removedKeys.has(key)) {
      return undefined;
    }
    return this.map2.get(key);
  }

  set(key: K, value: V): this {
    this.removedKeys.delete(key);
    this.map1.set(key, value);
    return this;
  }

  has(key: K): boolean {
    if (this.map1.has(key)) {
      return true;
    }
    if (this.removedKeys.has(key)) {
      return false;
    }
    return this.map2.has(key);
  }

  delete(key: K): boolean {
    const existed = this.has(key);
    this.map1.delete(key);
    if (this.map2.has(key)) {
      this.removedKeys.add(key);
    }
    return existed;
  }

  clear(): void {
    this.map1.clear();
    for (const key of this.map2.keys()) {
      this.removedKeys.add(key);
    }
  }

  // Mirrors the Dart `keys` getter: map1 keys ∪ map2 keys − removedKeys, with
  // map1's insertion order first.
  private mergedKeyList(): K[] {
    const keys = new Set<K>(this.map1.keys());
    for (const key of this.map2.keys()) {
      keys.add(key);
    }
    for (const key of this.removedKeys) {
      keys.delete(key);
    }
    return [...keys];
  }

  get size(): number {
    return this.mergedKeyList().length;
  }

  // A point-in-time real Map of the merged view. Iteration delegates to it so
  // the iterator types match the built-in Map exactly; writes still go through
  // set/delete/clear to the live backing maps, so mutations persist. This
  // mirrors the Dart, whose `keys` getter likewise returns a fresh set per call.
  private snapshot(): Map<K, V> {
    const merged = new Map<K, V>();
    for (const key of this.mergedKeyList()) {
      merged.set(key, this.get(key) as V);
    }
    return merged;
  }

  keys() {
    return this.snapshot().keys();
  }

  values() {
    return this.snapshot().values();
  }

  entries() {
    return this.snapshot().entries();
  }

  [Symbol.iterator]() {
    return this.snapshot().entries();
  }

  forEach(
    callbackfn: (value: V, key: K, map: Map<K, V>) => void,
    thisArg?: unknown,
  ): void {
    for (const [key, value] of this.snapshot()) {
      callbackfn.call(thisArg, value, key, this);
    }
  }

  get [Symbol.toStringTag](): string {
    return "MergedMap";
  }
}

export class Goal {
  // Nullable backing store so the `text` getter can apply the Dart's default.
  protected _text?: string;
  protected _log: GoalLogEntry[] = [];
  // The relationship maps are the single source of truth; the id sets are
  // derived, matching the Dart (`superGoalIds => superGoalRelationships.keys`).
  protected _superGoalRelationships: Map<string, GoalLogEntry> = new Map();
  protected _subGoalRelationships: Map<string, GoalLogEntry> = new Map();

  constructor(
    public readonly id: string,
    text: string | undefined,
    public readonly creationTime: Date,
  ) {
    this._text = text;
  }

  // Dart: `String get text => _text ?? 'Untitled';`
  get text(): string {
    return this._text ?? "Untitled";
  }

  set text(value: string) {
    this._text = value;
  }

  get log(): GoalLogEntry[] {
    return this._log;
  }

  get superGoalRelationships(): Map<string, GoalLogEntry> {
    return this._superGoalRelationships;
  }

  get subGoalRelationships(): Map<string, GoalLogEntry> {
    return this._subGoalRelationships;
  }

  // Derived from the relationship maps, like the Dart's `.keys` getters. Reads
  // through `this.subGoalRelationships`, so a GoalInstance's MergedMap override
  // flows into `subGoalIds` automatically.
  get superGoalIds(): Set<string> {
    return new Set(this.superGoalRelationships.keys());
  }

  get subGoalIds(): Set<string> {
    return new Set(this.subGoalRelationships.keys());
  }

  hasParent(goalId: string): boolean {
    return this.superGoalRelationships.has(goalId);
  }

  addSuperGoal(parentId: string, entry: GoalLogEntry) {
    this.superGoalRelationships.set(parentId, entry);
  }

  removeSuperGoal(parentId: string) {
    this.superGoalRelationships.delete(parentId);
  }

  addSubGoal(childId: string, entry: GoalLogEntry) {
    this.subGoalRelationships.set(childId, entry);
  }

  removeSubGoal(childId: string) {
    this.subGoalRelationships.delete(childId);
  }

  prependEntry(entry: GoalLogEntry) {
    this._log.unshift(entry);
  }

  clone(): Goal {
    const cloned = new Goal(this.id, this._text, this.creationTime);
    cloned._log = [...this.log];
    for (const [k, v] of this.superGoalRelationships) {
      cloned._superGoalRelationships.set(k, v);
    }
    for (const [k, v] of this.subGoalRelationships) {
      cloned._subGoalRelationships.set(k, v);
    }
    return cloned;
  }
}

export class GoalInstance extends Goal {
  private readonly _mergedSubGoals: MergedMap<string, GoalLogEntry>;

  constructor(
    public readonly goal: Goal,
    id: string,
    creationTime: Date,
  ) {
    // The instance carries no own text until one is set; `text` below falls
    // back to the backing goal.
    super(id, undefined, creationTime);
    this._mergedSubGoals = new MergedMap(
      this._subGoalRelationships,
      goal.subGoalRelationships,
    );
  }

  // Dart: `String get text => _text ?? goal.text;` — note this falls back to
  // the *backing goal*, not to 'Untitled' directly (the backing goal applies
  // that default itself).
  override get text(): string {
    return this._text ?? this.goal.text;
  }

  set text(value: string) {
    this._text = value;
  }

  // Dart delegates hasParent to the backing goal; an instance's parentage is
  // the backing goal's, not the instance's own super-goal map.
  override hasParent(goalId: string): boolean {
    return this.goal.hasParent(goalId);
  }

  // The entries that live only on this instance.
  get selfLog(): GoalLogEntry[] {
    return this._log;
  }

  // Dart: the backing goal's log minus StatusLogEntry / ClearStatusLogEntry,
  // concatenated with the instance's own entries, sorted newest-first by
  // creationTime. StatusLogEntry -> "status", ClearStatusLogEntry ->
  // "clearStatus"; ArchiveStatusLogEntry ("archiveStatus") is a sibling class
  // in the Dart and is deliberately NOT filtered.
  override get log(): GoalLogEntry[] {
    return [
      ...this.goal.log.filter(
        (e) => e.type !== "status" && e.type !== "clearStatus",
      ),
      ...this._log,
    ].sort((a, b) => b.creationTime - a.creationTime);
  }

  override get subGoalRelationships(): Map<string, GoalLogEntry> {
    return this._mergedSubGoals;
  }

  override clone(): GoalInstance {
    const newGoal = new GoalInstance(this.goal, this.id, this.creationTime);
    // Copy the merged views into the clone's own backing fields, exactly as the
    // Dart clone does (addAll over the getters).
    for (const [k, v] of this.subGoalRelationships) {
      newGoal._subGoalRelationships.set(k, v);
    }
    for (const [k, v] of this.superGoalRelationships) {
      newGoal._superGoalRelationships.set(k, v);
    }
    for (const e of this.log) {
      newGoal._log.push(e);
    }
    newGoal._text = this.text;
    return newGoal;
  }
}
