import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath, WorldContext;
import 'package:goals_core/sync.dart'
    show
        AddParentLogEntry,
        GoalDelta,
        MemoryLocalStore,
        MemoryPersistenceService,
        SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        DragEventType,
        GoalActionsContext,
        GoalWidgetsContext,
        dragEventProvider,
        expandedGoalsProvider,
        hasMouseProvider,
        hoverEventStream,
        selectedGoalsProvider,
        textFocusProvider,
        worldContextProvider;
import 'package:goals_widgets/goals_widgets.dart'
    show FlattenedGoalTree, ParentBreadcrumb, PathBreadcrumb, PathOmissionStrategy;

void main() {
  late SyncClient client;

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    worldContextProvider.add(WorldContext(time: DateTime(2026, 11, 3)));

    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();

    for (final (id, text) in [
      ('container', 'Container Folder'),
      ('root', 'Root'),
      ('mid', 'Sub Milestone'),
      ('leaf', 'Focused Goal'),
      ('parent_a', 'Ancestor Goal With Very Long Title Over Two Hundred Pixels'),
      ('parent_b', 'Second Parent Goal With Another Substantial Title'),
      ('parent_c', 'Third Parent Goal Requiring More Space'),
      ('child', 'Child Focus Goal'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }

    final time = DateTime(2026, 11, 3);
    for (final (childId, parentId) in [
      ('parent_b', 'parent_a'),
      ('parent_c', 'parent_b'),
      ('child', 'parent_c'),
      ('mid', 'root'),
      ('leaf', 'mid'),
    ]) {
      await client.modifyGoal(GoalDelta(
        id: childId,
        logEntry: AddParentLogEntry(
          id: '$childId-$parentId',
          parentId: parentId,
          creationTime: time,
        ),
      ));
    }

    // Embed leaf in container with displayedChildPath ['root', 'mid', 'leaf']
    await client.modifyGoal(GoalDelta(
      id: 'leaf',
      logEntry: AddParentLogEntry(
        id: 'leaf-container',
        parentId: 'container',
        creationTime: time,
        displayedChildPath: ['root', 'mid', 'leaf'],
      ),
    ));
  });

  tearDown(() {
    client.dispose();
  });

  testWidgets(
      '(a) ParentBreadcrumb still caps at 560px and omits from the start',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ParentBreadcrumb(path: const GoalPath(['child'])),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final pathBreadcrumbFinder = find.byType(PathBreadcrumb);
    expect(pathBreadcrumbFinder, findsOneWidget);
    final size = tester.getSize(pathBreadcrumbFinder);
    expect(size.width, lessThanOrEqualTo(560.0));
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Ancestor Goal With Very Long Title Over Two Hundred Pixels'),
        findsNothing);
  });

  testWidgets(
      '(b) displayed paths in FlattenedGoalTree expand beyond 560px when row width allows',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Expand container so leaf's row is visible in FlattenedGoalTree
    expandedGoalsProvider.add([const GoalPath(['container'])]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: SizedBox(
              width: 960,
              child: FlattenedGoalTree(
                rootGoalPaths: [const GoalPath(['container'])],
                showAddGoal: false,
                hoverActionsBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final pathBreadcrumbFinder = find.byType(PathBreadcrumb);
    expect(pathBreadcrumbFinder, findsOneWidget);
    final size = tester.getSize(pathBreadcrumbFinder);

    expect(find.text('Root'), findsOneWidget);
    expect(find.text('Sub Milestone'), findsOneWidget);
    expect(find.text('Focused Goal'), findsOneWidget);
    expect(find.text('…'), findsNothing);
    // PathBreadcrumb is not clamped to 560px when maxWidth is null.
    // In a 960px row, it expands to its natural width or row space available.
    expect(size.width, greaterThan(200.0));
    expect(tester.widget<PathBreadcrumb>(pathBreadcrumbFinder).maxWidth, isNull);
  });

  testWidgets(
      '(c) when constrained, displayed paths in FlattenedGoalTree place … in the middle without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Expand container so leaf's row is visible in FlattenedGoalTree
    expandedGoalsProvider.add([const GoalPath(['container'])]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: SizedBox(
              width: 320,
              child: FlattenedGoalTree(
                rootGoalPaths: [const GoalPath(['container'])],
                showAddGoal: false,
                hoverActionsBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    expect(find.text('Root'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Focused Goal'), findsOneWidget);
    expect(find.text('Sub Milestone'), findsNothing);

    final rootX = tester.getTopLeft(find.text('Root')).dx;
    final dotsX = tester.getTopLeft(find.text('…')).dx;
    final leafX = tester.getTopLeft(find.text('Focused Goal')).dx;
    expect(rootX, lessThan(dotsX));
    expect(dotsX, lessThan(leafX));
  });

  testWidgets(
      '(d) tapping visible crumbs before and after … emits the full prefix GoalPath',
      (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: Builder(
              builder: (context) => GoalActionsContext.overrideWith(
                context,
                onFocused: (p, {inPlace}) => focused.add(p),
                child: SizedBox(
                  width: 320,
                  child: PathBreadcrumb(
                    renderedPath: const GoalPath(['root', 'mid', 'leaf']),
                    omissionStrategy: PathOmissionStrategy.middle,
                    maxWidth: null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Root'));
    expect(focused, isNotEmpty);
    expect(focused.last, equals(const GoalPath(['root'])));

    await tester.tap(find.text('Focused Goal'));
    expect(focused.last, equals(const GoalPath(['root', 'mid', 'leaf'])));
  });
}
