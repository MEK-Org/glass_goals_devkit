import 'dart:math' show Random;

import 'package:goals_core/sync.dart';
import 'package:hlc/hlc.dart';
import 'package:test/test.dart';

final _time = DateTime.utc(2026, 11, 4);

/// Builds op logs whose HLCs increase in the order the ops are created.
class _Log {
  final List<Op> ops = [];
  int _seq = 0;

  String nextHlc() {
    _seq += 1;
    return HLC(timestamp: 1700000000000 + _seq, count: 0, node: 'test').pack();
  }

  DeltaOp delta(String goalId, {String? text, GoalLogEntry? entry}) {
    final op = DeltaOp(
      id: 'op-${_seq + 1}',
      hlcTimestamp: nextHlc(),
      delta: GoalDelta(id: goalId, text: text, logEntry: entry),
    );
    ops.add(op);
    return op;
  }

  void create(String goalId) => delta(goalId, text: goalId);

  DeltaOp addParent(String goalId, String parentId,
          {bool slice = false, String? entryId}) =>
      delta(goalId,
          entry: AddParentLogEntry(
              id: entryId ?? 'entry-${_seq + 1}',
              creationTime: _time,
              parentId: parentId,
              isSlice: slice));

  DeltaOp setParent(String goalId, String? parentId) => delta(goalId,
      entry: SetParentLogEntry(
          id: 'entry-${_seq + 1}', creationTime: _time, parentId: parentId));

  DeltaOp removeParent(String goalId, String parentId) => delta(goalId,
      entry: RemoveParentLogEntry(
          id: 'entry-${_seq + 1}', creationTime: _time, parentId: parentId));

  DeltaOp active(String goalId, {String? entryId}) => delta(goalId,
      entry: StatusLogEntry(
          id: entryId ?? 'entry-${_seq + 1}',
          creationTime: _time,
          status: GoalStatus.active));

  DeltaOp clearStatus(String goalId) => delta(goalId,
      entry: ClearStatusLogEntry(id: 'entry-${_seq + 1}', creationTime: _time));

  void disable(Op target) {
    final hlc = nextHlc();
    ops.add(DisableOp(id: 'op-$_seq', hlcTimestamp: hlc, opId: target.id));
  }

  void enable(Op target) {
    final hlc = nextHlc();
    ops.add(EnableOp(id: 'op-$_seq', hlcTimestamp: hlc, opId: target.id));
  }

  /// A second doc for an op id already in the log, at a newer HLC. The
  /// siliconfamiliar account has 34 such ids (#266).
  void redeliver(DeltaOp op) {
    ops.add(DeltaOp(id: op.id, hlcTimestamp: nextHlc(), delta: op.delta));
  }
}

typedef _Indexes = ({Set<String> roots, Set<String> status});

Future<_Indexes> _fetched(List<Op> ops) async {
  final store = MemoryLocalStore();
  final persistence = MemoryPersistenceService()..ops = ops;
  await InitialOpFetcher(persistenceService: persistence, localStore: store)
      .doInitialFetch();
  return (
    roots: store.getIndexGoalIds('rootGoals').toSet(),
    status: store.getIndexGoalIds('statusGoals').toSet(),
  );
}

/// The indexes of a client that folds the whole history itself. The client
/// has no lazy gaps here: every op arrives in one batch, sorted by HLC.
Future<_Indexes> _folded(List<Op> ops) async {
  final store = MemoryLocalStore();
  final sorted = [...ops]
    ..sort((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp));
  final persistence = MemoryPersistenceService()..ops = sorted;
  final client = SyncClient(localStore: store, persistenceService: persistence);
  await client.init();
  client.dispose();
  return (
    roots: store.getIndexGoalIds('rootGoals').toSet(),
    status: store.getIndexGoalIds('statusGoals').toSet(),
  );
}

/// Asserts the fetcher agrees with the fold and that both give [roots] and
/// [status], so a test can't pass with both sides wrong.
Future<void> _expectIndexes(List<Op> ops,
    {Set<String>? roots, Set<String>? status}) async {
  final fetched = await _fetched(ops);
  final folded = await _folded(ops);
  if (roots != null) {
    expect(folded.roots, roots, reason: 'fold rootGoals');
    expect(fetched.roots, roots, reason: 'fetcher rootGoals');
  }
  if (status != null) {
    expect(folded.status, status, reason: 'fold statusGoals');
    expect(fetched.status, status, reason: 'fetcher statusGoals');
  }
  expect(fetched.roots, folded.roots, reason: 'rootGoals vs fold');
  expect(fetched.status, folded.status, reason: 'statusGoals vs fold');
}

void main() {
  group('rootGoals', () {
    test('a self-link is rejected, so the goal stays a root', () async {
      final log = _Log()..create('a');
      log.addParent('a', 'a');
      await _expectIndexes(log.ops, roots: {'a'});
    });

    test('a longer cycle is rejected at the closing link', () async {
      final log = _Log()
        ..create('a')
        ..create('b')
        ..create('c');
      log.addParent('a', 'b');
      log.addParent('b', 'c');
      log.addParent('c', 'a');
      await _expectIndexes(log.ops, roots: {'c'});
    });

    test('a cycle-closing setParent still detaches the old parents', () async {
      final log = _Log()
        ..create('a')
        ..create('b')
        ..create('old');
      log.addParent('a', 'b');
      log.addParent('b', 'old');
      log.setParent('b', 'a');
      await _expectIndexes(log.ops, roots: {'b', 'old'});
    });

    test('a rejected link stays rejected after a later remove', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      log.addParent('a', 'b');
      log.addParent('b', 'a');
      log.removeParent('a', 'b');
      await _expectIndexes(log.ops, roots: {'a', 'b'});
    });

    test('disabling the other link re-admits a rejected one', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      final first = log.addParent('a', 'b');
      log.addParent('b', 'a');
      log.disable(first);
      await _expectIndexes(log.ops, roots: {'a'});
    });

    test('re-enabling the other link rejects it again', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      final first = log.addParent('a', 'b');
      log.addParent('b', 'a');
      log.disable(first);
      log.enable(first);
      await _expectIndexes(log.ops, roots: {'b'});
    });

    // #38: the re-enabled op keeps its own id, so a second disable finds it.
    test('a re-enabled parent link can be disabled again', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      final link = log.addParent('b', 'a');
      log.disable(link);
      log.enable(link);
      await _expectIndexes(log.ops, roots: {'a'});
      log.disable(link);
      await _expectIndexes(log.ops, roots: {'a', 'b'});
    });

    test('a slice link is checked with the slice id, not the goal id',
        () async {
      final log = _Log()
        ..create('g')
        ..create('p');
      log.addParent('p', 'g');
      // Would close a cycle through g, but the fold looks for the slice's id.
      log.addParent('g', 'p', slice: true);
      await _expectIndexes(log.ops, roots: {});
    });

    test('a slice link that reaches the slice id is rejected', () async {
      final log = _Log()
        ..create('g')
        ..create('p');
      log.addParent('p', 'the-slice');
      log.addParent('g', 'p', slice: true, entryId: 'the-slice');
      await _expectIndexes(log.ops, roots: {'g'});
    });

    test('a parent with no ops fails open, as in the fold', () async {
      final log = _Log()
        ..create('c')
        ..create('p')
        ..create('x');
      log.addParent('x', 'c');
      log.addParent('p', 'not-visible');
      log.addParent('p', 'x');
      // The walk meets not-visible before x's parent, so the fold allows it.
      log.addParent('c', 'p');
      await _expectIndexes(log.ops, roots: {});
    });

    test('ops read out of HLC order give the same roots', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      log.addParent('a', 'b');
      log.addParent('b', 'a');
      await _expectIndexes(log.ops.reversed.toList(), roots: {'b'});
    });

    test('a disable read before its target still applies', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      final link = log.addParent('a', 'b');
      log.disable(link);
      await _expectIndexes(log.ops.reversed.toList(), roots: {'a', 'b'});
    });

    test('a redelivered op applies at its newest HLC', () async {
      final log = _Log()
        ..create('a')
        ..create('b');
      final first = log.addParent('a', 'b');
      log.addParent('b', 'a');
      log.redeliver(first);
      await _expectIndexes(log.ops, roots: {'a'});
    });
  });

  group('statusGoals', () {
    test('a cleared status is not a status goal', () async {
      final log = _Log()..create('a');
      log.active('a');
      log.clearStatus('a');
      await _expectIndexes(log.ops, status: {});
    });

    test('a status set after a clear counts', () async {
      final log = _Log()..create('a');
      log.active('a');
      log.clearStatus('a');
      log.active('a');
      await _expectIndexes(log.ops, status: {'a'});
    });

    test('a disabled clearStatus is ignored', () async {
      final log = _Log()..create('a');
      log.active('a');
      final clear = log.clearStatus('a');
      log.disable(clear);
      await _expectIndexes(log.ops, status: {'a'});
    });

    test('a re-enabled clearStatus applies again', () async {
      final log = _Log()..create('a');
      log.active('a');
      final clear = log.clearStatus('a');
      log.disable(clear);
      log.enable(clear);
      await _expectIndexes(log.ops, status: {});
    });

    // #38: the re-enabled op keeps its own id, so a second disable finds it.
    test('a re-enabled clearStatus can be disabled again', () async {
      final log = _Log()..create('a');
      log.active('a');
      final clear = log.clearStatus('a');
      log.disable(clear);
      log.enable(clear);
      log.disable(clear);
      await _expectIndexes(log.ops, status: {'a'});
    });

    test('status ops read out of HLC order give the same result', () async {
      final log = _Log()..create('a');
      log.active('a');
      log.clearStatus('a');
      await _expectIndexes(log.ops.reversed.toList(), status: {});
    });

    test('a repeated status entry keeps its first place in the log', () async {
      final log = _Log()..create('a');
      log.active('a', entryId: 'same-entry');
      log.clearStatus('a');
      log.active('a', entryId: 'same-entry');
      await _expectIndexes(log.ops, status: {});
    });
  });

  test('goalNamesIndex still honors a disabled rename', () async {
    final log = _Log();
    log.delta('a', text: 'first');
    final rename = log.delta('a', text: 'second');
    log.disable(rename);
    final store = MemoryLocalStore();
    await InitialOpFetcher(
            persistenceService: MemoryPersistenceService()..ops = log.ops,
            localStore: store)
        .doInitialFetch();
    final index = await store.loadSearchIndex('goalNamesIndex');
    expect(index, contains('"first"'));
    expect(index, isNot(contains('"second"')));
  });

  test('random logs agree with the fold', () async {
    // Every goal starts with an op nothing disables: a goal whose every op is
    // disabled is a separate, known disagreement this fix leaves alone.
    for (var seed = 0; seed < 300; seed++) {
      final random = Random(seed);
      final goals = List.generate(2 + random.nextInt(5), (i) => 'g$i');
      final log = _Log();
      goals.forEach(log.create);
      final targets = <DeltaOp>[];
      String goal() => goals[random.nextInt(goals.length)];
      final count = 5 + random.nextInt(25);
      for (var i = 0; i < count; i++) {
        final kind = random.nextInt(10);
        if (kind < 4) {
          targets.add(
              log.addParent(goal(), goal(), slice: random.nextInt(8) == 0));
        } else if (kind == 4) {
          targets.add(
              log.setParent(goal(), random.nextInt(4) == 0 ? null : goal()));
        } else if (kind == 5) {
          targets.add(log.removeParent(goal(), goal()));
        } else if (kind == 6) {
          targets.add(log.active(goal()));
        } else if (kind == 7) {
          targets.add(log.clearStatus(goal()));
        } else if (targets.isNotEmpty) {
          final target = targets[random.nextInt(targets.length)];
          if (kind == 8) {
            log.disable(target);
          } else {
            log.enable(target);
          }
        }
      }
      final fetched = await _fetched(log.ops);
      final folded = await _folded(log.ops);
      expect(fetched.roots, folded.roots, reason: 'seed $seed rootGoals');
      expect(fetched.status, folded.status, reason: 'seed $seed statusGoals');
    }
  });
}
