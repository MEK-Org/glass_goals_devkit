import 'dart:async';
import 'dart:isolate';

import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

final _time = DateTime.utc(2026, 10, 3);

GoalDelta _parent(String child, String? parent,
        {bool set = false, bool slice = false}) =>
    GoalDelta(
      id: child,
      logEntry: set
          ? SetParentLogEntry(
              id: '$child-$parent-set', parentId: parent, creationTime: _time)
          : AddParentLogEntry(
              id: '$child-$parent-add',
              parentId: parent!,
              creationTime: _time,
              isSlice: slice),
    );

Future<SyncClient> _client(
    {MemoryPersistenceService? persistence, bool seed = true}) async {
  final client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: persistence ?? MemoryPersistenceService());
  await client.init();
  if (seed) {
    await client.modifyGoals([
      for (final id in ['a', 'b', 'old', 'root']) GoalDelta(id: id, text: id)
    ]);
  }
  return client;
}

/// A shared server for two devices with controllable delivery.
/// MemoryPersistenceService.save keeps only the batch it was given, so each
/// save here carries the existing ops too.
class _SharedPersistence extends MemoryPersistenceService {
  final _controller = StreamController<(Iterable<Op>, String)>.broadcast();
  bool _paused = false;
  String? _pausedCursor;
  final List<(Iterable<Op>, String)> _pendingEvents = [];

  void pauseDelivery() {
    _paused = true;
    _pausedCursor = maxHlc;
  }

  void resumeDelivery() {
    _paused = false;
    _pausedCursor = null;
    for (final event in _pendingEvents) {
      _controller.add(event);
    }
    _pendingEvents.clear();
  }

  void dispose() => _controller.close();

  @override
  Stream<(Iterable<Op>, String)> stream(String? cursor) => _controller.stream;

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    final resp = await super.load(cursor: cursor, limit: limit);
    if (_paused && _pausedCursor != null) {
      final filtered = resp.ops
          .where((op) => op.hlcTimestamp.compareTo(_pausedCursor!) <= 0)
          .toList();
      return LoadOpsResp(
        ops: filtered,
        cursor: filtered.isNotEmpty ? filtered.last.hlcTimestamp : cursor,
      );
    }
    return resp;
  }

  @override
  Future<void> save(Iterable<Op> ops) async {
    await super.save([...this.ops, ...ops]);
    final event = (ops, maxHlc ?? '');
    if (_paused) {
      _pendingEvents.add(event);
    } else {
      _controller.add(event);
    }
  }
}

/// Both graph sides as plain lists, so a failure prints the whole shape.
Map<String, List<String>> _edges(Map<String, Goal> goals) => {
      for (final id in ['a', 'b'])
        for (final (side, ids) in [
          ('up', goals[id]!.superGoalIds),
          ('down', goals[id]!.subGoalIds)
        ])
          '$id.$side': ids.toList(),
    };

const _emptyEdges = {
  'a.up': <String>[],
  'a.down': <String>[],
  'b.up': <String>[],
  'b.down': <String>[],
};

const _acyclicAUnderB = {
  'a.up': ['b'],
  'a.down': <String>[],
  'b.up': <String>[],
  'b.down': ['a'],
};

const _acyclicBUnderA = {
  'a.up': <String>[],
  'a.down': ['b'],
  'b.up': ['a'],
  'b.down': <String>[],
};

// Runs the reader on another isolate: the watchdog remains responsive even
// when a synchronous traversal blocks that isolate's event loop.
Future<T> _bounded<T>(FutureOr<T> Function() body) async {
  final receive = ReceivePort();
  final isolate = await Isolate.spawn((SendPort send) async {
    try {
      send.send(await body());
    } catch (error, stack) {
      send.send([error.toString(), stack.toString()]);
    }
  }, receive.sendPort);
  try {
    return await receive.first.timeout(const Duration(seconds: 2)) as T;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    receive.close();
  }
}

void main() {
  for (final set in [false, true]) {
    test(
        '${set ? 'SetParent' : 'AddParent'} rejects both sides of a closing edge',
        () async {
      final client = await _client();
      addTearDown(client.dispose);
      await client.modifyGoal(_parent('a', 'b'));
      await client.modifyGoal(_parent('b', 'a', set: set));
      final goals = client.stateSubject.value;
      print(
          '${set ? 'SetParent' : 'AddParent'}: a up=${goals['a']!.superGoalIds.toList()} down=${goals['a']!.subGoalIds.toList()}; b up=${goals['b']!.superGoalIds.toList()} down=${goals['b']!.subGoalIds.toList()}');
      expect(goals['a']!.superGoalIds, ['b']);
      expect(goals['b']!.subGoalIds, ['a']);
      expect(goals['a']!.subGoalIds, isEmpty);
      expect(goals['b']!.superGoalIds, isEmpty);
      expect(goals['b']!.log, hasLength(1),
          reason: 'the rejected relationship op remains in the log');
    });

    test(
        '${set ? 'SetParent' : 'AddParent'} op graph has bounded upward traversal',
        () async {
      final ids = await _bounded(() async {
        final client = await _client();
        try {
          await client.modifyGoal(_parent('a', 'b'));
          await client.modifyGoal(_parent('b', 'a', set: set));
          return getTransitiveSuperGoals(client.stateSubject.value, 'a')
              .keys
              .toList();
        } finally {
          client.dispose();
        }
      });
      expect(ids, unorderedEquals(['a', 'b']));
    });

    test(
        '${set ? 'SetParent' : 'AddParent'} allows unloaded parent and missing ancestor',
        () async {
      final client = await _client();
      addTearDown(client.dispose);
      await client.modifyGoal(_parent('a', 'missing', set: set));
      expect(client.stateSubject.value['a']!.superGoalIds, ['missing']);
      await client.modifyGoal(_parent('b', 'a', set: set));
      expect(client.stateSubject.value['b']!.superGoalIds, ['a']);
      expect(client.stateSubject.value['a']!.subGoalIds, ['b']);
    });
  }

  test('existing upward/downward cycles terminate, visiting each goal once',
      () async {
    final ids = await _bounded(() {
      final a = Goal(id: 'a', text: 'a', creationTime: _time)
        ..addSuperGoal('b')
        ..addSubGoal('b');
      final b = Goal(id: 'b', text: 'b', creationTime: _time)
        ..addSuperGoal('a')
        ..addSubGoal('a');
      final goals = {'a': a, 'b': b};
      return [
        getTransitiveSuperGoals(goals, 'a').keys.toList(),
        getTransitiveSubGoals(goals, 'a').keys.toList()
      ];
    });
    expect(ids, [
      ['a', 'b'],
      ['a', 'b']
    ]);
  });

  test('DAG diamond keeps all parents and visits shared ancestor once',
      () async {
    final client = await _client();
    addTearDown(client.dispose);
    await client.modifyGoals([
      _parent('a', 'root'),
      _parent('b', 'root'),
      _parent('old', 'a'),
      _parent('old', 'b')
    ]);
    final goals = client.stateSubject.value;
    final seen = <String>[];
    expect(
        getTransitiveSuperGoals(goals, 'old', predicate: (goal) {
          seen.add(goal.id);
          return true;
        }).keys,
        ['old', 'b', 'root', 'a']);
    expect(seen, ['b', 'root', 'a']);
    expect(
        getTransitiveSuperGoals(goals, 'old',
            predicate: (goal) => goal.id != 'root').keys,
        ['old', 'b', 'a']);
    expect(getTransitiveSuperGoals(goals, 'absent'), isEmpty);
    final paths = <GoalPath>[];
    traverseUp(goals, 'old',
        onVisit: (path, {required isLeaf, required childIndex}) {
      paths.add(path);
      return TraversalDecision.continueTraversal;
    });
    expect(paths, hasLength(5));
  });

  test('cyclic SetParent still detaches prior parents and notifies watches',
      () async {
    final client = await _client();
    addTearDown(client.dispose);
    await client.modifyGoals([_parent('b', 'old'), _parent('a', 'b')]);
    final watch = client.watchGoals(['old', 'root', 'a', 'b']);
    addTearDown(watch.dispose);
    await Future<void>.delayed(Duration.zero);
    final oldSnapshot = client.stateSubject.value;
    await client.modifyGoal(_parent('b', 'a', set: true));
    expect(client.stateSubject.value['b']!.superGoalIds, isEmpty);
    expect(watch.currentValue['old']!.subGoalIds, isEmpty);
    expect(watch.currentValue['b']!.superGoalIds, isEmpty);
    expect(watch.currentValue['a']!.subGoalIds, isEmpty);
    await client.undo();
    expect(watch.currentValue['old']!.subGoalIds, ['b']);
    expect(watch.currentValue['b']!.superGoalIds, ['old']);
    await client.redo();
    expect(watch.currentValue['old']!.subGoalIds, isEmpty);
    expect(watch.currentValue['b']!.superGoalIds, isEmpty);
    expect(oldSnapshot['old']!.subGoalIds, ['b'],
        reason: 'clone-on-write preserves published state');
    await client.modifyGoal(_parent('b', 'root', set: true));
    expect(client.stateSubject.value['root']!.subGoalIds, ['b']);
    await client.modifyGoal(_parent('b', null, set: true));
    expect(client.stateSubject.value['root']!.subGoalIds, isEmpty);
    expect(watch.currentValue['root']!.subGoalIds, isEmpty);
    expect(watch.currentValue['b']!.superGoalIds, isEmpty);
  });

  test('slice cycle guard retains slice identity and relationships', () async {
    final client = await _client();
    addTearDown(client.dispose);
    await client.modifyGoal(_parent('a', 'b'));
    await client.modifyGoal(_parent('b', 'a', slice: true));
    final goals = client.stateSubject.value;
    expect(goals['b']!.superGoalIds, ['a']);
    expect(goals['a']!.subGoalIds, ['b']);
    expect(
        (goals['b']!.superGoalRelationships['a'] as AddParentLogEntry).isSlice,
        isTrue);
    expect(
        await _bounded(() => getTransitiveSuperGoals(goals, 'a').keys.toList()),
        ['a', 'b']);
    await client.modifyGoal(GoalDelta(
        id: 'b',
        logEntry: RemoveParentLogEntry(
            id: 'remove', parentId: 'a', creationTime: _time)));
    expect(client.stateSubject.value['b']!.superGoalIds, isEmpty);
    expect(client.stateSubject.value['a']!.subGoalIds, isEmpty);
  });

  test(
      'two devices: A→B on one, B→A on the other, both converge acyclic '
      'after sync', () async {
    final persistence = _SharedPersistence();
    addTearDown(persistence.dispose);
    final first = await _client(persistence: persistence);
    addTearDown(first.dispose);
    await first.sync();
    // Ensure the second client starts with a strictly later wall-clock time
    // so its logical clock comes after the first client's seeded edits.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final second = await _client(persistence: persistence, seed: false);
    addTearDown(second.dispose);
    await second.sync();
    expect(second.stateSubject.value.keys, containsAll(['a', 'b', 'old', 'root']));
    expect(_edges(first.stateSubject.value), _emptyEdges);
    expect(_edges(second.stateSubject.value), _emptyEdges);

    // Partition delivery so each device performs its edit without seeing
    // the opposing relationship.
    persistence.pauseDelivery();

    await first.modifyGoal(_parent('a', 'b'));

    // Before the second device makes its edit, assert it has not seen A→B.
    expect(_edges(second.stateSubject.value), _emptyEdges,
        reason: 'second device has not seen A→B while partitioned');
    expect(_edges(first.stateSubject.value), _acyclicAUnderB,
        reason: 'first device accepted its local A→B edit');

    await second.modifyGoal(_parent('b', 'a'));

    // Assert both devices independently accepted opposite locally valid edges.
    expect(_edges(second.stateSubject.value), _acyclicBUnderA,
        reason: 'second device accepted its local B→A edit');
    expect(_edges(first.stateSubject.value), _acyclicAUnderB,
        reason: 'first device still has not seen B→A');

    // Restore delivery and sync until both devices receive all ops.
    persistence.resumeDelivery();

    bool delivered(SyncClient client) =>
        client.stateSubject.value['a']!.log.any((e) => e.id == 'a-b-add') &&
        client.stateSubject.value['b']!.log.any((e) => e.id == 'b-a-add');
    for (var i = 0; i < 20 && !(delivered(first) && delivered(second)); i++) {
      await second.sync();
      await first.sync();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    for (final client in [first, second]) {
      expect(delivered(client), isTrue,
          reason: 'both devices have received both ops');
      expect(_edges(client.stateSubject.value), _acyclicAUnderB,
          reason:
              'both devices converge to the acyclic graph of the earlier edit');
    }
  });
}
