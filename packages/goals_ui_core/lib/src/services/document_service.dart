import 'package:goals_core/model.dart' show Goal, GoalPath;
import 'package:goals_core/sync.dart' show GoalRef;

/// The goal references held by one document consumer (normally one editor).
///
/// A [DocumentService] uses this set to retain each goal consumed while it
/// loads or expands a document. The consumer owns and disposes the set.
class DocumentGoalReferences {
  final Future<GoalRef> Function(String) _loadGoalRef;
  final Map<String, GoalRef> _references = {};
  bool _disposed = false;

  DocumentGoalReferences({
    required Future<GoalRef> Function(String) loadGoalRef,
  }) : _loadGoalRef = loadGoalRef;

  Set<String> get goalIds => Set<String>.unmodifiable(_references.keys);

  GoalRef? operator [](String goalId) => _references[goalId];

  Future<Goal?> loadGoal(String goalId) async {
    if (_disposed) return null;
    final existing = _references[goalId];
    if (existing != null) return existing.goal;

    final reference = await _loadGoalRef(goalId);
    if (_disposed) {
      await reference.dispose();
      return null;
    }
    _references[goalId] = reference;
    return reference.goal;
  }

  /// Acquires only new ids, keeps existing handles, and releases removed ids.
  Future<void> reconcile(Iterable<String> goalIds) async {
    if (_disposed) return;
    final desired = goalIds.toSet();
    for (final goalId in desired) {
      await loadGoal(goalId);
    }

    final removedGoalIds = _references.keys
        .where((goalId) => !desired.contains(goalId))
        .toList();
    for (final goalId in removedGoalIds) {
      final reference = _references.remove(goalId);
      await reference?.dispose();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final references = _references.values.toList();
    _references.clear();
    for (final reference in references) {
      await reference.dispose();
    }
  }
}

/// Optional document expansion capabilities used by richer hover actions.
abstract class DocumentService {
  /// Computes a rich document for a goal subtree.
  Future<dynamic> computeDocument(
    Map<String, Goal> goalMap,
    GoalPath rootPath, {
    Set<String>? seenGoalIds,
    bool shouldExpandReferences = true,
    DocumentGoalReferences? goalReferences,
  });

  /// Expands inline goal references within a mutable document instance.
  Future<void> expandReferences(
    Map<String, Goal> goalMap,
    dynamic doc, {
    Set<String>? seenGoalIds,
    DocumentGoalReferences? goalReferences,
  });

  /// Renders a document to markdown plus collected citation footnotes.
  Future<(String, List<String>)> docToCitationMarkdown(
    Map<String, Goal> goalMap,
    dynamic doc,
    GoalPath path, {
    int citationIndex = 1,
    dynamic citationManager,
  });
}
