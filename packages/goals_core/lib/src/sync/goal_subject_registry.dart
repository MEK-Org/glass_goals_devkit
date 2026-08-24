import 'package:goals_core/model.dart' show Goal;
import 'package:rxdart/rxdart.dart' show BehaviorSubject;

/// Internal registry of per-goal [BehaviorSubject]s used by reactive
/// subscriptions (`watchGoals`). Pin-count bookkeeping lives on [SyncClient];
/// this registry only owns subject lifetimes — creating subjects on first
/// pin, emitting fresh values on op updates, and closing subjects when the
/// last pin is released.
///
/// Not exposed publicly. See devlog
/// 2026-05-25-goal-eviction-and-subscriptions.
class GoalSubjectRegistry {
  final Map<String, BehaviorSubject<Goal?>> _subjects = {};

  /// Returns the [BehaviorSubject] for [goalId], creating it (seeded with
  /// [initial]) if it does not yet exist.
  BehaviorSubject<Goal?> getOrCreate(String goalId, Goal? Function() initial) {
    final existing = _subjects[goalId];
    if (existing != null) {
      return existing;
    }
    final subject = BehaviorSubject<Goal?>.seeded(initial());
    _subjects[goalId] = subject;
    return subject;
  }

  /// Returns the existing subject for [goalId], or null if none has been
  /// created. Used by op-driven update paths that only want to wake live
  /// watchers without forcing a subject into existence.
  BehaviorSubject<Goal?>? get(String goalId) => _subjects[goalId];

  /// True if a subject currently exists for [goalId].
  bool has(String goalId) => _subjects.containsKey(goalId);

  /// Pushes [goal] onto [goalId]'s subject if one exists. No-op otherwise.
  void emit(String goalId, Goal? goal) {
    _subjects[goalId]?.add(goal);
  }

  /// Closes and removes the subject for [goalId]. Safe to call when no
  /// subject exists.
  void close(String goalId) {
    final subject = _subjects.remove(goalId);
    subject?.close();
  }

  /// Closes every subject in the registry. Called from [SyncClient.logOut]
  /// and [SyncClient.dispose].
  void closeAll() {
    for (final subject in _subjects.values) {
      subject.close();
    }
    _subjects.clear();
  }

  /// Snapshot of currently-registered goal ids. Returns a new list so callers
  /// can iterate without worrying about concurrent modification (e.g.
  /// subjects being closed during fan-out).
  List<String> get subjectIds => _subjects.keys.toList(growable: false);

  /// For debugging / tests.
  int get numSubjects => _subjects.length;
}
