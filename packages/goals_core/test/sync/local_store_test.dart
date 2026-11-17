import 'package:goals_core/model.dart' show Goal;
import 'package:test/test.dart';
import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';

void main() {
  group('MemoryLocalStore', () {
    test('storeSyncedOps indexes simple DeltaOp', () async {
      final store = MemoryLocalStore();
      final op = DeltaOp(
        id: 'op1',
        hlcTimestamp: HLC.now('client1').pack(),
        delta: GoalDelta(id: 'goal1', text: 'Goal 1'),
      );

      await store.storeSyncedOps([op]);

      final indexedOps = await store.loadOpsForGoal('goal1');
      expect(indexedOps.length, 1);
      expect(indexedOps.first.id, 'op1');
    });

    test('storeSyncedOps indexes AddParentLogEntry for child and parent',
        () async {
      final store = MemoryLocalStore();
      final op = DeltaOp(
        id: 'op2',
        hlcTimestamp: HLC.now('client1').increment().pack(),
        delta: GoalDelta(
          id: 'child1',
          logEntry: AddParentLogEntry(
            id: 'entry1',
            creationTime: DateTime.now(),
            parentId: 'parent1',
          ),
        ),
      );

      await store.storeSyncedOps([op]);

      final childOps = await store.loadOpsForGoal('child1');
      expect(childOps.length, 1);
      expect(childOps.first.id, 'op2');

      final parentOps = await store.loadOpsForGoal('parent1');
      expect(parentOps.length, 1);
      expect(parentOps.first.id, 'op2');
    });

    test('getIndexedOpsForGoal retrieves multiple ops', () async {
      final store = MemoryLocalStore();
      final hlc1 = HLC.now('client1');
      const parentId = 'parent2';
      const goalId = 'goal2';
      final op0 = DeltaOp(
        id: 'op1',
        hlcTimestamp: hlc1.pack(),
        delta: GoalDelta(id: parentId, text: 'Parent Goal'),
      );
      final hlc2 = hlc1.increment();
      final op1 = DeltaOp(
        id: 'op3',
        hlcTimestamp: hlc2.pack(),
        delta: GoalDelta(id: goalId, text: 'Goal 2'),
      );
      final hlc3 = hlc2.increment();
      final parentLogEntry = AddParentLogEntry(
        id: 'entry2',
        creationTime: DateTime.now(),
        parentId: parentId,
      );
      final op2 = DeltaOp(
        id: 'op4',
        hlcTimestamp: hlc3.pack(),
        delta: GoalDelta(
          id: goalId,
          logEntry: parentLogEntry,
        ),
      );

      final goal2 =
          Goal(id: goalId, text: 'Goal 2', creationTime: DateTime(2020, 3, 12));

      final parent = Goal(
          id: parentId,
          text: 'Parent Goal',
          creationTime: DateTime(2020, 3, 12));

      goal2.addSuperGoal(parentId, parentLogEntry);
      goal2.prependEntry(parentLogEntry);

      parent.addSubGoal(goalId, parentLogEntry);

      await store.storeSyncedOps([op0, op1, op2]);

      final goalOps = await store.loadOpsForGoal(goalId);
      expect(goalOps.length, 2);
      // Check if both ops are present (order might not be guaranteed by getIndexedOpsForGoal)
      expect(goalOps.any((op) => op.id == 'op3'), isTrue);
      expect(goalOps.any((op) => op.id == 'op4'), isTrue);

      final parentOps = await store.loadOpsForGoal(parentId);
      expect(parentOps.length, 2);
      expect(parentOps.first.id, 'op1');
    });

    test('getIndexedOpsForGoal returns empty for non-existent goal', () async {
      final store = MemoryLocalStore();
      final indexedOps = await store.loadOpsForGoal('nonexistent_goal');
      expect(indexedOps, isEmpty);
    });
    test('evictCachedOps evicts ops older than before', () async {
      final store = MemoryLocalStore();
      final hlc1 = HLC.now('client1');
      final hlc2 = hlc1.increment();
      final hlc3 = hlc2.increment();

      final op1 = DeltaOp(
        id: 'op1',
        hlcTimestamp: hlc1.pack(),
        delta: GoalDelta(id: 'goal1', text: 'Goal 1'),
      );
      final op2 = DeltaOp(
        id: 'op2',
        hlcTimestamp: hlc2.pack(),
        delta: GoalDelta(id: 'goal1', text: 'Goal 1 Updated'),
      );
      final op3 = DeltaOp(
        id: 'op3',
        hlcTimestamp: hlc3.pack(),
        delta: GoalDelta(id: 'goal1', text: 'Goal 1 Updated Again'),
      );

      await store.storeSyncedOps([op1, op2, op3]);

      expect(store.opCache.length, 3);

      store.evictCachedOps(before: hlc2.pack());

      expect(store.opCache.length, 2);
      expect(store.opCache.containsKey('op1'), isFalse);
      expect(store.opCache.containsKey('op2'), isTrue);
      expect(store.opCache.containsKey('op3'), isTrue);
    });

    test(
        'loadOpsForGoal prunes dangling opId references from goalOpsIndex and returns remaining valid ops',
        () async {
      final repo = MemorySyncRepository()..clientId = 'SVB5';
      final store = CachingLocalStore(repo: repo);
      final op1 = DeltaOp(
        id: 'op_1',
        hlcTimestamp: '001794930562329:00001:SVB5',
        delta: GoalDelta(
          id: 'goal_1',
          text: 'Goal One',
        ),
      );
      final op2 = DeltaOp(
        id: 'op_2',
        hlcTimestamp: '001794930562330:00001:SVB5',
        delta: GoalDelta(
          id: 'goal_1',
          logEntry: NoteLogEntry(
            id: 'note_1',
            creationTime: DateTime.utc(2026, 11, 17),
            text: 'Valid note',
          ),
        ),
      );
      await store.storeSyncedOps([op1, op2]);
      await store.settled();

      // Simulate an incomplete-batch dangling opId left in goalOpsIndex.
      await repo.storeGoalIndexEntry('goal_1', {
        'opIds': ['op_1', 'op_missing_dangling', 'op_2'],
      });
      await repo.storeGoalIndexEntry('goal_only_missing', {
        'opIds': ['op_never_written'],
      });
      store.clearCaches();

      final loaded = (await store.loadOpsForGoal('goal_1')).toList();
      expect(loaded.map((op) => op.id), ['op_1', 'op_2']);
      final cleanedEntry = await repo.loadGoalIndexEntry('goal_1');
      expect(cleanedEntry?['opIds'], ['op_1', 'op_2']);

      // Second read hits the pruned index cleanly (even from a fresh store).
      final reopened = CachingLocalStore(repo: repo);
      expect(
        (await reopened.loadOpsForGoal('goal_1')).map((op) => op.id),
        ['op_1', 'op_2'],
      );

      // All-missing goal returns [] and prunes opIds to [].
      expect(await reopened.loadOpsForGoal('goal_only_missing'), isEmpty);
      expect(
        (await repo.loadGoalIndexEntry('goal_only_missing'))?['opIds'],
        isEmpty,
      );
    });
  });
}
