import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:goals_core/sync.dart';

export 'book_metadata.dart';
export 'course_metadata.dart';

const GOAL_PREFIX = 'gg://';

class Goal {
  final String id;

  // These fields are intentionally not final to allow references to stay valid
  String? _text;

  String get text => _text ?? 'Untitled';

  set text(String value) {
    _text = value;
  }

  final Map<String, GoalLogEntry?> _superGoalRelationships = {};
  final Map<String, GoalLogEntry?> _subGoalRelationships = {};

  Map<String, GoalLogEntry?> get subGoalRelationships => _subGoalRelationships;
  Map<String, GoalLogEntry?> get superGoalRelationships =>
      _superGoalRelationships;

  Iterable<String> get subGoalIds => subGoalRelationships.keys;
  Iterable<String> get superGoalIds => superGoalRelationships.keys;

  /// A log of changes to this goal. This is guaranteed to be
  /// sorted from newest to oldest.
  final List<GoalLogEntry> _log = <GoalLogEntry>[];
  final DateTime creationTime;

  Goal({
    String? text,
    required this.id,
    required this.creationTime,
  }) : _text = text;

  List<GoalLogEntry> get log => _log;

  void prependEntry(GoalLogEntry entry) {
    _log.insert(0, entry);
  }

  /// Modifies the subgoal list of this goal to update the goal with the given id.
  /// or add it if it doesn't exist.
  void addSubGoal(String goalId, [GoalLogEntry? logEntry]) {
    subGoalRelationships[goalId] = logEntry;
  }

  void addSuperGoal(String goalId, [GoalLogEntry? logEntry]) {
    superGoalRelationships[goalId] = logEntry;
  }

  void removeSubGoal(String goalId) {
    subGoalRelationships.remove(goalId);
  }

  bool hasParent(String goalId) {
    return superGoalIds.contains(goalId);
  }

  void removeSuperGoal(String goalId) {
    superGoalRelationships.remove(goalId);
  }

  Goal clone() {
    final newGoal = Goal(text: text, id: id, creationTime: creationTime);
    newGoal.subGoalRelationships.addAll(subGoalRelationships);
    newGoal.superGoalRelationships.addAll(superGoalRelationships);
    if (log.isNotEmpty) {
      newGoal._log.cast<GoalLogEntry>().addAll(log.cast<GoalLogEntry>());
    }
    return newGoal;
  }

  Map<String, dynamic> getNodeInfoJsonMap(
      [Iterable<GoalLogEntry> Function(Iterable<GoalLogEntry>)? logMapper]) {
    logMapper ??= (log) => log;
    return {
      't': text,
      if (subGoalIds.isNotEmpty) 'b': subGoalIds.toList(),
      if (superGoalIds.isNotEmpty) 'p': superGoalIds.toList(),
      'c': creationTime.millisecondsSinceEpoch,
      'l': logMapper(log).map((e) {
        final map = e.toJsonMap();
        // never store the text of the log entry in the node info
        map[TextGoalLogEntry.TEXT_JSON_KEY] = null;
        return map;
      }).toList(),
    };
  }

  static Goal fromSnapshotJsonMap(
      String goalId, Map<dynamic, dynamic> jsonMap) {
    final goal = Goal(
      text: jsonMap['t'],
      id: goalId,
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          jsonMap['c'] ?? DateTime.now().millisecondsSinceEpoch),
    );
    for (final subGoalId in jsonMap['b'] ?? []) {
      goal.addSubGoal(subGoalId);
    }
    for (final superGoalId in jsonMap['p'] ?? []) {
      goal.addSuperGoal(superGoalId);
    }
    for (final entry in jsonMap['l'] ?? []) {
      final logEntry = GoalLogEntry.fromJsonMap(entry, 6);
      goal.prependEntry(logEntry);
    }
    return goal;
  }
}

class MergedMap<K, V> extends MapBase<K, V> {
  final Map<K, V> _map1;
  final Map<K, V> _map2;
  final Set<K> _removedKeys = {};

  MergedMap(this._map1, this._map2);

  @override
  V? operator [](Object? key) {
    if (_map1.containsKey(key)) {
      return _map1[key];
    }

    if (_removedKeys.contains(key)) {
      return null;
    }

    return _map2[key];
  }

  @override
  void operator []=(K key, V value) {
    if (_removedKeys.contains(key)) {
      _removedKeys.remove(key);
    }
    _map1[key] = value;
  }

  @override
  void clear() {
    _map1.clear();
    _removedKeys.addAll(_map2.keys);
  }

  @override
  Iterable<K> get keys {
    final resp = _map1.keys.toSet();
    resp.addAll(_map2.keys);
    resp.removeAll(_removedKeys);
    return resp;
  }

  @override
  V? remove(Object? key) {
    _map1.remove(key);
    if (_map2.containsKey(key)) {
      _removedKeys.add(key as K);
    }
  }
}

class GoalInstance extends Goal {
  final Goal goal;
  late final MergedMap<String, GoalLogEntry?> _mergedSubGoals;

  GoalInstance({
    required super.id,
    required this.goal,
    required super.creationTime,
  }) {
    _mergedSubGoals =
        MergedMap(_subGoalRelationships, goal.subGoalRelationships);
  }

  @override
  String get text => _text ?? goal.text;

  @override
  hasParent(String goalId) {
    return goal.hasParent(goalId);
  }

  /// Returns the entries that are only in this goal instance.
  List<GoalLogEntry> get selfLog => _log;

  // TODO: should I be memoizing here?
  @override
  List<GoalLogEntry> get log => [
        ...goal.log.where((entry) =>
            // feels a bit weird but maybe it's fine?
            (entry is! StatusLogEntry && entry is! ClearStatusLogEntry)),
        ..._log
      ].sorted((a, b) => b.creationTime.compareTo(a.creationTime));

  @override
  Map<String, GoalLogEntry?> get subGoalRelationships => _mergedSubGoals;

  @override
  GoalInstance clone() {
    final newGoal =
        GoalInstance(id: id, goal: goal, creationTime: creationTime);
    newGoal._subGoalRelationships.addAll(subGoalRelationships);
    newGoal._superGoalRelationships.addAll(superGoalRelationships);
    newGoal._log.addAll(log);
    newGoal._text = text;
    return newGoal;
  }
}

class WorldContext {
  final DateTime time;

  WorldContext({required this.time});

  static WorldContext now() => WorldContext(time: DateTime.now());
}

class GoalPath extends ListMixin<String> {
  final List<String> _path;

  const GoalPath(this._path);

  @override
  int get length => _path.length;

  @override
  set length(int newLength) {
    _path.length = newLength;
  }

  @override
  String operator [](int index) => _path[index];

  @override
  void operator []=(int index, String value) {
    _path[index] = value;
  }

  String get goalId => _path.last;

  String? get parentId {
    if (_path.length <= 1) {
      return null;
    }

    for (int i = _path.length - 2; i >= 0; i--) {
      if (_path[i].startsWith('ui:')) {
        return null;
      } else if (_path[i].startsWith('slice:')) {
        continue;
      } else {
        return _path[i];
      }
    }
  }

  /// This will lop off any leading items that are not goal ids.
  GoalPath get trailingGoalPath {
    if (_path.isEmpty) {
      return this;
    }
    for (int i = _path.length - 1; i >= 0; i--) {
      if (_path[i].contains(':')) {
        return GoalPath(_path.sublist(i + 1));
      }
    }
    return this;
  }

  GoalPath get parentPath => GoalPath(_path.sublist(0, _path.length - 1));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! GoalPath) return false;
    if (other.length != length) return false;
    for (int i = 0; i < length; i++) {
      if (other[i] != this[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // implement hash code so that paths that are equal have the same hash code
    int hash = 0;
    for (int i = 0; i < length; i++) {
      hash = hash * 31 + this[i].hashCode;
    }
    return hash;
  }

  bool endsWith(GoalPath other) {
    if (other.length > length) {
      return false;
    }
    for (int i = 0; i < other.length; i++) {
      if (other[i] != this[length - other.length + i]) {
        return false;
      }
    }
    return true;
  }

  bool startsWith(GoalPath other) {
    if (other.length > length) {
      return false;
    }
    for (int i = 0; i < other.length; i++) {
      if (other[i] != this[i]) {
        return false;
      }
    }
    return true;
  }

  bool containsPath(List<String> needle) {
    if (needle.isEmpty) {
      return true;
    }
    if (needle.length > length) {
      return false;
    }
    final firstElement = _path.indexOf(needle[0]);
    if (firstElement == -1) {
      return false;
    }
    if (firstElement + needle.length > length) {
      return false;
    }
    for (int i = 0; i < needle.length; i++) {
      if (needle[i] != this[firstElement + i]) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() {
    return "$GOAL_PREFIX${_path.join('/')}";
  }

  static GoalPath? parse(String path) {
    if (!path.startsWith(GOAL_PREFIX)) {
      return null;
    }
    path = path.substring(GOAL_PREFIX.length);
    final parts = path.split('/');
    if (parts.isEmpty) {
      return null;
    }

    return GoalPath(path.split('/'));
  }

  @override
  GoalPath sublist(int start, [int? end]) {
    return GoalPath(_path.sublist(start, end));
  }
}
