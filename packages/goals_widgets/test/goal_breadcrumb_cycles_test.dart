import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

  testWidgets(
      'narrow parent paths omit oldest crumbs while keeping paths, removal, and resize behavior',
      (tester) async {
    tester.view.physicalSize = const Size(280, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = SyncClient(
        localStore: MemoryLocalStore(),
        persistenceService: MemoryPersistenceService());
    await client.init();
    for (final (id, text) in [
      ('oldest', 'Oldest parent'),
      ('older', 'Older parent'),
      ('parent', 'Direct parent'),
      ('child', 'Nearest parent'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }

    final focused = <GoalPath>[];
    var removals = 0;
    Widget breadcrumb() => MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(8),
              child: GoalWidgetsContext(
                syncClient: client,
                child: GoalActionsContext.empty(
                  child: Builder(
                    builder: (context) => GoalActionsContext.overrideWith(
                      context,
                      onFocused: (path, {inPlace}) => focused.add(path),
                      child: PathBreadcrumb(
                        renderedPath: GoalPath(
                            const ['oldest', 'older', 'parent', 'child']),
                        onRemove: () => removals++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(breadcrumb());
    await tester.pump();

    expect(find.text('…'), findsOneWidget,
        reason: 'A narrow panel must disclose omitted older ancestors.');
    expect(find.text('Oldest parent'), findsNothing);
    expect(find.text('Nearest parent'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
          .color,
      isNot(Colors.transparent),
      reason: 'The remove control must remain visibly available without hover.',
    );
    expect(tester.takeException(), isNull,
        reason: 'The bounded row must not overflow the narrow panel.');

    await tester.tap(find.text('Nearest parent'));
    expect(focused, [
      GoalPath(const ['oldest', 'older', 'parent', 'child']),
    ]);
    await tester.tap(find.byIcon(Icons.close));
    expect(removals, 1);

    tester.view.physicalSize = const Size(1000, 160);
    await tester.pumpWidget(breadcrumb());
    await tester.pump();
    expect(find.text('Older parent'), findsOneWidget,
        reason: 'A wider panel restores as many recent ancestors as fit.');
    expect(find.text('Direct parent'), findsOneWidget);
    expect(find.text('Nearest parent'), findsOneWidget);
    expect(find.text('Oldest parent'), findsOneWidget,
        reason: 'All four compact crumbs fit at the 560px cap.');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    client.dispose();
  });

  testWidgets(
      'wide compact parent paths retain every fitting crumb without truncation',
      (tester) async {
    tester.view.physicalSize = const Size(560, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = SyncClient(
        localStore: MemoryLocalStore(),
        persistenceService: MemoryPersistenceService());
    await client.init();
    for (final (id, text) in [
      ('a', 'A'),
      ('b', 'B'),
      ('c', 'C'),
      ('d', 'D'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: const SizedBox(
              width: 560,
              child: PathBreadcrumb(
                renderedPath: GoalPath(['a', 'b', 'c', 'd']),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('…'), findsNothing,
        reason: 'Four compact crumbs fit in the 560px breadcrumb cap.');
    for (final label in ['A', 'B', 'C', 'D']) {
      expect(find.text(label), findsOneWidget,
          reason: 'A fitting compact crumb must remain visible: $label');
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(label))
            .didExceedMaxLines,
        isFalse,
        reason: 'A fitting compact crumb must not receive an ellipsis.',
      );
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    client.dispose();
  });
}
