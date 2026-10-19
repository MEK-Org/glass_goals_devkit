import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';
import 'package:test/test.dart';

void main() {
  test('SetParent is indexed for the former parent', () async {
    final store = MemoryLocalStore();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    await store.storeSyncedOps([adopt]);
    await store.storeSyncedOps([move]);

    final sourceOps = await store.loadOpsForGoal('source');
    expect(
      sourceOps.map((op) => op.id),
      contains('move'),
      reason: 'a cold source reload needs the later SetParent detach',
    );
    expect(
      (await store.loadOpsForGoal('destination')).map((op) => op.id),
      contains('move'),
    );
    expect(
      (await store.loadOpsForGoal('footnote')).map((op) => op.id),
      contains('move'),
    );

    final undoMove = DisableOp(
      id: 'undo-move',
      hlcTimestamp: clock.increment().increment().pack(),
      opId: move.id,
    );
    await store.storeSyncedOps([undoMove]);
    expect(
      (await store.loadOpsForGoal('source')).map((op) => op.id),
      contains('undo-move'),
      reason: 'Undo must also reach the former parent on a cold reload',
    );
  });

  test('SetParent in same batch with AddParent is indexed for former parent',
      () async {
    final store = MemoryLocalStore();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    // Same batch with move arriving before adopt in the list
    await store.storeSyncedOps([move, adopt]);

    final sourceOps = await store.loadOpsForGoal('source');
    expect(
      sourceOps.map((op) => op.id),
      contains('move'),
      reason: 'same-batch SetParent must be indexed for former parent',
    );
  });

  test('SetParent arrival before AddParent is indexed for former parent',
      () async {
    final store = MemoryLocalStore();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    // Arrive in reverse order (move first, then adopt)
    await store.storeSyncedOps([move]);
    await store.storeSyncedOps([adopt]);

    final sourceOps = await store.loadOpsForGoal('source');
    expect(
      sourceOps.map((op) => op.id),
      contains('move'),
      reason: 'former parent must receive move even if adopt arrives later',
    );
  });

  test('SetParent with null parentId is indexed for former parent', () async {
    final store = MemoryLocalStore();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final clear = DeltaOp(
      id: 'clear',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'clear-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: null,
        ),
      ),
    );

    await store.storeSyncedOps([adopt]);
    await store.storeSyncedOps([clear]);

    final sourceOps = await store.loadOpsForGoal('source');
    expect(
      sourceOps.map((op) => op.id),
      contains('clear'),
      reason: 'clearing parent must reach former parent index',
    );
  });

  test(
      'reopening legacy store repairs former parent index without wiping sync data',
      () async {
    final repo = MemorySyncRepository();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    final undoMove = DisableOp(
      id: 'undo-move',
      hlcTimestamp: clock.increment().increment().pack(),
      opId: move.id,
    );

    // Legacy store state:
    await repo.storeSyncedOps([adopt, move, undoMove]);
    // Simulate a store that already ran the original repair, which wrote the
    // pending move into the durable former-parent index and marked itself v1.
    await repo.storeGoalIndexEntry('source', {
      'opIds': ['adopt', 'move']
    });
    await repo.storeGoalIndexEntry('destination', {
      'opIds': ['move', 'undo-move']
    });
    await repo.storeGoalIndexEntry('footnote', {
      'opIds': ['adopt', 'move', 'undo-move']
    });
    await repo.setUnsyncedOps([adopt]);
    await repo.setAckedOpIds(['adopt']);

    final newStore = CachingLocalStore(repo: repo);
    await newStore.init();

    final sourceOps = await newStore.loadOpsForGoal('source');
    expect(
      sourceOps.map((op) => op.id),
      containsAll(['move', 'undo-move']),
      reason: 'reopened legacy store must index move and undo for source',
    );
    // Unsynced and acked ops must be preserved
    expect(newStore.getUnsyncedOps().map((o) => o.id), contains('adopt'));
    expect(newStore.getAckedOpIds(), contains('adopt'));
  });

  test('legacy repair keeps a pending SetParent out of durable indexes',
      () async {
    final repo = MemorySyncRepository();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    await repo.storeSyncedOps([adopt]);
    await repo.storeGoalIndexEntry('source', {
      'opIds': ['adopt']
    });
    await repo.storeGoalIndexEntry('footnote', {
      'opIds': ['adopt']
    });
    await repo.storeGoalIndexEntry('destination', {
      'opIds': ['move']
    });
    await repo.setUnsyncedOps([move]);
    await repo.setAckedOpIds(['move']);
    repo.cursor = move.hlcTimestamp;
    await repo.storeString('setParentIndexRepairVersion', '1');

    final store = CachingLocalStore(repo: repo);
    await store.init();

    expect(
      (await store.loadOpsForGoal('source')).map((op) => op.id),
      ['adopt'],
      reason: 'the durable index may not reference the pending move',
    );
    expect(store.getUnsyncedOps().map((op) => op.id), ['move']);
    expect(store.getAckedOpIds(), {'move'});
    expect(store.cursor, move.hlcTimestamp);
  });

  test('legacy repair keeps a pending Undo out of durable indexes', () async {
    final repo = MemorySyncRepository();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );
    final undo = DisableOp(
      id: 'undo',
      hlcTimestamp: clock.increment().increment().pack(),
      opId: 'move',
    );

    await repo.storeSyncedOps([adopt, move]);
    // Simulate the v1 repair having also written an accepted-but-not-echoed
    // undo into durable indexes.
    await repo.storeGoalIndexEntry('source', {
      'opIds': ['adopt', 'move', 'undo']
    });
    await repo.storeGoalIndexEntry('footnote', {
      'opIds': ['adopt', 'move', 'undo']
    });
    await repo.storeGoalIndexEntry('destination', {
      'opIds': ['move', 'undo']
    });
    await repo.setUnsyncedOps([undo]);
    await repo.setAckedOpIds(['undo']);
    repo.cursor = undo.hlcTimestamp;
    await repo.storeString('setParentIndexRepairVersion', '1');

    final store = CachingLocalStore(repo: repo);
    await store.init();

    final sourceOpIds =
        (await store.loadOpsForGoal('source')).map((op) => op.id).toSet();
    expect(sourceOpIds, containsAll(['adopt', 'move']));
    expect(sourceOpIds, isNot(contains('undo')),
        reason: 'the pending Undo remains on the pending overlay');
    expect(store.getUnsyncedOps().map((op) => op.id), ['undo']);
    expect(store.getAckedOpIds(), {'undo'});
    expect(store.cursor, undo.hlcTimestamp);
  });

  test('legacy repair cleans a v1-polluted index with only a pending SetParent',
      () async {
    final repo = MemorySyncRepository();
    final clock = HLC.now('client1');
    final adopt = DeltaOp(
      id: 'adopt',
      hlcTimestamp: clock.pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: AddParentLogEntry(
          id: 'adopt-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'source',
        ),
      ),
    );
    final move = DeltaOp(
      id: 'move',
      hlcTimestamp: clock.increment().pack(),
      delta: GoalDelta(
        id: 'footnote',
        logEntry: SetParentLogEntry(
          id: 'move-entry',
          creationTime: DateTime(2026, 10, 19),
          parentId: 'destination',
        ),
      ),
    );

    // No synced SetParent exists, but repair v1 already wrote the pending
    // move into the source index.
    await repo.storeSyncedOps([adopt]);
    await repo.storeGoalIndexEntry('source', {
      'opIds': ['adopt', 'move']
    });
    await repo.storeGoalIndexEntry('footnote', {
      'opIds': ['adopt', 'move']
    });
    await repo.storeGoalIndexEntry('destination', {
      'opIds': ['move']
    });
    await repo.setUnsyncedOps([move]);
    await repo.setAckedOpIds(['move']);
    repo.cursor = move.hlcTimestamp;
    await repo.storeString('setParentIndexRepairVersion', '1');

    final store = CachingLocalStore(repo: repo);
    await store.init();

    expect(
      (await store.loadOpsForGoal('source')).map((op) => op.id),
      ['adopt'],
      reason: 'the polluted durable index may not keep the pending move',
    );
    expect(await repo.loadString('setParentIndexRepairVersion'), '2',
        reason: 'the repair completes instead of rescanning every init');
    expect(store.getUnsyncedOps().map((op) => op.id), ['move']);
    expect(store.getAckedOpIds(), {'move'});
    expect(store.cursor, move.hlcTimestamp);
  });
}
