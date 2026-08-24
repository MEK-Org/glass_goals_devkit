import 'dart:async' show Completer, Timer;
import 'dart:convert' show jsonDecode;

import 'package:collection/collection.dart';
import 'package:goals_core/src/sync/sync_repository.dart'
    show SyncRepository, MemorySyncRepository;
import 'package:goals_core/src/util/random_utils.dart'
    show generateRandomString;
import 'package:goals_core/src/util/string_utils.dart';
import 'package:goals_core/sync.dart'
    show DisableOp, EnableOp, Op, getAffectedGoalIdsFromDeltaOp;
import 'package:goals_types/goals_types.dart' show DeltaOp, TextGoalLogEntry;
import 'package:goals_core/src/util/lru_cache.dart' show LruCache;
import 'package:logging/logging.dart' show Logger;
import 'package:queue/queue.dart';

abstract class LocalStore {
  String? cursor;

  Future<void> init();

  /// The number of times we've had to do a full sync because we were missing ops; should be 0 in normal operation
  int get fullSyncCount;

  void incrementFullSyncCount();

  abstract DateTime? lastSyncTime;

  String get clientId;

  Future<void> setUnsyncedOps(Iterable<Op> ops);

  /// Returns the unsynced ops, which are ops that have not yet been synced to the server.
  /// These ops are guaranteed to be deduped and sorted by their HLC timestamp.
  Iterable<Op> getUnsyncedOps();

  Future<void> storeSyncedOps(Iterable<Op> ops);

  Set<String> getIndexGoalIds(String key);
  void setIndexGoalIds(String key, Set<String> goalIds);

  Future<String?> loadSearchIndex(String indexKey);
  Future<void> setSearchIndex(String indexKey, String indexData);

  Future<Iterable<Op>> getAllOps();

  Iterable<Op> getOpsById(Iterable<String> opIds);
  Future<Iterable<Op?>> loadOpsById(Iterable<String> opIds);

  Future<String?> loadString(String key);
  Future<void> setString(String key, String value);

  Future<void> clear();

  Future<Iterable<Op>> loadOpsForGoal(String goalId);
}

class CacheMissException implements Exception {
  final String message;
  CacheMissException(this.message);
}

class MemoryLocalStore extends CachingLocalStore {
  MemoryLocalStore() : super(repo: MemorySyncRepository());

  Map<String, Op> get opCache => _opCache;
  Map<String, Map<String, dynamic>> get goalIndex => _goalOpsIndexCache;

  Map<String, String> get goalNameIndex =>
      (jsonDecode(repo.loadSearchIndex("goalNamesIndex") ?? "{}")
              as Map<String, dynamic>)
          .cast<String, String>();
}

class CachingLocalStore implements LocalStore {
  final Map<String, Map<String, dynamic>> _goalOpsIndexCache = {};

  final SyncRepository repo;

  final _stringCache = LruCache<String, String>(
    cullingThreshold: 1000,
    maxAge: const Duration(minutes: 10),
  );

  final _opCache = <String, Op>{};

  final _opStorageQueue = Queue();

  final _opReadQueue = Queue();

  final _opLoadRequests = <String, (Completer<Op?>, DateTime)>{};

  Timer? _batchTimer;
  DateTime? _batchStartTime;

  final _goalIndexReadQueue = Queue();

  final _goalIndexLoadRequests = <String, Completer<Map<String, dynamic>?>>{};

  CachingLocalStore({
    required this.repo,
  });

  void clearCaches() {
    _stringCache.clear();
    _opCache.clear();
    _goalOpsIndexCache.clear();
  }

  void evictCachedOps({String? before}) {
    if (before == null) {
      _opCache.clear();
    } else {
      _opCache
          .removeWhere((key, value) => value.hlcTimestamp.comesBefore(before));
    }
  }

  @override
  String get clientId {
    var clientId = repo.clientId;
    if (clientId == null) {
      clientId = generateRandomString(4);
      repo.clientId = clientId;
    }
    return clientId;
  }

  @override
  String? get cursor => repo.cursor;

  @override
  set cursor(String? value) {
    if (value != repo.cursor) {
      repo.cursor = value;
    }
  }

  @override
  int get fullSyncCount => repo.fullSyncCount;

  @override
  get lastSyncTime => repo.lastSyncTime;

  @override
  set lastSyncTime(DateTime? value) {
    repo.lastSyncTime = value;
  }

  @override
  Iterable<Op> getUnsyncedOps() {
    return repo.getUnsyncedOps();
  }

  @override
  Future<void> init() async {
    await repo.init();
  }

  @override
  Future<void> setUnsyncedOps(Iterable<Op> ops) async {
    final opMap = <String, Op>{};
    for (final op in ops) {
      opMap[op.id] = op;
      // Eagerly store the text in the string box
      if (op is DeltaOp) {
        final entry = op.delta.logEntry;

        if (entry is TextGoalLogEntry && entry.text != null) {
          _stringCache[entry.id] = entry.text!;
          repo.storeString(entry.id, entry.text!);
        }
      }
    }
    await repo.setUnsyncedOps(opMap.values
        .sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp)));
  }

  Future<void> _getGoalIndexBatch() async {
    if (_goalIndexLoadRequests.isEmpty) {
      return;
    }

    // Check if any of the requested indices have been added to the cache
    // between the time the request was made and now.
    for (final goalId in _goalIndexLoadRequests.keys) {
      if (_goalOpsIndexCache.containsKey(goalId)) {
        final completer = _goalIndexLoadRequests.remove(goalId);
        completer?.complete(_goalOpsIndexCache[goalId]);
      }
    }

    final goalIdsToLoad = _goalIndexLoadRequests.keys.toList();
    if (goalIdsToLoad.isEmpty) {
      return;
    }

    final entries = await repo.loadGoalIndexEntries(goalIdsToLoad);

    for (final goalId in goalIdsToLoad) {
      final entry = entries[goalId];
      if (entry != null) {
        _goalOpsIndexCache[goalId] = entry;
      }
      final completer = _goalIndexLoadRequests.remove(goalId);
      completer?.complete(entry);
    }
  }

  Future<Map<String, dynamic>?> _queuedGoalIndexGet(String goalId) {
    final existingRequest = _goalIndexLoadRequests[goalId];
    if (existingRequest != null) {
      return existingRequest.future;
    }
    final completer = Completer<Map<String, dynamic>?>();
    _goalIndexLoadRequests[goalId] = completer;

    _goalIndexReadQueue.add(() async {
      await _getGoalIndexBatch();
    });
    return completer.future;
  }

  Future<Map<String, dynamic>?> _getGoalIndexEntry(String goalId) async {
    var entry = _goalOpsIndexCache[goalId];
    if (entry != null) {
      return entry;
    }

    entry = await _queuedGoalIndexGet(goalId);
    if (entry != null) {
      _goalOpsIndexCache[goalId] = entry;
    }
    return entry;
  }

  Future<Map<String, dynamic>?> _computeNewGoalIndexEntry(
      String goalId, Op op) async {
    final currEntry = await _getGoalIndexEntry(goalId);

    final currOpIds =
        (currEntry?["opIds"] as List<dynamic>?)?.cast<String>() ?? [];

    final indexedOpIds = <String>{...currOpIds};

    if (indexedOpIds.contains(op.id)) {
      // If there is no op and no goal snapshot, we don't need to index anything
      Logger(goalId)
          .fine("No op or goal snapshot, skipping indexing for $goalId");
      return null;
    }

    Logger(op.id).fine("Indexing Op");
    indexedOpIds.add(op.id);

    final newEntry = {
      "opIds": [...indexedOpIds],
    };

    return newEntry;
  }

  @override
  Future<Iterable<Op>> loadOpsForGoal(String goalId) async {
    Map<String, dynamic>? cachedEntry = await _getGoalIndexEntry(goalId);

    final indexedOpIds =
        (cachedEntry?["opIds"] as List<dynamic>?)?.cast<String>() ?? [];

    if (indexedOpIds.isEmpty) {
      return [];
    }

    final ops = <Future<Op?>>[];
    for (final opId in indexedOpIds) {
      ops.add(_getOp(opId));
    }

    final result = <Op>[];
    for (final op in await Future.wait(ops)) {
      if (op == null) {
        throw CacheMissException(
            'Op not found in cache or repo for goal $goalId');
      }
      result.add(op);
    }
    return result;
  }

  Future<void> _getOpBatch() async {
    if (_opLoadRequests.isEmpty) {
      return;
    }

    // Check if any of the requested ops have been added to the cache
    // between the time the request was made and now.
    for (final opId in [..._opLoadRequests.keys]) {
      if (_opCache[opId] != null) {
        final request = _opLoadRequests.remove(opId);
        if (request != null) {
          final (completer, startTime) = request;
          // print(
          //     'Op $opId waited in queue for ${DateTime.now().difference(startTime).inMilliseconds}ms');
          completer.complete(_opCache[opId]);
        }
      }
    }

    final opsToLoad = _opLoadRequests.keys.toList();

    final ops = await repo.loadOps(opsToLoad);

    for (final (i, op) in ops.indexed) {
      final request = _opLoadRequests.remove(opsToLoad[i]);
      if (request != null) {
        final (completer, startTime) = request;
        // print(
        //     'Op ${opsToLoad[i]} waited in queue for ${DateTime.now().difference(startTime).inMilliseconds}ms');
        completer.complete(op);
      }
    }
  }

  void _executeBatch() {
    _batchTimer = null;
    _batchStartTime = null;
    _opReadQueue.add(() async {
      await _getOpBatch();
    });
  }

  void _scheduleBatch() {
    _batchStartTime ??= DateTime.now();
    _batchTimer?.cancel();
    final elapsed = DateTime.now().difference(_batchStartTime!);
    final delay = const Duration(milliseconds: 10);
    final maxDelay = const Duration(milliseconds: 30) - elapsed;
    final actualDelay = delay < maxDelay ? delay : maxDelay;
    _batchTimer = Timer(
        actualDelay.isNegative ? Duration.zero : actualDelay, _executeBatch);
  }

  Future<Op?> _queuedOpGet(String opId) {
    final existingRequest = _opLoadRequests[opId];
    if (existingRequest != null) {
      return existingRequest.$1.future;
    }
    final completer = Completer<Op?>();
    _opLoadRequests[opId] = (completer, DateTime.now());

    _scheduleBatch();
    return completer.future;
  }

  Future<Op?> _getOp(String opId) async {
    Op? op = _opCache[opId];
    if (op != null) {
      return op;
    }

    op = await _queuedOpGet(opId);
    if (op == null) {
      return null;
    }

    _opCache[opId] = op;
    return op;
  }

  @override
  Future<void> storeSyncedOps(Iterable<Op> ops) async {
    // Synchronously update the caches.
    for (final op in ops) {
      final opLogger = Logger(op.id);
      opLogger.fine("Putting Op Into Cache");
      _opCache[op.id] = op;
      if (op is DeltaOp && op.delta.logEntry is TextGoalLogEntry) {
        opLogger.fine("Op is DeltaOp with TextGoalLogEntry");
        final textLogEntry = op.delta.logEntry as TextGoalLogEntry;
        if (textLogEntry.text != null) {
          opLogger.fine("Text is not null, storing in string box");
          _stringCache[textLogEntry.id] = textLogEntry.text!;
        }
      }
    }

    // queue storage of the ops without waiting
    await _opStorageQueue.add(() => _doOpStorage(ops));
  }

  @override
  Future<Iterable<Op>> getAllOps() async {
    final opMap = <String, Op>{};
    final allOps = <Op>[
      ...await repo.loadAllSyncedOps(),
      ...repo.getUnsyncedOps(),
    ];
    for (final Op op in allOps) {
      opMap[op.hlcTimestamp] = op;
    }

    return opMap.values;
  }

  @override
  Future<String?> loadString(String key) async {
    return _stringCache.get(key) ?? await repo.loadString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    _stringCache.put(key, value);
    await repo.storeString(key, value);
  }

  @override
  void incrementFullSyncCount() {
    repo.fullSyncCount++;
  }

  Future<void> _doOpStorage(Iterable<Op> ops) async {
    final stringsToWrite = <String, String>{};
    final goalIndexEntriesToWrite = <String, Map<String, dynamic>>{};
    final opsToWrite = <Op>[];
    String? maxHlc;
    for (final op in ops) {
      maxHlc = maxHlc == null
          ? op.hlcTimestamp
          : (op.hlcTimestamp.comesAfter(maxHlc) ? op.hlcTimestamp : maxHlc);
      final opLogger = Logger(op.id);
      opLogger.fine("Storing Op");

      // Remove the op from unsyncedOps one at a time
      // to avoid clobbering other updates to unsyncedOps
      // that may have happened while this function was running.
      final unsyncedOps = [...repo.getUnsyncedOps()];
      for (final unsyncedOp in unsyncedOps) {
        if (unsyncedOp.id == op.id) {
          opLogger.fine("Clearing unsyncedOp");
          unsyncedOps.remove(unsyncedOp);
          setUnsyncedOps(unsyncedOps);
          break;
        }
      }

      final opJsonMap = op.toJsonMap();

      opLogger.fine("extracting text entry field");
      final resp = Op.extractEntryTextField(opJsonMap);
      if (resp != null) {
        opLogger.fine("had text entry field, storing in string box");
        final (entryId, entryText) = resp;
        stringsToWrite[entryId] = entryText;
        opsToWrite.add(Op.fromJsonMap(opJsonMap));
      } else {
        opsToWrite.add(op);
      }

      // Index the op for the goal
      opLogger.fine("indexing op for goal");
      switch (op) {
        case DeltaOp op:
          final affectedGoalIds = getAffectedGoalIdsFromDeltaOp(op);
          for (final goalId in affectedGoalIds) {
            opLogger.fine("goalId: $goalId");
            final newEntry = await _computeNewGoalIndexEntry(goalId, op);

            if (newEntry != null) {
              _goalOpsIndexCache[goalId] = newEntry;
              goalIndexEntriesToWrite[goalId] = newEntry;
            }
          }
        case EnableOp(opId: final opId) || DisableOp(opId: final opId):
          final affectedOp = await _getOp(opId);
          if (affectedOp == null) {
            print(
                "Warning: Enable/Disable Op $opId not found in cache, skipping indexing");
          }
          if (affectedOp is! DeltaOp) {
            print(
                "Warning: Expected Enable/Disable Op to be a DeltaOp, but got: $affectedOp");
            throw Exception(
                "Expected Enable/Disable Op to be a DeltaOp, but got: $affectedOp");
          }
          final affectedGoalIds = getAffectedGoalIdsFromDeltaOp(affectedOp);
          for (final goalId in affectedGoalIds) {
            opLogger.fine("goalId: $goalId");
            final newEntry = await _computeNewGoalIndexEntry(goalId, op);

            if (newEntry != null) {
              _goalOpsIndexCache[goalId] = newEntry;
              goalIndexEntriesToWrite[goalId] = newEntry;
            }
          }
          opLogger.fine("op is Enable/Disable Op, indexing");

          break;
      }
    }
    if (maxHlc != null) {
      repo.cursor = maxHlc;
    }

    await repo.storeStrings(stringsToWrite);
    await repo.storeSyncedOps(opsToWrite);
    await repo.storeGoalIndexEntries(goalIndexEntriesToWrite);
  }

  @override
  Future<void> clear() async {
    if (_opStorageQueue.remainingItemCount > 0) {
      await _opStorageQueue.onComplete;
    }
    await repo.clear();
    _stringCache.clear();
    _opCache.clear();
  }

  @override
  Future<Iterable<Op?>> loadOpsById(Iterable<String> opIds) async {
    return await Future.wait((opIds.map((opId) => _getOp(opId))));
  }

  @override
  Set<String> getIndexGoalIds(String key) {
    return repo.getIndexGoalIds(key);
  }

  @override
  void setIndexGoalIds(String key, Set<String> goalIds) {
    repo.setIndexGoalIds(key, goalIds);
  }

  @override
  Future<String?> loadSearchIndex(String indexKey) async {
    return repo.loadSearchIndex(indexKey);
  }

  @override
  Future<void> setSearchIndex(String indexKey, String indexData) async {
    await repo.setSearchIndex(indexKey, indexData);
  }

  @override
  Iterable<Op> getOpsById(Iterable<String> opIds) {
    return opIds.map((id) => _opCache[id]!);
  }
}
