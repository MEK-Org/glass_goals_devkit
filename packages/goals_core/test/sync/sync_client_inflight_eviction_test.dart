import 'dart:async';

import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

/// A store whose op lookups by id can be held open or failed on demand.
/// `loadGoal` resolves Disable/Enable targets through `loadOpsById` after it
/// installs the goal's base entry, so holding that lookup pauses a load in
/// flight.
class _GatedLocalStore extends MemoryLocalStore {
  final Map<String, int> loads = {};
  Future<void>? gate;
  Object? failNext;

  @override
  Future<Iterable<Op>> loadOpsForGoal(String goalId) {
    loads[goalId] = (loads[goalId] ?? 0) + 1;
    return super.loadOpsForGoal(goalId);
  }

  @override
  Future<Iterable<Op?>> loadOpsById(Iterable<String> opIds) async {
    final ids = opIds.toList();
    if (gate != null) await gate;
    final error = failNext;
    if (error != null) {
      failNext = null;
      throw error;
    }
    return super.loadOpsById(ids);
  }
}

String _h(int t) => '${'$t'.padLeft(15, '0')}:00000:srv';

Op _text(String i, int t, String goalId, String text) => Op.fromJsonMap({
      'h': _h(t),
      'i': i,
      'v': 6,
      't': 'd',
      'd': {'i': goalId, 't': text},
    });

Op _addParent(String i, int t, String goalId, String parentId) =>
    Op.fromJsonMap({
      'h': _h(t),
      'i': i,
      'v': 6,
      't': 'd',
      'd': {
        'i': goalId,
        'lE': {'t': 'aP', 'i': 'e-$i', 'cT': t, 'pI': parentId},
      },
    });

Op _disable(String i, int t, String target) =>
    Op.fromJsonMap({'h': _h(t), 'i': i, 'v': 6, 't': 'dO', 'oI': target});

/// Lets stream deliveries settle. The caching store batches repo reads on a
/// 10ms timer, so wait past it.
Future<void> _pump(MemoryPersistenceService persistence) async {
  for (var i = 0; i < 3; i++) {
    await persistence.settled;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Saves [ops] through a producer session, so they sit before the cursor.
Future<({MemoryPersistenceService persistence, _GatedLocalStore store})>
    _persistedStore(List<Op> ops) async {
  final persistence = MemoryPersistenceService();
  final store = _GatedLocalStore();
  await persistence.save(ops);
  await _pump(persistence);
  final producer = SyncClient(persistenceService: persistence, localStore: store);
  await producer.init();
  await _pump(persistence);
  producer.dispose();
  return (persistence: persistence, store: store);
}

Future<SyncClient> _start(
    MemoryPersistenceService persistence, _GatedLocalStore store, int cap) async {
  final client = SyncClient(
    persistenceService: persistence,
    localStore: store,
    residentSoftCap: cap,
  );
  await client.init();
  await _pump(persistence);
  return client;
}

/// `slow` resolves a Disable target from the store; `fast` does not.
List<Op> _twoChildren() => [
      _text('r', 1000, 'root', 'Root'),
      _text('s1', 1001, 'slow', 'Slow'),
      _text('s2', 1002, 'slow', 'Slow v2'),
      _addParent('sp', 1003, 'slow', 'root'),
      _disable('sd', 1004, 's2'),
      _text('f1', 1005, 'fast', 'Fast'),
      _addParent('fp', 1006, 'fast', 'root'),
    ];

void main() {
  group('SyncClient loads in flight during eviction', () {
    test('roots above a tiny cap stay loadable after init and restart',
        () async {
      // rb's Disable target is read from the store, so its init load is still
      // in flight when ra and rc finish and evict down to the cap. Loading kid
      // afterwards emits a fresh state built from the base.
      final setup = await _persistedStore([
        _text('ta', 1000, 'ra', 'Root ra'),
        _text('tb', 1001, 'rb', 'Root rb'),
        _text('tb2', 1002, 'rb', 'Root rb v2'),
        _disable('db', 1003, 'tb2'),
        _text('tc', 1004, 'rc', 'Root rc'),
        _text('tk', 1005, 'kid', 'Kid'),
        _addParent('pk', 1006, 'kid', 'ra'),
      ]);
      final store = setup.store;

      for (var session = 0; session < 2; session++) {
        final client = SyncClient(
          persistenceService: setup.persistence,
          localStore: store,
          residentSoftCap: 2,
        );
        store.gate = Future<void>.delayed(const Duration(milliseconds: 100));
        await client.init();
        store.gate = null;
        await _pump(setup.persistence);
        expect((await client.loadGoal('kid'))?.text, 'Kid');
        for (final id in ['ra', 'rb', 'rc']) {
          expect((await client.loadGoal(id))?.text, 'Root $id', reason: id);
        }
        expect(client.numResidentGoals, lessThanOrEqualTo(2));
        client.dispose();
      }
    });

    test('a goal evicted mid-load is not recorded as loaded', () async {
      final setup = await _persistedStore(_twoChildren());
      final store = setup.store;
      final client = await _start(setup.persistence, store, 1);
      final rootRef = await client.loadGoalRef('root');

      final release = Completer<void>();
      store.gate = release.future;
      final slow = client.loadGoal('slow');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect((await client.loadGoal('fast'))?.text, 'Fast');
      store.gate = null;
      release.complete();

      expect((await slow)?.text, 'Slow');
      expect((await client.loadGoal('slow'))?.text, 'Slow');
      expect(rootRef.goal?.text, 'Root');
      // Completed unpinned goals still evict and reload.
      expect(client.numResidentGoals, lessThanOrEqualTo(2));
      final fastLoads = store.loads['fast']!;
      expect((await client.loadGoal('fast'))?.text, 'Fast');
      expect(store.loads['fast'], fastLoads + 1);
      await rootRef.dispose();
      client.dispose();
    });

    test('concurrent loads of every goal under a tiny cap all return the goal',
        () async {
      final setup = await _persistedStore(_twoChildren());
      final client = await _start(setup.persistence, setup.store, 1);

      final ids = ['root', 'slow', 'fast'];
      final goals = await Future.wait(ids.map(client.loadGoal));
      expect(goals.map((goal) => goal?.text), ['Root', 'Slow', 'Fast']);
      for (var i = 0; i < ids.length; i++) {
        expect((await client.loadGoal(ids[i]))?.text, goals[i]?.text,
            reason: ids[i]);
      }
      client.dispose();
    });

    test('a failed load releases its protection from eviction', () async {
      final setup = await _persistedStore(_twoChildren());
      final store = setup.store;
      final client = await _start(setup.persistence, store, 1);

      final rootRef = await client.loadGoalRef('root');

      store.failNext = StateError('store unavailable');
      await expectLater(client.loadGoal('slow'), throwsStateError);

      // With root pinned, only slow and fast can go; a leaked protection on
      // slow would leave two goals resident.
      expect((await client.loadGoal('fast'))?.text, 'Fast');
      expect(client.numResidentGoals, 1);
      expect((await client.loadGoal('slow'))?.text, 'Slow');
      await rootRef.dispose();
      client.dispose();
    });
  });
}
