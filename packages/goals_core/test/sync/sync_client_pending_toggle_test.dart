import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';
import 'package:test/test.dart';

/// Uses the production SyncClient and CachingLocalStore. The service retains
/// every accepted operation; the repository can hold one local write forever
/// after its echo arrives. Writes that finished are what a same-repository
/// restart sees, as after a closed tab.
class _ControlledPersistence implements PersistenceService {
  final _historyById = <String, Op>{};
  final _pendingEchoes = <List<Op>>[];
  final _stream = StreamController<(Iterable<Op>, String)>.broadcast();

  _ControlledPersistence(Iterable<Op> seed) {
    _remember(seed);
  }

  List<Op> get history {
    final result = _historyById.values.toList()
      ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    return result;
  }

  List<String> get historyIds => history.map((op) => op.id).toList();

  @override
  Future<void> save(Iterable<Op> ops) async {
    final batch = ops.toList();
    _remember(batch);
    _pendingEchoes.add(batch);
  }

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    var result = history
        .where((op) => cursor == null || op.hlcTimestamp.compareTo(cursor) > 0)
        .toList();
    if (limit != null) result = result.take(limit).toList();
    return LoadOpsResp(
      ops: result,
      cursor: result.isEmpty ? cursor : result.last.hlcTimestamp,
    );
  }

  @override
  Future<String?> loadString(String entryId) async => null;

  @override
  Future<int> count({String? cursor}) async => history
      .where((op) => cursor == null || op.hlcTimestamp.compareTo(cursor) <= 0)
      .length;

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _stream.stream;

  void deliverNextEcho() {
    if (_pendingEchoes.isEmpty || _pendingEchoes.first.isEmpty) {
      throw StateError('No accepted batch is waiting for an echo');
    }
    final batch = _pendingEchoes.removeAt(0);
    final cursor = (batch.toList()
          ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp)))
        .last
        .hlcTimestamp;
    _stream.add((batch, cursor));
  }

  Future<void> dispose() => _stream.close();

  void _remember(Iterable<Op> ops) {
    for (final op in ops) {
      _historyById[op.id] = op;
    }
  }
}

class _GatedRepository extends MemorySyncRepository {
  final startedBatches = <List<String>>[];
  final committedBatches = <List<String>>[];
  final _startWaiters = <int, Completer<void>>{};
  Completer<void>? _nextGate;

  Future<void> waitForStarts(int count) {
    if (startedBatches.length >= count) return Future.value();
    return (_startWaiters[count] ??= Completer<void>()).future;
  }

  void blockNextStore() {
    if (_nextGate != null) throw StateError('A store is already blocked');
    _nextGate = Completer<void>();
  }

  @override
  Future<void> storeSyncedOps(Iterable<Op> ops) async {
    final batch = ops.toList();
    startedBatches.add(batch.map((op) => op.id).toList());
    for (final entry in _startWaiters.entries.toList()) {
      if (startedBatches.length >= entry.key) {
        _startWaiters.remove(entry.key);
        entry.value.complete();
      }
    }
    final gate = _nextGate;
    _nextGate = null;
    // Never completed: the write stays in flight, as when a tab closes.
    if (gate != null) await gate.future;
    await super.storeSyncedOps(batch);
    committedBatches.add(batch.map((op) => op.id).toList());
  }
}

class _TrackingStore extends CachingLocalStore {
  int completedWrites = 0;
  final _completionWaiters = <int, Completer<void>>{};

  _TrackingStore(_GatedRepository repository) : super(repo: repository);

  Future<void> waitForCompletedWrites(int count) {
    if (completedWrites >= count) return Future.value();
    return (_completionWaiters[count] ??= Completer<void>()).future;
  }

  @override
  Future<void> storeSyncedOps(Iterable<Op> ops) async {
    await super.storeSyncedOps(ops);
    completedWrites++;
    for (final entry in _completionWaiters.entries.toList()) {
      if (completedWrites >= entry.key) {
        _completionWaiters.remove(entry.key);
        entry.value.complete();
      }
    }
  }
}

String? _text(SyncClient client) => client.stateSubject.value['g']?.text;

Future<List<String>> _storedIds(_GatedRepository repository) async {
  final ops = (await repository.loadAllSyncedOps()).toList()
    ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  return ops.map((op) => op.id).toList();
}

Future<void> _deliverAndSettle(
  _ControlledPersistence persistence,
  _GatedRepository repository,
  _TrackingStore store,
) async {
  final starts = repository.startedBatches.length + 1;
  final completes = store.completedWrites + 1;
  persistence.deliverNextEcho();
  await repository.waitForStarts(starts);
  await store.waitForCompletedWrites(completes);
}

/// Lets queued storage, index writes and the store's 10ms read batch finish.
Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  test('pending final Undo remains recoverable before its local write finishes (#42)',
      () async {
    final original = DeltaOp(
      id: 'original',
      hlcTimestamp:
          HLC(timestamp: 1700000000000, count: 0, node: 'server').pack(),
      delta: GoalDelta(id: 'g', text: 'Original'),
    );
    final persistence = _ControlledPersistence([original]);
    final repository = _GatedRepository();
    final store = _TrackingStore(repository);
    final initialStarts = repository.startedBatches.length + 1;
    final initialCompletes = store.completedWrites + 1;
    final client = SyncClient(
      persistenceService: persistence,
      localStore: store,
    );
    await client.init();
    await repository.waitForStarts(initialStarts);
    await store.waitForCompletedWrites(initialCompletes);
    expect(_text(client), 'Original');

    await client.modifyGoal(GoalDelta(id: 'g', text: 'Changed'));
    await _deliverAndSettle(persistence, repository, store);
    expect(_text(client), 'Changed');

    // Undo and Redo use the echoed, locally durable change while their own
    // echoes are held: this is the offline base-op path.
    await client.undo();
    expect(_text(client), 'Original');
    await client.redo();
    expect(_text(client), 'Changed');
    await _deliverAndSettle(persistence, repository, store);
    await _deliverAndSettle(persistence, repository, store);
    expect(_text(client), 'Changed');

    await client.undo();
    expect(_text(client), 'Original');
    repository.blockNextStore();
    final blockedStart = repository.startedBatches.length + 1;
    persistence.deliverNextEcho();
    await repository.waitForStarts(blockedStart);

    final historyIds = persistence.historyIds;
    final finalToggleId = historyIds.last;
    final finalToggleHlc = persistence.history.last.hlcTimestamp;
    final boundary = {
      'cursor': repository.cursor,
      'persisted': await _storedIds(repository),
      'pending': repository.getUnsyncedOps().map((op) => op.id).toList(),
      'acknowledged': repository.getAckedOpIds().toList(),
      'history': historyIds,
    };
    print('[#42] boundary ${jsonEncode(boundary)}');

    // Stop here: the blocked write never completes. Only writes that finished
    // are in the repository, as after a closed tab. Reopen the same repository.
    client.dispose();
    final recovering = SyncClient(
      persistenceService: persistence,
      localStore: _TrackingStore(repository),
    );
    await recovering.init();
    await recovering.loadGoal('g');
    final recoveringText = _text(recovering);
    await _settle();
    final recoveredPersisted = await _storedIds(repository);
    print('[#42] recovering restart ${jsonEncode({
          'text': recoveringText,
          'cursor': repository.cursor,
          'persisted': recoveredPersisted,
          'pending': repository.getUnsyncedOps().map((op) => op.id).toList(),
          'acknowledged': repository.getAckedOpIds().toList(),
        })}');
    recovering.dispose();

    // Once the recovering client has settled, a later restart must match the
    // full server history, which ends with the final Undo.
    final restarted = SyncClient(
      persistenceService: persistence,
      localStore: _TrackingStore(repository),
    );
    await restarted.init();
    await restarted.loadGoal('g');
    final restartedText = _text(restarted);
    await _settle();
    restarted.dispose();
    print('[#42] settled restart ${jsonEncode({'text': restartedText})}');

    expect(
      {'text': restartedText, 'persisted': recoveredPersisted},
      {'text': 'Original', 'persisted': historyIds},
    );

    // While its write was blocked, the echoed op was still recoverable by a
    // same-repository restart: stored, before the cursor, or pending and
    // acknowledged so the pull starts before it.
    final boundaryCursor = boundary['cursor'] as String?;
    final boundaryPersisted = boundary['persisted'] as List<String>;
    final boundaryPending = boundary['pending'] as List<String>;
    final boundaryAcked = boundary['acknowledged'] as List<String>;
    expect(
      {
        'finalToggleId': finalToggleId,
        'recoverable': boundaryPersisted.contains(finalToggleId) ||
            (boundaryCursor != null &&
                boundaryCursor.compareTo(finalToggleHlc) < 0) ||
            (boundaryPending.contains(finalToggleId) &&
                boundaryAcked.contains(finalToggleId)),
      },
      {'finalToggleId': finalToggleId, 'recoverable': true},
    );
    await persistence.dispose();
  });
}
