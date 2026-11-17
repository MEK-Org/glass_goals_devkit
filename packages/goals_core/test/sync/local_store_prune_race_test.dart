import 'dart:async';

import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

/// MemorySyncRepository whose `loadOps` can pause around the point where the
/// superclass resolves the ids, so a `loadOpsForGoal` read can be held open
/// at a deterministic spot while another `storeSyncedOps` batch lands —
/// reproducing the prune/index race from review 5944743935 without timing
/// luck.
///
/// [holdBeforeResolution] pauses the read before it resolves (the missing op
/// is genuinely absent when the read resolves). [holdAfterResolution] lets
/// the read resolve first but delays its return, so the missing op can land
/// after the read observed it missing but before `loadOpsForGoal` continues.
class _GatedLoadOpsRepository extends MemorySyncRepository {
  final bool holdBeforeResolution;
  final bool Function(List<String> opIds) gatePredicate;
  final Completer<List<String>> gateEntered = Completer();
  Completer<void>? _gate;
  var _armed = false;

  _GatedLoadOpsRepository({
    required this.gatePredicate,
    this.holdBeforeResolution = true,
  });

  void armGate() {
    _armed = true;
    _gate ??= Completer<void>();
  }

  void releaseGate() {
    _gate?.complete();
  }

  @override
  Future<Iterable<Op?>> loadOps(Iterable<String> opIds) async {
    final ids = opIds.toList();
    if (_armed && gatePredicate(ids)) {
      _armed = false;
      if (holdBeforeResolution) {
        gateEntered.complete(ids);
        await _gate!.future;
      }
      final result = await super.loadOps(ids);
      if (!holdBeforeResolution) {
        gateEntered.complete(ids);
        await _gate!.future;
      }
      return result;
    }
    return super.loadOps(ids);
  }
}

DeltaOp _textOp(String id, String hlc, String goalId, String text) => DeltaOp(
      id: id,
      hlcTimestamp: hlc,
      delta: GoalDelta(id: goalId, text: text),
    );

const _goalId = 'goalG';
final _oldOp = _textOp(
    'op_old', '001794930562329:00021:SVB5', _goalId, 'Old title');
final _incomingOp = _textOp(
    'op_incoming', '001794930965354:0004b:SVB5', _goalId, 'Incoming title');
final _danglingOp = _textOp(
    'op_dangling', '001794930858323:0007m:SVB5', _goalId, 'Late title');

Future<_GatedLoadOpsRepository> _seedRepository() async {
  final repo = _GatedLoadOpsRepository(
    gatePredicate: (ids) => ids.contains('op_dangling'),
  );
  await repo.storeSyncedOps([_oldOp]);
  await repo.storeGoalIndexEntry(_goalId, {
    'opIds': ['op_old', 'op_dangling'],
  });
  repo.cursor = _oldOp.hlcTimestamp;
  return repo;
}

Future<List<String>> _waitForGate(_GatedLoadOpsRepository repo) async {
  try {
    return await repo.gateEntered.future
        .timeout(const Duration(seconds: 10));
  } on TimeoutException {
    repo.releaseGate();
    throw StateError(
        'the loadOpsForGoal read never reached the gated repository call');
  }
}

void main() {
  group('loadOpsForGoal prune under concurrent indexing (#375)', () {
    test(
        'preserves op references indexed while the missing-op read is paused '
        '(unrelated incoming op)', () async {
      final repo = await _seedRepository();
      final store = CachingLocalStore(repo: repo);

      repo.armGate();
      final loadFuture = store.loadOpsForGoal(_goalId);
      await _waitForGate(repo);

      // While the read is paused, an unrelated op for the same goal is
      // stored and indexed and the cursor advances past it.
      await store.storeSyncedOps([_incomingOp]);
      await store.settled();
      expect(repo.cursor, _incomingOp.hlcTimestamp);

      repo.releaseGate();
      final result = await loadFuture;

      expect(result.map((op) => op.id), ['op_old']);

      // The durable entry must still reference the concurrently indexed op;
      // its HLC is <= cursor, so an incremental replay would never
      // re-deliver it.
      expect(
        (await repo.loadGoalIndexEntry(_goalId))?['opIds'],
        ['op_old', 'op_incoming'],
      );

      final coldOps =
          await CachingLocalStore(repo: repo).loadOpsForGoal(_goalId);
      expect(coldOps.map((op) => op.id), ['op_old', 'op_incoming']);
    });

    test(
        'keeps the initially missing op when it arrives while the read is '
        'paused', () async {
      // Let the read resolve [op_old, null] (op_dangling is genuinely absent
      // from the repository), then hold it before loadOpsForGoal continues.
      final resolvedRepo = _GatedLoadOpsRepository(
        gatePredicate: (ids) => ids.contains('op_dangling'),
        holdBeforeResolution: false,
      );
      await resolvedRepo.storeSyncedOps([_oldOp]);
      await resolvedRepo.storeGoalIndexEntry(_goalId, {
        'opIds': ['op_old', 'op_dangling'],
      });
      resolvedRepo.cursor = _oldOp.hlcTimestamp;
      final resolvingStore = CachingLocalStore(repo: resolvedRepo);

      resolvedRepo.armGate();
      final loadFuture = resolvingStore.loadOpsForGoal(_goalId);
      await _waitForGate(resolvedRepo);

      // The missing op lands (stored and cursor-covered) after the read saw
      // it missing but before the prune decision.
      await resolvingStore.storeSyncedOps([_danglingOp]);
      await resolvingStore.settled();
      expect(resolvedRepo.cursor, _danglingOp.hlcTimestamp);

      resolvedRepo.releaseGate();
      final result = await loadFuture;

      expect(result.map((op) => op.id), ['op_old', 'op_dangling']);
      expect(
        (await resolvedRepo.loadGoalIndexEntry(_goalId))?['opIds'],
        ['op_old', 'op_dangling'],
      );

      final coldOps = await CachingLocalStore(repo: resolvedRepo)
          .loadOpsForGoal(_goalId);
      expect(coldOps.map((op) => op.id), ['op_old', 'op_dangling']);
    });
  });
}
