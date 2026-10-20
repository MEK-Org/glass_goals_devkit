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
}
