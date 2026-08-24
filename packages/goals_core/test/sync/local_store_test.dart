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
  });
}
