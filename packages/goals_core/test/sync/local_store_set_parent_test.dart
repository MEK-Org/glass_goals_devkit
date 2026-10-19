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
}
