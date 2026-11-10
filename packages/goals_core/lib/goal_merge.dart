import 'package:goals_types/goals_types.dart';

import 'src/model.dart';
import 'src/util/compressed_uuid.dart';

/// Chooses how document contents from goals being merged are retained.
enum DocumentContentsMergeStrategy {
  combine,
  keepOldest,
  keepNewest,
  keepGoalId,
}

/// A deterministic, single-batch plan for merging two or more goals.
///
/// The caller supplies the selected goals' materialized documents and operation
/// histories. This keeps persistence and UI concerns out of the shared planner
/// while making every structural decision identical for Dart and TypeScript
/// consumers.
class GoalMergePlan {
  final String survivingGoalId;
  final List<String> archivedGoalIds;
  final String chosenName;
  final List<GoalDelta> deltas;
  final int movedChildrenCount;
  final int copiedLogEntriesCount;

  const GoalMergePlan({
    required this.survivingGoalId,
    required this.archivedGoalIds,
    required this.chosenName,
    required this.deltas,
    required this.movedChildrenCount,
    required this.copiedLogEntriesCount,
  });

  String? get archivedGoalId =>
      archivedGoalIds.length == 1 ? archivedGoalIds.single : null;
}

bool _isStructuralOrStatusOrDocument(GoalLogEntry entry) =>
    entry is SetParentLogEntry ||
    entry is AddParentLogEntry ||
    entry is RemoveParentLogEntry ||
    entry is StatusLogEntry ||
    entry is ArchiveStatusLogEntry ||
    entry is ClearStatusLogEntry ||
    entry is PriorityLogEntry ||
    entry is MakeAnchorLogEntry ||
    entry is ClearAnchorLogEntry ||
    entry is CreateInstanceLogEntry ||
    entry is DocumentContentsEntry ||
    entry is ClearDocumentContentsEntry;

({String text, String timestamp})? _latestTextOp(Iterable<Op> operations) {
  final ordered = operations.toList()
    ..sort((left, right) => left.hlcTimestamp.compareTo(right.hlcTimestamp));
  final disabledIds = <String>{};
  for (final op in ordered) {
    if (op is DisableOp) {
      disabledIds.add(op.opId);
    } else if (op is EnableOp) {
      disabledIds.remove(op.opId);
    }
  }

  ({String text, String timestamp})? latest;
  for (final op in ordered) {
    if (op is! DeltaOp || op.delta.text == null || disabledIds.contains(op.id)) {
      continue;
    }
    if (latest == null || op.hlcTimestamp.compareTo(latest.timestamp) > 0) {
      latest = (text: op.delta.text!, timestamp: op.hlcTimestamp);
    }
  }
  return latest;
}

List<String>? _rewrittenPath(
  GoalLogEntry? relationship,
  Set<String> absorbedIds,
  String survivingGoalId,
) {
  if (relationship is! AddParentLogEntry ||
      relationship.displayedChildPath == null) {
    return null;
  }
  return relationship.displayedChildPath!
      .map((segment) =>
          absorbedIds.contains(segment) ? survivingGoalId : segment)
      .toList();
}

/// Plans a merge of [goals] into their oldest member, without mutating state.
///
/// Goals are sorted by creation time, then id, so selection order never affects
/// the survivor. The returned deltas are intended to be passed as one
/// `SyncClient.modifyGoals` batch by the caller.
GoalMergePlan planGoalMerge({
  required List<Goal> goals,
  Map<String, String> documentContents = const {},
  Map<String, Iterable<Op>> opsByGoal = const {},
  DocumentContentsMergeStrategy documentContentsStrategy =
      DocumentContentsMergeStrategy.combine,
  String? documentContentsGoalId,
  DateTime? now,
  String Function()? newId,
}) {
  final ids = <String>{};
  for (final goal in goals) {
    if (!ids.add(goal.id)) {
      throw ArgumentError('Goal ids must be distinct');
    }
  }
  if (goals.length < 2) {
    throw ArgumentError('At least two goals must be merged');
  }

  final orderedGoals = goals.toList()
    ..sort((left, right) {
      final byCreation = left.creationTime.compareTo(right.creationTime);
      return byCreation != 0 ? byCreation : left.id.compareTo(right.id);
    });
  final survivingGoal = orderedGoals.first;
  final archivedGoals = orderedGoals.skip(1).toList();
  final archivedIds = archivedGoals.map((goal) => goal.id).toSet();
  final allMergedIds = orderedGoals.map((goal) => goal.id).toSet();
  final timestamp = now ?? DateTime.now();
  final id = newId ?? () => Cupid.random().encode();

  var chosenName = orderedGoals.last.text;
  ({String text, String timestamp})? latestText;
  var hasTimestampTie = false;
  for (final goal in orderedGoals) {
    final candidate = _latestTextOp(opsByGoal[goal.id] ?? const []);
    if (candidate == null) continue;
    if (latestText == null) {
      latestText = candidate;
    } else {
      final comparison = candidate.timestamp.compareTo(latestText.timestamp);
      if (comparison > 0) {
        latestText = candidate;
        hasTimestampTie = false;
      } else if (comparison == 0) {
        hasTimestampTie = true;
      }
    }
  }
  if (latestText != null && !hasTimestampTie) {
    chosenName = latestText.text;
  }

  final deltas = <GoalDelta>[];
  if (survivingGoal.text != chosenName) {
    deltas.add(GoalDelta(id: survivingGoal.id, text: chosenName));
  }

  final nonEmptyDocuments = orderedGoals
      .map((goal) => (goal: goal, text: documentContents[goal.id] ?? ''))
      .where((entry) => entry.text.isNotEmpty)
      .toList();
  String? mergedDocument;
  switch (documentContentsStrategy) {
    case DocumentContentsMergeStrategy.combine:
      if (nonEmptyDocuments.isNotEmpty) {
        mergedDocument = nonEmptyDocuments
            .map((entry) => entry.text.trim())
            .join('\n\n');
      }
    case DocumentContentsMergeStrategy.keepOldest:
      mergedDocument = documentContents[survivingGoal.id];
    case DocumentContentsMergeStrategy.keepNewest:
      mergedDocument = documentContents[orderedGoals.last.id];
    case DocumentContentsMergeStrategy.keepGoalId:
      if (documentContentsGoalId == null ||
          !allMergedIds.contains(documentContentsGoalId)) {
        throw ArgumentError('A selected document goal id is required');
      }
      mergedDocument = documentContents[documentContentsGoalId];
  }
  final existingDocument = documentContents[survivingGoal.id] ?? '';
  if (mergedDocument != null &&
      mergedDocument.isNotEmpty &&
      mergedDocument != existingDocument) {
    deltas.add(GoalDelta(
      id: survivingGoal.id,
      logEntry: DocumentContentsEntry(
        id: id(),
        creationTime: timestamp,
        text: mergedDocument,
      ),
    ));
  }

  var copiedLogEntriesCount =
      mergedDocument != null && mergedDocument != existingDocument ? 1 : 0;
  for (final archivedGoal in archivedGoals) {
    for (final entry in archivedGoal.log.reversed) {
      if (_isStructuralOrStatusOrDocument(entry)) continue;
      deltas.add(GoalDelta(id: survivingGoal.id, logEntry: entry));
      copiedLogEntriesCount++;
    }
  }

  final parentIds = survivingGoal.superGoalIds.toSet();
  for (final archivedGoal in archivedGoals) {
    for (final parentId in archivedGoal.superGoalIds) {
      final relationship = archivedGoal.superGoalRelationships[parentId];
      if (!allMergedIds.contains(parentId) && parentIds.add(parentId)) {
        deltas.add(GoalDelta(
          id: survivingGoal.id,
          logEntry: AddParentLogEntry(
            id: id(),
            creationTime: timestamp,
            parentId: parentId,
            isSlice: relationship is AddParentLogEntry && relationship.isSlice,
            displayedChildPath:
                _rewrittenPath(relationship, archivedIds, survivingGoal.id),
          ),
        ));
      }
      deltas.add(GoalDelta(
        id: archivedGoal.id,
        logEntry: RemoveParentLogEntry(
          id: id(),
          creationTime: timestamp,
          parentId: parentId,
        ),
      ));
    }
  }

  final childIds = survivingGoal.subGoalIds.toSet();
  var movedChildrenCount = 0;
  for (final archivedGoal in archivedGoals) {
    for (final childId in archivedGoal.subGoalIds) {
      if (allMergedIds.contains(childId)) continue;
      final relationship = archivedGoal.subGoalRelationships[childId];
      if (childIds.add(childId)) {
        deltas.add(GoalDelta(
          id: childId,
          logEntry: AddParentLogEntry(
            id: id(),
            creationTime: timestamp,
            parentId: survivingGoal.id,
            isSlice: relationship is AddParentLogEntry && relationship.isSlice,
            displayedChildPath:
                _rewrittenPath(relationship, archivedIds, survivingGoal.id),
          ),
        ));
        movedChildrenCount++;
      }
      deltas.add(GoalDelta(
        id: childId,
        logEntry: RemoveParentLogEntry(
          id: id(),
          creationTime: timestamp,
          parentId: archivedGoal.id,
        ),
      ));
    }
  }

  for (final archivedGoal in archivedGoals) {
    deltas.add(GoalDelta(
      id: archivedGoal.id,
      logEntry: StatusLogEntry(
        id: id(),
        creationTime: timestamp,
        status: GoalStatus.archived,
      ),
    ));
  }

  return GoalMergePlan(
    survivingGoalId: survivingGoal.id,
    archivedGoalIds: archivedGoals.map((goal) => goal.id).toList(),
    chosenName: chosenName,
    deltas: deltas,
    movedChildrenCount: movedChildrenCount,
    copiedLogEntriesCount: copiedLogEntriesCount,
  );
}
