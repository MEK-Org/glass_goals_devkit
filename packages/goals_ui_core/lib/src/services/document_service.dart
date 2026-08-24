import 'package:goals_core/model.dart' show Goal, GoalPath;

/// Optional document expansion capabilities used by richer hover actions.
abstract class DocumentService {
  /// Computes a rich document for a goal subtree.
  Future<dynamic> computeDocument(
    Map<String, Goal> goalMap,
    GoalPath rootPath, {
    Set<String>? seenGoalIds,
    bool shouldExpandReferences = true,
  });

  /// Expands inline goal references within a mutable document instance.
  Future<void> expandReferences(
    Map<String, Goal> goalMap,
    dynamic doc, {
    Set<String>? seenGoalIds,
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
