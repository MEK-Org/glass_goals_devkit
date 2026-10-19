import 'dart:async';

import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';
import 'package:test/test.dart';

/// A child's AddParent op also belongs to its parent, so loading the parent
/// first records every op the child needs. Loading the child afterwards adds
/// no new op ids, but it still puts the child in the resident set. These
/// tests pin down that every read path sees it once it is fully loaded.
/// See https://github.com/MEK-Org/glass_goals_devkit/issues/19.
Future<SyncClient> _coldClientWithParentAndChild() async {
  final store = MemoryLocalStore();
  final t0 = HLC.now('producer');
  final t1 = t0.increment();
  await store.storeSyncedOps([
    DeltaOp(
      id: 'op-parent',
      hlcTimestamp: t0.pack(),
      delta: GoalDelta(id: 'parent', text: 'Parent'),
    ),
    DeltaOp(
      id: 'op-child',
      hlcTimestamp: t1.pack(),
      delta: GoalDelta(
        id: 'child',
        text: 'Child',
        logEntry: AddParentLogEntry(
          id: 'add-parent',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'parent',
        ),
      ),
    ),
  ]);
  store.cursor = t1.pack();

  final client = SyncClient(localStore: store);
  await client.init();
  await client.loadGoal('parent');
  return client;
}

/// A cold client over goals that are not roots, so none load during init.
Future<SyncClient> _coldClientWithNonRootGoals(
  Iterable<String> ids, {
  int residentSoftCap = 2000,
}) async {
  final store = MemoryLocalStore();
  var hlc = HLC.now('producer');
  final ops = <Op>[];
  for (final id in ids) {
    ops.add(DeltaOp(
      id: 'op-$id',
      hlcTimestamp: hlc.pack(),
      delta: GoalDelta(
        id: id,
        text: '$id text',
        logEntry: AddParentLogEntry(
          id: 'add-parent-$id',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'unloaded-parent-$id',
        ),
      ),
    ));
    hlc = hlc.increment();
  }
  await store.storeSyncedOps(ops);
  store.cursor = ops.last.hlcTimestamp;

  final client =
      SyncClient(localStore: store, residentSoftCap: residentSoftCap);
  await client.init();
  return client;
}

Future<({int states, int cursors})> _countEmissions(
  SyncClient client,
  Future<void> Function() body,
) async {
  var states = 0;
  var cursors = 0;
  final stateSub = client.stateSubject.skip(1).listen((_) => states++);
  final cursorSub = client.syncSubject.skip(1).listen((_) => cursors++);
  await body();
  await Future<void>.delayed(Duration.zero);
  await stateSub.cancel();
  await cursorSub.cancel();
  return (states: states, cursors: cursors);
}

void main() {
  group('reads of a goal loaded without new op ids', () {
    test('loadGoal cache hit returns the goal a watch loaded', () async {
      final client = await _coldClientWithParentAndChild();

      final watch = client.watchGoals(['parent', 'child']);
      await watch.stream
          .firstWhere((goals) => goals['child'] != null)
          .timeout(const Duration(seconds: 1));
      final watched = watch.currentValue['child'];
      expect(watched?.text, equals('Child'));

      final cached = await client.loadGoal('child');
      expect(cached, isNotNull);
      expect(cached, same(watched));
      expect(client.stateSubject.value['child'], same(watched));

      await watch.dispose();
      client.dispose();
    });

    test('loadGoal returns the same goal on a later cache hit', () async {
      final client = await _coldClientWithParentAndChild();

      final loaded = await client.loadGoal('child');
      expect(loaded?.text, equals('Child'));
      expect(loaded?.superGoalIds, contains('parent'));

      expect(await client.loadGoal('child'), same(loaded));

      client.dispose();
    });

    test('GoalRef.goal reads the loaded goal', () async {
      final client = await _coldClientWithParentAndChild();

      final ref = await client.loadGoalRef('child');
      expect(ref.goal?.text, equals('Child'));

      await ref.dispose();
      client.dispose();
    });

    test('loading it does not emit a new sync cursor', () async {
      final client = await _coldClientWithParentAndChild();
      final cursors = <String?>[];
      final sub = client.syncSubject.skip(1).listen(cursors.add);

      await client.loadGoal('child');
      await Future<void>.delayed(Duration.zero);

      expect(cursors, isEmpty);
      await sub.cancel();
      client.dispose();
    });

    test('loadGoal cache hit returns a reloaded evicted goal', () async {
      final ids = ['g0', 'g1', 'g2', 'g3'];
      final client = await _coldClientWithNonRootGoals(ids, residentSoftCap: 2);
      for (final id in ids) {
        await client.loadGoal(id);
      }
      expect(client.numResidentGoals, lessThanOrEqualTo(2),
          reason: 'precondition: g0 was evicted');

      final reloaded = await client.loadGoal('g0');
      expect(reloaded?.text, equals('g0 text'));
      expect(await client.loadGoal('g0'), same(reloaded));

      client.dispose();
    });

    test('concurrent loads of one goal emit state once', () async {
      final client = await _coldClientWithNonRootGoals(['g0', 'g1']);

      final emissions = await _countEmissions(
        client,
        () => Future.wait([
          client.loadGoal('g0'),
          client.loadGoal('g0'),
          client.loadGoal('g0'),
        ]),
      );

      expect(emissions.states, equals(1));
      expect(emissions.cursors, equals(0));
      expect(await client.loadGoal('g0'), isNotNull);
      client.dispose();
    });

    test('a local edit still emits state once', () async {
      final client = await _coldClientWithNonRootGoals(['g0']);
      await client.loadGoal('g0');
      final watch = client.watchGoals(['g0']);

      final emissions = await _countEmissions(
        client,
        () => client.modifyGoal(GoalDelta(id: 'g0', text: 'edited')),
      );

      expect(emissions.states, equals(1));
      expect(emissions.cursors, equals(1));
      expect(client.stateSubject.value['g0']?.text, equals('edited'));
      await watch.dispose();
      client.dispose();
    });
  });
}
