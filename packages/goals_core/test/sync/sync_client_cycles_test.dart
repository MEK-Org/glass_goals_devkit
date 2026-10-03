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

Future<SyncClient> _client() async {
  final client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService());
  await client.init();
  await client.modifyGoals([
    for (final id in ['a', 'b', 'old', 'root']) GoalDelta(id: id, text: id)
  ]);
  return client;
}

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
}
