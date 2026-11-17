import 'dart:async';

import 'package:collection/collection.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

const _crashCursor = '001794930789467:0006j: SVB5';
const _parentImportId = 'zYTiFzVSXYM4Sg';
const _corruptedGoalId = 'cZoLug5RNb1VQA';
const _mauetCh9Id = 'Uxy3JtLjb6VHSw';
const _rootTestGoalId = 'UWY6j_uIt4BNRQ';

/// In-memory persistence double that preserves all committed ops across saves
/// and optionally limits batch size to exercise multi-batch pulls.
class _AppendServer implements PersistenceService {
  final List<Op> committed = [];
  final Map<String, String> strings = {};
  final _controller = StreamController<(Iterable<Op>, String)>.broadcast();
  bool failSave = false;
  final List<String?> loadCursors = [];

  _AppendServer({List<Op> initialOps = const []}) {
    for (final op in initialOps) {
      _recordOp(op);
    }
    committed.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  }

  void _recordOp(Op op) {
    committed.removeWhere((existing) => existing.id == op.id);
    committed.add(op);
    final extracted = Op.extractEntryTextField(op.toJsonMap());
    if (extracted != null) {
      strings[extracted.$1] = extracted.$2;
    }
  }

  @override
  Future<void> save(Iterable<Op> ops) async {
    if (failSave) {
      throw StateError('offline');
    }
    for (final op in ops) {
      _recordOp(op);
    }
    committed.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  }

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    loadCursors.add(cursor);
    final effectiveLimit = limit ?? 4000;
    final filtered = committed
        .where((op) => cursor == null || op.hlcTimestamp.compareTo(cursor) > 0)
        .sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp))
        .take(effectiveLimit)
        .toList();
    return LoadOpsResp(
      ops: filtered,
      cursor: filtered.isEmpty ? cursor : filtered.last.hlcTimestamp,
    );
  }

  @override
  Future<String?> loadString(String entryId) async => strings[entryId];

  @override
  Future<int> count({String? cursor}) async => committed.length;

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _controller.stream;
}

DeltaOp _titleOp(String id, String hlc, String goalId, String text) => DeltaOp(
      id: id,
      hlcTimestamp: hlc,
      delta: GoalDelta(id: goalId, text: text),
    );

DeltaOp _addParentOp(
  String id,
  String hlc,
  String goalId,
  String parentId,
  int ms,
) =>
    DeltaOp(
      id: id,
      hlcTimestamp: hlc,
      delta: GoalDelta(
        id: goalId,
        logEntry: AddParentLogEntry(
          id: 'parent-$id',
          creationTime: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
          parentId: parentId,
        ),
      ),
    );

DeltaOp _noteOp(
  String id,
  String hlc,
  String goalId,
  String entryId,
  String text,
  int ms,
) =>
    DeltaOp(
      id: id,
      hlcTimestamp: hlc,
      delta: GoalDelta(
        id: goalId,
        logEntry: NoteLogEntry(
          id: entryId,
          creationTime: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
          text: text,
        ),
      ),
    );

List<Op> _buildIncidentCorpus() {
  final ops = <Op>[
    // Pre-cursor import ops (<= 001794930789467:0006j: SVB5)
    _titleOp(
      'op_import_root',
      '001794930562329:00021:SVB5',
      _parentImportId,
      'Test: Copyright and Artificial Intelligence, Part 3',
    ),
    _titleOp(
      'op_cZo_old',
      '001794930562329:00022:SVB5',
      _corruptedGoalId,
      'V - LICENSING FOR AI TRAINING',
    ),
    _addParentOp(
      'op_cZo_parent',
      '001794930562329:00023:SVB5',
      _corruptedGoalId,
      _parentImportId,
      1794930562329,
    ),
    // Post-cursor batch 1 ops (after 001794930789467:0006j: SVB5): 4000 ops
    // total so _pull() must issue a second batch for Mauet Ch9 and root test.
    _noteOp(
      'op_cZo_in_batch',
      '001794930858323:0007m:SVB5',
      _corruptedGoalId,
      'note-cZo-1',
      'Licensing note from SVB5',
      1794930858323,
    ),
    for (var i = 0; i < 3998; i++)
      _titleOp(
        'op_filler_$i',
        '${(1794930860000 + i).toString().padLeft(15, '0')}:00000:SVB5',
        'filler_goal_${i % 50}',
        'Filler ${i % 50}',
      ),
    _titleOp(
      'op_batch1_tail',
      '001794930965354:0004b:SVB5',
      _parentImportId,
      'Test: Copyright and Artificial Intelligence, Part 3 (updated)',
    ),
    // Batch 2 ops: Mauet Chapter 9 and root test goal
    _titleOp(
      'op_mauet_ch9',
      '001794934601337:0006q:FXH0',
      _mauetCh9Id,
      'Chapter 9 — Closing Arguments',
    ),
    _titleOp(
      'JfqMHYUd_aNNRQ',
      '001794935913195:0000i:FXH0',
      _rootTestGoalId,
      'Sync test — November 17, 17:19 UTC',
    ),
  ];
  return ops;
}

void main() {
  group('Issue #375 CacheMissException recovery', () {
    test(
        'resolves incoming batch op already present in goalOpsIndex without CacheMissException',
        () async {
      final corpus = _buildIncidentCorpus();
      // Pre-cursor ops were stored normally; crash left op_cZo_in_batch in
      // goalOpsIndex['cZoLug5RNb1VQA'] without writing it to syncedOps or
      // advancing cursor past _crashCursor.
      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..cursor = _crashCursor;
      final preStore = CachingLocalStore(repo: repo);
      await preStore.storeSyncedOps(corpus.take(3));
      await preStore.settled();
      repo.cursor = _crashCursor;
      await repo.storeGoalIndexEntry(_corruptedGoalId, {
        'opIds': ['op_cZo_old', 'op_cZo_parent', 'op_cZo_in_batch'],
      });
      await repo.setIndexGoalIds('rootGoals', {_parentImportId});

      final pendingEdit = _noteOp(
        'op_local_pending',
        '001794930990000:00001:SVB5',
        'localPendingGoal',
        'local-note-1',
        'Unsynced local note',
        1794930990000,
      );
      final localStore = CachingLocalStore(repo: repo);
      await localStore.setUnsyncedOps([pendingEdit]);

      final server = _AppendServer(initialOps: corpus)..failSave = true;
      final client = SyncClient(
        persistenceService: server,
        localStore: localStore,
      );

      await client.init();
      await client.loadGoal(_corruptedGoalId);
      await client.loadGoal(_mauetCh9Id);
      await client.loadGoal(_rootTestGoalId);

      expect(client.fullSyncCount, 0);
      expect(client.stateSubject.value[_corruptedGoalId]?.text,
          'V - LICENSING FOR AI TRAINING');
      expect(client.stateSubject.value[_mauetCh9Id]?.text,
          'Chapter 9 — Closing Arguments');
      expect(client.stateSubject.value[_rootTestGoalId]?.text,
          'Sync test — November 17, 17:19 UTC');
      expect(
        localStore.getUnsyncedOps().map((op) => op.id),
        contains('op_local_pending'),
      );
      expect(await localStore.loadString('local-note-1'), 'Unsynced local note');
    });

    test(
        'recovers from missing historical op in syncedOps, increments fullSyncCount, preserves unsyncedOps (offline save)',
        () async {
      final corpus = _buildIncidentCorpus();
      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..cursor = _crashCursor;
      // Store only op_import_root; drop op_cZo_old from syncedOps while
      // goalOpsIndex['cZoLug5RNb1VQA'] still references it.
      await repo.storeSyncedOps([corpus[0], corpus[2]]);
      await repo.storeGoalIndexEntry(_parentImportId, {
        'opIds': ['op_import_root', 'op_cZo_parent'],
      });
      await repo.storeGoalIndexEntry(_corruptedGoalId, {
        'opIds': ['op_cZo_old', 'op_cZo_parent'],
      });
      await repo.setIndexGoalIds('rootGoals', {_parentImportId});

      final pendingEdit = _noteOp(
        'op_local_pending',
        '001794930990000:00001:SVB5',
        'localPendingGoal',
        'local-note-1',
        'Unsynced local note',
        1794930990000,
      );
      final localStore = CachingLocalStore(repo: repo);
      await localStore.setUnsyncedOps([pendingEdit]);
      await localStore.setAckedOpIds(['acked_unreceived_id']);

      final server = _AppendServer(initialOps: corpus)..failSave = true;
      final client = SyncClient(
        persistenceService: server,
        localStore: localStore,
      );

      await client.init();
      await client.loadGoal(_corruptedGoalId);
      await client.loadGoal(_mauetCh9Id);
      await client.loadGoal(_rootTestGoalId);

      expect(client.fullSyncCount, 1);
      expect(localStore.clientId, 'SVB5');
      expect(localStore.getAckedOpIds(), contains('acked_unreceived_id'));
      expect(
        localStore.getUnsyncedOps().map((op) => op.id),
        equals(['op_local_pending']),
      );
      expect(await localStore.loadString('local-note-1'), 'Unsynced local note');
      expect(server.loadCursors, contains(null));
      expect(client.stateSubject.value[_corruptedGoalId]?.text,
          'V - LICENSING FOR AI TRAINING');
      expect(client.stateSubject.value[_mauetCh9Id]?.text,
          'Chapter 9 — Closing Arguments');
      expect(client.stateSubject.value[_rootTestGoalId]?.text,
          'Sync test — November 17, 17:19 UTC');
    });

    test(
        'recovers from missing historical op and still pushes preserved unsyncedOps when online',
        () async {
      final corpus = _buildIncidentCorpus();
      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..cursor = _crashCursor;
      await repo.storeSyncedOps([corpus[0]]);
      await repo.storeGoalIndexEntry(_corruptedGoalId, {
        'opIds': ['op_cZo_old', 'op_cZo_parent'],
      });
      await repo.setIndexGoalIds('rootGoals', {_parentImportId});

      final pendingEdit = _titleOp(
        'op_local_pending',
        '001794930990000:00001:SVB5',
        'localPendingGoal',
        'Local Pending Title',
      );
      final localStore = CachingLocalStore(repo: repo);
      await localStore.setUnsyncedOps([pendingEdit]);

      final server = _AppendServer(initialOps: corpus);
      final client = SyncClient(
        persistenceService: server,
        localStore: localStore,
      );

      await client.init();
      await client.loadGoal(_corruptedGoalId);
      await client.loadGoal(_mauetCh9Id);
      await client.loadGoal(_rootTestGoalId);

      expect(client.fullSyncCount, 1);
      expect(
        server.committed.map((op) => op.id),
        contains('op_local_pending'),
      );
      expect(client.stateSubject.value['localPendingGoal']?.text,
          'Local Pending Title');
      expect(client.stateSubject.value[_rootTestGoalId]?.text,
          'Sync test — November 17, 17:19 UTC');
    });

    test(
        'recovers when CacheMissException occurs on loadGoal after quiet pull and coalesces concurrent loads',
        () async {
      final corpus = _buildIncidentCorpus();
      final latestCursor = corpus.last.hlcTimestamp;
      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..cursor = latestCursor;
      // Corrupt both corruptedGoalId and mauetCh9Id while cursor is at tip so
      // _pull() returns 0 ops during init().
      await repo.storeGoalIndexEntry(_corruptedGoalId, {
        'opIds': ['op_cZo_old'],
      });
      await repo.storeGoalIndexEntry(_mauetCh9Id, {
        'opIds': ['op_mauet_ch9'],
      });
      await repo.setIndexGoalIds('rootGoals', {_parentImportId});

      final pendingEdit = _titleOp(
        'op_local_pending',
        '001794930990000:00001:SVB5',
        'localPendingGoal',
        'Local Pending Title',
      );
      final localStore = CachingLocalStore(repo: repo);
      await localStore.setUnsyncedOps([pendingEdit]);

      final server = _AppendServer(initialOps: corpus)
        ..failSave = true;
      final client = SyncClient(
        persistenceService: server,
        localStore: localStore,
      );

      await client.init();
      final results = await Future.wait([
        client.loadGoal(_corruptedGoalId),
        client.loadGoal(_mauetCh9Id),
      ]);

      expect(client.fullSyncCount, 1);
      expect(results[0]?.text, 'V - LICENSING FOR AI TRAINING');
      expect(results[1]?.text, 'Chapter 9 — Closing Arguments');
      expect(
        localStore.getUnsyncedOps().map((op) => op.id),
        equals(['op_local_pending']),
      );
    });

    test('seeds writer HLC from stored cursor and keeps repo.cursor monotonic',
        () async {
      final futureMs = DateTime.now().millisecondsSinceEpoch + 3600000;
      final futureCursor =
          '${futureMs.toString().padLeft(15, '0')}:0006j: SVB5';
      final olderHlc =
          '${(futureMs - 100000).toString().padLeft(15, '0')}:00001:FXH0';

      final repo = MemorySyncRepository()
        ..clientId = 'SVB5'
        ..cursor = futureCursor;
      final store = CachingLocalStore(repo: repo);
      final client = SyncClient(localStore: store);

      await client.init();
      expect(
        client.hlc.pack().compareTo(futureCursor),
        greaterThanOrEqualTo(0),
      );

      await store.storeSyncedOps([
        _titleOp('op_older', olderHlc, 'g_older', 'Older Goal'),
      ]);
      await store.settled();
      expect(repo.cursor, futureCursor);
    });
  });
}
