import 'package:goals_core/sync.dart'
    show SyncClient, MemoryLocalStore, AddParentLogEntry;
import 'package:goals_core/src/sync/persistence_service.dart'
    show MemoryPersistenceService;
import 'package:goals_types/goals_types.dart' show GoalDelta;
import 'package:test/test.dart'
    show equals, expect, group, isFalse, isTrue, test;

/// These tests pin down the contract the flattened goal tree relies on:
///
///   "When `modifyGoal`/`modifyGoals` resolves, a watch on the affected
///    parent already reflects the change — including a brand-new child —
///    in its synchronous [WatchedGoalSet.currentValue], with no further
///    pumping or refresh."
///
/// This is what lets a consumer await the mutation and then render in the
/// same turn (e.g. advance focus) without a one-frame flash, and without the
/// "added goal doesn't show up until something else triggers a refresh" bug.
SyncClient _newClient() => SyncClient(
      persistenceService: MemoryPersistenceService(),
      localStore: MemoryLocalStore(),
    );

void main() {
  group('reactive watch sets', () {
    test('a watched parent adopts a newly-added child by the time the '
        'modify future resolves', () async {
      final client = _newClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'p', text: 'parent'));

      final watch = client.watchGoals(['p']);
      // Let the initial seed/load for the watched parent settle.
      await Future<void>.delayed(Duration.zero);
      expect(watch.currentValue.containsKey('p'), isTrue);
      expect(watch.currentValue.containsKey('c'), isFalse);

      await client.modifyGoal(GoalDelta(
        id: 'c',
        text: 'child',
        logEntry: AddParentLogEntry(
          id: 'e1',
          parentId: 'p',
          creationTime: DateTime.now(),
        ),
      ));

      // No extra delay / no pump: the moment the future resolves the watch
      // must already carry the child.
      expect(watch.currentValue.containsKey('c'), isTrue,
          reason: 'reactive adoption: a watched parent should pull in its '
              'newly-added child synchronously by the time modify resolves');
      expect(watch.currentValue['c']!.text, equals('child'));
      expect(watch.currentValue['p']!.subGoalIds.contains('c'), isTrue);

      await watch.dispose();
    });

    test('an adopted child is dropped again once the parent no longer lists it',
        () async {
      final client = _newClient();
      await client.init();
      await client.modifyGoal(GoalDelta(id: 'p', text: 'parent'));

      final watch = client.watchGoals(['p']);
      await Future<void>.delayed(Duration.zero);

      await client.modifyGoal(GoalDelta(
        id: 'c',
        text: 'child',
        logEntry: AddParentLogEntry(
          id: 'e1',
          parentId: 'p',
          creationTime: DateTime.now(),
        ),
      ));
      expect(watch.currentValue.containsKey('c'), isTrue);

      // Explicitly narrowing the watch back to just the parent unpins the
      // adopted child — adoption is a transient bridge, reconciled by the
      // consumer's next setIds.
      watch.setIds(['p']);
      expect(watch.currentValue.containsKey('c'), isFalse);

      await watch.dispose();
    });
  });
}
