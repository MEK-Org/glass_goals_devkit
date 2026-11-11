import 'package:goals_core/goal_merge.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

Goal _goal(String id, int createdAt, String text) => Goal(
      id: id,
      text: text,
      creationTime: DateTime.fromMillisecondsSinceEpoch(createdAt),
    );

DeltaOp _rename(String opId, String goalId, String text, String hlc) => DeltaOp(
      id: opId,
      hlcTimestamp: hlc,
      delta: GoalDelta(id: goalId, text: text),
    );

void main() {
  test('plans a deterministic n-way merge with documents and relationships', () {
    final oldest = _goal('oldest', 10, 'Old title');
    final middle = _goal('middle', 20, 'Middle title');
    final newest = _goal('newest', 30, 'Newest title');
    final parentRelationship = AddParentLogEntry(
      id: 'middle-parent',
      creationTime: DateTime.fromMillisecondsSinceEpoch(20),
      parentId: 'parent',
      displayedChildPath: const ['parent', 'middle'],
    );
    final childRelationship = AddParentLogEntry(
      id: 'middle-child',
      creationTime: DateTime.fromMillisecondsSinceEpoch(20),
      parentId: 'middle',
      displayedChildPath: const ['middle', 'child'],
    );
    middle.addSuperGoal('parent', parentRelationship);
    middle.addSubGoal('child', childRelationship);
    middle.prependEntry(NoteLogEntry(
      id: 'note',
      creationTime: DateTime.fromMillisecondsSinceEpoch(25),
      text: 'Keep this note',
    ));

    var serial = 0;
    final plan = planGoalMerge(
      goals: [newest, middle, oldest],
      documentContents: const {
        'oldest': 'Old document',
        'middle': 'Middle document',
        'newest': 'Newest document',
      },
      opsByGoal: {
        'oldest': [_rename('old-name', 'oldest', 'Old title', '001')],
        'middle': [_rename('middle-name', 'middle', 'Middle title', '003')],
        'newest': [_rename('new-name', 'newest', 'Newest title', '002')],
      },
      now: DateTime.fromMillisecondsSinceEpoch(100),
      newId: () => 'generated-${serial++}',
    );

    expect(plan.survivingGoalId, 'oldest');
    expect(plan.archivedGoalIds, ['middle', 'newest']);
    expect(plan.chosenName, 'Middle title');
    expect(
      plan.deltas
          .where((delta) => delta.logEntry is DocumentContentsEntry)
          .single
          .logEntry,
      isA<DocumentContentsEntry>().having(
        (entry) => entry.text,
        'combined text',
        'Old document\n\nMiddle document\n\nNewest document',
      ),
    );
    expect(
      plan.deltas.where((delta) => delta.logEntry is NoteLogEntry).length,
      1,
    );
    final parentAdd = plan.deltas
        .map((delta) => delta.logEntry)
        .whereType<AddParentLogEntry>()
        .firstWhere((entry) => entry.parentId == 'parent');
    expect(parentAdd.displayedChildPath, ['parent', 'oldest']);
    expect(
      plan.deltas.where((delta) =>
          delta.id == 'middle' && delta.logEntry is StatusLogEntry).length,
      1,
    );
    expect(
      plan.deltas.where((delta) =>
          delta.id == 'newest' && delta.logEntry is StatusLogEntry).length,
      1,
    );
  });

  test('keeps a requested goal document instead of concatenating', () {
    final oldest = _goal('a', 10, 'A');
    final newest = _goal('b', 20, 'B');
    var serial = 0;
    final plan = planGoalMerge(
      goals: [oldest, newest],
      documentContents: const {'a': 'A prose', 'b': 'B prose'},
      documentContentsStrategy: DocumentContentsMergeStrategy.keepGoalId,
      documentContentsGoalId: 'b',
      now: DateTime.fromMillisecondsSinceEpoch(100),
      newId: () => 'generated-${serial++}',
    );

    final entry = plan.deltas
        .where((delta) => delta.logEntry is DocumentContentsEntry)
        .single
        .logEntry as DocumentContentsEntry;
    expect(entry.text, 'B prose');
  });

  bool isDocumentDelta(GoalDelta delta) =>
      delta.logEntry is DocumentContentsEntry ||
      delta.logEntry is ClearDocumentContentsEntry;

  for (final testCase in [
    (
      name: 'keepNewest with an empty newest document',
      strategy: DocumentContentsMergeStrategy.keepNewest,
      goalId: null,
      documents: const {'a': 'A prose'},
    ),
    (
      name: 'keepGoalId with an absent selected document',
      strategy: DocumentContentsMergeStrategy.keepGoalId,
      goalId: 'b',
      documents: const {'a': 'A prose'},
    ),
    (
      name: 'keepGoalId with an explicitly empty selected document',
      strategy: DocumentContentsMergeStrategy.keepGoalId,
      goalId: 'b',
      documents: const {'a': 'A prose', 'b': ''},
    ),
  ]) {
    test('clears the survivor document for ${testCase.name}', () {
      final plan = planGoalMerge(
        goals: [_goal('a', 10, 'A'), _goal('b', 20, 'B')],
        documentContents: testCase.documents,
        documentContentsStrategy: testCase.strategy,
        documentContentsGoalId: testCase.goalId,
        now: DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'generated',
      );

      final documentDelta = plan.deltas.where(isDocumentDelta).single;
      expect(documentDelta.id, 'a');
      expect(documentDelta.logEntry, isA<ClearDocumentContentsEntry>());
      expect(plan.copiedLogEntriesCount, 1);
    });
  }

  test('keeps an empty oldest document without emitting a document delta', () {
    final plan = planGoalMerge(
      goals: [_goal('a', 10, 'A'), _goal('b', 20, 'B')],
      documentContents: const {'b': 'B prose'},
      documentContentsStrategy: DocumentContentsMergeStrategy.keepOldest,
      now: DateTime.fromMillisecondsSinceEpoch(100),
      newId: () => 'generated',
    );

    expect(plan.deltas.where(isDocumentDelta), isEmpty);
    expect(plan.copiedLogEntriesCount, 0);
  });

  test('removes edges between merged goals in both directions', () {
    final child = _goal('child', 10, 'Oldest child');
    final parent = _goal('parent', 20, 'Newer parent');
    final grandchild = _goal('grandchild', 30, 'Newest grandchild');
    final parentEdge = AddParentLogEntry(
      id: 'child-under-parent',
      creationTime: DateTime.fromMillisecondsSinceEpoch(20),
      parentId: 'parent',
    );
    child.addSuperGoal('parent', parentEdge);
    parent.addSubGoal('child', parentEdge);
    final grandchildEdge = AddParentLogEntry(
      id: 'grandchild-under-child',
      creationTime: DateTime.fromMillisecondsSinceEpoch(30),
      parentId: 'child',
    );
    grandchild.addSuperGoal('child', grandchildEdge);
    child.addSubGoal('grandchild', grandchildEdge);
    child.addSuperGoal(
      'external',
      AddParentLogEntry(
        id: 'child-under-external',
        creationTime: DateTime.fromMillisecondsSinceEpoch(15),
        parentId: 'external',
      ),
    );

    var serial = 0;
    final plan = planGoalMerge(
      goals: [parent, grandchild, child],
      now: DateTime.fromMillisecondsSinceEpoch(100),
      newId: () => 'generated-${serial++}',
    );

    expect(plan.survivingGoalId, 'child');
    final removals = [
      for (final delta in plan.deltas)
        if (delta.logEntry case RemoveParentLogEntry(:final parentId))
          '${delta.id}<-$parentId',
    ];
    expect(removals, contains('child<-parent'));
    expect(removals, contains('grandchild<-child'));
    expect(removals, isNot(contains('child<-external')));
    final mergedIds = {...plan.archivedGoalIds, plan.survivingGoalId};
    expect(
      plan.deltas.where((delta) =>
          mergedIds.contains(delta.id) &&
          delta.logEntry is AddParentLogEntry &&
          mergedIds.contains((delta.logEntry as AddParentLogEntry).parentId)),
      isEmpty,
    );
  });
}
