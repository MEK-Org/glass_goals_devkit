import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:goals_widgets/src/goal_breadcrumb.dart';

void main() {
  testWidgets(
      'parent breadcrumb bounds legacy/slice cycles and rebuilds after removal',
      (tester) async {
    final client = SyncClient(
        localStore: MemoryLocalStore(),
        persistenceService: MemoryPersistenceService());
    await client.init();
    final time = DateTime.utc(2026, 10, 3);
    await client.modifyGoal(GoalDelta(id: 'a', text: 'Alpha'));
    await client.modifyGoal(GoalDelta(id: 'b', text: 'Beta'));
    await client.modifyGoal(GoalDelta(
        id: 'a',
        logEntry:
            AddParentLogEntry(id: 'ab', parentId: 'b', creationTime: time)));
    // Slices intentionally use the relationship entry's identity for the guard;
    // this remains a valid op-created cycle after the ordinary edge fix.
    await client.modifyGoal(GoalDelta(
        id: 'b',
        logEntry: AddParentLogEntry(
            id: 'ba-slice', parentId: 'a', creationTime: time, isSlice: true)));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GoalWidgetsContext(
      syncClient: client,
      child: GoalActionsContext.empty(
          child: ParentBreadcrumb(path: GoalPath(['a']))),
    ))));
    expect(
        tester.widget<PathBreadcrumb>(find.byType(PathBreadcrumb)).renderedPath,
        ['b', 'a']);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    await client.modifyGoal(GoalDelta(
        id: 'a',
        logEntry: RemoveParentLogEntry(
            id: 'remove', parentId: 'b', creationTime: time)));
    await tester.pump(const Duration(milliseconds: 32));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    client.dispose();
  });
}
