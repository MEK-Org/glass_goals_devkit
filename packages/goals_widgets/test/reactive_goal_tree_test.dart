import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show Goal;
import 'package:goals_core/sync.dart'
    show
        SyncClient,
        MemoryLocalStore,
        MemoryPersistenceService,
        WatchedGoalSet,
        AddParentLogEntry,
        GoalDelta;
import 'package:rxdart/rxdart.dart';

/// A stripped-down stand-in for `FlattenedGoalTree`, distilled to the
/// interaction that produced the regressions:
///
///   * it watches a node and renders that node's children,
///   * it reads goal data from the watch's synchronous [currentValue] and uses
///     the (throttled) watch stream only as a rebuild trigger, and
///   * its add flow awaits the mutation, then synchronously advances a
///     focus-like piece of state (mirroring `_onAddGoal` advancing
///     `textFocusProvider` after the goal is created).
///
/// The point of the test: after adding a child, that child must be on screen
/// in the very next frame — no second refresh, no one-frame flash.
class _MiniGoalTree extends StatefulWidget {
  final SyncClient client;
  final String rootId;
  const _MiniGoalTree({required this.client, required this.rootId});

  @override
  State<_MiniGoalTree> createState() => _MiniGoalTreeState();
}

class _MiniGoalTreeState extends State<_MiniGoalTree> {
  WatchedGoalSet? _watch;
  StreamSubscription<Map<String, Goal>>? _sub;

  // Stand-in for the focus cursor: bumped synchronously after an add to force
  // a rebuild in the same turn the goal was created.
  int _focusTick = 0;

  @override
  void initState() {
    super.initState();
    _watch = widget.client.watchGoals([widget.rootId]);
    _sub = _watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _watch?.dispose();
    super.dispose();
  }

  /// Exposed for the test to drive the add interaction.
  Future<void> addChild(String parentId, String childId, String text) async {
    await widget.client.modifyGoal(GoalDelta(
      id: childId,
      text: text,
      logEntry: AddParentLogEntry(
        id: '$childId-edge',
        parentId: parentId,
        creationTime: DateTime.now(),
      ),
    ));
    // Synchronous post-mutation UI step (the analog of advancing focus).
    if (mounted) setState(() => _focusTick++);
  }

  @override
  Widget build(BuildContext context) {
    final goals = _watch!.currentValue;
    final root = goals[widget.rootId];
    final childIds =
        root?.subGoalIds.where(goals.containsKey).toList() ?? const <String>[];
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            for (final id in childIds)
              Text(goals[id]!.text, key: ValueKey('goal-$id')),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
      'a child added to the watched node renders in the next frame '
      '(no flash, no missing root add)', (tester) async {
    final client = SyncClient(
      persistenceService: MemoryPersistenceService(),
      localStore: MemoryLocalStore(),
    );
    await client.init();
    await client.modifyGoal(GoalDelta(id: 'root', text: 'root'));

    await tester.pumpWidget(_MiniGoalTree(client: client, rootId: 'root'));
    await tester.pump();

    final state =
        tester.state<_MiniGoalTreeState>(find.byType(_MiniGoalTree));

    // Add a child and await the mutation, then render exactly one frame —
    // crucially WITHOUT advancing past the 16ms throttle window. The child
    // must already be present, sourced from the watch's synchronous snapshot.
    await state.addChild('root', 'c1', 'child one');
    await tester.pump();

    expect(find.byKey(const ValueKey('goal-c1')), findsOneWidget,
        reason: 'newly-added child should be visible in the frame right '
            'after the add resolves, without a throttle-window refresh');

    // A second add behaves the same.
    await state.addChild('root', 'c2', 'child two');
    await tester.pump();
    expect(find.byKey(const ValueKey('goal-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('goal-c1')), findsOneWidget);

    // Drain the throttle + persistence timers so teardown doesn't trip the
    // "Timer still pending" invariant.
    await tester.pump(const Duration(milliseconds: 50));
  });
}
