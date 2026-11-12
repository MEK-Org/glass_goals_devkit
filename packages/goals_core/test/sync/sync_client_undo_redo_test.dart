// Regressions for glass_goals_devkit#38: an op restored by an EnableOp must
// keep its own id, so a later DisableOp of that op (the next undo) finds it.
// The TypeScript suite (goals-core/src/sync-client.undo-redo.test.ts) covers
// the same cases against the TypeScript SyncClient; the shared
// `reenabled_op_identity` parity scenario covers remote Enable/Disable order.
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

Future<SyncClient> _freshClient() async {
  final client = SyncClient();
  await client.init();
  return client;
}

String? _text(SyncClient client, String goalId) =>
    client.stateSubject.value[goalId]?.text;

List<String?> _notes(SyncClient client, String goalId) => [
      for (final entry
          in client.stateSubject.value[goalId]?.log ?? const <GoalLogEntry>[])
        if (entry is NoteLogEntry) entry.text
    ];

void main() {
  group('SyncClient undo/redo keeps op identity (#38)', () {
    test('undo after redo restores the earlier value', () async {
      final client = await _freshClient();
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Original'));
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Changed'));

      await client.undo();
      expect(_text(client, 'g'), 'Original');
      await client.redo();
      expect(_text(client, 'g'), 'Changed');
      await client.undo();
      expect(_text(client, 'g'), 'Original');
    });

    test('survives repeated undo/redo cycles', () async {
      final client = await _freshClient();
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Original'));
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Changed'));

      for (var cycle = 0; cycle < 4; cycle++) {
        await client.undo();
        expect(_text(client, 'g'), 'Original', reason: 'undo, cycle $cycle');
        await client.redo();
        expect(_text(client, 'g'), 'Changed', reason: 'redo, cycle $cycle');
      }

      // Unwind past the creation, then rewind both actions.
      await client.undo();
      expect(_text(client, 'g'), 'Original');
      await client.undo();
      expect(client.stateSubject.value.containsKey('g'), isFalse);
      await client.redo();
      expect(_text(client, 'g'), 'Original');
      await client.redo();
      expect(_text(client, 'g'), 'Changed');
      await client.undo();
      expect(_text(client, 'g'), 'Original');
    });

    test('unwinds and rewinds interleaved edits to several goals', () async {
      final client = await _freshClient();
      await client.modifyGoal(GoalDelta(id: 'a', text: 'a1'));
      await client.modifyGoal(GoalDelta(id: 'b', text: 'b1'));
      await client.modifyGoal(GoalDelta(id: 'a', text: 'a2'));
      await client.modifyGoals([
        GoalDelta(id: 'a', text: 'a3'),
        GoalDelta(id: 'b', text: 'b2'),
      ]);

      List<String?> state() => [_text(client, 'a'), _text(client, 'b')];
      const history = [
        ['a1', null],
        ['a1', 'b1'],
        ['a2', 'b1'],
        ['a3', 'b2'],
      ];
      expect(state(), history[3]);

      // Two full unwind/rewind passes: the second only works when every
      // re-enabled op is still addressable by its own id.
      for (var pass = 0; pass < 2; pass++) {
        for (var i = 2; i >= 0; i--) {
          await client.undo();
          expect(state(), history[i], reason: 'pass $pass undo to $i');
        }
        await client.undo();
        expect(client.stateSubject.value.containsKey('a'), isFalse,
            reason: 'pass $pass all undone');
        for (var i = 0; i <= 3; i++) {
          await client.redo();
          expect(state(), history[i], reason: 'pass $pass redo to $i');
        }
      }

      // A partial zig-zag in the middle of the stack.
      await client.undo();
      await client.undo();
      expect(state(), history[1]);
      await client.redo();
      expect(state(), history[2]);
      await client.undo();
      expect(state(), history[1]);
      await client.redo();
      await client.redo();
      expect(state(), history[3]);
    });

    test('toggles a metadata log entry through repeated undo/redo', () async {
      final client = await _freshClient();
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Doc'));
      await client.modifyGoal(GoalDelta(
        id: 'g',
        logEntry: NoteLogEntry(
          id: 'note-1',
          creationTime: DateTime.utc(2026, 11, 12),
          text: 'a note',
        ),
      ));
      expect(_notes(client, 'g'), ['a note']);

      for (var cycle = 0; cycle < 3; cycle++) {
        await client.undo();
        expect(_notes(client, 'g'), isEmpty, reason: 'undo, cycle $cycle');
        await client.redo();
        expect(_notes(client, 'g'), ['a note'], reason: 'redo, cycle $cycle');
      }
      await client.undo();
      expect(_notes(client, 'g'), isEmpty);
      expect(_text(client, 'g'), 'Doc');
    });
  });

  group('undo/redo replays the same after a restart (#38)', () {
    Future<SyncClient> restarted(
        MemoryPersistenceService persistence, MemoryLocalStore store) async {
      await persistence.settled;
      final client =
          SyncClient(persistenceService: persistence, localStore: store);
      await client.init();
      await client.loadGoal('g');
      return client;
    }

    /// A fresh client that pulls the whole recorded history from a new
    /// server. The memory server keeps only its latest saved batch, so it is
    /// seeded from every op the first client stored.
    Future<SyncClient> replayedFromScratch(MemoryLocalStore store) async {
      final ops = (await store.getAllOps()).toList()
        ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
      final history = MemoryPersistenceService()..ops = ops;
      return restarted(history, MemoryLocalStore());
    }

    test('keeps undo after redo undone across a restart', () async {
      final persistence = MemoryPersistenceService();
      final store = MemoryLocalStore();
      final client =
          SyncClient(persistenceService: persistence, localStore: store);
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Original'));
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Changed'));
      await client.undo();
      await client.redo();
      await client.undo();
      expect(_text(client, 'g'), 'Original');
      await client.redo();
      await client.undo();
      expect(_text(client, 'g'), 'Original');
      await persistence.settled;
      client.dispose();

      final reopened = await restarted(persistence, store);
      expect(_text(reopened, 'g'), 'Original');
      reopened.dispose();

      final replayed = await replayedFromScratch(store);
      expect(_text(replayed, 'g'), 'Original');
      replayed.dispose();
    });

    test('keeps a redone value across a restart after repeated cycles',
        () async {
      final persistence = MemoryPersistenceService();
      final store = MemoryLocalStore();
      final client =
          SyncClient(persistenceService: persistence, localStore: store);
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Original'));
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Changed'));
      for (var cycle = 0; cycle < 3; cycle++) {
        await client.undo();
        await client.redo();
      }
      expect(_text(client, 'g'), 'Changed');
      await persistence.settled;
      client.dispose();

      final reopened = await restarted(persistence, store);
      expect(_text(reopened, 'g'), 'Changed');
      reopened.dispose();

      final replayed = await replayedFromScratch(store);
      expect(_text(replayed, 'g'), 'Changed');
      replayed.dispose();
    });
  });
}
