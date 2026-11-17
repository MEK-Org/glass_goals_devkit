import 'dart:async';

import 'package:collection/collection.dart';
import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';
import 'package:test/test.dart';

/// Models `FirestoreRealmV1PersistenceService`'s `min(cursor, now - 90s)`
/// incremental load bound and `stream` delivery without losing prior ops.
class _FutureAwarePersistenceService implements PersistenceService {
  final List<Op> _ops = [];
  final Map<String, String> _strings = {};
  final _controller = StreamController<(Iterable<Op>, String)>.broadcast();
  DateTime Function() nowFn;

  _FutureAwarePersistenceService({
    List<Op> initialOps = const [],
    DateTime Function()? nowFn,
  }) : nowFn = nowFn ?? DateTime.now {
    _ops.addAll(initialOps);
    _ops.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  }

  String _startAfterFor(String cursor) {
    final hlc = HLC.unpack(cursor);
    final ninetySecondsAgo = nowFn()
        .subtract(const Duration(seconds: 90))
        .millisecondsSinceEpoch;
    return hlc.timestamp < ninetySecondsAgo
        ? cursor
        : ninetySecondsAgo.toString().padLeft(15, '0');
  }

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    Iterable<Op> result = _ops;
    if (cursor != null) {
      final startAfter = _startAfterFor(cursor);
      result = result.where((op) => op.hlcTimestamp.compareTo(startAfter) > 0);
    }
    if (limit != null) {
      result = result.take(limit);
    }
    final list = result.toList();
    var latestCursor = cursor;
    for (final op in list) {
      if (latestCursor == null ||
          op.hlcTimestamp.compareTo(latestCursor) > 0) {
        latestCursor = op.hlcTimestamp;
      }
    }
    return LoadOpsResp(ops: list, cursor: latestCursor);
  }

  @override
  Future<void> save(Iterable<Op> ops) async {
    final batch = ops.toList();
    for (final op in batch) {
      final text = Op.extractEntryTextField(op.toJsonMap());
      if (text != null) {
        _strings[text.$1] = text.$2;
      }
      if (!_ops.any((existing) => existing.id == op.id)) {
        _ops.add(op);
      }
    }
    _ops.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    if (batch.isNotEmpty) {
      final maxHlc =
          batch.map((o) => o.hlcTimestamp).sorted().last;
      Future<void>.delayed(Duration.zero, () {
        _controller.add((batch, maxHlc));
      });
    }
  }

  void deliverWithoutLoad(List<Op> ops) {
    for (final op in ops) {
      if (!_ops.any((existing) => existing.id == op.id)) {
        _ops.add(op);
      }
    }
    _ops.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    if (ops.isNotEmpty) {
      final maxHlc = ops.map((o) => o.hlcTimestamp).sorted().last;
      _controller.add((ops, maxHlc));
    }
  }

  @override
  Future<String?> loadString(String entryId) async => _strings[entryId];

  @override
  Future<int> count({String? cursor}) async => _ops.length;

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _controller.stream;

  void dispose() {
    _controller.close();
  }
}

/// Returns ops strictly on [load] without broadcasting on [stream], to exercise
/// post-startup `_pull()` via `client.sync()`.
class _PullOnlyPersistenceService implements PersistenceService {
  final List<Op> _ops = [];
  final _controller = StreamController<(Iterable<Op>, String)>.broadcast();

  _PullOnlyPersistenceService(List<Op> initialOps) {
    _ops.addAll(initialOps);
  }

  void addRemoteOpSilently(Op op) {
    _ops.add(op);
    _ops.sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  }

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    final ops = _ops.sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
    var latestCursor = cursor;
    for (final op in ops) {
      if (latestCursor == null ||
          op.hlcTimestamp.compareTo(latestCursor) > 0) {
        latestCursor = op.hlcTimestamp;
      }
    }
    return LoadOpsResp(ops: ops, cursor: latestCursor);
  }

  @override
  Future<void> save(Iterable<Op> ops) async {}

  @override
  Future<String?> loadString(String entryId) async => null;

  @override
  Future<int> count({String? cursor}) async => _ops.length;

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _controller.stream;

  void dispose() {
    _controller.close();
  }
}

Future<void> _drain() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('Future-cursor HLC seeding & monotonic cursor (#375)', () {
    test(
        'SyncClient.init seeds writer HLC from future localStore.cursor on '
        'quiet startup so modifyGoal mints HLC > stored cursor', () async {
      final now = DateTime.now();
      final futureMs =
          now.add(const Duration(hours: 24)).millisecondsSinceEpoch;
      final futureCursor =
          HLC(timestamp: futureMs, count: 235, node: ' SVB5').pack();

      final futureRootOp = DeltaOp(
        id: 'future-root-op',
        hlcTimestamp: futureCursor,
        delta: GoalDelta(id: 'future-root', text: 'Future Root'),
      );

      final store = MemoryLocalStore();
      await store.storeSyncedOps([futureRootOp]);
      store.setIndexGoalIds('rootGoals', {'future-root'});
      store.cursor = futureCursor;

      // Quiet startup: persistence returns 0 ops on initial load.
      final persistence = _FutureAwarePersistenceService(
        initialOps: [futureRootOp],
        nowFn: () => now,
      );

      final client = SyncClient(
        persistenceService: persistence,
        localStore: store,
      );
      await client.init();

      await client.modifyGoal(GoalDelta(id: 'new-goal', text: 'Created Now'));
      await _drain();

      final pushedOp =
          persistence._ops.firstWhere((op) => op.id != 'future-root-op');
      expect(
        pushedOp.hlcTimestamp.compareTo(futureCursor),
        greaterThan(0),
        reason: 'newly minted op HLC must strictly exceed future stored cursor',
      );
      expect(
        store.cursor!.compareTo(futureCursor),
        greaterThan(0),
        reason: 'cursor must advance past future stored cursor after echo',
      );

      // A reloading client whose cursor was futureCursor (> 90s later) must
      // still see the newly created goal.
      final reloadStore = MemoryLocalStore();
      await reloadStore.storeSyncedOps([futureRootOp]);
      reloadStore.setIndexGoalIds('rootGoals', {'future-root'});
      reloadStore.cursor = futureCursor;
      persistence.nowFn = () => now.add(const Duration(minutes: 10));

      final reloadedClient = SyncClient(
        persistenceService: persistence,
        localStore: reloadStore,
      );
      await reloadedClient.init();

      expect(
        reloadedClient.stateSubject.value['new-goal']?.text,
        equals('Created Now'),
      );

      reloadedClient.dispose();
      client.dispose();
      persistence.dispose();
    });

    test(
        'InitialOpFetcher followed by SyncClient.init with quiet startup seeds '
        'writer HLC >= future cursor', () async {
      final now = DateTime.now();
      final futureMs =
          now.add(const Duration(hours: 24)).millisecondsSinceEpoch;
      final futureCursor =
          HLC(timestamp: futureMs, count: 235, node: ' SVB5').pack();

      final rootOp = DeltaOp(
        id: 'root-op',
        hlcTimestamp: HLC(
                timestamp: now
                    .subtract(const Duration(minutes: 10))
                    .millisecondsSinceEpoch,
                count: 0,
                node: 'seed')
            .pack(),
        delta: GoalDelta(id: 'root', text: 'Root'),
      );
      final futureChildOp = DeltaOp(
        id: 'future-child-op',
        hlcTimestamp: futureCursor,
        delta: GoalDelta(
          id: 'child',
          text: 'Future Child',
          logEntry: AddParentLogEntry(
            id: 'e-child',
            creationTime: now,
            parentId: 'root',
          ),
        ),
      );

      final persistence = _FutureAwarePersistenceService(
        initialOps: [rootOp, futureChildOp],
        nowFn: () => now,
      );
      final store = MemoryLocalStore();

      await InitialOpFetcher(
        persistenceService: persistence,
        localStore: store,
      ).doInitialFetch();
      expect(store.cursor, equals(futureCursor));
      store.clearCaches();

      // Notice: child is NOT a root goal, so init()'s root load won't touch
      // futureChildOp; SyncClient.init() must seed hlc from store.cursor.
      final client = SyncClient(
        persistenceService: persistence,
        localStore: store,
      );
      await client.init();

      await client.modifyGoal(GoalDelta(id: 'writer-goal', text: 'Writer'));
      await _drain();

      final mintedOp = persistence._ops.firstWhere(
        (op) => op.id != 'root-op' && op.id != 'future-child-op',
      );
      expect(mintedOp.hlcTimestamp.compareTo(futureCursor), greaterThan(0));

      client.dispose();
      persistence.dispose();
    });

    test(
        'CachingLocalStore.storeSyncedOps keeps cursor monotonic when storing '
        'normal wall-clock op behind future cursor', () async {
      final now = DateTime.now();
      final futureMs =
          now.add(const Duration(hours: 24)).millisecondsSinceEpoch;
      final futureCursor =
          HLC(timestamp: futureMs, count: 235, node: ' SVB5').pack();
      final normalHlc =
          HLC(timestamp: now.millisecondsSinceEpoch, count: 0, node: 'wall')
              .pack();

      final store = MemoryLocalStore();
      await store.storeSyncedOps([
        DeltaOp(
          id: 'future-op',
          hlcTimestamp: futureCursor,
          delta: GoalDelta(id: 'future-goal', text: 'Future'),
        ),
      ]);
      expect(store.cursor, equals(futureCursor));

      await store.storeSyncedOps([
        DeltaOp(
          id: 'normal-op',
          hlcTimestamp: normalHlc,
          delta: GoalDelta(id: 'normal-goal', text: 'Normal'),
        ),
      ]);

      expect(store.cursor, equals(futureCursor));
      final loaded = await store.loadOpsForGoal('normal-goal');
      expect(loaded.map((o) => o.id), equals(['normal-op']));
    });

    test(
        'normal wall-clock op received behind future cursor does not regress '
        'cursor and remains visible in-session and across reload', () async {
      final now = DateTime.now();
      final futureMs =
          now.add(const Duration(hours: 24)).millisecondsSinceEpoch;
      final futureCursor =
          HLC(timestamp: futureMs, count: 235, node: ' SVB5').pack();

      final futureRootOp = DeltaOp(
        id: 'future-root-op',
        hlcTimestamp: futureCursor,
        delta: GoalDelta(id: 'future-root', text: 'Future Root'),
      );

      final store = MemoryLocalStore();
      await store.storeSyncedOps([futureRootOp]);
      store.setIndexGoalIds('rootGoals', {'future-root'});
      store.cursor = futureCursor;

      final persistence = _FutureAwarePersistenceService(
        initialOps: [futureRootOp],
        nowFn: () => now,
      );

      final client = SyncClient(
        persistenceService: persistence,
        localStore: store,
      );
      await client.init();

      final normalOp = DeltaOp(
        id: 'normal-wall-op',
        hlcTimestamp:
            HLC(timestamp: now.millisecondsSinceEpoch, count: 1, node: 'unseed')
                .pack(),
        delta: GoalDelta(id: 'normal-root', text: 'Normal Wall-Clock Goal'),
      );
      persistence.deliverWithoutLoad([normalOp]);
      await _drain();

      expect(client.cursor, equals(futureCursor));
      expect(
        client.stateSubject.value['normal-root']?.text,
        equals('Normal Wall-Clock Goal'),
      );

      client.dispose();

      // Reload over the same store with quiet persistence.
      final quietPersistence = _FutureAwarePersistenceService(nowFn: () => now);
      final reloaded = SyncClient(
        persistenceService: quietPersistence,
        localStore: store,
      );
      await reloaded.init();

      expect(reloaded.cursor, equals(futureCursor));
      expect(
        reloaded.stateSubject.value['normal-root']?.text,
        equals('Normal Wall-Clock Goal'),
      );
      expect(reloaded.getRootGoalIds(), contains('normal-root'));

      reloaded.dispose();
      persistence.dispose();
      quietPersistence.dispose();
    });

    test(
        'post-startup _pull delivering op <= _baseStateCursor updates '
        'stateSubject for already-loaded goals and survives reload', () async {
      final now = DateTime.now();
      final futureMs =
          now.add(const Duration(hours: 24)).millisecondsSinceEpoch;
      final futureCursor =
          HLC(timestamp: futureMs, count: 235, node: ' SVB5').pack();

      final futureRootOp = DeltaOp(
        id: 'future-root-op',
        hlcTimestamp: futureCursor,
        delta: GoalDelta(id: 'future-root', text: 'Future Root'),
      );

      final store = MemoryLocalStore();
      await store.storeSyncedOps([futureRootOp]);
      store.setIndexGoalIds('rootGoals', {'future-root'});
      store.cursor = futureCursor;

      final persistence = _PullOnlyPersistenceService([]);
      final client = SyncClient(
        persistenceService: persistence,
        localStore: store,
      );
      await client.init();
      expect(client.stateSubject.value['future-root']?.log, isEmpty);

      final normalNoteOp = DeltaOp(
        id: 'late-note-op',
        hlcTimestamp:
            HLC(timestamp: now.millisecondsSinceEpoch, count: 1, node: 'peer')
                .pack(),
        delta: GoalDelta(
          id: 'future-root',
          logEntry: NoteLogEntry(
            id: 'note-1',
            creationTime: now,
            text: 'Wall-clock note',
          ),
        ),
      );
      persistence.addRemoteOpSilently(normalNoteOp);
      await client.sync();

      expect(client.cursor, equals(futureCursor));
      expect(
        client.stateSubject.value['future-root']?.log
            .whereType<NoteLogEntry>()
            .map((e) => e.text),
        contains('Wall-clock note'),
      );

      client.dispose();

      final reloaded = SyncClient(
        persistenceService: _PullOnlyPersistenceService([]),
        localStore: store,
      );
      await reloaded.init();

      expect(reloaded.cursor, equals(futureCursor));
      expect(
        reloaded.stateSubject.value['future-root']?.log
            .whereType<NoteLogEntry>()
            .map((e) => e.text),
        contains('Wall-clock note'),
      );

      reloaded.dispose();
      persistence.dispose();
    });
  });
}
