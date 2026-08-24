/// Manual perf benchmark for [SyncClient]'s modify path.
///
/// Skipped by default — run with:
///
/// ```
/// RUN_PERF_TESTS=1 dart test test/sync/sync_client_perf_test.dart -r expanded
/// ```
///
/// The test reports median add-child latency for two corpus sizes (100 and
/// 1000 loaded goals) and the ratio between them. A 10s backstop fails the
/// test if the large case grows catastrophically; otherwise the value is in
/// the printed numbers.
import 'dart:io' show Platform;

import 'package:goals_core/src/sync/persistence_service.dart'
    show MemoryPersistenceService;
import 'package:goals_core/sync.dart'
    show
        AddParentLogEntry,
        MemoryLocalStore,
        SyncClient,
        syncPerfLogEnabled;
import 'package:goals_types/goals_types.dart' show GoalDelta;
import 'package:test/test.dart' show Timeout, expect, lessThan, test;

const _perfSkipReason =
    'manual perf benchmark — run with RUN_PERF_TESTS=1';

bool get _perfEnabled => Platform.environment['RUN_PERF_TESTS'] != null;

/// Build a SyncClient whose `_baseState` contains [corpusSize] children
/// under a single root, then time the median latency of [measuredIters]
/// add-child operations.
Future<int> _measureMedianModifyMicros({
  required int corpusSize,
  int warmupIters = 3,
  int measuredIters = 10,
}) async {
  final persistence = MemoryPersistenceService();
  // Shared local store: the producer's persistence subscription advances
  // store.cursor and stores synced ops; the measured client reuses both via
  // the shared store, so init() sees a non-null cursor and loadGoal can
  // promote children into _baseState (instead of leaking them into
  // _workingOps because baseStateCursor stayed null).
  final sharedStore = MemoryLocalStore();

  final producer = SyncClient(
    persistenceService: persistence,
    localStore: sharedStore,
  );
  await producer.init();
  await producer.modifyGoal(GoalDelta(id: 'root', text: 'root'));
  for (var i = 0; i < corpusSize; i++) {
    await producer.modifyGoal(GoalDelta(
      id: 'g$i',
      text: 'goal $i',
      logEntry: AddParentLogEntry(
        id: 'p$i',
        parentId: 'root',
        creationTime: DateTime.now(),
      ),
    ));
  }
  await persistence.settled;
  // Drain the producer's persistence-subscription microtasks so its
  // storeSyncedOps + cursor updates are fully visible before we dispose.
  await Future.delayed(Duration.zero);
  producer.dispose();

  final client = SyncClient(
    persistenceService: persistence,
    localStore: sharedStore,
  );
  await client.init();
  // init() only eager-loads root goals. Explicitly load each child so the
  // measured _baseState reflects the full corpus, matching the production
  // case where opening a goal-detail view loads its descendants.
  for (var i = 0; i < corpusSize; i++) {
    await client.loadGoal('g$i');
  }

  for (var i = 0; i < warmupIters; i++) {
    await client.modifyGoal(GoalDelta(
      id: 'warm_$i',
      text: 'warm',
      logEntry: AddParentLogEntry(
        id: 'warm_p$i',
        parentId: 'root',
        creationTime: DateTime.now(),
      ),
    ));
  }

  // One pre-measurement modify with perf logging enabled, so the test output
  // includes the per-phase breakdown. Cheap and one-shot.
  syncPerfLogEnabled = true;
  // ignore: avoid_print
  print('\n[perf-probe] one instrumented modify, corpus=$corpusSize:');
  await client.modifyGoal(GoalDelta(
    id: 'probe',
    text: 'probe',
    logEntry: AddParentLogEntry(
      id: 'probe_p',
      parentId: 'root',
      creationTime: DateTime.now(),
    ),
  ));
  syncPerfLogEnabled = false;

  final samples = <int>[];
  for (var i = 0; i < measuredIters; i++) {
    final sw = Stopwatch()..start();
    await client.modifyGoal(GoalDelta(
      id: 'meas_$i',
      text: 'meas',
      logEntry: AddParentLogEntry(
        id: 'meas_p$i',
        parentId: 'root',
        creationTime: DateTime.now(),
      ),
    ));
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  client.dispose();
  return samples[samples.length ~/ 2];
}

void main() {
  test('add-child time vs corpus size', () async {
    final small = await _measureMedianModifyMicros(corpusSize: 100);
    final large = await _measureMedianModifyMicros(corpusSize: 1000);
    final smallMs = (small / 1000).toStringAsFixed(2);
    final largeMs = (large / 1000).toStringAsFixed(2);
    final ratio = (large / small).toStringAsFixed(2);
    // ignore: avoid_print
    print('\n[perf] 100 goals:  $smallMs ms (median of 10)');
    // ignore: avoid_print
    print('[perf] 1000 goals: $largeMs ms (median of 10)');
    // ignore: avoid_print
    print('[perf] ratio:      ${ratio}x');

    // Backstop: catch catastrophic regressions even when running manually.
    // 10s leaves room for slow CI runners; the underlying numbers should
    // be in the tens of ms today and dropping after clone-on-write.
    expect(large, lessThan(10 * 1000 * 1000),
        reason:
            '1000-goal modify took ${largeMs}ms, over the 10s backstop');
  },
      timeout: Timeout(Duration(minutes: 5)),
      skip: _perfEnabled ? null : _perfSkipReason);
}
