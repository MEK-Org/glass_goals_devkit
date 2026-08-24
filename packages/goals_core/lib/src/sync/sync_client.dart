import 'dart:async';
import 'dart:convert' show jsonEncode, jsonDecode;

import 'package:collection/collection.dart';
import 'package:goals_core/model.dart' show Goal, GoalInstance;
import 'package:goals_core/src/sync/local_store.dart'
    show LocalStore, MemoryLocalStore, CachingLocalStore;
import 'package:goals_core/src/sync/sync_logger.dart' show SyncEventLogger;
import 'package:goals_core/src/util/iterable_utils.dart';
import 'package:goals_core/src/util/string_utils.dart';
import 'package:goals_core/util.dart' show Cupid;
import 'package:goals_types/goals_types.dart'
    show
        AddParentLogEntry,
        ClearStatusLogEntry,
        CreateInstanceLogEntry,
        DeltaOp,
        DisableOp,
        EnableOp,
        GoalDelta,
        GoalLogEntry,
        GoalStatus,
        Op,
        RemoveParentLogEntry,
        SetParentLogEntry,
        StatusLogEntry,
        TextGoalLogEntry,
        getAffectedGoalIdsFromDeltaOp;
import 'package:hlc/hlc.dart';
import 'package:rxdart/rxdart.dart' show BehaviorSubject;
import 'package:queue/queue.dart' show Queue;

import 'goal_subject_registry.dart' show GoalSubjectRegistry;
import 'persistence_service.dart' show LoadOpsResp, PersistenceService;

enum _GoalLoadState {
  loading,
  fullyLoaded,
}

/// When true, [SyncClient] prints per-phase timings for the modify path
/// (and a few related operations) to the console. Intended for ad-hoc
/// investigation — leave off in production.
bool syncPerfLogEnabled = false;

void _perfLog(String message) {
  if (syncPerfLogEnabled) {
    // ignore: avoid_print
    print('[sync-perf] $message');
  }
}

String _ms(Stopwatch sw) =>
    '${(sw.elapsedMicroseconds / 1000).toStringAsFixed(2)}ms';

class SyncClient {
  final BehaviorSubject<Map<String, Goal>> stateSubject =
      BehaviorSubject.seeded({});
  late HLC hlc;

  final PersistenceService? persistenceService;
  final LocalStore localStore;

  Future<void> syncFuture = Future.value();
  BehaviorSubject<String?> syncSubject = BehaviorSubject.seeded(null);

  Map<String, Goal> _baseState = {};
  String? _baseStateCursor;

  int? _lastEmittedStateOpCount;

  final Set<String> _emittedBaseStateOpIds = {};

  final Set<String> _emittedWorkingStateOpIds = {};

  final Map<String, Op> _workingOps = {};

  final Map<String, _GoalLoadState> _goalLoadState = {};

  /// Goal-id → number of outstanding pins (refs/watches) holding it resident.
  /// A goal with `_pinCount[id] > 0` is never evicted. See devlog
  /// 2026-05-25-goal-eviction-and-subscriptions.
  final Map<String, int> _pinCount = {};

  /// Goal-id → last time the goal was loaded, mutated, or otherwise touched.
  /// Used as the LRU sort key when eviction runs.
  final Map<String, DateTime> _lastAccessed = {};

  /// Per-goal subject registry; populated lazily by `watchGoals`.
  final GoalSubjectRegistry _goalSubjects = GoalSubjectRegistry();

  final baseStateQueue = Queue();

  final SyncEventLogger? _logger;

  /// Soft upper bound on the number of unpinned resident goals. When
  /// `_baseState.length` exceeds this after a mutation batch, the LRU-oldest
  /// unpinned goals are evicted until the count drops back to the cap. Pinned
  /// goals are never evicted, so the actual resident count can transiently
  /// exceed the cap by the number of pinned ids — hence "soft".
  ///
  /// Defaults are deliberately generous for production; tests and debug
  /// builds typically pass a smaller value to exercise the eviction path.
  final int residentSoftCap;

  SyncClient({
    this.persistenceService,
    LocalStore? localStore,
    logger,
    this.residentSoftCap = 2000,
  })  : localStore = localStore ?? MemoryLocalStore(),
        _logger = logger;

  // in memory mapping from "action" ids, to the set of hlc timestamps that that action contained
  final modificationMap = <String, Set<String>>{};

  StreamSubscription? persistenceSubscription;

  List<String> undoStack = [];
  List<String> redoStack = [];

  final Map<String, bool Function(Goal goal)> _indexers = {};

  // In-memory index mapping goal names to goal IDs for efficient searching
  Map<String, String> _goalNamesIndex = {};

  Future<void> init() async {
    print('[SYNC-DIAG] SyncClient.init: start');
    await localStore.init();
    hlc = HLC.now(localStore.clientId);

    _indexers["rootGoals"] = _isRootGoal;
    _indexers["statusGoals"] = _isStatusGoal;

    // Load the goal names index from storage
    await _loadGoalNamesIndex();

    _baseStateCursor = localStore.cursor;
    print(
        '[SYNC-DIAG] SyncClient.init: after localStore.init cursor=$_baseStateCursor unsyncedCount=${localStore.getUnsyncedOps().length}');

    // we call sync even if we don't have a persistence service to
    // emit the initial state
    try {
      await sync();
      print('[SYNC-DIAG] SyncClient.init: sync() completed');
    } catch (e, stackTrace) {
      print('[SYNC-DIAG] SyncClient.init: sync() THREW error=$e');
      print('[SYNC-DIAG] SyncClient.init: stack=$stackTrace');
      rethrow;
    }

    // it's possible the base was updated during sync, so we set it again
    _baseStateCursor = localStore.cursor;

    final futures = <Future<void>>[];
    for (final goalId in getRootGoalIds()) {
      futures.add(loadGoal(goalId));
    }
    await Future.wait(futures);

    if (persistenceService != null) {
      persistenceSubscription = persistenceService!
          .stream(localStore.cursor)
          .listen((opsEvent) async {
        final (ops, cursor) = opsEvent;

        // TODO: it seems like we shouldn't be setting the cursor until after persisting the ops???
        localStore.cursor = cursor;
        for (final op in ops) {
          _logger?.log('Received op from remote, updating entry in _workingOps',
              opId: op.id);
          _workingOps[op.id] = op;
        }
        await _persistOps(ops);
        final affectedIds = await _computeAffectedGoalIds(ops);
        _computeAndEmitUnsyncedState(
          "remote ops received",
          affectedGoalIds: affectedIds,
        );
      });
    }
  }

  void dispose() {
    stateSubject.close();
    syncSubject.close();
    _goalSubjects.closeAll();
    persistenceSubscription?.cancel();
    persistenceSubscription = null;
  }

  Future<void> modifyGoal(GoalDelta delta) async {
    await _modifyGoals([delta]);
  }

  Future<void> modifyGoals(List<GoalDelta> deltas) async {
    await _modifyGoals(deltas);
  }

  /// This is only exposed for debugging purposes.
  Future<void> debugAddUnsyncedOps(List<String> ops) async {
    final allOps = await localStore.getAllOps();

    final knownOps = <String>{};
    for (final op in allOps) {
      knownOps.add(op.id);
    }

    final opMap = <String, Op>{};
    for (final op in ops) {
      final parsedOp = Op.fromJson(op);
      if (knownOps.contains(parsedOp.id)) {
        continue;
      }
      opMap[parsedOp.hlcTimestamp] = parsedOp;
    }

    final unsyncedOps = [...localStore.getUnsyncedOps(), ...opMap.values];

    localStore.setUnsyncedOps(unsyncedOps);
    _push();
  }

  int get numUnsyncedOps => localStore.getUnsyncedOps().length;

  /// Number of goals currently resident in `_baseState`. Exposed for
  /// eviction tests and debug overlays; production UI should not depend on
  /// this number (it shrinks under memory pressure as goals fall out of the
  /// LRU window).
  int get numResidentGoals => _baseState.length;

  /// Number of goal ids currently held by at least one pin.
  int get numPinnedGoals => _pinCount.length;

  /// Increments the pin count for [goalId] and refreshes its LRU timestamp.
  /// A goal with at least one pin is never evicted.
  void _pin(String goalId) {
    _pinCount[goalId] = (_pinCount[goalId] ?? 0) + 1;
    _touch(goalId);
  }

  /// Decrements the pin count for [goalId]. Removes the entry when it reaches
  /// zero so [numPinnedGoals] reflects unique pinned ids.
  void _unpin(String goalId) {
    final current = _pinCount[goalId];
    if (current == null) {
      return;
    }
    if (current <= 1) {
      _pinCount.remove(goalId);
    } else {
      _pinCount[goalId] = current - 1;
    }
  }

  /// Stamps `_lastAccessed[goalId]` to now. Called from every code path that
  /// reads or mutates a resident goal.
  void _touch(String goalId) {
    _lastAccessed[goalId] = DateTime.now();
  }

  /// Drops [goalId] from the resident set and its bookkeeping. Caller is
  /// responsible for ensuring the goal is unpinned (`_pinCount[id] ?? 0 == 0`).
  ///
  /// Per-goal subjects are intentionally left alone: a subject is created by
  /// `watchGoals._addId` and torn down by `_removeId` when the last watcher
  /// unpins. Since we only evict unpinned goals, no subject ever exists for an
  /// evicted id at the time of eviction. (If one is later re-created by a new
  /// `watchGoals` call, the cold-load path will re-populate `_baseState`.)
  ///
  /// `_emittedBaseStateOpIds` is NOT pruned here. Op-id-count-based dedup in
  /// `_emitState` is conservative: re-adding the same ids on reload is a
  /// no-op for the set, and any subsequent op-driven emit re-broadcasts the
  /// reloaded goal in the full `stateSubject` payload. The per-goal subject
  /// path is unaffected. See design doc 2026-05-25 §"Behavior of eviction".
  void _evict(String goalId) {
    _baseState.remove(goalId);
    _goalLoadState.remove(goalId);
    _lastAccessed.remove(goalId);
  }

  /// If `_baseState.length` exceeds [residentSoftCap], evicts LRU-oldest
  /// unpinned goals until the count is back at the cap (or no more unpinned
  /// candidates remain — pinned goals are never evicted).
  ///
  /// Called from the mutation batch boundaries (`_persistOps`,
  /// `_handleNewUnsyncedOps`, the persistence-stream callback) so eviction
  /// cost amortizes over a batch rather than firing per-goal.
  void _maybeEvict() {
    final overage = _baseState.length - residentSoftCap;
    if (overage <= 0) return;
    final evictable = _baseState.keys
        .where((id) => (_pinCount[id] ?? 0) == 0)
        .toList()
      ..sort((a, b) {
        final aTime = _lastAccessed[a];
        final bTime = _lastAccessed[b];
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return -1;
        if (bTime == null) return 1;
        return aTime.compareTo(bTime);
      });
    final toEvict = evictable.take(overage).toList();
    if (toEvict.isEmpty) return;
    for (final id in toEvict) {
      _evict(id);
    }
    _perfLog(
        '[EVICT] dropped=${toEvict.length} resident=${_baseState.length} pinned=${_pinCount.length} cap=$residentSoftCap');
  }

  bool _isRootGoal(Goal goal) {
    return goal.superGoalIds.isEmpty;
  }

  bool _isStatusGoal(Goal goal) {
    for (final entry in goal.log) {
      if (entry is ClearStatusLogEntry) {
        return false;
      }
      if (entry is! StatusLogEntry) {
        continue;
      }
      final StatusLogEntry(
        startTime: startTime,
        endTime: endTime,
        status: status
      ) = entry;
      if (status == GoalStatus.archived) {
        continue;
      }
      if (endTime == null) {
        if (status == GoalStatus.active) {
          return true;
        }
        continue;
      }
      if (startTime == null) {
        if (endTime.isAfter(DateTime.now())) {
          return true;
        }
        continue;
      }
      if (startTime.isAfter(DateTime.now()) ||
          endTime.isAfter(DateTime.now())) {
        return true;
      }
    }
    return false;
  }

  Set<String> getRootGoalIds() {
    final clonedBase = <String, Goal>{};
    final rootGoalIds = {...localStore.getIndexGoalIds("rootGoals")};

    final workingState = _computeStateFromBase(_workingOps.values);

    for (final entry in workingState.entries) {
      clonedBase[entry.key] = entry.value.clone();
    }

    final modifiedGoalIds = <String>{};

    final sortedOps = localStore.getUnsyncedOps().toList()
      ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    final disabledOps = _computeDisabledOps(sortedOps);
    for (final op in sortedOps.whereType<DeltaOp>()) {
      if (disabledOps.containsKey(op.id)) {
        // skip disabled ops
        continue;
      }
      modifiedGoalIds.addAll(_applyDeltaOp(clonedBase, op));
    }

    for (final goalId in modifiedGoalIds) {
      final goal = clonedBase[goalId];
      if (goal == null) {
        continue;
      }
      if (_isRootGoal(goal)) {
        rootGoalIds.add(goalId);
      } else {
        rootGoalIds.remove(goalId);
      }
    }

    return rootGoalIds;
  }

  List<String> getStatusGoalIds() {
    final clonedBase = <String, Goal>{};
    final statusGoalIds = {...localStore.getIndexGoalIds("statusGoals")};

    final workingState = _computeStateFromBase(_workingOps.values);

    for (final entry in workingState.entries) {
      clonedBase[entry.key] = entry.value.clone();
    }

    final modifiedGoalIds = <String>{};

    final sortedOps = localStore.getUnsyncedOps().toList()
      ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    final disabledOps = _computeDisabledOps(sortedOps);
    for (final op in sortedOps.whereType<DeltaOp>()) {
      if (disabledOps.containsKey(op.id)) {
        // skip disabled ops
        continue;
      }
      modifiedGoalIds.addAll(_applyDeltaOp(clonedBase, op));
    }

    for (final goalId in modifiedGoalIds) {
      final goal = clonedBase[goalId];
      if (goal == null) {
        continue;
      }
      final isStatusGoal = _isStatusGoal(goal);
      if (isStatusGoal) {
        statusGoalIds.add(goalId);
      } else {
        statusGoalIds.remove(goalId);
      }
    }

    return statusGoalIds.toList();
  }

  String? get cursor => localStore.cursor;

  int get fullSyncCount => localStore.fullSyncCount;

  DateTime? get lastSyncTime => localStore.lastSyncTime;

  List<String> getUnsyncedOpStrings() {
    return (localStore.getUnsyncedOps()).map((op) => op.toJson()).toList();
  }

  Future<String?> loadString(String key) async {
    final localString = await localStore.loadString(key);

    if (localString != null) {
      return localString;
    }

    if (persistenceService == null) {
      return null;
    }

    final remoteString = await persistenceService!.loadString(key);
    if (remoteString == null) {
      return null;
    }
    localStore.setString(key, remoteString);
    return remoteString;
  }

  Future<void> getAllOpStrings(
      Future<void> Function(List<String>) handleChunk) async {
    final ops = await localStore.getAllOps();

    final result = <String>[];
    var chunkSize = 1000;
    for (final op in ops) {
      if (op is! DeltaOp) {
        result.add(op.toJson());
        continue;
      }

      final entry = op.delta.logEntry;
      if (entry is! TextGoalLogEntry) {
        result.add(op.toJson());
        continue;
      }
      final textLogEntryOp = op.toJsonMap();

      textLogEntryOp[DeltaOp.DELTA_JSON_KEY][GoalDelta.LOG_ENTRY_FIELD_NAME]
          [TextGoalLogEntry.TEXT_JSON_KEY] = await loadString(entry.id);
      result.add(jsonEncode(textLogEntryOp));
      if (result.length >= chunkSize) {
        await handleChunk(result);
        result.clear();
      }
    }
    if (result.isNotEmpty) {
      await handleChunk(result);
    }
  }

  Iterable<DeltaOp> _processDeltas(Iterable<GoalDelta> deltas) {
    _logger?.log('_processDeltas');
    if (deltas.isEmpty) {
      _logger?.log('Deltas Empty. Returning empty list.');
      return [];
    }

    final actionOpIds = <String>{};
    final deltaOps = <DeltaOp>[];
    for (final delta in deltas) {
      hlc = hlc.increment();
      final op = DeltaOp(
          id: Cupid.random().encode(), hlcTimestamp: hlc.pack(), delta: delta);
      deltaOps.add(op);
      _logger?.log('Op Created: $delta', opId: op.id);
      actionOpIds.add(op.id);
    }
    final actionId = Cupid.random().encode();
    modificationMap[actionId] = actionOpIds;
    undoStack.add(actionId);
    redoStack.clear();

    return deltaOps;
  }

  Future<void> _handleNewUnsyncedOps(Iterable<Op> newOps) async {
    _logger?.log("_handleNewUnsyncedOps");
    final totalSw = Stopwatch()..start();

    final phaseSw = Stopwatch()..start();

    // update unsynced ops
    final unsyncedOps = localStore.getUnsyncedOps();

    _logger?.log("Setting unsynced ops: ${newOps.map((e) => e.id)}");

    localStore.setUnsyncedOps([...unsyncedOps, ...newOps]);
    _perfLog(
        'setUnsyncedOps ${_ms(phaseSw)} (existing=${unsyncedOps.length}, new=${newOps.length})');

    // Emission is async: there is a single emit below, after the affected
    // goals are loaded. Callers that need to render the result in the same
    // turn (e.g. the add-goal flow advancing focus) `await` this future —
    // when it resolves the new state has been emitted and any watch on an
    // affected parent has adopted newly-added children. We deliberately no
    // longer do a synchronous pre-push emit.
    phaseSw
      ..reset()
      ..start();
    await _push();
    _perfLog('push ${_ms(phaseSw)}');

    phaseSw
      ..reset()
      ..start();
    final affectedGoalIds = await _computeAffectedGoalIds(newOps);
    _perfLog(
        'computeAffectedGoalIds ${_ms(phaseSw)} (affected=${affectedGoalIds.length})');

    phaseSw
      ..reset()
      ..start();
    var loadedCount = 0;
    for (final goalId in affectedGoalIds) {
      if (_goalLoadState[goalId] == _GoalLoadState.fullyLoaded) {
        // if the goal is already fully loaded, we don't need to load it again
        continue;
      }

      await loadGoal(goalId);
      loadedCount++;
    }
    _perfLog('loadGoal_loop ${_ms(phaseSw)} (loaded=$loadedCount)');

    phaseSw
      ..reset()
      ..start();
    _computeAndEmitUnsyncedState(
      "new unsynced ops, after goal loads",
      affectedGoalIds: affectedGoalIds,
    );
    _perfLog('emit (post-load) ${_ms(phaseSw)}');

    // Yield once so the live per-goal subjects fan out to their watchers
    // before this future resolves. This is what makes "await modifyGoals;
    // then render" correct: by the time the caller resumes, a watch on an
    // affected parent has received the update and adopted any newly-added
    // child into its `currentValue`. A microtask drain (not a timer) keeps
    // this off the event queue so widget tests don't need an extra pump.
    await Future<void>.microtask(() {});

    _maybeEvict();

    _perfLog('TOTAL handleNewUnsyncedOps ${_ms(totalSw)}');
  }

  Future<Set<String>> _computeAffectedGoalIds(Iterable<Op> ops) async {
    final result = <String>{};
    for (final op in ops) {
      switch (op) {
        case DeltaOp deltaOp:
          result.addAll(getAffectedGoalIdsFromDeltaOp(deltaOp));
          break;
        case EnableOp(opId: final affectedOpId) ||
              DisableOp(opId: final affectedOpId):
          // Resolve the referenced op to find which goal it touches. Check
          // in-memory state first (`_workingOps` + the unsynced-ops list):
          // undo/redo reference recently-local ops that are reliably still in
          // memory but may not be retrievable from the local store within the
          // same session. Fall back to disk for older targets.
          var affectedOp = _lookupOpInMemory(affectedOpId);
          affectedOp ??=
              (await localStore.loadOpsById([affectedOpId])).firstOrNull;
          if (affectedOp == null) {
            _logger?.log('No affected op found for $affectedOpId', opId: op.id);
            continue;
          }
          if (affectedOp is! DeltaOp) {
            _logger?.log('Affected op is not a DeltaOp: $affectedOpId',
                opId: op.id);
            continue;
          }
          result.addAll(getAffectedGoalIdsFromDeltaOp(affectedOp));
          break;
      }
    }
    return result;
  }

  /// Looks up an op by id in in-memory state only: first `_workingOps`,
  /// then the unsynced-ops list. Returns `null` if the op is on disk only.
  Op? _lookupOpInMemory(String opId) {
    final working = _workingOps[opId];
    if (working != null) return working;
    for (final op in localStore.getUnsyncedOps()) {
      if (op.id == opId) return op;
    }
    return null;
  }

  Map<String, Goal> _computeAndEmitUnsyncedState(
    String trigger, {
    Set<String>? affectedGoalIds,
  }) {
    _logger?.log('_computeAndEmitUnsyncedState: $trigger');

    final opsToApply = [..._workingOps.values, ...localStore.getUnsyncedOps()];
    final clonedBase = _computeStateFromBase(opsToApply);

    for (final op in opsToApply) {
      _emittedWorkingStateOpIds.add(op.id);
    }

    _emitState(clonedBase, affectedGoalIds: affectedGoalIds);

    return clonedBase;
  }

  /// Returns a [Goal] from [goalMap] that is safe to mutate without affecting
  /// [_baseState]. If the current entry is the same instance as [_baseState]'s
  /// entry for [goalId], clones it and replaces the entry. Otherwise returns
  /// the existing entry (already a clone or a goal created during this
  /// projection). Returns null when [goalMap] has no entry for [goalId].
  Goal? _ensureMutable(Map<String, Goal> goalMap, String goalId) {
    final existing = goalMap[goalId];
    if (existing == null) return null;
    if (identical(_baseState[goalId], existing)) {
      final cloned = existing.clone();
      goalMap[goalId] = cloned;
      return cloned;
    }
    return existing;
  }

  Map<String, Goal> _computeStateFromBase(Iterable<Op> ops) {
    final totalSw = Stopwatch()..start();

    // Shallow copy: values still point at _baseState's Goal instances.
    // Any goal we mutate gets cloned in-place via _ensureMutable on first
    // touch — so unchanged goals stay shared with _baseState.
    final copySw = Stopwatch()..start();
    final workingState = Map<String, Goal>.from(_baseState);
    _perfLog(
        '  computeStateFromBase.shallowCopy ${_ms(copySw)} (loaded=${_baseState.length})');

    final enableDisableSw = Stopwatch()..start();
    final effectiveOps = _applyEnableAndDisableOps(ops);
    _perfLog(
        '  computeStateFromBase.applyEnableDisable ${_ms(enableDisableSw)}');

    final sortSw = Stopwatch()..start();
    final sortedOps = effectiveOps
        .whereType<DeltaOp>()
        .sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    _perfLog(
        '  computeStateFromBase.sortDeltaOps ${_ms(sortSw)} (count=${sortedOps.length})');

    final applySw = Stopwatch()..start();
    final handledOpIds = <String>{};
    var appliedCount = 0;
    for (final op in sortedOps) {
      if (handledOpIds.contains(op.id)) {
        // skip already handled ops
        continue;
      }
      handledOpIds.add(op.id);

      _logger?.log('Synchronously applying op', opId: op.id);
      _applyDeltaOp(workingState, op);
      appliedCount++;
    }
    _perfLog(
        '  computeStateFromBase.applyDeltaOps ${_ms(applySw)} (applied=$appliedCount)');

    _perfLog('computeStateFromBase TOTAL ${_ms(totalSw)}');
    return workingState;
  }

  void _emitState(
    Map<String, Goal> newState, {
    Set<String>? affectedGoalIds,
  }) {
    final emittedStateOpCount =
        _emittedBaseStateOpIds.length + _emittedWorkingStateOpIds.length;
    final stateAdvanced = _lastEmittedStateOpCount != emittedStateOpCount;

    if (stateAdvanced) {
      _lastEmittedStateOpCount = emittedStateOpCount;
      stateSubject.add(newState);
    }

    // Always fan out to per-goal subjects in `affectedGoalIds`. The op-count
    // guard above skips redundant stateSubject emissions when concurrent
    // loadGoal calls each reach _emitState after the cumulative working-op
    // set has already grown — but the per-goal subjects for goals touched by
    // those calls still need pushes (a subject that was just created with a
    // null seed will otherwise never see its loaded goal). The identity check
    // below dedups when the goal instance hasn't changed.
    final fanOutIds = affectedGoalIds ?? _goalSubjects.subjectIds.toSet();
    for (final id in fanOutIds) {
      final subject = _goalSubjects.get(id);
      if (subject == null) continue;
      final newValue = newState[id];
      if (identical(subject.valueOrNull, newValue)) continue;
      subject.add(newValue);
    }

    if (!stateAdvanced) return;

    // If the state cursor hasn't changed, don't emit a new sync event.
    final stateCursor =
        "$_baseStateCursor:${(_emittedWorkingStateOpIds.length).toString().padLeft(5, '0')}";
    if (syncSubject.value == stateCursor) {
      return;
    }
    syncSubject.add(stateCursor);
  }

  Future<void> _modifyGoals(Iterable<GoalDelta> deltas) async {
    if (deltas.isEmpty) {
      return;
    }
    final newOps = _processDeltas(deltas);
    await _handleNewUnsyncedOps(newOps);
  }

  Future<void> undo() async {
    if (undoStack.isEmpty) {
      return;
    }
    final actionToUndo = undoStack.removeLast();
    await _undoAction(actionToUndo);
    redoStack.add(actionToUndo);
  }

  Future<void> redo() async {
    if (redoStack.isEmpty) {
      return;
    }
    final actionToRedo = redoStack.removeLast();
    await _redoAction(actionToRedo);
    undoStack.add(actionToRedo);
  }

  Future<void> _undoAction(String actionId) async {
    final actionOpIds = modificationMap[actionId];
    if (actionOpIds == null) {
      print('Action not found: $actionId');
      throw Exception('Action not found: $actionId');
    }
    final newOps = <Op>[];
    for (final opId in actionOpIds) {
      hlc = hlc.increment();
      final op = DisableOp(
        id: Cupid.random().encode(),
        hlcTimestamp: hlc.pack(),
        opId: opId,
      );
      _logger?.log('Disable Op Created. Disabling ${op.opId}', opId: op.id);
      _logger?.log('Disable Op Created. Being Disabled By ${op.id}',
          opId: op.opId);
      newOps.add(op);
    }
    _logger
        ?.log('Undoing action: $actionId with ops: ${newOps.map((e) => e.id)}');
    await _handleNewUnsyncedOps(newOps);
  }

  Future<void> _redoAction(String actionId) async {
    final actionOpIds = modificationMap[actionId];
    if (actionOpIds == null) {
      print('Action not found: $actionId');
      throw Exception('Action not found: $actionId');
    }
    final newOps = <Op>[];
    for (final opId in actionOpIds) {
      hlc = hlc.increment();
      final op = EnableOp(
          id: Cupid.random().encode(), hlcTimestamp: hlc.pack(), opId: opId);
      _logger?.log('Enable Op Created. Enabling ${op.opId}', opId: op.id);
      _logger?.log('Enable Op Created. Being Re-Enabled By ${op.id}',
          opId: op.opId);
      newOps.add(op);
    }

    await _handleNewUnsyncedOps(newOps);
  }

  bool _checkCycles(Map<String, Goal> goalMap, String goalId,
      Set<String> frontierIds, Set<String> seenIds) {
    if (frontierIds.isEmpty) {
      return false;
    }

    if (frontierIds.contains(goalId)) {
      return true;
    }

    Set<String> newFrontierIds = {};
    for (final parentId in frontierIds) {
      final parent = goalMap[parentId];
      if (parent == null) {
        // if we don't have the parent, just allow this parent relationship and wait for it to be handled by the async process
        return false;
      }
      for (final superGoalId in parent.superGoalIds) {
        if (superGoalId == goalId) {
          return true;
        }
        if (!seenIds.contains(superGoalId)) {
          newFrontierIds.add(superGoalId);
          seenIds.add(superGoalId);
        }
      }
    }

    return _checkCycles(goalMap, goalId, newFrontierIds, seenIds);
  }

  Set<String> _evaluateSuperGoals(
      Map<String, Goal> goalMap, Goal goal, GoalLogEntry? entry) {
    final Set<String> modifiedGoalIds = {};
    if (entry is SetParentLogEntry) {
      // Snapshot superGoalIds before clearing — clear() would invalidate iteration.
      final priorSuperGoalIds = goal.superGoalIds.toList(growable: false);
      for (final superGoalId in priorSuperGoalIds) {
        // We'll detach the sub goal from each existing super goal if it
        // exists. It may not — in a partial-state world the super goal may
        // not be loaded yet.
        final superGoal = _ensureMutable(goalMap, superGoalId);
        if (superGoal != null) {
          superGoal.removeSubGoal(goal.id);
        }
        modifiedGoalIds.add(superGoalId);
      }

      goal.superGoalRelationships.clear();

      final newParentId = entry.parentId;
      if (newParentId == null) {
        return modifiedGoalIds;
      }

      goal.addSuperGoal(newParentId, entry);
      modifiedGoalIds.add(goal.id);
      modifiedGoalIds.add(newParentId);

      final newSuperGoal = _ensureMutable(goalMap, newParentId);
      if (newSuperGoal != null) {
        // TODO: how does this work in an async world?
        if (_checkCycles(
            goalMap, goal.id, {newSuperGoal.id}, {newSuperGoal.id})) {
          // silently ignore deltas that would create cycles ¯\_(ツ)_/¯
          return {};
        }

        newSuperGoal.addSubGoal(goal.id, entry);
      }
    } else if (entry is AddParentLogEntry) {
      final childId = entry.isSlice ? entry.id : goal.id;
      goal.addSuperGoal(entry.parentId, entry);
      modifiedGoalIds.add(goal.id);

      // We'll add the sub goal to the new super goal if it exists
      // This is not an error because in a partial-state
      // world, the super goal may not be loaded yet.
      final newSuperGoal = _ensureMutable(goalMap, entry.parentId);
      if (newSuperGoal != null) {
        if (_checkCycles(
            goalMap, childId, {newSuperGoal.id}, {newSuperGoal.id})) {
          // silently ignore deltas that would create cycles ¯\_(ツ)_/¯
          return {};
        }

        newSuperGoal.addSubGoal(goal.id, entry);
      }
      modifiedGoalIds.add(entry.parentId);
    } else if (entry is RemoveParentLogEntry) {
      goal.removeSuperGoal(entry.parentId);
      modifiedGoalIds.add(goal.id);

      // Don't worry if the previous super goal is null
      final prevSuperGoal = _ensureMutable(goalMap, entry.parentId);
      if (prevSuperGoal != null) {
        prevSuperGoal.removeSubGoal(goal.id);
      }
      modifiedGoalIds.add(entry.parentId);
    }
    return modifiedGoalIds;
  }

  Set<String> _applyDeltaOp(Map<String, Goal> goalMap, DeltaOp op) {
    _logger?.log('_applyDeltaOp', opId: op.id);
    final modifiedGoalIds = <String>{};

    final opHlc = HLC.unpack(op.hlcTimestamp);
    hlc = hlc.receive(opHlc);
    _touch(op.delta.id);
    Goal? goal = goalMap[op.delta.id];

    if (goal == null) {
      goal = Goal(
          id: op.delta.id,
          text: op.delta.text,
          // TODO: make an explicit goal creation log entry.
          creationTime: DateTime.fromMillisecondsSinceEpoch(opHlc.timestamp));
      modifiedGoalIds.add(op.delta.id);
      _logger?.log('Creating new goal', goalId: goal.id);

      goalMap[op.delta.id] = goal;
    } else {
      // Clone-on-write: if this goal is still the _baseState instance, swap
      // in a clone before any subsequent mutation.
      goal = _ensureMutable(goalMap, op.delta.id)!;
    }

    if (op.delta.text != null && goal.text != op.delta.text) {
      goal.text = op.delta.text!;
      modifiedGoalIds.add(op.delta.id);
    }

    final entry = op.delta.logEntry;
    if (entry != null) {
      // TODO: should we be requiring entry id's be absolutely unique?
      if (goal.log.firstWhereOrNull(
              (e) => e.id == entry.id && e.runtimeType == entry.runtimeType) ==
          null) {
        goal.prependEntry(entry);
        modifiedGoalIds.add(op.delta.id);

        if (entry is CreateInstanceLogEntry) {
          goalMap[entry.id] = GoalInstance(
            goal: goal,
            id: entry.id,
            creationTime: entry.creationTime,
          );
          modifiedGoalIds.add(entry.id);
        }
      }

      // We evaluate super goals even if the entry is already in the log
      // because it's possible that we need to update the super goal.
      modifiedGoalIds.addAll(_evaluateSuperGoals(goalMap, goal, entry));
    }

    return modifiedGoalIds;
  }

  Map<String, String> _computeDisabledOps([Iterable<Op> ops = const []]) {
    _logger?.log('_computeDisabledOps with ops: ${ops.map((e) => e.id)}');
    final disabledOps = <String, String>{};

    for (final op in [
      ...ops,
      ..._workingOps.values,
      ...localStore.getUnsyncedOps(),
    ].cast<Op>().sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp))) {
      // TODO: what happens if we disable a disable op?
      // perhaps we should iterate backwards and check if the op is disabled?
      if (op is DisableOp) {
        _logger?.log("Applying disable op.", opId: op.id);
        _logger?.log("Op is being disabled.", opId: op.opId);
        disabledOps[op.opId] = op.id;
      } else if (op is EnableOp) {
        _logger?.log("Applying enable op.", opId: op.id);
        _logger?.log("Op is being enabled.", opId: op.opId);
        disabledOps.remove(op.opId);
      }
    }

    return disabledOps;
  }

  Future<Map<String, Goal>> _persistOps(Iterable<Op> newSyncedOps,
      {bool loadAffectedGoals = true}) async {
    if (newSyncedOps.isEmpty) {
      return _computeStateFromBase(_workingOps.values);
    }

    final affectedGoalIds = await _computeAffectedGoalIds(newSyncedOps);

    for (final goalId in affectedGoalIds) {
      _touch(goalId);
    }

    if (loadAffectedGoals) {
      final futures = <Future<void>>[];
      for (final goalId in affectedGoalIds) {
        if (_goalLoadState[goalId] == _GoalLoadState.fullyLoaded) {
          // if the goal is already fully loaded, we don't need to load it again
          continue;
        }

        _goalLoadState[goalId] = _GoalLoadState.loading;
        _logger?.log('Loading goal $goalId due to new synced ops');
        futures.add(loadGoal(goalId));
      }
      await Future.wait(futures);
    } else {
      for (final goalId in affectedGoalIds) {
        if (_goalLoadState[goalId] != _GoalLoadState.fullyLoaded) {
          _goalLoadState[goalId] = _GoalLoadState.fullyLoaded;
        }
      }
    }

    final state = _computeStateFromBase(
      _workingOps.isEmpty
          ? newSyncedOps
          : [..._workingOps.values, ...newSyncedOps],
    );

    final newIndexValues = <String, Set<String>>{};

    for (final index in _indexers.entries) {
      newIndexValues[index.key] = localStore.getIndexGoalIds(index.key);
    }

    for (final goalId in affectedGoalIds) {
      for (final MapEntry(key: indexKey, value: indexer) in _indexers.entries) {
        final goal = state[goalId];
        // This means that the goal has been removed, likely
        // as a result of an undo.
        if (goal == null) {
          newIndexValues[indexKey]!.remove(goalId);
          continue;
        }

        if (indexer(goal)) {
          newIndexValues[indexKey]!.add(goal.id);
        } else {
          newIndexValues[indexKey]!.remove(goal.id);
        }
      }
    }

    for (final index in newIndexValues.entries) {
      localStore.setIndexGoalIds(index.key, index.value);
    }

    // Update goal names index for affected goals
    for (final goalId in affectedGoalIds) {
      final goal = state[goalId];
      if (goal == null) {
        // Goal has been removed, remove from names index
        _goalNamesIndex.removeWhere((name, id) => id == goalId);
      } else {
        // Goal exists, ensure it's in the names index
        final normalizedText = goal.text.toLowerCase();
        if (normalizedText.isNotEmpty) {
          // Remove any old entries for this goal ID first
          _goalNamesIndex.removeWhere((name, id) => id == goalId);
          // Add current mapping
          _goalNamesIndex[normalizedText] = goalId;
        }
      }
    }
    // Save the updated names index
    if (affectedGoalIds.isNotEmpty) {
      _saveGoalNamesIndex();
    }

    // synchronously updates the caches and queues storage to hive
    // so we don't need to wait.
    localStore.storeSyncedOps(newSyncedOps);

    _maybeEvict();

    return state;
  }

  Future<Goal?> loadGoal(String goalId) async {
    _logger?.log('loadGoal', goalId: goalId);
    final totalSw = Stopwatch()..start();
    final baseStateCursor = _baseStateCursor;

    if (_goalLoadState[goalId] == _GoalLoadState.fullyLoaded) {
      _touch(goalId);
      _perfLog('loadGoal($goalId) TOTAL ${_ms(totalSw)} (cache hit)');
      return stateSubject.value[goalId];
    }

    final loadOpsSw = Stopwatch()..start();
    var opsToApply = await localStore.loadOpsForGoal(goalId);
    _perfLog(
        'loadGoal.loadOpsForGoal($goalId) ${_ms(loadOpsSw)} (ops=${opsToApply.length})');

    if (opsToApply.isEmpty) {
      _goalLoadState[goalId] = _GoalLoadState.fullyLoaded;
      _touch(goalId);
      _perfLog('loadGoal($goalId) TOTAL ${_ms(totalSw)} (empty)');
      return null;
    }

    // Ops up through the baseStateCursor are applied to the base state.
    // The rest are working ops that are used to compute the unsynced state.
    // TODO: is it possible for a loadGoal call to have ops that are after the baseStateCursor?
    final (baseOps, workingOps) = opsToApply.partition((op) =>
        baseStateCursor != null &&
        op.hlcTimestamp.comesBeforeOrEquals(baseStateCursor));

    if (baseOps.isNotEmpty) {
      // the goal that we loaded the ops for is the only one that is safe to
      // transfer to the base state.
      final newGoalBase = _computeStateFromBase(baseOps);
      final loadedGoal = newGoalBase[goalId];
      if (loadedGoal != null) {
        _baseState[goalId] = loadedGoal;
        _emittedBaseStateOpIds.addAll(baseOps.map((op) => op.id));
      }
    }

    _workingOps.addAll({for (var op in workingOps) op.id: op});

    if (localStore is CachingLocalStore && baseStateCursor != null) {
      (localStore as CachingLocalStore).evictCachedOps(before: baseStateCursor);
    }

    // Loading a goal touches the goal itself plus any parent referenced by
    // its ops (via AddParentLogEntry / SetParentLogEntry / RemoveParentLogEntry
    // in `_evaluateSuperGoals`). Fan out to all of those.
    final affectedIds = await _computeAffectedGoalIds(opsToApply)
      ..add(goalId);
    final newState = _computeAndEmitUnsyncedState(
      'loadGoal',
      affectedGoalIds: affectedIds,
    );
    _goalLoadState[goalId] = _GoalLoadState.fullyLoaded;
    _touch(goalId);

    _maybeEvict();

    _perfLog('loadGoal($goalId) TOTAL ${_ms(totalSw)}');

    return newState[goalId];
  }

  /// Loads the goal identified by [goalId] (idempotent) and returns a
  /// [GoalRef] that pins it in the resident set until disposed. Use this
  /// for short-lived imperative work that needs a goal to stay loaded for
  /// the duration of a handler (drop targets, keybinding actions, document
  /// computations).
  Future<GoalRef> loadGoalRef(String goalId) async {
    await loadGoal(goalId);
    _pin(goalId);
    return GoalRef._(this, goalId);
  }

  /// Returns a [WatchedGoalSet] that holds one pin per id in [goalIds] and
  /// emits a `Map<String, Goal>` whenever any watched goal changes. Use this
  /// for reactive views (tree, detail panel, search results) that need to
  /// rebuild on per-goal updates without subscribing to the whole resident
  /// set via `stateSubject`.
  WatchedGoalSet watchGoals(Iterable<String> goalIds) {
    return WatchedGoalSet._(this, goalIds);
  }

  Iterable<Op> _reHlcOps(Iterable<Op> ops) {
    List<Op> result = [];
    for (Op op in ops) {
      final newHlc = hlc.pack();
      result.add(switch (op) {
        DeltaOp() => DeltaOp(
            id: op.id,
            hlcTimestamp: newHlc,
            delta: op.delta,
          ),
        DisableOp() => DisableOp(
            id: op.id,
            hlcTimestamp: newHlc,
            opId: op.opId,
          ),
        EnableOp() => EnableOp(
            id: op.id,
            hlcTimestamp: newHlc,
            opId: op.opId,
          ),
        // Add a default case to handle any other Op types, though ideally this shouldn't be hit.
        _ => throw Exception(
            'Unknown op type encountered in _reHlcOps: \${op.runtimeType}'),
      });

      hlc = hlc.increment();
    }

    return result;
  }

  Iterable<Op> _applyEnableAndDisableOps(Iterable<Op> ops) {
    final opMap = <String, Op>{};
    final disabledOpMap = <String, Op>{};
    for (final op
        in ops.sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp))) {
      opMap[op.id] = op;
      if (op is DisableOp) {
        final opToDisable = opMap[op.opId];
        // if the op that we're disabling is in the list of ops
        // we remove it from the list of ops and add it to the disabledOpMap
        if (opToDisable != null) {
          disabledOpMap[op.opId] = opToDisable;
          opMap.remove(op.opId);
        }
      } else if (op is EnableOp) {
        final opToEnable = disabledOpMap[op.opId];

        if (opToEnable != null) {
          // if the op that we're enabling is in the disabledOpMap, we remove it
          // from the disabledOpMap and add it back to the opMap
          disabledOpMap.remove(op.opId);
          opMap[op.hlcTimestamp] = opToEnable;
        }
      }
    }
    return opMap.values;
  }

  Future<void> _pull() async {
    if (persistenceService == null) {
      print('[SYNC-DIAG] _pull: skipped (no persistenceService)');
      return;
    }

    LoadOpsResp result;
    String? latestCursor = localStore.cursor;
    int batchSize = 4000;
    print('[SYNC-DIAG] _pull: start cursor=$latestCursor');

    try {
      do {
        result = await persistenceService!
            .load(cursor: latestCursor, limit: batchSize);
        print(
            '[SYNC-DIAG] _pull: loaded ${result.ops.length} ops, newCursor=${result.cursor}');

        for (Op op in result.ops) {
          HLC.unpack(op.hlcTimestamp);
          hlc = hlc.receive(HLC.unpack(op.hlcTimestamp));
        }

        _baseState = await _persistOps(result.ops);

        if (result.cursor != null &&
            (localStore.cursor == null ||
                result.cursor!.compareTo(localStore.cursor!) > 0)) {
          latestCursor = result.cursor;
        }
      } while (result.ops.length >= batchSize);

      localStore.lastSyncTime = DateTime.now();
      print('[SYNC-DIAG] _pull: end cursor=${localStore.cursor}');
    } catch (e, stackTrace) {
      print('[SYNC-DIAG] _pull: FAILED error=$e');
      print('[SYNC-DIAG] _pull: stack=$stackTrace');
      rethrow;
    }
  }

  Future<void> _push() async {
    _logger?.log('_push');
    if (persistenceService == null) {
      print('[SYNC-DIAG] _push: skipped (no persistenceService)');
      return;
    }

    Iterable<Op> sortedUnsyncedOps = localStore.getUnsyncedOps().sorted(
          (a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp),
        );

    print(
        '[SYNC-DIAG] _push: start unsyncedCount=${sortedUnsyncedOps.length}');

    if (sortedUnsyncedOps.isNotEmpty) {
      await localStore.setUnsyncedOps(sortedUnsyncedOps);
      final unsyncedOpsBatches = <List<Op>>[];
      for (int i = 0; i < sortedUnsyncedOps.length; i += 1000) {
        unsyncedOpsBatches.add(sortedUnsyncedOps.skip(i).take(1000).toList());
      }
      try {
        for (final batch in unsyncedOpsBatches) {
          final mappedOps = _reHlcOps(batch);
          for (final op in mappedOps) {
            _logger?.log('Pushing op to remote', opId: op.id);
          }
          print(
              '[SYNC-DIAG] _push: calling persistenceService.save batchSize=${mappedOps.length}');
          await persistenceService!.save(mappedOps);
          print(
              '[SYNC-DIAG] _push: save resolved successfully for ${mappedOps.length} ops');
          final unsyncedOps = localStore.getUnsyncedOps().toList();
          for (final op in mappedOps) {
            _logger?.log('Op pushed to remote', opId: op.id);
            unsyncedOps.removeWhere((e) => e.id == op.id);
            _workingOps[op.id] = op;
          }
          localStore.setUnsyncedOps(unsyncedOps);
        }
      } catch (e, stackTrace) {
        print('[SYNC-DIAG] _push: SAVE FAILED error=$e');
        print('[SYNC-DIAG] _push: stack=$stackTrace');
        print('[_push] Save failed: $e');
      }
    }
    print(
        '[SYNC-DIAG] _push: end unsyncedCount=${localStore.getUnsyncedOps().length}');
  }

  Future<void> sync() async {
    final currentSyncFuture = syncFuture;
    final syncCompleter = Completer<void>();
    syncFuture = syncCompleter.future;
    await currentSyncFuture;

    if (persistenceService != null) {
      await _pull();

      await _push();
    }

    _computeAndEmitUnsyncedState("sync");
    syncCompleter.complete();
  }

  Future<void> logOut() async {
    try {
      await localStore.clear();
    } catch (e) {
      print('Failed to clear local store: $e');
    }
    undoStack.clear();
    redoStack.clear();
    _baseState = {};
    _pinCount.clear();
    _lastAccessed.clear();
    _goalSubjects.closeAll();
    _goalNamesIndex.clear();
    hlc = HLC.now(localStore.clientId);
    stateSubject.add({});
    syncSubject.add(null);
    syncFuture = Future.value();
  }

  // Goal Names Index Management
  static const String _goalNamesIndexKey = "goalNamesIndex";

  /// Load the goal names index from storage into memory
  Future<void> _loadGoalNamesIndex() async {
    final indexData = await localStore.loadSearchIndex(_goalNamesIndexKey);
    if (indexData != null) {
      try {
        final Map<String, dynamic> parsed = jsonDecode(indexData);
        _goalNamesIndex = parsed.cast<String, String>();
      } catch (e) {
        print('Failed to parse goal names index: $e');
        _goalNamesIndex = {};
      }
    } else {
      _goalNamesIndex = {};
    }
  }

  /// Save the goal names index to storage
  Future<void> _saveGoalNamesIndex() async {
    final indexData = jsonEncode(_goalNamesIndex);

    await localStore.setSearchIndex(_goalNamesIndexKey, indexData);
  }

  /// Search for goals by name using the in-memory index
  List<String> searchGoalsByName(String searchText) {
    if (searchText.isEmpty) {
      return [];
    }

    final normalizedSearch = searchText.toLowerCase();
    final matchingGoalIds = <String>[];

    // Find goals whose names contain the search text
    for (final MapEntry(key: goalName, value: goalId)
        in _goalNamesIndex.entries) {
      if (goalName.contains(normalizedSearch)) {
        matchingGoalIds.add(goalId);
      }
    }

    return matchingGoalIds;
  }
}

/// A reference handle for a single loaded goal. Holding a [GoalRef] pins the
/// goal in [SyncClient]'s resident set; once disposed, the pin is released
/// and the goal becomes a candidate for LRU eviction (Phase D).
///
/// Created by [SyncClient.loadGoalRef]. Disposal is idempotent.
class GoalRef {
  final SyncClient _client;
  final String goalId;
  bool _disposed = false;

  GoalRef._(this._client, this.goalId);

  /// The current value of the goal in the working state, or `null` if the
  /// goal does not (yet) exist. Read-only — does not refresh LRU on access
  /// since the pin itself is the access signal.
  Goal? get goal => _client.stateSubject.value[goalId];

  /// Releases the pin. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _client._unpin(goalId);
  }
}

/// A reactive view over a dynamic set of goal ids. Holds one pin per id in
/// its current set and emits a `Map<String, Goal>` whenever a watched goal
/// changes.
///
/// Created by [SyncClient.watchGoals]. Update the watched ids via [setIds]
/// (bulk replace), [add] (single id), or [remove] (single id). Always
/// [dispose] when done — otherwise the pins leak.
class WatchedGoalSet {
  final SyncClient _client;
  final Set<String> _ids = {};
  final Map<String, StreamSubscription<Goal?>> _subs = {};
  final Map<String, Goal> _current = {};
  final BehaviorSubject<Map<String, Goal>> _output =
      BehaviorSubject.seeded(const {});
  bool _disposed = false;

  WatchedGoalSet._(this._client, Iterable<String> initialIds) {
    setIds(initialIds);
  }

  /// A `Map<String, Goal>` containing only the currently-watched goals.
  /// Goals not yet loaded (or that have no value) are omitted from the map.
  Stream<Map<String, Goal>> get stream => _output.stream;

  /// The live, synchronous snapshot of the currently-watched goals. Unlike a
  /// value cached off [stream] (which lags by a microtask plus any throttle
  /// window), this reflects every mutation that has already been applied to
  /// the watch set — including children adopted during the current
  /// emit. Consumers that render in the same turn as a mutation (e.g. right
  /// after awaiting `modifyGoals`) should read this rather than a stream copy,
  /// and use [stream] only as a rebuild trigger.
  Map<String, Goal> get currentValue => Map<String, Goal>.unmodifiable(_current);

  /// Snapshot of the goal ids this set currently watches.
  Set<String> get watchedIds => Set<String>.unmodifiable(_ids);

  /// Replaces the watched-id set with [newIds]. Pins newly-added ids and
  /// unpins removed ids in a single pass. Calling with the existing set is
  /// a no-op.
  void setIds(Iterable<String> newIds) {
    if (_disposed) return;
    final newSet = newIds.toSet();
    final currentIds = Set<String>.from(_ids);
    final toAdd = newSet.difference(currentIds);
    final toRemove = currentIds.difference(newSet);
    for (final id in toAdd) {
      _addId(id);
    }
    for (final id in toRemove) {
      _removeId(id);
    }
  }

  /// Adds [id] to the watched set. No-op if [id] is already watched.
  void add(String id) {
    if (_disposed || _ids.contains(id)) return;
    _addId(id);
  }

  /// Removes [id] from the watched set. No-op if [id] is not watched.
  void remove(String id) {
    if (_disposed || !_ids.contains(id)) return;
    _removeId(id);
  }

  void _addId(String id) {
    _ids.add(id);
    _client._pin(id);
    final subject = _client._goalSubjects.getOrCreate(
      id,
      () => _client.stateSubject.value[id],
    );
    // Seed `_current` synchronously from the subject's current value so a
    // freshly-added id (in particular, a child adopted mid-emit) is reflected
    // in [currentValue] in the same turn, rather than one microtask later when
    // the subscription below first fires.
    final seed = subject.valueOrNull;
    if (seed != null) {
      _current[id] = seed;
    }
    _subs[id] = subject.listen((goal) {
      if (_disposed) return;
      final previous = _current[id];
      if (goal != null) {
        _current[id] = goal;
      } else {
        _current.remove(id);
      }
      // Reactive adoption: when an already-watched parent gains a child, pull
      // that child into the watch set immediately so consumers render it in
      // the same turn the parent update arrives — no re-traversal / setIds
      // round-trip, no one-frame flash. Scoped to children that newly appear
      // on an update (`previous != null`): we deliberately do NOT adopt the
      // pre-existing children of a goal on its initial load, so watching a
      // collapsed node doesn't drag in its whole child level. The adoption is
      // a transient bridge — the consumer's next setIds reconciles it (and
      // unpins anything it no longer wants).
      if (goal != null && previous != null) {
        final previousChildren = previous.subGoalIds;
        for (final childId in goal.subGoalIds) {
          if (!previousChildren.contains(childId) && !_ids.contains(childId)) {
            _addId(childId);
          }
        }
      }
      _emit();
    });
    // Kick off load if needed; loadGoal is idempotent on fullyLoaded.
    // Fire-and-forget — when the load completes, _emitState fans out to
    // the subject we just registered.
    _client.loadGoal(id);
  }

  void _removeId(String id) {
    _ids.remove(id);
    _subs.remove(id)?.cancel();
    _current.remove(id);
    _client._unpin(id);
    // Close the per-goal subject only if no other watcher (or loadGoalRef)
    // holds a pin on this id.
    if ((_client._pinCount[id] ?? 0) == 0) {
      _client._goalSubjects.close(id);
    }
    if (!_disposed) {
      _emit();
    }
  }

  void _emit() {
    if (_output.isClosed) return;
    _output.add(Map<String, Goal>.from(_current));
  }

  /// Releases every pin held by this set and closes the output stream.
  /// Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final ids = List<String>.from(_ids);
    for (final id in ids) {
      _removeId(id);
    }
    await _output.close();
  }
}
