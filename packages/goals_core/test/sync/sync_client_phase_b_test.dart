import 'dart:async';

import 'package:goals_core/model.dart' show Goal;
import 'package:goals_core/sync.dart' show SyncClient;
import 'package:goals_types/goals_types.dart' show GoalDelta;
import 'package:test/test.dart'
    show
        equals,
        expect,
        group,
        isFalse,
        isNotNull,
        isNull,
        isTrue,
        test;

void main() {
  group('loadGoalRef / GoalRef', () {
    test('loads the goal and pins it', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      expect(client.numPinnedGoals, equals(0));

      final ref = await client.loadGoalRef('A');

      expect(ref.goal, isNotNull);
      expect(ref.goal!.text, equals('first'));
      expect(client.numPinnedGoals, equals(1));
    });

    test('multiple refs to the same id share the pin count', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      final ref1 = await client.loadGoalRef('A');
      final ref2 = await client.loadGoalRef('A');

      // Two refs => two pins on the same id => still one *unique* pinned id.
      expect(client.numPinnedGoals, equals(1));

      await ref1.dispose();
      // ref2 still pinning => still 1 unique pinned id.
      expect(client.numPinnedGoals, equals(1));

      await ref2.dispose();
      expect(client.numPinnedGoals, equals(0));
    });

    test('dispose is idempotent', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      final ref = await client.loadGoalRef('A');
      expect(client.numPinnedGoals, equals(1));

      await ref.dispose();
      expect(client.numPinnedGoals, equals(0));

      // Double dispose must not under-flow the pin count.
      await ref.dispose();
      expect(client.numPinnedGoals, equals(0));

      // And pinning a new ref still works correctly afterwards.
      final ref2 = await client.loadGoalRef('A');
      expect(client.numPinnedGoals, equals(1));
      await ref2.dispose();
    });

    test('goal is null for a never-loaded id', () async {
      final client = SyncClient();
      await client.init();

      final ref = await client.loadGoalRef('does-not-exist');
      expect(ref.goal, isNull);
      // We still pin it — the pin survives even for "missing" ids so that
      // an in-flight create op landing later attaches to a still-resident
      // slot.
      expect(client.numPinnedGoals, equals(1));
      await ref.dispose();
    });
  });

  group('watchGoals / WatchedGoalSet', () {
    test('emits the current value on first listen', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      final watch = client.watchGoals(['A']);
      final firstMap = await watch.stream
          .firstWhere((m) => m.containsKey('A'))
          .timeout(Duration(seconds: 1));
      expect(firstMap['A']!.text, equals('first'));

      await watch.dispose();
    });

    test('pins watched ids, unpins on dispose', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));
      await client.modifyGoal(GoalDelta(id: 'B', text: 'second'));

      final watch = client.watchGoals(['A', 'B']);
      expect(client.numPinnedGoals, equals(2));

      await watch.dispose();
      expect(client.numPinnedGoals, equals(0));
    });

    test('emits when an op modifies a watched goal', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      final watch = client.watchGoals(['A']);

      // Skip the seed emission, then collect subsequent emissions.
      final updates = <Goal?>[];
      final sub = watch.stream.skip(1).listen((m) => updates.add(m['A']));

      await client.modifyGoal(GoalDelta(id: 'A', text: 'second'));
      await Future.delayed(Duration(milliseconds: 10));

      await sub.cancel();
      await watch.dispose();

      expect(updates.isNotEmpty, isTrue,
          reason: 'modifying a watched goal should wake the watcher');
      expect(updates.last?.text, equals('second'));
    });

    test('does not emit when an op modifies only unwatched goals', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));
      await client.modifyGoal(GoalDelta(id: 'B', text: 'other'));

      final watch = client.watchGoals(['A']);

      // Drain the seed.
      await watch.stream.first.timeout(Duration(seconds: 1));

      var emittedAfterSeed = false;
      final sub = watch.stream.listen((_) => emittedAfterSeed = true);
      // Reset — `listen` may replay the BehaviorSubject's seed first.
      await Future.delayed(Duration.zero);
      emittedAfterSeed = false;

      // Mutating B (unwatched) should not wake the watcher.
      await client.modifyGoal(GoalDelta(id: 'B', text: 'other-updated'));
      await Future.delayed(Duration(milliseconds: 10));

      await sub.cancel();
      await watch.dispose();

      expect(emittedAfterSeed, isFalse,
          reason:
              'a watcher for A should not wake on ops that only touch B');
    });

    test('multiple watchers of the same id share the pin', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'first'));

      final w1 = client.watchGoals(['A']);
      final w2 = client.watchGoals(['A']);
      expect(client.numPinnedGoals, equals(1));

      await w1.dispose();
      expect(client.numPinnedGoals, equals(1));

      await w2.dispose();
      expect(client.numPinnedGoals, equals(0));
    });

    test('add/remove/setIds adjust pins idempotently', () async {
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'a'));
      await client.modifyGoal(GoalDelta(id: 'B', text: 'b'));
      await client.modifyGoal(GoalDelta(id: 'C', text: 'c'));

      final watch = client.watchGoals(['A']);
      expect(watch.watchedIds, equals({'A'}));
      expect(client.numPinnedGoals, equals(1));

      watch.add('B');
      expect(watch.watchedIds, equals({'A', 'B'}));
      expect(client.numPinnedGoals, equals(2));

      // Re-adding an existing id is a no-op.
      watch.add('B');
      expect(client.numPinnedGoals, equals(2));

      watch.remove('A');
      expect(watch.watchedIds, equals({'B'}));
      expect(client.numPinnedGoals, equals(1));

      // Removing an absent id is a no-op.
      watch.remove('A');
      expect(client.numPinnedGoals, equals(1));

      watch.setIds({'B', 'C'});
      expect(watch.watchedIds, equals({'B', 'C'}));
      expect(client.numPinnedGoals, equals(2));

      await watch.dispose();
      expect(client.numPinnedGoals, equals(0));
    });

    test('undo wakes only the watcher whose goal was affected', () async {
      // The sync best-effort path for EnableOp/DisableOp must resolve the
      // referenced op from in-memory state — otherwise the pre-await emit
      // would miss the affected goal and the watcher wouldn't wake until
      // the post-load second emit.
      final client = SyncClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'A', text: 'a'));
      await client.modifyGoal(GoalDelta(id: 'B', text: 'b'));

      final watchA = client.watchGoals(['A']);
      final watchB = client.watchGoals(['B']);

      // Drain seeds.
      await watchA.stream.firstWhere((m) => m.containsKey('A'));
      await watchB.stream.firstWhere((m) => m.containsKey('B'));

      var aWoke = false;
      var bWoke = false;
      final subA = watchA.stream.listen((_) => aWoke = true);
      final subB = watchB.stream.listen((_) => bWoke = true);
      await Future.delayed(Duration.zero);
      aWoke = false;
      bWoke = false;

      // Undo the last modification (B). Watcher for B should wake; A should not.
      await client.undo();
      await Future.delayed(Duration(milliseconds: 10));

      await subA.cancel();
      await subB.cancel();
      await watchA.dispose();
      await watchB.dispose();

      expect(bWoke, isTrue, reason: 'undo of B should wake its watcher');
      expect(aWoke, isFalse,
          reason: 'undo of B should not wake an unrelated watcher of A');
    });

    test('cold subscribe: subject wakes once the goal loads', () async {
      final client = SyncClient();
      await client.init();

      // No goal exists yet — watcher subscribes first.
      final watch = client.watchGoals(['A']);

      // Now create the goal. The watcher should observe a non-null entry.
      await client.modifyGoal(GoalDelta(id: 'A', text: 'arrived'));

      final loaded = await watch.stream
          .firstWhere((m) => m['A']?.text == 'arrived')
          .timeout(Duration(seconds: 1));
      expect(loaded['A']!.text, equals('arrived'));

      await watch.dispose();
    });
  });
}
