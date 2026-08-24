import 'package:goals_core/sync.dart' show Op;

abstract class SyncRepository {
  Future<void> init();

  String? get clientId;
  set clientId(String? value);

  String? get cursor;
  set cursor(String? value);

  DateTime? get lastSyncTime;
  set lastSyncTime(DateTime? value);

  int get fullSyncCount;
  set fullSyncCount(int value);

  List<Op> getUnsyncedOps();
  Future<void> setUnsyncedOps(Iterable<Op> ops);

  Future<String?> loadString(String key);
  Future<void> storeString(String key, String value);
  Future<void> storeStrings(Map<String, String> values);

  Future<void> storeGoalIndexEntry(String goalId, Map<String, dynamic> entry);
  Future<void> storeGoalIndexEntries(Map<String, Map<String, dynamic>> entries);
  Future<Map<String, dynamic>?> loadGoalIndexEntry(String goalId);
  Future<Map<String, Map<String, dynamic>?>> loadGoalIndexEntries(
      Iterable<String> goalIds);

  Future<Iterable<Op?>> loadOps(Iterable<String> opIds);
  Future<void> storeSyncedOps(Iterable<Op> ops);
  Future<Iterable<Op>> loadAllSyncedOps();

  Set<String> getIndexGoalIds(String key);
  Future<void> setIndexGoalIds(String key, Set<String> goalIds);

  String? loadSearchIndex(String indexKey);
  Future<void> setSearchIndex(String indexKey, String indexData);

  int get version;
  set version(int value);

  Future<void> clear();
}

class MemorySyncRepository implements SyncRepository {
  String? _clientId;
  String? _cursor;
  DateTime? _lastSyncTime;
  int _fullSyncCount = 0;
  int _version = 0;
  final List<Op> _unsyncedOps = [];
  final Map<String, String> _strings = {};
  final Map<String, Map<String, dynamic>> _goalIndex = {};
  final Map<String, Op> _syncedOps = {};
  final Map<String, Set<String>> _indexGoalIds = {};
  final Map<String, String> _searchIndices = {};

  @override
  Future<void> init() async {}

  @override
  String? get clientId => _clientId;
  @override
  set clientId(String? value) => _clientId = value;

  @override
  String? get cursor => _cursor;
  @override
  set cursor(String? value) => _cursor = value;

  @override
  DateTime? get lastSyncTime => _lastSyncTime;
  @override
  set lastSyncTime(DateTime? value) => _lastSyncTime = value;

  @override
  int get fullSyncCount => _fullSyncCount;
  @override
  set fullSyncCount(int value) => _fullSyncCount = value;

  @override
  List<Op> getUnsyncedOps() => List.unmodifiable(_unsyncedOps);
  @override
  Future<void> setUnsyncedOps(Iterable<Op> ops) async {
    _unsyncedOps
      ..clear()
      ..addAll(ops);
  }

  @override
  Future<String?> loadString(String key) async => _strings[key];
  @override
  Future<void> storeString(String key, String value) async {
    _strings[key] = value;
  }

  @override
  Future<void> storeStrings(Map<String, String> values) async {
    _strings.addAll(values);
  }

  @override
  Future<void> storeGoalIndexEntry(
      String goalId, Map<String, dynamic> entry) async {
    _goalIndex[goalId] = Map<String, dynamic>.from(entry);
  }

  @override
  Future<void> storeGoalIndexEntries(
      Map<String, Map<String, dynamic>> entries) async {
    entries.forEach((k, v) {
      _goalIndex[k] = Map<String, dynamic>.from(v);
    });
  }

  @override
  Future<Map<String, dynamic>?> loadGoalIndexEntry(String goalId) async =>
      _goalIndex[goalId];

  @override
  Future<Map<String, Map<String, dynamic>?>> loadGoalIndexEntries(
      Iterable<String> goalIds) async {
    final result = <String, Map<String, dynamic>?>{};
    for (final goalId in goalIds) {
      result[goalId] = _goalIndex[goalId];
    }
    return result;
  }

  @override
  Future<Iterable<Op?>> loadOps(Iterable<String> opIds) async {
    final List<Op?> ops = [];
    for (final opId in opIds) {
      ops.add(_syncedOps[opId]);
    }
    return ops;
  }

  @override
  Future<void> storeSyncedOps(Iterable<Op> ops) async {
    for (final op in ops) {
      _syncedOps[op.id] = op;
    }
  }

  @override
  Future<Iterable<Op>> loadAllSyncedOps() async => _syncedOps.values;

  @override
  Set<String> getIndexGoalIds(String key) => _indexGoalIds[key] ?? <String>{};
  @override
  Future<void> setIndexGoalIds(String key, Set<String> goalIds) async {
    _indexGoalIds[key] = Set<String>.from(goalIds);
  }

  @override
  String? loadSearchIndex(String indexKey) {
    return _searchIndices[indexKey];
  }

  @override
  Future<void> setSearchIndex(String indexKey, String indexData) async {
    _searchIndices[indexKey] = indexData;
  }

  @override
  int get version => _version;
  @override
  set version(int value) => _version = value;

  @override
  Future<void> clear() async {
    _clientId = null;
    _cursor = null;
    _lastSyncTime = null;
    _fullSyncCount = 0;
    _version = 0;
    _unsyncedOps.clear();
    _strings.clear();
    _goalIndex.clear();
    _syncedOps.clear();
    _indexGoalIds.clear();
    _searchIndices.clear();
  }
}
