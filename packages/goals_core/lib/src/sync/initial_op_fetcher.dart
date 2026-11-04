import 'dart:convert' show jsonEncode;

import 'package:goals_core/sync.dart'
    show LocalStore, PersistenceService, LoadOpsResp;
import 'package:goals_types/goals_types.dart'
    show
        Op,
        DeltaOp,
        EnableOp,
        DisableOp,
        CreateInstanceLogEntry,
        GoalLogEntry,
        SetParentLogEntry,
        AddParentLogEntry,
        RemoveParentLogEntry,
        StatusLogEntry,
        ClearStatusLogEntry,
        GoalStatus;
import 'package:rxdart/subjects.dart' show BehaviorSubject;

class InitialOpFetcher {
  final PersistenceService persistenceService;
  final LocalStore localStore;

  // Progress tracking for initial load: (downloaded ops, total ops expected)
  // null means initial load is complete
  BehaviorSubject<({int downloaded, int total, bool isComplete})?>
      initialLoadProgressSubject = BehaviorSubject.seeded(null);

  final Map<String, List<DeltaOp>> _goalParentOps = {};
  final Map<String, List<DeltaOp>> _goalStatusOps = {};
  final Map<String, List<DeltaOp>> _goalNameOps = {};

  /// The oldest HLC of any delta op on each goal, or of the op creating an
  /// instance: the point from which the fold has that id in its goal map.
  /// Doesn't look at whether that op is later disabled, which the fold's walk
  /// would see.
  final Map<String, String> _firstSeenHlc = {};

  final List<Op> _enableAndDisableOps = [];

  final Set<String> _disabledOps = {};

  InitialOpFetcher({
    required this.persistenceService,
    required this.localStore,
  });

  /// Works out which recorded ops the fold would apply, and in what order.
  ///
  /// Ops are read in document order and a batch at a time, so this waits for
  /// the last batch and then follows `SyncClient._applyEnableAndDisableOps`
  /// and `_computeStateFromBase`: an op disabled by an older Disable stays
  /// enabled, and an op id with several docs applies once.
  List<DeltaOp> _computeEffectiveOps() {
    final opMap = <String, Op>{};
    final disabledOpMap = <String, Op>{};
    final recordedOps = <Op>[
      for (final ops in _goalParentOps.values) ...ops,
      for (final ops in _goalStatusOps.values) ...ops,
      for (final ops in _goalNameOps.values) ...ops,
      ..._enableAndDisableOps,
    ]..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    for (final op in recordedOps) {
      opMap[op.id] = op;
      if (op is DisableOp) {
        final opToDisable = opMap.remove(op.opId);
        if (opToDisable != null) {
          disabledOpMap[op.opId] = opToDisable;
        }
      } else if (op is EnableOp) {
        final opToEnable = disabledOpMap.remove(op.opId);
        if (opToEnable != null) {
          opMap[op.hlcTimestamp] = opToEnable;
        }
      }
    }

    final effectiveOps = opMap.values.whereType<DeltaOp>().toList()
      ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    final handledOpIds = <String>{};
    return [
      for (final op in effectiveOps)
        if (handledOpIds.add(op.id)) op
    ];
  }

  /// Whether a link from [goalId] to [parentId], made at [hlc], closes a
  /// cycle. Follows `SyncClient._checkCycles`, including allowing the link as
  /// soon as the walk meets a goal the fold wouldn't have yet.
  bool _closesCycle(Map<String, Set<String>> goalParents, String goalId,
      String parentId, String hlc) {
    bool isKnown(String id) {
      final firstSeen = _firstSeenHlc[id];
      return firstSeen != null && firstSeen.compareTo(hlc) <= 0;
    }

    if (!isKnown(parentId)) {
      return false;
    }
    if (parentId == goalId) {
      return true;
    }
    final seenIds = {parentId};
    var frontierIds = {parentId};
    while (frontierIds.isNotEmpty) {
      final newFrontierIds = <String>{};
      for (final id in frontierIds) {
        if (!isKnown(id)) {
          return false;
        }
        for (final superGoalId in goalParents[id] ?? const <String>{}) {
          if (superGoalId == goalId) {
            return true;
          }
          if (seenIds.add(superGoalId)) {
            newFrontierIds.add(superGoalId);
          }
        }
      }
      frontierIds = newFrontierIds;
    }
    return false;
  }

  /// Replays the parent ops in HLC order, skipping links that close a cycle.
  /// Nothing is dropped from the store, so if the other link in a cycle is
  /// later disabled, the next replay admits the skipped one.
  Set<String> _findRootGoalIds(List<DeltaOp> effectiveOps) {
    final goalParents = {for (final id in _goalParentOps.keys) id: <String>{}};

    for (final op in effectiveOps) {
      final goalId = op.delta.id;
      final parents = goalParents[goalId]!;
      switch (op.delta.logEntry) {
        case SetParentLogEntry(parentId: final parentId):
          parents.clear();
          if (parentId != null &&
              !_closesCycle(goalParents, goalId, parentId, op.hlcTimestamp)) {
            parents.add(parentId);
          }
        case AddParentLogEntry entry:
          // The fold checks a slice link using the slice's id.
          final childId = entry.isSlice ? entry.id : goalId;
          if (!_closesCycle(
              goalParents, childId, entry.parentId, op.hlcTimestamp)) {
            parents.add(entry.parentId);
          }
        case RemoveParentLogEntry(parentId: final parentId):
          parents.remove(parentId);
        default:
          break;
      }
    }

    return {
      for (final MapEntry(key: goalId, value: parents) in goalParents.entries)
        if (parents.isEmpty) goalId
    };
  }

  Set<String> _findStatusGoalIds(List<DeltaOp> effectiveOps) {
    final statusGoalIds = <String>{};

    // Oldest first. Like the fold's log, keeps the first of a repeated entry.
    final goalStatusEntries = <String, List<GoalLogEntry>>{};
    final seenEntries = <(String, Type, String)>{};
    for (final op in effectiveOps) {
      final entry = op.delta.logEntry;
      if ((entry is StatusLogEntry || entry is ClearStatusLogEntry) &&
          seenEntries.add((op.delta.id, entry.runtimeType, entry!.id))) {
        goalStatusEntries.putIfAbsent(op.delta.id, () => []).add(entry);
      }
    }

    for (final MapEntry(key: goalId, value: entries)
        in goalStatusEntries.entries) {
      for (final entry in entries.reversed) {
        if (entry is ClearStatusLogEntry) {
          break;
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
            statusGoalIds.add(goalId);
            break;
          }
          continue;
        }
        if (startTime == null) {
          if (endTime.isAfter(DateTime.now())) {
            statusGoalIds.add(goalId);
            break;
          }
          continue;
        }
        if (startTime.isAfter(DateTime.now()) ||
            endTime.isAfter(DateTime.now())) {
          statusGoalIds.add(goalId);
          break;
        }
      }
    }

    return statusGoalIds;
  }

  Map<String, String> _buildGoalSearchIndex() {
    final goalSearchIndex = <String, String>{};

    for (final entry in _goalNameOps.entries) {
      final goalId = entry.key;
      final nameOps = entry.value;

      for (final DeltaOp(id: id, delta: delta) in nameOps.reversed) {
        if (_disabledOps.contains(id)) {
          continue;
        }
        final goalName = delta.text;

        if (goalName == null) {
          continue;
        }

        goalSearchIndex[goalName.toLowerCase()] = goalId;
        break;
      }
    }

    return goalSearchIndex;
  }

  Future<void> doInitialFetch() async {
    int batchSize = 4000;

    int totalOpsDownloaded = 0;
    int totalOpsProcessed = 0;
    int totalOpsCount = await persistenceService.count();

    // Handle empty case
    if (totalOpsCount == 0) {
      localStore.lastSyncTime = DateTime.now();
      initialLoadProgressSubject
          .add((downloaded: 0, total: 0, isComplete: true));
      return;
    }

    emitProgress() {
      initialLoadProgressSubject.add((
        downloaded: totalOpsDownloaded + totalOpsProcessed,
        total: totalOpsCount * 2,
        isComplete: false
      ));
    }

    // Start with unknown total (we'll update as we discover more)
    initialLoadProgressSubject
        .add((downloaded: 0, total: 0, isComplete: false));

    await _streamOps(batchSize)
        .asyncMap((resp) async {
          totalOpsDownloaded += resp.ops.length;
          emitProgress();
          print('Processing ${resp.ops.length} ops');
          _processOps(resp.ops);
          await localStore.storeSyncedOps(resp.ops);
          totalOpsProcessed += resp.ops.length;
          emitProgress();
        })
        .listen((_) {})
        .asFuture();

    final effectiveOps = _computeEffectiveOps();
    final effectiveOpIds = {for (final op in effectiveOps) op.id};
    _disabledOps.addAll([
      for (final ops in _goalNameOps.values)
        for (final op in ops)
          if (!effectiveOpIds.contains(op.id)) op.id
    ]);

    // Determine root goals
    localStore.setIndexGoalIds("rootGoals", _findRootGoalIds(effectiveOps));
    localStore.setIndexGoalIds("statusGoals", _findStatusGoalIds(effectiveOps));
    localStore.setSearchIndex(
        "goalNamesIndex", jsonEncode(_buildGoalSearchIndex()));

    localStore.lastSyncTime = DateTime.now();

    // Clear initial load progress when done
    initialLoadProgressSubject.add(
        (downloaded: totalOpsCount, total: totalOpsCount, isComplete: true));
  }

  /// Stream cursor ranges by listing docs in chunks
  Stream<LoadOpsResp> _streamOps(int batchSize) async* {
    String? listCursor;

    while (true) {
      final resp = await persistenceService.load(
        cursor: listCursor,
        limit: batchSize,
      );

      if (resp.ops.isEmpty) {
        break;
      }

      yield resp;

      listCursor = resp.cursor;

      // If we got fewer docs than requested, we're done
      if (resp.ops.length < batchSize) {
        break;
      }
    }
  }

  /// Process operations and update internal tracking maps
  void _processOps(List<Op> ops) {
    for (final op in ops) {
      switch (op) {
        case DeltaOp deltaOp:
          _noteFirstSeen(deltaOp.delta.id, op.hlcTimestamp);
          if (!_goalParentOps.containsKey(deltaOp.delta.id)) {
            _goalParentOps[deltaOp.delta.id] = [];
          }
          if (deltaOp.delta.text != null) {
            final nameOps =
                _goalNameOps.putIfAbsent(deltaOp.delta.id, () => []);
            if (nameOps.lastOrNull?.delta.text != deltaOp.delta.text) {
              nameOps.add(deltaOp);
            }
          }
          switch (deltaOp.delta.logEntry) {
            case SetParentLogEntry _:
            case AddParentLogEntry _:
            case RemoveParentLogEntry _:
              _goalParentOps.putIfAbsent(deltaOp.delta.id, () => []).add(op);
              break;
            case StatusLogEntry _:
            case ClearStatusLogEntry _:
              _goalStatusOps.putIfAbsent(deltaOp.delta.id, () => []).add(op);
              break;
            case CreateInstanceLogEntry(id: final instanceId):
              _noteFirstSeen(instanceId, op.hlcTimestamp);
              break;
          }
          break;
        case DisableOp _:
        case EnableOp _:
          _enableAndDisableOps.add(op);
          break;
      }
    }
  }

  void _noteFirstSeen(String id, String hlc) {
    final firstSeen = _firstSeenHlc[id];
    if (firstSeen == null || hlc.compareTo(firstSeen) < 0) {
      _firstSeenHlc[id] = hlc;
    }
  }
}
