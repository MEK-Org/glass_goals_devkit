import 'dart:convert' show jsonEncode;

import 'package:goals_core/sync.dart'
    show LocalStore, PersistenceService, LoadOpsResp, GoalDelta;
import 'package:goals_types/goals_types.dart'
    show
        Op,
        DeltaOp,
        EnableOp,
        DisableOp,
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

  final Set<String> _applicableOpIds = {};

  final Set<String> _disabledOps = {};

  InitialOpFetcher({
    required this.persistenceService,
    required this.localStore,
  });

  Set<String> _findRootGoalIds() {
    final rootGoalIds = <String>{};

    for (final entry in _goalParentOps.entries) {
      final goalId = entry.key;
      final parentOps = entry.value;

      final parents = <String>{};

      for (final op in parentOps) {
        if (_disabledOps.contains(op.id)) {
          continue;
        }
        switch (op) {
          case DeltaOp deltaOp:
            switch (deltaOp.delta.logEntry) {
              case SetParentLogEntry(parentId: final parentId):
                parents.clear();
                if (parentId != null) {
                  parents.add(parentId);
                }
              case AddParentLogEntry(parentId: final parentId):
                parents.add(parentId);
              case RemoveParentLogEntry(parentId: final parentId):
                parents.remove(parentId);
            }
        }
      }
      if (parents.isEmpty) {
        rootGoalIds.add(goalId);
      }
    }

    return rootGoalIds;
  }

  Set<String> _findStatusGoalIds() {
    final statusGoalIds = <String>{};

    for (final entry in _goalStatusOps.entries) {
      final goalId = entry.key;
      final statusOps = entry.value;

      for (final DeltaOp(id: id, delta: GoalDelta(logEntry: entry))
          in statusOps.reversed) {
        if (_disabledOps.contains(id)) {
          continue;
        }
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

    // Determine root goals
    localStore.setIndexGoalIds("rootGoals", _findRootGoalIds());
    localStore.setIndexGoalIds("statusGoals", _findStatusGoalIds());
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
          if (!_goalParentOps.containsKey(deltaOp.delta.id)) {
            _goalParentOps[deltaOp.delta.id] = [];
          }
          if (deltaOp.delta.text != null) {
            final nameOps =
                _goalNameOps.putIfAbsent(deltaOp.delta.id, () => []);
            if (nameOps.lastOrNull?.delta.text != deltaOp.delta.text) {
              nameOps.add(deltaOp);
              _applicableOpIds.add(op.id);
            }
          }
          switch (deltaOp.delta.logEntry) {
            case SetParentLogEntry _:
            case AddParentLogEntry _:
            case RemoveParentLogEntry _:
              _goalParentOps.putIfAbsent(deltaOp.delta.id, () => []).add(op);
              _applicableOpIds.add(op.id);
              break;
            case StatusLogEntry _:
              _goalStatusOps.putIfAbsent(deltaOp.delta.id, () => []).add(op);
              _applicableOpIds.add(op.id);
              break;
          }
          break;
        case DisableOp(opId: final disabledOpId):
          if (_applicableOpIds.contains(disabledOpId)) {
            _disabledOps.add(disabledOpId);
          }
          break;
        case EnableOp(opId: final enabledOpId):
          _disabledOps.remove(enabledOpId);
          break;
      }
    }
  }
}
