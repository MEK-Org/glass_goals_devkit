import 'dart:math';

import 'package:goals_core/model.dart' show Goal, getDocumentEntry;
import 'package:goals_core/src/model.dart' show GoalPath;
import 'package:goals_core/src/sync/persistence_service.dart'
    show MemoryPersistenceService;
import 'package:goals_core/src/sync/sync_logger.dart' show MemoryEventLogger;
import 'package:goals_core/sync.dart'
    show
        SyncClient,
        MemoryLocalStore,
        AddParentLogEntry,
        RemoveParentLogEntry,
        Op;
import 'package:goals_types/goals_types.dart'
    show
        CreateInstanceLogEntry,
        GoalDelta,
        SetParentLogEntry,
        DocumentContentsEntry;
import 'package:test/test.dart'
    show
        contains,
        equals,
        expect,
        greaterThan,
        isNotNull,
        isNull,
        test;

Future<void> initState(SyncClient client) async {
  await client.modifyGoal(GoalDelta(
    id: '0',
    text: 'root',
  ));

  await client.modifyGoal(GoalDelta(
    id: '2',
    text: 'bar',
  ));

  await client.modifyGoal(GoalDelta(
    id: '2',
    logEntry: AddParentLogEntry(
      id: '3',
      parentId: '0',
      creationTime: DateTime.now(),
    ),
  ));
}

void main() {
  test('add subgoal', () async {
    final client = SyncClient();

    await client.init();

    await initState(client);

    await client.modifyGoal(GoalDelta(
        id: '1',
        text: 'foo',
        logEntry: SetParentLogEntry(
            id: '3', parentId: '0', creationTime: DateTime.now())));

    final goals = client.stateSubject.value;

    expect(goals['0']!.subGoalIds.length, equals(2));

    expect(goals[goals['0']!.subGoalIds.toList()[1]]!.text, equals('foo'));
  });

  test('add subsubgoal', () async {
    final client = SyncClient();
    await client.init();

    await initState(client);

    await client.modifyGoal(GoalDelta(
        id: '3',
        text: 'foo',
        logEntry: AddParentLogEntry(
            id: '3', parentId: '2', creationTime: DateTime.now())));

    final goals = client.stateSubject.value;

    expect(goals['0']!.subGoalIds.length, equals(1));

    final [subGoalId] = goals['0']!.subGoalIds.toList();
    expect(goals[subGoalId]!.text, equals('bar'));

    expect(goals[subGoalId]!.subGoalIds.length, equals(1));

    expect(goals[goals[subGoalId]!.subGoalIds.first]!.text, equals('foo'));
  });

  test('modifies existing goal', () async {
    final client = SyncClient();
    await client.init();

    await initState(client);
    await client.modifyGoal(GoalDelta(
        id: '2',
        text: 'foo',
        logEntry: AddParentLogEntry(
            id: '3', parentId: '0', creationTime: DateTime.now())));

    final goals = client.stateSubject.value;

    expect(goals['0']!.subGoalIds.length, equals(1));

    expect(goals[goals['0']!.subGoalIds.first]!.text, equals('foo'));
  });

  test('applies 2 ops', () async {
    final client = SyncClient();
    await client.init();

    await initState(client);

    await client.modifyGoals([
      GoalDelta(
          id: '3',
          text: 'foo',
          logEntry: AddParentLogEntry(
              id: '4', parentId: '2', creationTime: DateTime.now())),
      GoalDelta(
          id: '4',
          text: 'baz',
          logEntry: AddParentLogEntry(
              id: '5', parentId: '3', creationTime: DateTime.now())),
    ]);

    final goals = client.stateSubject.value;

    final parentGoal = goals['3']!;

    expect(parentGoal.subGoalIds.length, equals(1));

    final childGoalId = parentGoal.subGoalIds.first;
    expect(goals[childGoalId]!.text, equals('baz'));
  });

  test('rehomes goal', () async {
    final client = SyncClient();
    await client.init();

    await initState(client);

    await client.modifyGoal(GoalDelta(
        id: '3',
        text: 'foo',
        logEntry: AddParentLogEntry(
            id: '4', parentId: '2', creationTime: DateTime.now())));

    var goals = client.stateSubject.value;

    var parentGoal = goals['2']!;

    expect(parentGoal.subGoalIds.length, equals(1));

    final childGoalId = parentGoal.subGoalIds.first;
    expect(goals[childGoalId]!.text, equals('foo'));

    await client.modifyGoals([
      GoalDelta(
        id: '3',
        logEntry: RemoveParentLogEntry(
            id: '5', parentId: '2', creationTime: DateTime.now()),
      ),
      GoalDelta(
          id: '3',
          text: 'foo',
          logEntry: AddParentLogEntry(
              id: '6', parentId: '0', creationTime: DateTime.now())),
    ]);

    goals = client.stateSubject.value;

    parentGoal = goals['2']!;
    expect(parentGoal.subGoalIds.length, equals(0));
    final newParentGoal = goals['0']!;

    expect(newParentGoal.subGoalIds, contains(childGoalId));
    expect(goals[goals[childGoalId]!.superGoalIds.first]!.id, equals('0'));
  });

  test('undo', () async {
    final client = SyncClient();
    await client.init();

    await client.modifyGoal(GoalDelta(
      id: '0',
      text: 'root',
    ));
    await client.modifyGoal(GoalDelta(
      id: '2',
      text: 'bar',
    ));
    await client.modifyGoal(
      GoalDelta(
          id: '2',
          text: 'foo',
          logEntry: SetParentLogEntry(
              id: '2', parentId: '0', creationTime: DateTime.now())),
    );
    await client.modifyGoal(
      GoalDelta(
          id: '3',
          text: 'foo',
          logEntry: SetParentLogEntry(
              id: '3', parentId: '2', creationTime: DateTime.now())),
    );

    final initialState = client.stateSubject.value;

    var parentGoal = initialState['2']!;

    expect(parentGoal.subGoalIds.length, equals(1));

    var childGoalId = parentGoal.subGoalIds.first;
    expect(initialState[childGoalId]!.text, equals('foo'));

    await client.modifyGoal(
      GoalDelta(
          id: '3',
          text: 'foo',
          logEntry: SetParentLogEntry(
              id: '4', parentId: '0', creationTime: DateTime.now())),
    );

    final newState = client.stateSubject.value;

    parentGoal = newState['2']!;

    expect(parentGoal.subGoalIds.length, equals(0));
    final newParentGoal = newState['0']!;

    final newChildGoal = newState['3']!;
    expect(newParentGoal.subGoalIds, contains(childGoalId));
    expect(newChildGoal.superGoalIds.first, equals('0'));

    await client.undo();
    final undoneState = client.stateSubject.value;

    parentGoal = undoneState['2']!;

    expect(parentGoal.subGoalIds.length, equals(1));

    childGoalId = parentGoal.subGoalIds.first;
    expect(undoneState[childGoalId]!.text, equals('foo'));

    await client.redo();

    final redoneState = client.stateSubject.value;

    parentGoal = redoneState['2']!;

    expect(parentGoal.subGoalIds.length, equals(0));
    final redoneParentGoal = redoneState['0']!;

    final redoneChildGoal = redoneState['3']!;
    expect(redoneParentGoal.subGoalIds, contains(childGoalId));
    expect(redoneChildGoal.superGoalIds.first, equals('0'));
  });

  test('indexed correctly', () async {
    final persistenceService = MemoryPersistenceService();
    final store = MemoryLocalStore();
    final client1 = SyncClient(
      persistenceService: persistenceService,
      localStore: store,
    );

    await client1.init();

    await client1.modifyGoal(GoalDelta(
      id: '0',
      text: 'root',
    ));

    final goal = client1.stateSubject.value['0'];
    expect(goal!.text, equals('root'));

    await Future.delayed(Duration.zero);

    final indexEntry = store.goalIndex['0'];
    expect(indexEntry, isNotNull, reason: "Goal '0' should be indexed");

    final opIds = indexEntry?['opIds'];
    expect(opIds?.length, equals(1), reason: "Goal '0' should have one op");
  });

  test('undo, persistence', () async {
    final persistenceService = MemoryPersistenceService();
    final store = MemoryLocalStore();
    final client1 = SyncClient(
      persistenceService: persistenceService,
      localStore: store,
    );

    await client1.init();

    await client1.modifyGoal(GoalDelta(
      id: '0',
      text: 'root',
    ));

    await client1.undo();

    final undoneGoal = client1.stateSubject.value['0'];

    expect(undoneGoal, isNull,
        reason: "Goal '0' should not exist after undoing the creation");

    // Wait for persistence writes to complete.
    await Future.delayed(Duration.zero);

    final undoneIndexEntry = await store.repo.loadGoalIndexEntry('0');
    expect(undoneIndexEntry, isNotNull, reason: "Goal '0' is still indexed");

    final undoneOpIds = undoneIndexEntry?['opIds'];
    expect(undoneOpIds?.length, equals(2),
        reason: "Goal '0' should have two ops");

    final client2 = SyncClient(
      persistenceService: persistenceService,
      localStore: store,
    );

    await client2.init();

    final goals2 = client2.stateSubject.value;
    expect(goals2['0'], isNull,
        reason: "Goal '0' should not exist in client2 after undoing");
  });

  test('redo, persistence', () async {
    final persistenceService = MemoryPersistenceService();
    final store = MemoryLocalStore();
    final logger = MemoryEventLogger();
    final client1 = SyncClient(
      persistenceService: persistenceService,
      localStore: store,
      logger: logger,
    );

    await client1.init();

    await client1.modifyGoal(GoalDelta(
      id: '0',
      text: 'root',
    ));

    await client1.undo();

    await client1.redo();

    final redoneGoal = client1.stateSubject.value['0'];

    expect(redoneGoal!.text, equals('root'),
        reason: "Goal '0' should exist after being redone");

    await Future.delayed(Duration.zero);

    final redoneIndexEntry = await store.repo.loadGoalIndexEntry('0');
    expect(redoneIndexEntry, isNotNull, reason: "Goal '0' is still indexed");

    final redoneOpIds = redoneIndexEntry?['opIds'];
    expect(redoneOpIds?.length, equals(3),
        reason: "Goal '0' should have three ops");

    final client2 = SyncClient(
      persistenceService: persistenceService,
      localStore: store,
    );

    await client2.init();

    final goals2 = client2.stateSubject.value;
    expect(goals2['0']!.text, equals('root'),
        reason: "Goal '0' should not exist in client2 after undoing");
  });

  test('create instance', () async {
    final client = SyncClient();
    await client.init();

    await initState(client);

    final newInstanceId = '4';
    await client.modifyGoal(GoalDelta(
        id: '2',
        logEntry: CreateInstanceLogEntry(
            id: newInstanceId, creationTime: DateTime.now())));

    final goals = client.stateSubject.value;

    final goal = goals['2']!;

    expect(goal, isNotNull);

    final instance = goals[newInstanceId]!;

    expect(instance.text, equals('bar'));
  });

  test('modifying a not-yet-loaded grandchild causes it to load', () async {
    final sharedLocalStore = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    // Setup client (client1) to establish the backend state
    final client1 = SyncClient(
        localStore: sharedLocalStore,
        persistenceService: MemoryPersistenceService());
    await client1.init();

    // R (root)
    await client1.modifyGoal(GoalDelta(id: 'R', text: 'Root Goal'));
    //   C1 (child of R)
    await client1.modifyGoal(GoalDelta(
        id: 'C1',
        text: 'Child 1',
        logEntry: AddParentLogEntry(
            id: 'logC1_partial_load_test', // Unique log ID
            parentId: 'R',
            creationTime: DateTime.now())));
    //     G1.1 (child of C1, text: "initial text")
    await client1.modifyGoal(GoalDelta(
        id: 'G1.1',
        text: 'Grandchild 1.1 initial',
        logEntry: AddParentLogEntry(
            id: 'logG1.1_partial_load_test', // Unique log ID
            parentId: 'C1',
            creationTime: DateTime.now())));

    final state1 = client1.stateSubject.value;

    expect(state1['R'], isNotNull,
        reason: "Root R should be loaded by client1");
    expect(state1['C1'], isNotNull,
        reason: "Child C1 should be loaded by client1");
    expect(state1['G1.1'], isNotNull,
        reason: "Grandchild G1.1 should be loaded by client1");

    // do this to avoid hlc collisions
    await Future.delayed(Duration(milliseconds: 1));

    // Test client (client2)
    final client2 = SyncClient(
        localStore: sharedLocalStore, persistenceService: persistenceService);
    await client2.init();

    var state2 = client2.stateSubject.value;
    expect(state2['C1'], isNull,
        reason: "Child C1 should not be loaded by client2, initially");

    // Crucial assumption for this test: G1.1 is not loaded by the initial sync of client2.
    // This assertion verifies that precondition for the test.
    // If SyncClient always fully loads, this expect will fail,
    // indicating this test isn't testing "on-demand loading" but "modification".
    // With MemoryLocalStore, it appears G1.1 IS loaded.
    expect(state2['G1.1'], isNull,
        reason:
            "Grandchild G1.1 should not be loaded initially by client2 when using a shared MemoryLocalStore");

    // Now, client2 modifies G1.1.
    await client2.modifyGoal(GoalDelta(
        id: 'G1.1',
        logEntry: DocumentContentsEntry(
            id: 'G1.1_DocContents', creationTime: DateTime.now())));

    state2 = client2.stateSubject.value;

    expect(state2['G1.1'], isNotNull,
        reason: "Grandchild G1.1 should be loaded after modification");
    expect(state2['G1.1']!.text, equals('Grandchild 1.1 initial'),
        reason: "G1.1 text should be updated");
    expect(state2['G1.1']!.superGoalIds, contains('C1'),
        reason: "G1.1 should list C1 as a supergoal");
  });

  test('edit goal without goal name', () async {
    final store = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    // Setup client (client1)
    final client1 =
        SyncClient(localStore: store, persistenceService: persistenceService);
    await client1.init();

    // R (root)
    await client1.modifyGoal(GoalDelta(id: 'R', text: 'Root Goal'));

    expect(
      persistenceService.ops.length,
      equals(1),
    );

    await Future.delayed(Duration.zero);

    expect(
      store.opCache.length,
      equals(1),
    );

    expect(
      client1.stateSubject.value['R']!.text,
      equals('Root Goal'),
    );

    final indexEntry = store.goalIndex['R'];
    final opIds = indexEntry?['opIds'];

    expect(
      opIds.length,
      equals(1),
    );

    await client1.modifyGoal(GoalDelta(
        id: 'R',
        logEntry: DocumentContentsEntry(
          id: 'Document',
          creationTime: DateTime.now(),
          text: "This is a document",
        )));

    await Future.delayed(Duration.zero);

    final goalIndexEntry1 = store.goalIndex['R'];
    final opIds1 = goalIndexEntry1?['opIds'];

    expect(
      opIds1.length,
      equals(2),
    );

    final docEntry =
        getDocumentEntry(GoalPath(["R"]), goalMap: client1.stateSubject.value);

    final docContents = await client1.loadString(docEntry!.id);

    expect(
      docContents,
      equals('This is a document'),
    );
  });

// This test was used to investigate what seemed like unnecessary saves,
// this happens because we persist the ops immediately after a successful
// op push to the server and the server returns the same op which we also store.
// In practice, this is not an issue because the save is idempotent,
  test('not performing unnecessary saves', () async {
    final store = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    // Setup client (client1)
    final client1 =
        SyncClient(localStore: store, persistenceService: persistenceService);
    await client1.init();

    // R (root)
    await client1.modifyGoal(GoalDelta(id: 'R', text: 'Root Goal'));

    expect(
      persistenceService.ops.length,
      equals(1),
    );

    // wait for the persistence to complete
    await Future.delayed(Duration.zero);

    expect(
      store.opCache.length,
      equals(1),
    );

    expect(
      client1.stateSubject.value['R']!.text,
      equals('Root Goal'),
    );

    final goalIndexEntry = store.goalIndex['R'];
    final opIds = goalIndexEntry?['opIds'];

    expect(
      opIds.length,
      equals(1),
    );
  });

  test('simulate reload', () async {
    final store1 = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    final sequenceOfStates = <Map<String, Goal>>[];

    // Setup client (client1)
    final client1 =
        SyncClient(localStore: store1, persistenceService: persistenceService);

    await client1.init();

    client1.stateSubject.listen((state) {
      sequenceOfStates.add(state);
    });

    await initState(client1);

    final goals1 = client1.stateSubject.value;

    expect(goals1['0']!.text, equals('root'));
    expect(goals1['2']!.text, equals('bar'));

    // allow persistence to complete
    await Future.delayed(Duration.zero);

    final logger = MemoryEventLogger();
    final client2 = SyncClient(
        localStore: store1,
        persistenceService: persistenceService,
        logger: logger);
    await client2.init();

    final goals2 = client2.stateSubject.value;

    // Root will be loaded because it is a root goal.
    expect(goals2['0']!.text, equals('root'));
    expect(goals2['2'], isNull);

    await client2.loadGoal('0');

    expect(goals2['0']!.text, equals('root'));
  });

  test("async emit reflects the modification once its future resolves",
      () async {
    final store1 = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    // Setup client (client1)
    final client1 =
        SyncClient(localStore: store1, persistenceService: persistenceService);

    await client1.init();

    final modification = client1.modifyGoal(GoalDelta(
      id: '0',
      text: 'root',
    ));

    // Emission is no longer synchronous: nothing is reflected in
    // `stateSubject` before the modify future resolves.
    expect(client1.stateSubject.value['0'], isNull);

    await modification;

    // By the time the future resolves, the state has been emitted.
    final rootGoal = client1.stateSubject.value['0'];
    expect(rootGoal, isNotNull);
    expect(rootGoal!.text, equals('root'));

    // Let the persistence subscription settle so the goal index is written.
    await Future.delayed(Duration.zero);
    final indexEntry = store1.goalIndex['0'];
    final opIds = indexEntry?['opIds'] as Iterable<String>;
    expect(opIds.length, equals(1));
  });

  test("loadGoal correctly loads goal", () async {
    final store1 = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();
    final logger = MemoryEventLogger();

    // Setup client (client1)
    final client1 = SyncClient(
        localStore: store1,
        persistenceService: persistenceService,
        logger: logger);

    await client1.init();

    await initState(client1);

    // flush any outstanding notifications
    // from persistenceService
    await persistenceService.settled;

    final logger2 = MemoryEventLogger();
    final client2 = SyncClient(
        localStore: store1,
        persistenceService: persistenceService,
        logger: logger2);

    await client2.init();

    final goal2 = await client2.loadGoal('2');

    expect(goal2?.text, equals('bar'));
  });

  test("simple reload test", () async {
    final store = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();
    final logger1 = MemoryEventLogger();

    // Setup client (client1)
    final client1 = SyncClient(
        localStore: store,
        persistenceService: persistenceService,
        logger: logger1);

    await client1.init();

    await initState(client1);

    // creating grandchild goal
    await client1.modifyGoal(GoalDelta(
        id: '3',
        text: 'foo',
        logEntry: AddParentLogEntry(
            id: '4', parentId: '2', creationTime: DateTime.now())));

    // flush any outstanding notifications
    // from persistenceService
    await persistenceService.settled;

    final logger2 = MemoryEventLogger();
    final client2 = SyncClient(
        localStore: store,
        persistenceService: persistenceService,
        logger: logger2);

    await client2.init();

    expect(client2.stateSubject.value['2'], isNull,
        reason: "Goal '2' is not initially loaded in client2");
    expect(client2.stateSubject.value['3'], isNull,
        reason: "Goal '3' is not initially loaded in client2");

    final goal3 = await client2.loadGoal('3');

    expect(goal3, isNotNull, reason: "Goal '3' should be loaded");
    expect(goal3!.text, equals('foo'), reason: "Goal '3' text should be 'foo'");
    expect(goal3.superGoalIds, contains('2'),
        reason: "Goal '3' should have '2' as a supergoal");

    expect(client2.stateSubject.value['2'], isNull,
        reason: "Loading Goal '3' should not load Goal '2'");
  });

  test(
      "loadGoal should load child relationships even if child has already been loaded",
      () async {
    final store = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();
    final logger1 = MemoryEventLogger();

    // Setup client (client1)
    final client1 = SyncClient(
        localStore: store,
        persistenceService: persistenceService,
        logger: logger1);

    await client1.init();

    await initState(client1);

    // this is a sibling of '2'
    await client1.modifyGoal(GoalDelta(
        id: '4',
        text: 'Child 2',
        logEntry: AddParentLogEntry(
            id: '5', parentId: '0', creationTime: DateTime.now())));

    // creating a grandchild goal
    await client1.modifyGoal(GoalDelta(
        id: '3',
        text: 'Grandchild',
        logEntry: AddParentLogEntry(
            id: '4', parentId: '2', creationTime: DateTime.now())));

    // also parenting '3' to '4'
    await client1.modifyGoal(GoalDelta(
        id: '3',
        logEntry: AddParentLogEntry(
            id: '6', parentId: '4', creationTime: DateTime.now())));

    // flush any outstanding notifications
    // from persistenceService
    await persistenceService.settled;

    final logger2 = MemoryEventLogger();
    final client2 = SyncClient(
        localStore: store,
        persistenceService: persistenceService,
        logger: logger2);

    await client2.init();

    expect(client2.stateSubject.value['2'], isNull,
        reason: "Goal '2' is not initially loaded in client2");
    expect(client2.stateSubject.value['3'], isNull,
        reason: "Goal '3' is not initially loaded in client2");
    expect(client2.stateSubject.value['4'], isNull,
        reason: "Goal '3' is not initially loaded in client2");

    final goal2 = await client2.loadGoal('2');

    expect(goal2?.text, equals("bar"), reason: "Goal '2' should be loaded");

    final goal3 = await client2.loadGoal('3');

    expect(goal3?.text, equals("Grandchild"),
        reason: "Goal '3' should be loaded");

    expect(goal3?.superGoalIds, contains('2'));
    expect(goal3?.superGoalIds, contains('4'));

    final goal4 = await client2.loadGoal('4');

    expect(goal4?.text, equals("Child 2"), reason: "Goal '4' should be loaded");
    expect(goal4?.superGoalIds, contains('0'),
        reason: "Goal '4' should have '0' as a supergoal");
    expect(goal4?.subGoalIds, contains('3'));
  });

  test('remote ops for already-loaded goals trigger a stateSubject emit',
      () async {
    final sharedPersistenceService = MemoryPersistenceService();

    final client1 = SyncClient(
      persistenceService: sharedPersistenceService,
      localStore: MemoryLocalStore(),
    );
    await client1.init();

    // Create a root goal that both clients will share.
    await client1.modifyGoal(GoalDelta(id: 'A', text: 'initial'));
    await sharedPersistenceService.settled;

    // Set up client2 against the same persistence service. After init,
    // client2 should have goal 'A' loaded as a root goal.
    final client2 = SyncClient(
      persistenceService: sharedPersistenceService,
      localStore: MemoryLocalStore(),
    );
    await client2.init();
    await sharedPersistenceService.settled;
    await Future.delayed(Duration.zero);

    expect(client2.stateSubject.value['A']?.text, equals('initial'),
        reason: "precondition: goal 'A' should be loaded in client2");

    // Subscribe to client2's state stream and count emissions from this
    // point forward. The initial replayed BehaviorSubject value lands in
    // the first microtask, so drain that before recording the baseline.
    var emissionCount = 0;
    final sub = client2.stateSubject.listen((_) => emissionCount++);
    await Future.delayed(Duration.zero);
    final baselineEmissions = emissionCount;

    // Avoid an HLC tie with the previous op.
    await Future.delayed(Duration(milliseconds: 1));

    // client1 mutates goal 'A'. The shared persistence service should
    // broadcast the resulting op to client2's persistence subscription.
    await client1.modifyGoal(GoalDelta(id: 'A', text: 'updated'));
    await sharedPersistenceService.settled;
    // Give client2's persistence subscription handler time to process.
    await Future.delayed(Duration(milliseconds: 10));

    await sub.cancel();

    expect(emissionCount, greaterThan(baselineEmissions),
        reason:
            "client2's stateSubject should emit after receiving a remote op for an already-loaded goal");
    expect(client2.stateSubject.value['A']?.text, equals('updated'),
        reason: "client2's emitted state should reflect the remote update");
  });
}
