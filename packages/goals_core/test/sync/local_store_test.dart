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
        'resetSyncedCache clears synced cache and cursor while preserving unsyncedOps, ackedOpIds, clientId, fullSyncCount, and unsynced strings',
        () async {
      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..version = 2;
      final store = CachingLocalStore(repo: repo);
      final syncedOp = DeltaOp(
        id: 'op_synced',
        hlcTimestamp: '001794930562329:00001:SVB5',
        delta: GoalDelta(
          id: 'goal_synced',
          text: 'Synced Goal',
          logEntry: NoteLogEntry(
            id: 'note_synced',
            creationTime: DateTime.utc(2026, 11, 17),
            text: 'Synced note',
          ),
        ),
      );
      await store.storeSyncedOps([syncedOp]);
      await store.settled();
      store.setIndexGoalIds('rootGoals', {'goal_synced'});
      await store.setSearchIndex('goalNamesIndex', '{"synced goal":"goal_synced"}');
      store.lastSyncTime = DateTime.utc(2026, 11, 17);
      store.incrementFullSyncCount();

      final unsyncedOp = DeltaOp(
        id: 'op_unsynced',
        hlcTimestamp: '001794930990000:00001:SVB5',
        delta: GoalDelta(
          id: 'goal_unsynced',
          logEntry: NoteLogEntry(
            id: 'note_unsynced',
            creationTime: DateTime.utc(2026, 11, 17),
            text: 'Unsynced note',
          ),
        ),
      );
      await store.setUnsyncedOps([unsyncedOp]);
      await store.setAckedOpIds(['op_unsynced']);

      await store.resetSyncedCache();

      expect(store.cursor, isNull);
      expect(store.lastSyncTime, isNull);
      expect(await store.loadOpsForGoal('goal_synced'), isEmpty);
      expect(await repo.loadOps(['op_synced']), [isNull]);
      expect(await store.loadString('note_synced'), isNull);
      expect(store.getIndexGoalIds('rootGoals'), isEmpty);
      expect(await store.loadSearchIndex('goalNamesIndex'), isNull);

      expect(store.clientId, 'SVB5');
      expect(repo.version, 2);
      expect(store.fullSyncCount, 1);
      expect(store.getUnsyncedOps().map((op) => op.id), ['op_unsynced']);
      expect(store.getAckedOpIds(), {'op_unsynced'});
      expect(await store.loadString('note_unsynced'), 'Unsynced note');
    });
  });
}
