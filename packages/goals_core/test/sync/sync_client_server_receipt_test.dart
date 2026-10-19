import 'dart:async';

import 'package:collection/collection.dart';
import 'package:goals_core/src/sync/persistence_service.dart'
    show LoadOpsResp, PersistenceService;
import 'package:goals_core/src/sync/sync_logger.dart' show SyncEventLogger;
import 'package:goals_core/sync.dart' show SyncClient, MemoryLocalStore, Op;
import 'package:goals_types/goals_types.dart'
    show GoalDelta, GoalStatus, NoteLogEntry, StatusLogEntry;
import 'package:test/test.dart';

/// A server whose REST commits succeed immediately but whose listener echo
/// (and, optionally, read visibility) is delayed until the test releases it.
class DelayedEchoServer implements PersistenceService {
  final committed = <Op>[];
  final strings = <String, String>{};
  final saveCounts = <String, int>{};
  final _pendingEchoes = <Op>[];
  final _controller = StreamController<(Iterable<Op>, String)>.broadcast();

  /// When true, committed ops are not returned by [load] (stale/cached read).
  bool readsLag = false;
  int failSaves = 0;

  @override
  Future<void> save(Iterable<Op> ops) async {
    await Future<void>.delayed(Duration.zero);
    if (failSaves > 0) {
      failSaves--;
      throw StateError('simulated REST failure');
    }
    for (final op in ops) {
      saveCounts[op.id] = (saveCounts[op.id] ?? 0) + 1;
      final text = Op.extractEntryTextField(op.toJsonMap());
      if (text != null) strings[text.$1] = text.$2;
      committed.add(op);
      _pendingEchoes.add(op);
    }
  }

  /// Delivers held listener events. [reversed] delivers newest first,
  /// [duplicate] delivers each event twice, and [only] keeps the rest held.
  Future<void> releaseEchoes(
      {bool reversed = false,
      bool duplicate = false,
      bool Function(Op op)? only}) async {
    final echoes = [..._pendingEchoes.where(only ?? (_) => true)];
    _pendingEchoes.removeWhere((op) => echoes.contains(op));
    for (final op in reversed ? echoes.reversed : echoes) {
      for (var i = 0; i < (duplicate ? 2 : 1); i++) {
        _controller.add(([op], op.hlcTimestamp));
        await _drain();
      }
    }
  }

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    final visible = readsLag ? <Op>[] : committed;
    final ops = visible
        .where((op) => cursor == null || op.hlcTimestamp.compareTo(cursor) > 0)
        .sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp))
        .take(limit ?? 1 << 30)
        .toList();
    return LoadOpsResp(
        ops: ops, cursor: ops.isEmpty ? cursor : ops.last.hlcTimestamp);
  }

  @override
  Future<String?> loadString(String entryId) async => strings[entryId];

  @override
  Future<int> count({String? cursor}) async => committed.length;

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _controller.stream;
}

/// Counts the receipt acknowledgements SyncClient logs per op.
class AcknowledgementLogger implements SyncEventLogger {
  final acknowledged = <String, int>{};

  @override
  void log(String message, {String? opId, String? goalId}) {
    if (opId != null && message == 'Op received from remote, acknowledged') {
      acknowledged[opId] = (acknowledged[opId] ?? 0) + 1;
    }
  }
}

Future<void> _drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GoalDelta _activeToday(String goalId) => GoalDelta(
      id: goalId,
      logEntry: StatusLogEntry(
        id: 'status-$goalId',
        creationTime: DateTime.now(),
        status: GoalStatus.active,
      ),
    );

/// The change is represented by every read path a view uses.
void _expectRepresented(SyncClient client, String goalId, String text,
    {required String phase}) {
  expect(client.stateSubject.value[goalId]?.text, equals(text),
      reason: '$phase: working state');
  expect(client.getRootGoalIds(), contains(goalId),
      reason: '$phase: root goal index');
  expect(client.getStatusGoalIds(), contains(goalId),
      reason: '$phase: status goal index');
}

void main() {
  test(
      'successful push keeps the op pending and visible until the server echo '
      'acknowledges it once', () async {
    final server = DelayedEchoServer();
    final store = MemoryLocalStore();
    final logger = AcknowledgementLogger();
    final client = SyncClient(
        persistenceService: server, localStore: store, logger: logger);
    await client.init();

    await client.modifyGoals([GoalDelta(id: 'g', text: 'Local edit')]);
    await client.modifyGoal(_activeToday('g'));
    await _drain();

    // REST succeeded, echo has not arrived.
    expect(server.committed.length, equals(2));
    expect(client.numUnsyncedOps, equals(2),
        reason: 'push success is not server receipt');
    _expectRepresented(client, 'g', 'Local edit', phase: 'after REST success');

    // Another edit pushes again; pushed ops acked by the server are not resent.
    await client.modifyGoal(GoalDelta(
        id: 'g',
        logEntry: NoteLogEntry(
            id: 'note-1', creationTime: DateTime.now(), text: 'a note')));
    await _drain();
    expect(server.saveCounts.values, everyElement(equals(1)),
        reason: 'no resend while acked');
    expect(server.saveCounts.length, equals(3));
    expect(client.numUnsyncedOps, equals(3));
    _expectRepresented(client, 'g', 'Local edit', phase: 'awaiting echo');

    // Out-of-order and duplicated echoes acknowledge each op exactly once.
    await server.releaseEchoes(reversed: true, duplicate: true);
    await _drain();
    expect(client.numUnsyncedOps, equals(0));
    _expectRepresented(client, 'g', 'Local edit', phase: 'after echo');
    final stored = (await store.getAllOps()).map((op) => op.id).toList();
    expect(stored.length, equals(3));
    expect(stored.toSet().length, equals(3));
    expect(logger.acknowledged.keys, unorderedEquals(stored));
    expect(logger.acknowledged.values, everyElement(equals(1)),
        reason: 'each op is acknowledged exactly once');

    // Later pushes have nothing to resend.
    await client.modifyGoal(GoalDelta(id: 'g', text: 'Second edit'));
    await _drain();
    expect(server.saveCounts.values.where((n) => n != 1), isEmpty);
    expect(client.stateSubject.value['g']?.text, equals('Second edit'));
    client.dispose();
  });

  test('cold restart before the echo keeps the change and does not resend it',
      () async {
    final server = DelayedEchoServer();
    final store = MemoryLocalStore();
    final client1 = SyncClient(persistenceService: server, localStore: store);
    await client1.init();
    await client1.modifyGoals([GoalDelta(id: 'g', text: 'Before reload')]);
    await client1.modifyGoal(_activeToday('g'));
    await _drain();
    expect(server.committed.length, equals(2));
    client1.dispose();

    // Reload while reads are served stale (e.g. offline cache).
    server.readsLag = true;
    final client2 = SyncClient(persistenceService: server, localStore: store);
    await client2.init();
    await _drain();
    for (final id in client2.getRootGoalIds()) {
      await client2.loadGoal(id);
    }
    expect(client2.numUnsyncedOps, equals(2));
    _expectRepresented(client2, 'g', 'Before reload', phase: 'after reload');
    expect(server.saveCounts.values, everyElement(equals(1)),
        reason: 'restart does not resend ops the server already accepted');

    // Authoritative receipt arrives through the listener.
    server.readsLag = false;
    await server.releaseEchoes();
    await _drain();
    expect(client2.numUnsyncedOps, equals(0));
    _expectRepresented(client2, 'g', 'Before reload', phase: 'after receipt');
    client2.dispose();
  });

  test('cold restart acknowledges pushed ops received by the initial pull',
      () async {
    final server = DelayedEchoServer();
    final store = MemoryLocalStore();
    final client1 = SyncClient(persistenceService: server, localStore: store);
    await client1.init();
    await client1.modifyGoal(GoalDelta(id: 'g', text: 'Pulled'));
    await _drain();
    client1.dispose();

    final client2 = SyncClient(persistenceService: server, localStore: store);
    await client2.init();
    await _drain();
    expect(client2.numUnsyncedOps, equals(0));
    expect(server.saveCounts.values, everyElement(equals(1)));
    expect(client2.stateSubject.value['g']?.text, equals('Pulled'));
    client2.dispose();
  });

  test(
      'cold restart after the cursor passed an unreceived op still receives '
      'it', () async {
    final server = DelayedEchoServer();
    final store = MemoryLocalStore();
    final author = SyncClient(persistenceService: server, localStore: store);
    await author.init();

    await author.modifyGoal(GoalDelta(id: 'mine', text: 'Pushed'));
    await _drain();
    final mine = server.committed.single;
    // Its initial pull orders the other client's clock after the pushed op.
    final other = SyncClient(
        persistenceService: server, localStore: MemoryLocalStore());
    await other.init();
    await other.modifyGoal(GoalDelta(id: 'theirs', text: 'Later'));
    await _drain();

    // The author hears the later op, but its own echo is lost.
    await server.releaseEchoes(only: (op) => op.id != mine.id);
    await _drain();
    expect(store.cursor!.compareTo(mine.hlcTimestamp), greaterThan(0));
    expect(author.numUnsyncedOps, equals(1));
    author.dispose();
    other.dispose();

    final restarted =
        SyncClient(persistenceService: server, localStore: store);
    await restarted.init();
    await _drain();
    expect(restarted.numUnsyncedOps, equals(0),
        reason: 'the pull resumes before the oldest acked op');
    expect(server.saveCounts[mine.id], equals(1));
    expect(restarted.stateSubject.value['mine']?.text, equals('Pushed'));
    expect(restarted.getRootGoalIds(), containsAll(['mine', 'theirs']));
    restarted.dispose();
  });

  test('failed push stays pending and retries; success then awaits receipt',
      () async {
    final server = DelayedEchoServer()..failSaves = 1;
    final client = SyncClient(
        persistenceService: server, localStore: MemoryLocalStore());
    await client.init();

    await client.modifyGoal(GoalDelta(id: 'g', text: 'Offline edit'));
    await _drain();
    expect(server.committed, isEmpty);
    expect(client.numUnsyncedOps, equals(1));
    expect(client.stateSubject.value['g']?.text, equals('Offline edit'));

    await client.sync();
    await _drain();
    expect(server.saveCounts.values.single, equals(1));
    expect(client.numUnsyncedOps, equals(1));
    expect(client.getRootGoalIds(), contains('g'));

    await client.sync();
    await _drain();
    expect(server.saveCounts.values.single, equals(1),
        reason: 'manual sync does not resend an accepted op');

    await server.releaseEchoes();
    await _drain();
    expect(client.numUnsyncedOps, equals(0));
    expect(client.getRootGoalIds(), contains('g'));
    client.dispose();
  });

  test('other clients converge while the author awaits its own echo',
      () async {
    final server = DelayedEchoServer();
    final a = SyncClient(
        persistenceService: server, localStore: MemoryLocalStore());
    final b = SyncClient(
        persistenceService: server, localStore: MemoryLocalStore());
    await a.init();
    await b.init();

    await a.modifyGoal(GoalDelta(id: 'g', text: 'from A'));
    await _drain();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    expect(a.stateSubject.value['g']?.text, equals('from A'));
    expect(a.getRootGoalIds(), contains('g'));

    await server.releaseEchoes();
    await _drain();
    await b.loadGoal('g');
    expect(b.stateSubject.value['g']?.text, equals('from A'));

    await b.modifyGoal(GoalDelta(id: 'g', text: 'from B'));
    await _drain();
    // A keeps its acknowledged state until B's op is received.
    expect(a.numUnsyncedOps, equals(0));
    expect(b.numUnsyncedOps, equals(1));
    expect(b.stateSubject.value['g']?.text, equals('from B'));
    expect(b.getRootGoalIds(), contains('g'));

    await server.releaseEchoes();
    await _drain();
    expect(a.stateSubject.value['g']?.text, equals('from B'));
    expect(b.stateSubject.value['g']?.text, equals('from B'));
    expect(b.numUnsyncedOps, equals(0));
    a.dispose();
    b.dispose();
  });

  test('undo and redo around server receipt keep op identity and order',
      () async {
    final server = DelayedEchoServer();
    final client = SyncClient(
        persistenceService: server, localStore: MemoryLocalStore());
    await client.init();

    await client.modifyGoal(GoalDelta(id: 'g', text: 'one'));
    await client.modifyGoal(GoalDelta(id: 'g', text: 'two'));
    await _drain();
    expect(client.stateSubject.value['g']?.text, equals('two'));

    // Undo targets an op the server accepted but has not sent back.
    await client.undo();
    await _drain();
    expect(client.stateSubject.value['g']?.text, equals('one'));
    expect(client.numUnsyncedOps, equals(3));

    await server.releaseEchoes(reversed: true);
    await _drain();
    expect(client.numUnsyncedOps, equals(0));
    expect(client.stateSubject.value['g']?.text, equals('one'));

    // Redo targets an op that has since been received.
    await client.redo();
    await _drain();
    expect(client.stateSubject.value['g']?.text, equals('two'));
    expect(client.numUnsyncedOps, equals(1));

    await server.releaseEchoes();
    await _drain();
    expect(client.numUnsyncedOps, equals(0));
    expect(client.stateSubject.value['g']?.text, equals('two'));
    expect(server.saveCounts.values, everyElement(equals(1)));
    expect(server.saveCounts.length, equals(4));
    client.dispose();
  });
}
