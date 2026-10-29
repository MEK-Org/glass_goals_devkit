# SyncClient parity with the Dart

The Dart `SyncClient` in `packages/goals_core/lib/src/sync/` is the source of
truth. The TypeScript client in this package is a port of it and should behave
identically, including the Dart's lazy loading.

## How parity is checked

Both languages run the same scenarios. The scenarios live in
`packages/goals_core/test/sync/fixtures/sync_parity_scenarios.json`, generated
by `gen_sync_parity_scenarios.mjs` in the same directory.

- `goals_core/test/sync/sync_parity_fixture_test.dart` runs each scenario
  against the Dart client. With `UPDATE_SYNC_PARITY=1` it records what it
  observed in `sync_parity_expected.json`. Without that variable, it checks the
  Dart client still produces that output.
- `goals-core/src/sync-client.parity.test.ts` runs the same scenarios against
  the TS client. It asserts the output equals the Dart-recorded file exactly.

Each snapshot records:

- the emitted state: each goal's title, parents, children and log;
- resident and pinned goal counts;
- the root index and the unsynced op count;
- per-goal `loadOpsForGoal` counts and `getAllOps` calls, from an
  instrumented store;
- `GoalRef` and `WatchedGoalSet` contents;
- optionally, the cursor and stored strings.

The scenarios cover:

- parent-first and child-first cold loads;
- late older-HLC batches;
- exact redelivery;
- Disable/Enable before and after the base cursor;
- mutate, echo, undo and redo across a restart;
- the root index;
- LRU touches and eviction;
- pin, release and watch disposal;
- string conservation across reload;
- cycle guards, on cold load and in session.

`sync-client.lazy.test.ts` adds deterministic cost checks:

- a cold start loads only the root goals and never reads the full history;
- `loadGoal` reads a goal's indexed ops once;
- warm batches replay only the session's working ops;
- eviction respects `residentSoftCap`;
- a goal whose load is in flight is not evicted, even across init and
  restart with more roots than the cap;
- projections never mutate the base or an earlier emission.

## Port map

| Dart (`goals_core/lib/src/sync/`) | TypeScript (`goals-core/src/`) |
| --- | --- |
| `sync_client.dart` `SyncClient`, `GoalRef`, `WatchedGoalSet` | `sync-client.ts` |
| `goal_subject_registry.dart` | `goal-subject-registry.ts` |
| `local_store.dart` `LocalStore`, `CachingLocalStore`, `MemoryLocalStore`, `CacheMissException` | `local-store.ts` |
| `sync_repository.dart` `SyncRepository`, `MemorySyncRepository` | `sync-repository.ts` |
| `persistence_service.dart` `PersistenceService`, `MemoryPersistenceService` | `persistence.ts` |
| rxdart `BehaviorSubject` | `subject.ts` (minimal) |
| `getAffectedGoalIdsFromDeltaOp`, `Op.extractEntryTextField` (goals_types) | `op-utils.ts` |

## SyncClient API inventory

Construction differs in shape:

```ts
new SyncClient(persistenceService?, localStore?, { residentSoftCap, onError })
```

The Dart takes named parameters, including `logger`.

| Dart member | TS member | Notes |
| --- | --- | --- |
| `stateSubject` | `stateSubject` | Holds the **loaded** goals, not the whole graph. |
| `syncSubject` | `syncSubject` | Same `"$cursor:%05d"` value. |
| `hlc`, `syncFuture`, `residentSoftCap` | same | |
| `persistenceService`, `localStore` | same | |
| `modificationMap`, `undoStack`, `redoStack` | same | |
| `init`, `dispose`, `sync`, `logOut` | same | |
| `modifyGoal`, `modifyGoals`, `undo`, `redo` | same | |
| `loadGoal`, `loadGoalRef`, `watchGoals` | same | |
| `getRootGoalIds`, `getStatusGoalIds`, `searchGoalsByName` | same | Index-backed; they cover unloaded goals. |
| `numUnsyncedOps`, `numResidentGoals`, `numPinnedGoals` | same | |
| `cursor`, `fullSyncCount`, `lastSyncTime` | same | |
| `getUnsyncedOpStrings`, `getAllOpStrings`, `loadString` | same | Strings are wire JSON (`compressOp`). |
| `debugAddUnsyncedOps` | same | |
| `persistenceSubscription` | — | TS keeps the unsubscribe function private. |
| `baseStateQueue` | — | Unused in the Dart. |
| `syncPerfLogEnabled`, `[sync-perf]`/`SYNC-DIAG` prints, `SyncEventLogger` | — | Not ported. Background errors go to `onError` (default `console.error`). |
| — | `subscribe(cb)` | TS only. Calls `cb` now with `stateSubject.value`, then on each emission. |
| — | `getGoals()` | TS only. A copy of `stateSubject.value`: the loaded goals. |
| — | `applyOps(ops)` | TS only. Applies synced ops through the remote-batch path without moving the cursor. |
| — | `stats.appliedDeltaOps` | TS only. A diagnostic counter used by the cost tests. |

`GoalRef` and `WatchedGoalSet` match the Dart. `WatchedGoalSet.stream` is the
TS `BehaviorSubject`; subscribe to it with `stream.subscribe(listener)`.

Other modules:

- `InitialOpFetcher` (`initial_op_fetcher.dart`) is not ported.
- `MemoryLocalStore` used to live in `sync-client.ts` and is still re-exported
  from there.

## Implementation differences that do not change observed behavior

- LRU order uses a monotonic counter instead of `DateTime.now()`.
- `CachingLocalStore` reads its repository directly. The Dart batches reads
  on a 10 ms timer.
- The string cache is a 1000-entry LRU without the Dart's 10-minute expiry.
- `MemoryPersistenceService.settled()` is a method; the Dart's is a getter.
- After `dispose`, a late emission is dropped. The Dart throws "Cannot add new
  events after calling close" into the zone.
- A failed push goes to `onError`; the Dart prints it.

## Known Dart behaviors the port keeps

These are observed in the shared fixture. The TS client reproduces each one,
because the two clients are meant to behave identically. Fixing any of them
belongs in the Dart first, with the fixture regenerated.

1. **Late op older than the base cursor.** It is a working op, so it is
   replayed after the base. In session it wins over a newer op already folded
   into the base. After a restart, the op is folded in HLC order and loses.
   See `late_older_hlc_batch`.
2. **Enable/Disable of an op at or before the base cursor.** The target is in
   the base, not the working set, so in session the Enable/Disable has no
   effect. It applies after a restart. See `disable_enable_across_cursor`.
3. **The cursor can move backward.** A remote batch sets the cursor to the
   server cursor. The store then sets it to the batch's highest HLC when it
   writes the batch.
4. **An edge to a parent created later in HLC order stays one-sided.** The
   child records the parent, but the parent gets no child. This holds in
   session and after a restart. See `remote_edges_in_session`. An earlier TS
   port deferred such down edges; that was removed for parity.
5. **The cycle guard rejects both sides of a cycle-closing edge.** It fails
   open when a frontier parent is not loaded. A partial load can therefore
   admit an edge the full graph would reject, and the result can depend on load
   order. See `cycle_guard`.
6. **The memory test double keeps only the latest batch.**
   `MemoryPersistenceService.save` rebuilds its op list from the batch being
   saved. Both test doubles do this.

The goals-types TS `expandLogEntry` drops `te` for entry types it does not
know. The Dart keeps the text in its own entry classes.
