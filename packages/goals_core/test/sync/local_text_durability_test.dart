import 'dart:async';

import 'package:goals_core/src/sync/local_store.dart' show CachingLocalStore;
import 'package:goals_core/src/sync/sync_repository.dart'
    show MemorySyncRepository;
import 'package:goals_core/sync.dart' show DeltaOp, GoalDelta, SyncClient;
import 'package:goals_types/goals_types.dart' show DocumentContentsEntry;
import 'package:hlc/hlc.dart' show HLC;
import 'package:test/test.dart';

/// Models an IndexedDB string transaction that has begun but has not finished.
/// The unsynced-op box is intentionally left independently writable, matching
/// Hive's separate sync box and strings collection.
class _GatedStringRepository extends MemorySyncRepository {
  final stringWriteStarted = Completer<void>();
  final stringWriteGate = Completer<void>();

  Future<void> _waitForStringWrite() async {
    if (!stringWriteStarted.isCompleted) stringWriteStarted.complete();
    await stringWriteGate.future;
  }

  @override
  Future<void> storeString(String key, String value) async {
    await _waitForStringWrite();
    await super.storeString(key, value);
  }

  @override
  Future<void> storeStrings(Map<String, String> values) async {
    await _waitForStringWrite();
    await super.storeStrings(values);
  }

  void releaseStringWrite() {
    if (!stringWriteGate.isCompleted) stringWriteGate.complete();
  }
}

void main() {
  test(
      'does not make a text op restart-visible before its string is durable '
      '(#336)', () async {
    final repository = _GatedStringRepository();
    final store = CachingLocalStore(repo: repository);
    final op = DeltaOp(
      id: 'text-op',
      hlcTimestamp:
          HLC(timestamp: 1763150000000, count: 0, node: 'guest').pack(),
      delta: GoalDelta(
        id: 'parent',
        logEntry: DocumentContentsEntry(
          id: 'parent-document',
          creationTime: DateTime.utc(2026, 11, 14),
          text: 'parent continuation survives reload',
        ),
      ),
    );
    addTearDown(repository.releaseStringWrite);

    final persist = store.setUnsyncedOps([op]);
    await repository.stringWriteStarted.future;

    // A fresh cache can only read durable repository state. If the op is
    // already in the unsynced box here, a browser restart can reconstruct an
    // empty document even though the latest operation carries complete text.
    expect(repository.getUnsyncedOps(), isEmpty,
        reason: 'the text string must commit before the unsynced operation');

    repository.releaseStringWrite();
    await persist;
    final reloadedStore = CachingLocalStore(repo: repository);
    await reloadedStore.init();
    expect(repository.getUnsyncedOps().map((stored) => stored.id), ['text-op']);
    expect(await reloadedStore.loadString('parent-document'),
        'parent continuation survives reload');
  });

  test(
      'keeps an overlapping non-text edit while a document string is pending '
      '(#336)', () async {
    final repository = _GatedStringRepository();
    final client = SyncClient(
      localStore: CachingLocalStore(repo: repository),
    );
    addTearDown(repository.releaseStringWrite);
    addTearDown(client.dispose);
    await client.init();

    final parentEdit = client.modifyGoal(GoalDelta(
      id: 'parent',
      logEntry: DocumentContentsEntry(
        id: 'parent-document',
        creationTime: DateTime.utc(2026, 11, 14),
        text: 'parent continuation survives reload',
      ),
    ));
    await repository.stringWriteStarted.future;

    // This edit has no separate string write, so the old replace-style
    // unsynced-op update can complete while the parent remains gated.
    final childEdit = client.modifyGoal(const GoalDelta(
      id: 'child',
      text: 'renamed child',
    ));
    // Let the overlapping modify reach its local write. On the old
    // replacement path it commits while the parent string transaction waits;
    // the repaired path queues that local transaction until release.
    await Future<void>.delayed(Duration.zero);

    repository.releaseStringWrite();
    await Future.wait([parentEdit, childEdit]);

    expect(repository.getUnsyncedOps().map((op) => (op as DeltaOp).delta.id),
        unorderedEquals(['parent', 'child']),
        reason: 'a gated document write must not replace an overlapping edit');
  });
}
