import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart'
    show
        Goal,
        GoalPath,
        computeDropGoalEffects,
        getGoalPriority;
import 'package:goals_core/sync.dart'
    show
        AddParentLogEntry,
        GoalDelta,
        MemoryLocalStore,
        MemoryPersistenceService,
        PriorityLogEntry,
        RemoveParentLogEntry,
        SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        DragEventType,
        GoalActionsContext,
        GoalWidgetsContext,
        dragEventProvider,
        expandedGoalsProvider,
        hasMouseProvider,
        selectedGoalsProvider,
        textFocusProvider;
import 'package:goals_widgets/goals_widgets.dart'
    show FlattenedGoalTree, GoalItemDragHandle, GoalItemWidget, GoalSeparator;

void main() {
  late SyncClient client;

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    dragEventProvider.add(DragEventType.none);

    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();
  });

  tearDown(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    dragEventProvider.add(DragEventType.none);
    client.dispose();
  });

  group('Alt-drag goal add/copy interaction and visual affordance', () {
    testWidgets(
        'drag feedback shows standard move affordance without Alt and switches to additive affordance on Alt press/release',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Goal 1'));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: GoalItemWidget(
                path: GoalPath(const ['g1']),
                hasRenderableChildren: false,
                dragHandle: GoalItemDragHandle.item,
                hoverActionsBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Start dragging Goal 1 past touch slop
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Goal 1')));
      await tester.pump();
      await gesture.moveBy(const Offset(50, 50));
      await tester.pump();

      expect(dragEventProvider.value, equals(DragEventType.start));
      expect(find.text('1'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);

      // Press Alt while drag is active
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      // Additive affordance should now be visible in drag feedback
      expect(find.textContaining('+'), findsOneWidget,
          reason:
              'Drag feedback must show additive (+) affordance when Alt is pressed');

      // Release Alt while drag is still active
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      // Should revert to move mode affordance
      expect(find.textContaining('+'), findsNothing,
          reason:
              'Drag feedback must revert to normal move affordance when Alt is released');

      // Clean up drag and drain timers
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets(
        'normal drag drop on another goal invokes onDropGoal with source and target paths in move mode',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Goal 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Goal 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Goal 3'));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      GoalPath? droppedSource;
      GoalPath? droppedTarget;
      dynamic additiveFlag;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      dynamic isAdditive}) {
                    droppedSource = source;
                    droppedTarget = dropPath;
                    additiveFlag = isAdditive;
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Goal 2');
      final g3Finder = find.text('Goal 3');

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g3Finder));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      expect(droppedSource, equals(GoalPath(const ['g1', 'g2'])));
      expect(droppedTarget, equals(GoalPath(const ['g3'])));
      expect(additiveFlag, isNot(isTrue),
          reason: 'Normal drag drop must not have additive flag set to true');
    });

    testWidgets(
        'Alt-drag drop on another goal invokes onDropGoal in additive mode (isAdditive = true)',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Goal 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Goal 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Goal 3'));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      GoalPath? droppedSource;
      GoalPath? droppedTarget;
      dynamic additiveFlag;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      dynamic isAdditive}) {
                    droppedSource = source;
                    droppedTarget = dropPath;
                    additiveFlag = isAdditive;
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Goal 2');
      final g3Finder = find.text('Goal 3');

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g3Finder));
      await tester.pump();

      // Hold Alt key during drop
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      expect(droppedSource, equals(GoalPath(const ['g1', 'g2'])));
      expect(droppedTarget, equals(GoalPath(const ['g3'])));
      expect(additiveFlag, isTrue,
          reason:
              'Alt-drag drop must invoke onDropGoal with isAdditive = true');
    });

    testWidgets(
        'Alt-drag drop on separator invokes onDropGoal in additive mode (isAdditive = true)',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Goal 1'));
      await client.modifyGoal(GoalDelta(id: 'g2', text: 'Goal 2'));

      GoalPath? droppedSource;
      dynamic additiveFlag;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      dynamic isAdditive}) {
                    droppedSource = source;
                    additiveFlag = isAdditive;
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g2'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g1Finder = find.text('Goal 1');
      final separatorFinder = find.byType(GoalSeparator).first;

      final gesture = await tester.startGesture(tester.getCenter(g1Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      expect(droppedSource, equals(GoalPath(const ['g1'])));
      expect(additiveFlag, isTrue,
          reason:
              'Alt-drag drop on separator must invoke onDropGoal with isAdditive = true');
    });

    testWidgets(
        'outcome: Alt-drag drop on another goal preserves source parent edge and adds destination edge through production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Parent 3'));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Child 2');
      final g3Finder = find.text('Parent 3');

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g3Finder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final g2 = client.stateSubject.value['g2']!;
      expect(g2.superGoalRelationships.containsKey('g1'), isTrue,
          reason: 'Source parent edge g1 must be preserved on Alt-drag add');
      expect(g2.superGoalRelationships.containsKey('g3'), isTrue,
          reason: 'Destination parent edge g3 must be added on Alt-drag add');
    });

    testWidgets(
        'outcome: normal drag drop on another goal removes source parent edge and adds destination edge through production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Parent 3'));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Child 2');
      final g3Finder = find.text('Parent 3');

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g3Finder));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final g2 = client.stateSubject.value['g2']!;
      expect(g2.superGoalRelationships.containsKey('g1'), isFalse,
          reason: 'Source parent edge g1 must be removed on normal drag move');
      expect(g2.superGoalRelationships.containsKey('g3'), isTrue,
          reason: 'Destination parent edge g3 must be added on normal drag move');
    });

    testWidgets(
        'outcome: Alt-drag drop on separator under destination parent preserves source parent and adds destination parent through production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Parent 3'));
      await client.modifyGoal(GoalDelta(
        id: 'g4',
        text: 'Child 4',
        logEntry: AddParentLogEntry(
          id: 'edge-3-4',
          parentId: 'g3',
          creationTime: DateTime.now(),
        ),
      ));

      expandedGoalsProvider.add([
        GoalPath(const ['g1']),
        GoalPath(const ['g3']),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Child 2');
      final separatorFinder = find.byType(GoalSeparator).at(3);

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final g2 = client.stateSubject.value['g2']!;
      expect(g2.superGoalRelationships.containsKey('g1'), isTrue,
          reason: 'Source parent edge g1 must be preserved on Alt-drag separator drop');
      expect(g2.superGoalRelationships.containsKey('g3'), isTrue,
          reason: 'Destination parent edge g3 must be added on Alt-drag separator drop');
    });

    testWidgets(
        'outcome: normal drag drop on separator under destination parent removes source parent and adds destination parent through production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'g3', text: 'Parent 3'));
      await client.modifyGoal(GoalDelta(
        id: 'g4',
        text: 'Child 4',
        logEntry: AddParentLogEntry(
          id: 'edge-3-4',
          parentId: 'g3',
          creationTime: DateTime.now(),
        ),
      ));

      expandedGoalsProvider.add([
        GoalPath(const ['g1']),
        GoalPath(const ['g3']),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [
                      GoalPath(const ['g1']),
                      GoalPath(const ['g3'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Child 2');
      final separatorFinder = find.byType(GoalSeparator).at(3);

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final g2 = client.stateSubject.value['g2']!;
      expect(g2.superGoalRelationships.containsKey('g1'), isFalse,
          reason: 'Source parent edge g1 must be removed on normal drag separator drop');
      expect(g2.superGoalRelationships.containsKey('g3'), isTrue,
          reason: 'Destination parent edge g3 must be added on normal drag separator drop');
    });

    testWidgets(
        'outcome: invalid additive drop onto descendant (cycle) is rejected by production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [GoalPath(const ['g1'])],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g1Finder = find.text('Parent 1');
      final g2Finder = find.text('Child 2');

      final gesture = await tester.startGesture(tester.getCenter(g1Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g2Finder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final g1 = client.stateSubject.value['g1']!;
      expect(g1.superGoalRelationships.containsKey('g2'), isFalse,
          reason: 'Cycle creation (dropping parent onto child) must produce zero effects');
    });

    testWidgets(
        'outcome: invalid additive drop onto existing parent (duplicate edge) is rejected by production drop handler',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime.now(),
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      final initialLogCount = client.stateSubject.value['g2']!.log.length;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [GoalPath(const ['g1'])],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final g2Finder = find.text('Child 2');
      final g1Finder = find.text('Parent 1');

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(g1Finder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final g2 = client.stateSubject.value['g2']!;
      expect(g2.log.length, equals(initialLogCount),
          reason: 'Duplicate edge creation must produce zero effects and no new log entries');
    });

    testWidgets(
        'outcome: Alt-drag separator drop onto already-existing destination parent produces zero effects and no priority mutation',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        logEntry: PriorityLogEntry(
          id: 'p-g2',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 100.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g3',
        text: 'Child 3',
        logEntry: AddParentLogEntry(
          id: 'edge-1-3',
          parentId: 'g1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g3',
        logEntry: PriorityLogEntry(
          id: 'p-g3',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 200.0,
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [GoalPath(const ['g1'])],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final initialG2Priority =
          getGoalPriority(client.stateSubject.value, GoalPath(const ['g1', 'g2']));
      final initialG3Priority =
          getGoalPriority(client.stateSubject.value, GoalPath(const ['g1', 'g3']));
      final initialLogCountG2 = client.stateSubject.value['g2']!.log.length;

      // Alt-drag Child 2 onto the separator between Child 2 and Child 3 (under Parent 1, where Child 2 already belongs)
      final g2Finder = find.text('Child 2');
      final separatorFinder = find.byType(GoalSeparator).at(2);

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final goalMapAfter = client.stateSubject.value;
      expect(
          getGoalPriority(goalMapAfter, GoalPath(const ['g1', 'g2'])),
          equals(initialG2Priority),
          reason:
              'Additive separator drop onto existing destination parent must not mutate priority');
      expect(
          getGoalPriority(goalMapAfter, GoalPath(const ['g1', 'g3'])),
          equals(initialG3Priority),
          reason: 'Sibling priority must not be mutated');
      expect(goalMapAfter['g2']!.log.length, equals(initialLogCountG2),
          reason:
              'Additive drop onto existing parent must produce zero effects and no log entries');
    });

    testWidgets(
        'outcome: normal drag separator drop under same parent reorders goal and updates priority',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'g1', text: 'Parent 1'));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
          id: 'edge-1-2',
          parentId: 'g1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g2',
        logEntry: PriorityLogEntry(
          id: 'p-g2',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 100.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g3',
        text: 'Child 3',
        logEntry: AddParentLogEntry(
          id: 'edge-1-3',
          parentId: 'g1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'g3',
        logEntry: PriorityLogEntry(
          id: 'p-g3',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 200.0,
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['g1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    rootGoalPaths: [GoalPath(const ['g1'])],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Normal drag Child 2 onto the separator between Child 2 and Child 3
      final g2Finder = find.text('Child 2');
      final separatorFinder = find.byType(GoalSeparator).at(2);

      final gesture = await tester.startGesture(tester.getCenter(g2Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final goalMapAfter = client.stateSubject.value;
      final newG2Priority =
          getGoalPriority(goalMapAfter, GoalPath(const ['g1', 'g2']));
      expect(newG2Priority, isNotNull);
      expect(newG2Priority!, equals(150.0),
          reason:
              'Normal drag separator drop must reorder goal and assign new priority between Child 2 and Child 3');
    });

    testWidgets(
        'outcome: Alt-drag separator drop onto root separator produces zero effects and no priority mutation',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'r1', text: 'Root 1'));
      await client.modifyGoal(GoalDelta(
        id: 'r1',
        logEntry: PriorityLogEntry(
          id: 'p-r1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 10.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'r2', text: 'Root 2'));
      await client.modifyGoal(GoalDelta(
        id: 'r2',
        logEntry: PriorityLogEntry(
          id: 'p-r2',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 200.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'c1',
        text: 'Child 1',
        logEntry: AddParentLogEntry(
          id: 'edge-r1-c1',
          parentId: 'r1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'c1',
        logEntry: PriorityLogEntry(
          id: 'p-c1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 100.0,
          path: GoalPath(const ['r1']),
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['r1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    showAddGoal: false,
                    rootGoalPaths: [
                      GoalPath(const ['r1']),
                      GoalPath(const ['r2'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final initialR1Priority =
          getGoalPriority(client.stateSubject.value, GoalPath(const ['r1']));
      final initialR2Priority =
          getGoalPriority(client.stateSubject.value, GoalPath(const ['r2']));
      final initialC1LogCount = client.stateSubject.value['c1']!.log.length;

      // Drag Child 1 to root separator between Child 1 and Root 2 with Alt held
      final c1Finder = find.text('Child 1');
      // In FlattenedGoalTree with showAddGoal=false: [sep0, r1, sep1, c1, sep2, r2, sep3]
      final separatorFinder = find.byType(GoalSeparator).at(2);

      final gesture = await tester.startGesture(tester.getCenter(c1Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      final goalMapAfter = client.stateSubject.value;
      final c1 = goalMapAfter['c1']!;
      expect(c1.superGoalRelationships.containsKey('r1'), isTrue,
          reason: 'Child 1 must remain parented to r1');
      expect(c1.log.length, equals(initialC1LogCount),
          reason: 'Additive drop to root separator must produce zero effects');
      expect(getGoalPriority(goalMapAfter, GoalPath(const ['r1'])),
          equals(initialR1Priority),
          reason: 'Root 1 priority must not be mutated');
      expect(getGoalPriority(goalMapAfter, GoalPath(const ['r2'])),
          equals(initialR2Priority),
          reason: 'Root 2 priority must not be mutated');
    });

    testWidgets(
        'outcome: normal drag separator drop of child to root separator removes parent edge and moves child to root',
        (tester) async {
      await client.modifyGoal(GoalDelta(id: 'r1', text: 'Root 1'));
      await client.modifyGoal(GoalDelta(
        id: 'r1',
        logEntry: PriorityLogEntry(
          id: 'p-r1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 10.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(id: 'r2', text: 'Root 2'));
      await client.modifyGoal(GoalDelta(
        id: 'r2',
        logEntry: PriorityLogEntry(
          id: 'p-r2',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 200.0,
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'c1',
        text: 'Child 1',
        logEntry: AddParentLogEntry(
          id: 'edge-r1-c1',
          parentId: 'r1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
        ),
      ));
      await client.modifyGoal(GoalDelta(
        id: 'c1',
        logEntry: PriorityLogEntry(
          id: 'p-c1',
          creationTime: DateTime(2026, 1, 1, 10, 0),
          priority: 100.0,
          path: GoalPath(const ['r1']),
        ),
      ));

      expandedGoalsProvider.add([GoalPath(const ['r1'])]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onDropGoal: (source,
                      {dropPath,
                      nextDropPath,
                      prevDropPath,
                      bool isAdditive = false}) async {
                    final deltas = computeDropGoalEffects(
                      client.stateSubject.value,
                      source,
                      dropPath: dropPath,
                      prevDropPath: prevDropPath,
                      nextDropPath: nextDropPath,
                      isAdditive: isAdditive,
                    );
                    if (deltas.isNotEmpty) {
                      await client.modifyGoals(deltas);
                    }
                  },
                  child: FlattenedGoalTree(
                    showAddGoal: false,
                    rootGoalPaths: [
                      GoalPath(const ['r1']),
                      GoalPath(const ['r2'])
                    ],
                    hoverActionsBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Drag Child 1 to root separator between Child 1 and Root 2 without Alt (normal move)
      final c1Finder = find.text('Child 1');
      final separatorFinder = find.byType(GoalSeparator).at(2);

      final gesture = await tester.startGesture(tester.getCenter(c1Finder));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(separatorFinder));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final goalMapAfter = client.stateSubject.value;
      final c1 = goalMapAfter['c1']!;
      expect(c1.superGoalRelationships.containsKey('r1'), isFalse,
          reason: 'Parent edge r1 must be removed on normal move to root');
      final newC1Priority =
          getGoalPriority(goalMapAfter, GoalPath(const ['c1']));
      expect(newC1Priority, isNotNull);
      expect(newC1Priority!, equals(150.0),
          reason: 'Child 1 must be assigned root priority between Child 1 and Root 2');
    });

    test('direct unit test: computeDropGoalEffects distinguishes move from add and rejects invalid operations', () {
      final now = DateTime.now();
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final p2 = Goal(id: 'p2', text: 'Parent 2', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');

      final goalMap = {'p1': p1, 'p2': p2, 'c1': c1};

      // 1. Move to p2: removes p1, adds p2
      final moveDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p2']),
        isAdditive: false,
      );
      expect(moveDeltas.where((d) => d.logEntry is RemoveParentLogEntry).length, equals(1));
      expect(moveDeltas.where((d) => d.logEntry is AddParentLogEntry).length, equals(1));
      final removeEntry = moveDeltas.firstWhere((d) => d.logEntry is RemoveParentLogEntry).logEntry as RemoveParentLogEntry;
      final addEntry = moveDeltas.firstWhere((d) => d.logEntry is AddParentLogEntry).logEntry as AddParentLogEntry;
      expect(removeEntry.parentId, equals('p1'));
      expect(addEntry.parentId, equals('p2'));

      // 2. Add to p2: keeps p1 (no RemoveParentLogEntry), adds p2
      final addDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p2']),
        isAdditive: true,
      );
      expect(addDeltas.where((d) => d.logEntry is RemoveParentLogEntry), isEmpty);
      expect(addDeltas.where((d) => d.logEntry is AddParentLogEntry).length, equals(1));
      final addOnlyEntry = addDeltas.first.logEntry as AddParentLogEntry;
      expect(addOnlyEntry.parentId, equals('p2'));

      // 3. Add to p1 (duplicate edge): rejected with 0 deltas
      final dupDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p1']),
        isAdditive: true,
      );
      expect(dupDeltas, isEmpty);

      // 4. Add p1 to c1 (cycle): rejected with 0 deltas
      final cycleDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1']),
        dropPath: GoalPath(const ['p1', 'c1']),
        isAdditive: true,
      );
      expect(cycleDeltas, isEmpty);

      // 5. Additive drop to separator under existing parent: rejected with 0 deltas
      final dupSepDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1', 'c1']),
        nextDropPath: GoalPath(const ['p1', 'c1']),
        isAdditive: true,
      );
      expect(dupSepDeltas, isEmpty);

      // 6. Normal separator drop under same parent: emits PriorityLogEntry
      final normalSepDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1', 'c1']),
        nextDropPath: GoalPath(const ['p1', 'c1']),
        isAdditive: false,
      );
      expect(normalSepDeltas.any((d) => d.logEntry is PriorityLogEntry), isTrue);

      // 7. Additive drop to root separator: rejected with 0 deltas
      final rootAdditiveDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1']),
        nextDropPath: GoalPath(const ['p2']),
        isAdditive: true,
      );
      expect(rootAdditiveDeltas, isEmpty);

      // 8. Normal child to root separator move: removes parent edge and assigns root priority
      final rootMoveDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1']),
        nextDropPath: GoalPath(const ['p2']),
        isAdditive: false,
      );
      expect(rootMoveDeltas.where((d) => d.logEntry is RemoveParentLogEntry).length, equals(1));
      expect(rootMoveDeltas.where((d) => d.id == 'c1' && d.logEntry is PriorityLogEntry).length, equals(1));
      final rootRemove = rootMoveDeltas.firstWhere((d) => d.logEntry is RemoveParentLogEntry).logEntry as RemoveParentLogEntry;
      expect(rootRemove.parentId, equals('p1'));
    });
  });
}
