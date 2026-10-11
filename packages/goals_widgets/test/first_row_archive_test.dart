import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart'
    show GoalPath, WorldContext, getGoalStatus;
import 'package:goals_types/goals_types.dart' show GoalStatus, Op;
import 'package:goals_core/sync.dart'
    show
        GoalDelta,
        StatusLogEntry,
        MemoryLocalStore,
        MemoryPersistenceService,
        SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        GoalActionsContext,
        GoalWidgetsContext,
        SHORTCUTS,
        expandedGoalsProvider,
        hasMouseProvider,
        hoverEventStream,
        selectedGoalsProvider,
        textFocusProvider,
        worldContextProvider;
import 'package:goals_widgets/goals_widgets.dart'
    show FlattenedGoalTree, GoalItemWidget;

class _Remote extends MemoryPersistenceService {
  Future<void> persist(List<Op> batch) => super.save([
        ...ops.where((old) => !batch.any((op) => op.id == old.id)),
        ...batch,
      ]);
  @override
  Future<void> save(Iterable<Op> values) async {
    await persist(values.toList());
  }
}

void main() {
  late SyncClient client;
  late _Remote persistenceService;
  late MemoryLocalStore localStore;
  final archivedPaths = <GoalPath>[];

  setUp(() async {
    archivedPaths.clear();
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    worldContextProvider.add(WorldContext(time: DateTime(2026)));

    localStore = MemoryLocalStore();
    persistenceService = _Remote();
    client = SyncClient(
      localStore: localStore,
      persistenceService: persistenceService,
    );
    await client.init();
    await client.modifyGoals([
      GoalDelta(id: 'g1', text: 'Goal 1'),
      GoalDelta(id: 'g2', text: 'Goal 2'),
      GoalDelta(id: 'g3', text: 'Goal 3'),
    ]);
    await client.sync();
  });

  tearDown(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hoverEventStream.add(null);
    client.dispose();
  });

  Widget buildTree({List<GoalPath>? rootGoalPaths, bool showAddGoal = true}) {
    return MaterialApp(
      home: Scaffold(
        body: Shortcuts(
          shortcuts: SHORTCUTS,
          child: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onArchive: (path) {
                    if (path != null) {
                      archivedPaths.add(path);
                      client.modifyGoal(GoalDelta(
                        id: path.goalId,
                        logEntry: StatusLogEntry(
                          id: 'archive-${path.goalId}',
                          creationTime: DateTime.now(),
                          status: GoalStatus.archived,
                        ),
                      ));
                    }
                  },
                  child: FlattenedGoalTree(
                    predicate: (worldContext, goalMap, path, goal) =>
                        getGoalStatus(worldContext, goal)?.status !=
                        GoalStatus.archived,
                    showAddGoal: showAddGoal,
                    rootGoalPaths: rootGoalPaths ?? [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g2']),
                      GoalPath(const ['g3']),
                    ],
                    hoverActionsBuilder: (path) => KeyedSubtree(
                      key: ValueKey('hover-action-${path?.goalId}'),
                      child: const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool isGoalItemRenderedHovered(WidgetTester tester, String goalId) {
    final itemFinder = find.byWidgetPredicate(
      (w) => w is GoalItemWidget && w.path == GoalPath([goalId]),
    );
    if (itemFinder.evaluate().isEmpty) return false;

    final hasHoverAction = find
        .descendant(
          of: itemFinder,
          matching: find.byKey(ValueKey('hover-action-$goalId')),
        )
        .evaluate()
        .isNotEmpty;

    final context = tester.element(itemFinder);
    final hoverColor = Theme.of(context).hoverColor;
    final containers = tester.widgetList<Container>(
      find.descendant(of: itemFinder, matching: find.byType(Container)),
    );
    final hasHoverBackground = containers.any((c) =>
        c.decoration is BoxDecoration &&
        (c.decoration as BoxDecoration).color == hoverColor);

    return hasHoverAction && hasHoverBackground;
  }

  testWidgets(
      'hover first row and Backspace archives first goal without crash and focuses remaining row',
      (tester) async {
    await tester.pumpWidget(buildTree());
    await tester.pumpAndSettle();

    // Hover first row
    hoverEventStream.add(GoalPath(const ['g1']));
    await tester.pumpAndSettle();

    expect(isGoalItemRenderedHovered(tester, 'g1'), isTrue);
    expect(isGoalItemRenderedHovered(tester, 'g2'), isFalse);
    expect(isGoalItemRenderedHovered(tester, 'g3'), isFalse);

    // Press Backspace
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g1'])]));
    expect(hoverEventStream.value, equals(GoalPath(const ['g2'])));

    // g1 should be removed from the rendered tree
    expect(find.text('Goal 1'), findsNothing);

    // Rendered hover verification: new first row (g2) must carry hover, g3 must not
    expect(isGoalItemRenderedHovered(tester, 'g2'), isTrue,
        reason: 'The new first row (g2) must visibly render hovered');
    expect(isGoalItemRenderedHovered(tester, 'g3'), isFalse,
        reason: 'The formerly third row (g3) must NOT render hovered');
  });

  testWidgets(
      'hover middle row and Backspace archives middle goal and keeps prior row hovered',
      (tester) async {
    await tester.pumpWidget(buildTree());
    await tester.pumpAndSettle();

    // Hover middle row (g2)
    hoverEventStream.add(GoalPath(const ['g2']));
    await tester.pumpAndSettle();

    expect(isGoalItemRenderedHovered(tester, 'g2'), isTrue);

    // Press Backspace
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g2'])]));
    expect(hoverEventStream.value, equals(GoalPath(const ['g1'])));
    expect(find.text('Goal 2'), findsNothing);
    expect(isGoalItemRenderedHovered(tester, 'g1'), isTrue);
    expect(isGoalItemRenderedHovered(tester, 'g3'), isFalse);
  });

  testWidgets(
      'hover last row and Backspace archives last goal and clears hover when showAddGoal is false',
      (tester) async {
    await tester.pumpWidget(buildTree(showAddGoal: false));
    await tester.pumpAndSettle();

    // Hover last row (g3)
    hoverEventStream.add(GoalPath(const ['g3']));
    await tester.pumpAndSettle();

    expect(isGoalItemRenderedHovered(tester, 'g3'), isTrue);

    // Press Backspace
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g3'])]));
    expect(hoverEventStream.value, isNull);
    expect(find.text('Goal 3'), findsNothing);
    expect(isGoalItemRenderedHovered(tester, 'g1'), isFalse);
    expect(isGoalItemRenderedHovered(tester, 'g2'), isFalse);
  });

  testWidgets(
      'hover last goal row and Backspace archives last goal and moves hover to prior goal when showAddGoal is true',
      (tester) async {
    await tester.pumpWidget(buildTree(showAddGoal: true));
    await tester.pumpAndSettle();

    // Hover last goal row (g3) with add-goal placeholder following it
    hoverEventStream.add(GoalPath(const ['g3']));
    await tester.pumpAndSettle();

    expect(isGoalItemRenderedHovered(tester, 'g3'), isTrue);

    // Press Backspace
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g3'])]));
    expect(hoverEventStream.value, equals(GoalPath(const ['g2'])));
    expect(find.text('Goal 3'), findsNothing);
    expect(isGoalItemRenderedHovered(tester, 'g2'), isTrue);
    expect(isGoalItemRenderedHovered(tester, 'g1'), isFalse);
  });

  testWidgets(
      'hover single goal row and Backspace archives goal and clears hover (showAddGoal true and false)',
      (tester) async {
    // 1. showAddGoal: false
    await tester.pumpWidget(
        buildTree(rootGoalPaths: [GoalPath(const ['g1'])], showAddGoal: false));
    await tester.pumpAndSettle();

    hoverEventStream.add(GoalPath(const ['g1']));
    await tester.pumpAndSettle();
    expect(isGoalItemRenderedHovered(tester, 'g1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g1'])]));
    expect(hoverEventStream.value, isNull);
    expect(find.text('Goal 1'), findsNothing);

    archivedPaths.clear();

    // 2. showAddGoal: true (trailing add goal placeholder)
    await tester.pumpWidget(
        buildTree(rootGoalPaths: [GoalPath(const ['g2'])], showAddGoal: true));
    await tester.pumpAndSettle();

    hoverEventStream.add(GoalPath(const ['g2']));
    await tester.pumpAndSettle();
    expect(isGoalItemRenderedHovered(tester, 'g2'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g2'])]));
    expect(hoverEventStream.value, isNull);
    expect(find.text('Goal 2'), findsNothing);
  });

  testWidgets(
      'absent or stale hover ignores Backspace without crash or archive',
      (tester) async {
    await tester.pumpWidget(buildTree());
    await tester.pumpAndSettle();

    // Absent hover
    hoverEventStream.add(null);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(archivedPaths, isEmpty);

    // Stale hover (goal not in tree)
    hoverEventStream.add(GoalPath(const ['non_existent_goal']));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(archivedPaths, isEmpty);
  });

  testWidgets(
      'active text focus does not trigger RemoveIntent on Backspace',
      (tester) async {
    await tester.pumpWidget(buildTree());
    await tester.pumpAndSettle();

    // Goal is hovered, but a text editor is focused
    hoverEventStream.add(GoalPath(const ['g1']));
    textFocusProvider.add(GoalPath(const ['g1']));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, isEmpty);
  });

  testWidgets(
      'archive retains across client reload from persistence',
      (tester) async {
    await tester.pumpWidget(buildTree());
    await tester.pumpAndSettle();

    // Hover first row and archive via Backspace
    hoverEventStream.add(GoalPath(const ['g1']));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(archivedPaths, equals([GoalPath(const ['g1'])]));

    // Reload with a new client backed by the same persistence service
    final reloadedClient = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: persistenceService,
    );
    await reloadedClient.init();

    final g1 = reloadedClient.stateSubject.value['g1'];
    expect(g1, isNotNull);
    final status = getGoalStatus(WorldContext(time: DateTime(2026)), g1!);
    expect(status?.status, equals(GoalStatus.archived));
    reloadedClient.dispose();
  });
}
