import 'package:test/test.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_types/goals_types.dart';

void main() {
  group('Goal Names Index', () {
    test('creates and maintains index correctly', () async {
      // Create a SyncClient with memory store
      final persistenceService = MemoryPersistenceService();
      final localStore = MemoryLocalStore();
      final syncClient = SyncClient(
          localStore: localStore, persistenceService: persistenceService);

      await syncClient.init();

      // Create some test goals
      final goal1 = GoalDelta(id: 'test-id-1', text: 'Learn Flutter');
      final goal2 = GoalDelta(id: 'test-id-2', text: 'Build Mobile App');
      final goal3 = GoalDelta(id: 'test-id-3', text: 'Learn Dart Language');

      // Modify goals to trigger index updates
      await syncClient.modifyGoals([goal1, goal2, goal3]);
      await persistenceService.settled;

      // let all async stuff settle
      await Future.delayed(Duration(milliseconds: 1));

      // Test searching
      final flutterResults = syncClient.searchGoalsByName('flutter');
      expect(flutterResults, contains('test-id-1'));

      final learnResults = syncClient.searchGoalsByName('learn');
      expect(learnResults.length, equals(2));
      expect(learnResults, contains('test-id-1'));
      expect(learnResults, contains('test-id-3'));

      final dartResults = syncClient.searchGoalsByName('dart');
      expect(dartResults, contains('test-id-3'));
    });

    test('updates index when goal text changes', () async {
      final persistenceService = MemoryPersistenceService();
      final syncClient = SyncClient(persistenceService: persistenceService);
      await syncClient.init();

      // Create a goal
      final goal = GoalDelta(id: 'test-id', text: 'Learn Flutter');
      await syncClient.modifyGoal(goal);

      await persistenceService.settled;

      await Future.delayed(Duration(milliseconds: 1));

      // Verify it's searchable by original text
      final originalResults = syncClient.searchGoalsByName('flutter');
      expect(originalResults, contains('test-id'));

      // Update the goal text
      final updatedGoal =
          GoalDelta(id: 'test-id', text: 'Master Dart Language');
      await syncClient.modifyGoal(updatedGoal);

      await persistenceService.settled;

      await Future.delayed(Duration(milliseconds: 1));

      // Verify it's searchable by new text
      final newResults = syncClient.searchGoalsByName('dart');
      expect(newResults, contains('test-id'));

      // Verify it's no longer searchable by old text
      final oldResults = syncClient.searchGoalsByName('flutter');
      expect(oldResults, isNot(contains('test-id')));
    });

    test('handles case-insensitive search', () async {
      final persistenceService = MemoryPersistenceService();
      final syncClient = SyncClient(persistenceService: persistenceService);
      await syncClient.init();

      final goal = GoalDelta(id: 'test-id', text: 'Learn Flutter Framework');
      await syncClient.modifyGoal(goal);
      await persistenceService.settled;

      await Future.delayed(Duration(milliseconds: 1));

      // Test case-insensitive search
      expect(syncClient.searchGoalsByName('flutter'), contains('test-id'));
      expect(syncClient.searchGoalsByName('FLUTTER'), contains('test-id'));
      expect(syncClient.searchGoalsByName('Flutter'), contains('test-id'));
      expect(syncClient.searchGoalsByName('learn'), contains('test-id'));
      expect(syncClient.searchGoalsByName('LEARN'), contains('test-id'));
    });

    test('handles empty search correctly', () async {
      final syncClient = SyncClient();
      await syncClient.init();

      final goal = GoalDelta(id: 'test-id', text: 'Test Goal');
      await syncClient.modifyGoal(goal);

      // Empty search should return empty results
      expect(syncClient.searchGoalsByName(''), isEmpty);
    });

    // Regression for MEK-Org/glass_goals#77 (Matt's explicit ask on PR #78):
    // search must return goal ids for goals that a fresh client has NEVER
    // loaded into its resident working set. On init a client eagerly loads
    // only root goals (and, transitively, their direct children via the
    // parent-indexed AddParentLogEntry edge). A *grandchild* of a root is
    // therefore never resident until an explicit loadGoal — yet search must
    // still find it, because search reads the persisted name index, not the
    // resident state. (The modal fix in PR #78 folds resident state in for the
    // freshly-created-this-session case; this test covers the complementary
    // case where the goal exists on disk but was never loaded at all.)
    //
    // Build the corpus with a short-lived *producer* client, then dispose it so
    // the shared localStore's cursor is advanced, and open a fresh *consumer*
    // client over the same store+persistence — the corpus is then
    // promotable-but-not-resident (same idiom as
    // sync_client_eviction_test.dart's `_setupConsumerWithCorpus`).
    test(
        'search returns ids for goals never loaded into the working set '
        '(persisted grandchildren of an unloaded subtree) (#77)', () async {
      final persistence = MemoryPersistenceService();
      final store = MemoryLocalStore();

      final producer =
          SyncClient(persistenceService: persistence, localStore: store);
      await producer.init();

      // root -> child -> grandchild. The grandchild's only parent edge is
      // indexed under the child (never under the root), so loading the root on
      // consumer init never pulls the grandchild into resident state. Its text
      // is the search target.
      await producer.modifyGoals([
        GoalDelta(id: 'root-goal', text: 'Root planning goal'),
        GoalDelta(
            id: 'child-goal',
            text: 'Child goal',
            logEntry: AddParentLogEntry(
              id: 'e-child-parent',
              parentId: 'root-goal',
              creationTime: DateTime(2026, 1, 1),
            )),
        GoalDelta(
            id: 'grandchild-goal',
            text: 'Subterranean grandchild goal',
            logEntry: AddParentLogEntry(
              id: 'e-grandchild-parent',
              parentId: 'child-goal',
              creationTime: DateTime(2026, 1, 1),
            )),
      ]);
      await persistence.settled;
      // Drain the persistence-subscription microtasks so the shared cursor and
      // the persisted name index reflect every saved op before we dispose.
      await Future<void>.delayed(Duration.zero);
      producer.dispose();

      // Fresh consumer over the same store: it loads the persisted name index
      // and eagerly loads only the root subtree, leaving the grandchild
      // unloaded.
      final consumer =
          SyncClient(persistenceService: persistence, localStore: store);
      await consumer.init();

      // Precondition: the grandchild really is absent from the resident working
      // set — this is what "never loaded" means for the modal's stateSubject
      // fold, and it is the condition that makes the search guarantee below
      // non-trivial.
      expect(consumer.stateSubject.value.containsKey('grandchild-goal'),
          isFalse,
          reason: 'grandchild of a root must not be eagerly loaded on init');

      // The guarantee Matt asked us to confirm: search returns the id of a goal
      // that was never loaded into the working set of goals.
      expect(consumer.searchGoalsByName('subterranean'),
          contains('grandchild-goal'),
          reason:
              'search must return goal ids for goals absent from the resident '
              'working set, via the persisted name index');

      consumer.dispose();
    });
  });
}
