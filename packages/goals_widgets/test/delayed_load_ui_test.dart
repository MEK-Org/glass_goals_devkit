import 'dart:async';

import 'package:fade_shimmer/fade_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:goals_widgets/goals_widgets.dart';
import 'package:hlc/hlc.dart';

class _GatedStore extends MemoryLocalStore {
  Completer<void>? childGate;
  int childLoads = 0;

  @override
  Future<Iterable<Op>> loadOpsForGoal(String goalId) async {
    if (goalId == 'child' && childGate != null) {
      childLoads++;
      await childGate!.future;
    }
    return super.loadOpsForGoal(goalId);
  }
}

Future<({SyncClient client, _GatedStore store})> _cold() async {
  final store = _GatedStore();
  final t0 = HLC.now('producer');
  final t1 = t0.increment();
  await store.storeSyncedOps([
    DeltaOp(
      id: 'op-parent',
      hlcTimestamp: t0.pack(),
      delta: GoalDelta(id: 'parent', text: 'Parent title'),
    ),
    DeltaOp(
      id: 'op-child',
      hlcTimestamp: t1.pack(),
      delta: GoalDelta(
        id: 'child',
        text: 'Delayed child title',
        logEntry: AddParentLogEntry(
          id: 'edge', parentId: 'parent', creationTime: DateTime.utc(2026, 10, 21),
        ),
      ),
    ),
  ]);
  store.cursor = t1.pack();
  final client = SyncClient(localStore: store);
  await client.init();
  await client.loadGoal('parent');
  store.childGate = Completer<void>();
  return (client: client, store: store);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Future<void> _mount(WidgetTester tester, SyncClient client, Widget widget) async {
  // This package's process-global shimmer timer must start on the real clock.
  await tester.runAsync(() => tester.pumpWidget(const FadeShimmer(
      width: 1, height: 1, fadeTheme: FadeTheme.light)));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: GoalWidgetsContext(
      syncClient: client,
      child: GoalActionsContext.empty(child: widget),
    )),
  ));
  await _frames(tester);
}

void main() {
  for (final surface in ['flattened tree', 'rendered child path']) {
    testWidgets('$surface replaces a delayed loading placeholder without an edit', (tester) async {
      final f = await _cold();
      final client = f.client;
      final watch = client.watchGoals(['parent', 'child']);
      addTearDown(() async {
        f.store.childGate?.complete();
        await watch.dispose();
        client.dispose();
        expandedGoalsProvider.add([]);
      });
      expandedGoalsProvider.add([GoalPath(['parent'])]);
      textFocusProvider.add(null);
      hoverEventStream.add(null);
      worldContextProvider.add(WorldContext(time: DateTime.utc(2026, 10, 21)));

      final widget = surface == 'flattened tree'
          ? FlattenedGoalTree(
              rootGoalPaths: [GoalPath(['parent'])],
              showAddGoal: false,
              hoverActionsBuilder: (_) => const SizedBox(),
            )
          : GoalItemWidget(
              path: GoalPath(['parent']),
              renderedPath: GoalPath(['parent', 'child']),
              hasRenderableChildren: false,
              hoverActionsBuilder: (_) => const SizedBox(),
            );
      await _mount(tester, client, widget);
      expect(find.text('Delayed child title'), findsNothing);
      expect(f.store.childLoads, greaterThan(0));
      f.store.childGate!.complete();
      f.store.childGate = null;
      await _frames(tester);

      // Independent observation: the actual goal watch has completed loading.
      expect(watch.currentValue['child']?.text, 'Delayed child title');
      final rowCount = find.byWidgetPredicate((w) => w is GoalItemWidget && w.path.goalId == 'child').evaluate().length;
      final before = find.text('Delayed child title').evaluate().length;
      final stateHasChild = client.stateSubject.value.containsKey('child');
      print('UI_TRACE surface=$surface watchHasChild=true stateHasChild=$stateHasChild childRows=$rowCount visibleBeforeEdit=$before');

      // Reproduce Matt's recovery step using an unrelated goal-note edit.
      await client.modifyGoal(GoalDelta(id: 'parent', logEntry: NoteLogEntry(
        id: 'note', text: 'Unrelated note', creationTime: DateTime.utc(2026, 10, 21),
      )));
      await _frames(tester);
      final after = find.text('Delayed child title').evaluate().length;
      print('UI_TRACE surface=$surface visibleAfterUnrelatedNote=$after');
      expect(after, 1, reason: 'control: unrelated note causes the title to appear');

      // Tear down animations before reporting the no-edit invariant.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(before, 1, reason: 'the loaded title must render before any note edit');
    });
  }
}
