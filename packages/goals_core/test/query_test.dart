import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

// Helper function to initialize a SyncClient and add a root goal.
Future<SyncClient> _initializeClientWithRootGoal(SyncClient client) async {
  await client.init();
  // Create the 'root' goal with id '0' and text 'root'
  await client.modifyGoal(GoalDelta(id: '0', text: 'root'));
  return client;
}

void main() {
  test('getActiveGoalExpiringSoonest', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);

    await client.modifyGoal(
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '1',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12),
              startTime: DateTime(2020, 1, 1, 12),
              endTime: DateTime(2020, 1, 1, 12))),
    );

    expect(
        getActiveGoalExpiringSoonest(
            WorldContext(time: DateTime(2020, 1, 1, 13)),
            client.stateSubject.value),
        isNull);
  });

  test('getActiveGoalExpiringSoonest, unset active', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);

    // The '0' goal is already created by _initializeClientWithRootGoal.
    // These modifyGoals calls will further update it.
    await client.modifyGoals([
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '1',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12),
              startTime: DateTime(2020, 1, 1, 12),
              endTime: DateTime(2020, 1, 2, 12))),
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '2',
              creationTime: DateTime(2020, 1, 1, 13),
              startTime: DateTime(2020, 1, 1, 13))),
    ]);

    expect(
        getActiveGoalExpiringSoonest(
            WorldContext(time: DateTime(2020, 1, 1, 14)),
            client.stateSubject.value),
        isNull);
  });

  test('getGoalStatus, happy path', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);
    await client.sync(); // Keep sync if it was there for specific test timing

    await client.modifyGoal(GoalDelta(
        id: '0',
        logEntry: StatusLogEntry(
            id: '1',
            status: GoalStatus.active,
            creationTime: DateTime(2020, 1, 1, 12),
            startTime: DateTime(2020, 1, 1, 12),
            endTime: DateTime(2020, 1, 2, 12))));

    final goals = client.stateSubject.value;

    expect(
        getGoalStatus(WorldContext(time: DateTime(2020, 1, 1, 14)), goals['0']!)
            ?.status,
        equals(GoalStatus.active));
  });

  test('getGoalStatus, archived status', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);
    await client.sync(); // Keep sync if it was there for specific test timing

    await client.modifyGoal(GoalDelta(
        id: '0',
        logEntry: StatusLogEntry(
            id: '1',
            status: GoalStatus.active,
            creationTime: DateTime(2020, 1, 1, 12),
            startTime: DateTime(2020, 1, 1, 12),
            endTime: DateTime(2020, 1, 2, 12))));

    await client.modifyGoal(GoalDelta(
        id: '0',
        logEntry: ArchiveStatusLogEntry(
          id: '1',
          creationTime: DateTime(2020, 1, 1, 13),
        )));

    final goals = client.stateSubject.value;

    final status = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 14)), goals['0']!);
    expect(status, isNotNull);
    expect(status?.status, equals(null));
  });

  test('getGoalStatus, patches', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);

    await client.modifyGoals([
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '1',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12),
              startTime: DateTime(2020, 1, 1, 12),
              endTime: DateTime(2020, 1, 2, 12))),
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '2',
              creationTime: DateTime(2020, 1, 1, 13),
              startTime: DateTime(2020, 1, 1, 13),
              endTime: DateTime(2020, 1, 1, 14))),
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '3',
              creationTime: DateTime(2020, 1, 1, 15),
              startTime: DateTime(2020, 1, 1, 15),
              endTime: DateTime(2020, 1, 1, 16))),
      GoalDelta(
          id: '0',
          logEntry: StatusLogEntry(
              id: '4',
              creationTime: DateTime(2020, 1, 1, 17),
              status: GoalStatus.pending,
              startTime: DateTime(2020, 1, 1, 17),
              endTime: DateTime(2020, 1, 1, 18))),
    ]);

    final goals = client.stateSubject.value;

    expect(
        getGoalStatus(
                WorldContext(time: DateTime(2020, 1, 1, 14, 30)), goals['0']!)
            ?.status,
        equals(GoalStatus.active));
    expect(
        getGoalStatus(
                WorldContext(time: DateTime(2020, 1, 1, 13, 30)), goals['0']!)
            ?.status,
        isNull);
    expect(
        getGoalStatus(
                WorldContext(time: DateTime(2020, 1, 1, 17, 30)), goals['0']!)
            ?.status,
        GoalStatus.pending);
    expect(
        getGoalStatus(
                WorldContext(time: DateTime(2020, 1, 2, 8, 30)), goals['0']!)
            ?.status,
        GoalStatus.active);
  });

  test('getGoalsRequiringAttention, clustering', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);

    // Goal '0' is already created by the helper.
    // This modifies goal '0' and adds new goals '1' and '2' as its children.
    await client.modifyGoals([
      GoalDelta(
          id: '0'), // Ensures '0' is part of this transaction if needed, or just modifies it
      GoalDelta(
          id: '1',
          text: 'child 1', // Add text for clarity if these are new goals
          logEntry: SetParentLogEntry(
              id: '3', creationTime: DateTime.now(), parentId: '0')),
      GoalDelta(
          id: '2',
          text: 'child 2', // Add text for clarity
          logEntry: SetParentLogEntry(
              id: '4', creationTime: DateTime.now(), parentId: '0')),
    ]);

    final requiringAttention = getGoalsRequiringAttention(
        WorldContext(time: DateTime(2020, 1, 1, 14, 30)),
        client.stateSubject.value);

    expect(requiringAttention, contains('0'));
    expect(requiringAttention, contains('1'));
    expect(requiringAttention, contains('2'));
  });

  test('getGoalsRequiringAttention, subclustering', () async {
    final client = SyncClient();
    // Using init directly as this test defines its own 'root' goal, not '0'.
    // Alternatively, could use _initializeClientWithRootGoal and then add 'root'.
    await client.init();

    await client.modifyGoals([
      GoalDelta(
          id: 'root', // This test uses 'root' as the ID, not '0'
          logEntry:
              StatusLogEntry(id: '1', creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child-1',
          logEntry: SetParentLogEntry(
              id: '2',
              parentId: 'root',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child-1',
          logEntry: StatusLogEntry(
              id: '3',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child-2',
          logEntry: SetParentLogEntry(
              id: '2',
              parentId: 'root',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1-1',
          logEntry: SetParentLogEntry(
              id: '4',
              parentId: 'child-1',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1-1',
          logEntry: StatusLogEntry(
              id: '5',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1-2',
          logEntry: SetParentLogEntry(
              id: '6',
              parentId: 'child-1',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1-2',
          logEntry: StatusLogEntry(
              id: '7',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-2-1',
          logEntry: SetParentLogEntry(
              id: '6',
              parentId: 'child-2',
              creationTime: DateTime(2020, 1, 1, 12))),
    ]);

    final requiringAttention = getGoalsRequiringAttention(
        WorldContext(time: DateTime(2020, 1, 1, 14, 30)),
        client.stateSubject.value);

    expect(requiringAttention, contains('child-2'));
    expect(requiringAttention, contains('sub-child-2-1'));
  });

  test('getTransitiveSubgoals', () async {
    final client = SyncClient();
    await client.init(); // Keep as is, defines its own 'root'

    await client.modifyGoals([
      GoalDelta(
          id: 'root',
          logEntry:
              StatusLogEntry(id: '1', creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child',
          logEntry: SetParentLogEntry(
              id: '2',
              parentId: 'root',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child',
          logEntry: StatusLogEntry(
              id: '3',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1',
          logEntry: SetParentLogEntry(
              id: '4',
              parentId: 'child',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1',
          logEntry: StatusLogEntry(
              id: '5',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-2',
          logEntry: SetParentLogEntry(
              id: '6',
              parentId: 'child',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-2',
          logEntry: StatusLogEntry(
              id: '7',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
    ]);

    final transitiveSubGoals =
        getTransitiveSubGoals(client.stateSubject.value, 'root');

    expect(transitiveSubGoals, contains('child'));
    expect(transitiveSubGoals, contains('sub-child-1'));
    expect(transitiveSubGoals, contains('sub-child-2'));
  });

  test('getTransitiveSubgoals, with predicate', () async {
    final client = SyncClient();
    await client.init(); // Keep as is, defines its own 'root'

    await client.modifyGoals([
      GoalDelta(
          id: 'root',
          logEntry:
              StatusLogEntry(id: '1', creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child',
          logEntry: SetParentLogEntry(
              id: '2',
              parentId: 'root',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'child',
          logEntry: StatusLogEntry(
              id: '3',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1',
          logEntry: SetParentLogEntry(
              id: '4',
              parentId: 'child',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-1',
          logEntry: StatusLogEntry(
              id: '5',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-2',
          logEntry: SetParentLogEntry(
              id: '6',
              parentId: 'child',
              creationTime: DateTime(2020, 1, 1, 12))),
      GoalDelta(
          id: 'sub-child-2',
          logEntry: StatusLogEntry(
              id: '7',
              status: GoalStatus.active,
              creationTime: DateTime(2020, 1, 1, 12))),
    ]);

    final transitiveSubGoals = getTransitiveSubGoals(
        client.stateSubject.value, 'root',
        predicate: (goal) => !goal.id.startsWith('sub'));

    expect(transitiveSubGoals, contains('child'));
    expect(transitiveSubGoals, isNot(contains('sub-child-1')));
    expect(transitiveSubGoals, isNot(contains('sub-child-2')));
  });

  test('traverseDown', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild
    };

    final paths = [];
    final isLeafs = [];
    final childIndicies = [];
    await traverseDownAsync(goalMap, GoalPath([parent.id]),
        onVisit: (path, {required bool isLeaf, required int childIndex}) async {
      paths.add(path);
      childIndicies.add(childIndex);
      isLeafs.add(isLeaf);
    });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'child'],
          ['parent', 'child', 'grandChild'],
        ]));
    expect(
        isLeafs,
        equals([
          false,
          false,
          true,
        ]));
    expect(
        childIndicies,
        equals([
          0,
          0,
          0,
        ]));
  });

  test('traverseAllAsync loads children', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild
    };

    final paths = <String>[];
    await traverseAllAsync(
      {},
      [
        GoalPath([parent.id])
      ],
      loadGoal: (goalId) => Future.value(goalMap[goalId]),
      onVisit: (path, {required bool isLeaf, required int childIndex}) async {
        paths.add("Visit: ${path.toString()}");
      },
    );

    expect(
        paths,
        equals([
          'Visit: gg://parent',
          'Visit: gg://parent/child',
          'Visit: gg://parent/child/grandChild',
        ]));
  });

  test('traverseAllAsync, breadth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild1 = Goal(
        id: 'grandChild 1',
        text: 'grandChild 1',
        creationTime: DateTime(2020, 1, 1));

    Goal grandChild2 = Goal(
        id: 'grandChild 2',
        text: 'grandChild 2',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild1.id);
    grandChild1.addSuperGoal(child.id);

    child.addSubGoal(grandChild2.id);
    grandChild2.addSuperGoal(child.id);

    Goal greatGrandChild1 = Goal(
        id: 'greatGrandChild 1',
        text: 'greatGrandChild 1',
        creationTime: DateTime(2020, 1, 1));

    grandChild1.addSubGoal(greatGrandChild1.id);
    greatGrandChild1.addSuperGoal(grandChild1.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild1.id: grandChild1,
      grandChild2.id: grandChild2,
      greatGrandChild1.id: greatGrandChild1,
    };

    final paths = <String>[];
    await traverseAllAsync(
      {},
      [
        GoalPath([parent.id])
      ],
      loadGoal: (goalId) => Future.value(goalMap[goalId]),
      onVisit: (path, {required bool isLeaf, required int childIndex}) async {
        paths.add("Visit: ${path.toString()}");
      },
    );

    expect(
        paths,
        equals([
          'Visit: gg://parent',
          'Visit: gg://parent/child',
          'Visit: gg://parent/child/grandChild 1',
          'Visit: gg://parent/child/grandChild 2',
          'Visit: gg://parent/child/grandChild 1/greatGrandChild 1',
        ]));
  });

  test('traverseAllAsync, depth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild1 = Goal(
        id: 'grandChild 1',
        text: 'grandChild 1',
        creationTime: DateTime(2020, 1, 1));

    Goal grandChild2 = Goal(
        id: 'grandChild 2',
        text: 'grandChild 2',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild1.id);
    grandChild1.addSuperGoal(child.id);

    child.addSubGoal(grandChild2.id);
    grandChild2.addSuperGoal(child.id);

    Goal greatGrandChild1 = Goal(
        id: 'greatGrandChild 1',
        text: 'greatGrandChild 1',
        creationTime: DateTime(2020, 1, 1));

    grandChild1.addSubGoal(greatGrandChild1.id);
    greatGrandChild1.addSuperGoal(grandChild1.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild1.id: grandChild1,
      grandChild2.id: grandChild2,
      greatGrandChild1.id: greatGrandChild1,
    };

    final paths = <String>[];
    await traverseAllAsync(
      {},
      [
        GoalPath([parent.id])
      ],
      loadGoal: (goalId) => Future.value(goalMap[goalId]),
      order: TraversalOrder.depthFirst,
      onVisit: (path, {required bool isLeaf, required int childIndex}) async {
        paths.add("Arrive: ${path.toString()}");
      },
      onDepart: (path, {required bool isLeaf, required int childIndex}) async {
        paths.add("Depart: ${path.toString()}");
      },
    );

    expect(
        paths,
        equals([
          'Arrive: gg://parent',
          'Arrive: gg://parent/child',
          'Arrive: gg://parent/child/grandChild 1',
          'Arrive: gg://parent/child/grandChild 1/greatGrandChild 1',
          'Depart: gg://parent/child/grandChild 1/greatGrandChild 1',
          'Depart: gg://parent/child/grandChild 1',
          'Arrive: gg://parent/child/grandChild 2',
          'Depart: gg://parent/child/grandChild 2',
          'Depart: gg://parent/child',
          'Depart: gg://parent'
        ]));
  });

  test('traverseAll, breadth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild1 = Goal(
        id: 'grandChild 1',
        text: 'grandChild 1',
        creationTime: DateTime(2020, 1, 1));

    Goal grandChild2 = Goal(
        id: 'grandChild 2',
        text: 'grandChild 2',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild1.id);
    grandChild1.addSuperGoal(child.id);

    child.addSubGoal(grandChild2.id);
    grandChild2.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild1.id: grandChild1,
      grandChild2.id: grandChild2
    };

    final paths = <String>[];
    traverseAll(goalMap, [
      GoalPath([parent.id])
    ], onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add("Visit: ${path.toString()}");
    });

    expect(
        paths,
        equals([
          'Visit: gg://parent',
          'Visit: gg://parent/child',
          'Visit: gg://parent/child/grandChild 1',
          'Visit: gg://parent/child/grandChild 2',
        ]));
  });

  test('traverseAll, depth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild1 = Goal(
        id: 'grandChild 1',
        text: 'grandChild 1',
        creationTime: DateTime(2020, 1, 1));

    Goal grandChild2 = Goal(
        id: 'grandChild 2',
        text: 'grandChild 2',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild1.id);
    grandChild1.addSuperGoal(child.id);

    child.addSubGoal(grandChild2.id);
    grandChild2.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild1.id: grandChild1,
      grandChild2.id: grandChild2
    };

    final paths = <String>[];
    traverseAll(
      goalMap,
      [
        GoalPath([parent.id])
      ],
      order: TraversalOrder.depthFirst,
      onVisit: (path, {required bool isLeaf, required int childIndex}) {
        paths.add("Arrive: ${path.toString()}");
      },
      onDepart: (path, {required bool isLeaf, required int childIndex}) {
        paths.add("Depart: ${path.toString()}");
      },
    );

    expect(
        paths,
        equals([
          'Arrive: gg://parent',
          'Arrive: gg://parent/child',
          'Arrive: gg://parent/child/grandChild 1',
          'Depart: gg://parent/child/grandChild 1',
          'Arrive: gg://parent/child/grandChild 2',
          'Depart: gg://parent/child/grandChild 2',
          'Depart: gg://parent/child',
          'Depart: gg://parent'
        ]));
  });

  test('traverseUp', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild
    };

    final paths = [];
    final isLeafs = [];
    traverseUp(goalMap, grandChild.id,
        onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add(path);
      isLeafs.add(isLeaf);
    });

    expect(
        paths,
        equals([
          ['grandChild'],
          ['child', 'grandChild'],
          ['parent', 'child', 'grandChild'],
        ]));
    expect(
        isLeafs,
        equals([
          false,
          false,
          true,
        ]));
  });

  test('traverseDown, stopTraversal', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild
    };

    final paths = [];
    final isLeafs = [];
    traverseDown(goalMap, parent.id,
        onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add(path);
      isLeafs.add(isLeaf);
      return TraversalDecision.stopTraversal;
    });

    expect(
        paths,
        equals([
          ['parent'],
        ]));
    expect(isLeafs, equals([false]));
  });

  test('traverseDown, dontRecurse', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));
    Goal sibling = Goal(
        id: 'sibling', text: 'sibling', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    parent.addSubGoal(sibling.id);
    sibling.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild,
      sibling.id: sibling,
    };

    final paths = [];
    final isLeafs = [];
    traverseDown(goalMap, parent.id,
        onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add(path);
      isLeafs.add(isLeaf);
      if (path.goalId == 'child') {
        return TraversalDecision.dontRecurse;
      }
      return TraversalDecision.continueTraversal;
    });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'child'],
          ['parent', 'sibling'],
        ]));
    expect(
        isLeafs,
        equals([
          false,
          false,
          true,
        ]));
  });

  test('traverseDown, dontRecurse', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));
    Goal sibling = Goal(
        id: 'sibling', text: 'sibling', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    parent.addSubGoal(sibling.id);
    sibling.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild,
      sibling.id: sibling,
    };

    final paths = [];
    final isLeafs = [];
    traverseDown(goalMap, parent.id,
        onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add(path);
      isLeafs.add(isLeaf);
      if (path.goalId == 'child') {
        return TraversalDecision.dontRecurse;
      }
      return TraversalDecision.continueTraversal;
    });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'child'],
          ['parent', 'sibling'],
        ]));
    expect(
        isLeafs,
        equals([
          false,
          false,
          true,
        ]));
  });

  test('traverseDown, missing from map', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));
    Goal sibling = Goal(
        id: 'sibling', text: 'sibling', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    parent.addSubGoal(sibling.id);
    sibling.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final goalMap = {
      parent.id: parent,
      grandChild.id: grandChild,
      sibling.id: sibling,
    };

    final paths = [];
    traverseDown(goalMap, parent.id,
        onVisit: (path, {required bool isLeaf, required int childIndex}) {
      paths.add(path);
    });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'sibling'],
        ]));
  });

  test('traverseDownAsync, depth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));
    Goal sibling = Goal(
        id: 'sibling', text: 'sibling', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    parent.addSubGoal(sibling.id);
    sibling.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final storedGoals = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild,
      sibling.id: sibling,
    };

    final goalMap = {
      parent.id: parent,
      child.id: child,
      sibling.id: sibling,
    };

    final paths = [];
    await traverseDownAsync(goalMap, GoalPath([parent.id]),
        loadGoal: (goalId) async {
          return storedGoals[goalId];
        },
        order: TraversalOrder.depthFirst,
        onVisit: (path, {required bool isLeaf, required int childIndex}) async {
          paths.add(path);
        });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'child'],
          ['parent', 'child', 'grandChild'],
          ['parent', 'sibling'],
        ]));
  });

  test('traverseDownAsync, breadth first', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));
    Goal sibling = Goal(
        id: 'sibling', text: 'sibling', creationTime: DateTime(2020, 1, 1));

    parent.addSubGoal(child.id);
    child.addSuperGoal(parent.id);

    parent.addSubGoal(sibling.id);
    sibling.addSuperGoal(parent.id);

    Goal grandChild = Goal(
        id: 'grandChild',
        text: 'grandChild',
        creationTime: DateTime(2020, 1, 1));

    child.addSubGoal(grandChild.id);
    grandChild.addSuperGoal(child.id);

    final storedGoals = {
      parent.id: parent,
      child.id: child,
      grandChild.id: grandChild,
      sibling.id: sibling,
    };

    final goalMap = {
      parent.id: parent,
      child.id: child,
      sibling.id: sibling,
    };

    final paths = [];
    await traverseDownAsync(goalMap, GoalPath([parent.id]),
        loadGoal: (goalId) async {
          return storedGoals[goalId];
        },
        order: TraversalOrder.breadthFirst,
        onVisit: (path, {required bool isLeaf, required int childIndex}) async {
          paths.add(path);
        });

    expect(
        paths,
        equals([
          ['parent'],
          ['parent', 'child'],
          ['parent', 'sibling'],
          ['parent', 'child', 'grandChild'],
        ]));
  });

  test('getAbbreviatedLogEntries', () async {
    final client = SyncClient();
    await _initializeClientWithRootGoal(client);

    final [entry] =
        getAbbreviatedLogEntries(WorldContext(time: DateTime(2020, 1, 1, 14)), [
      StatusLogEntry(
          id: '1',
          status: GoalStatus.active,
          creationTime: DateTime(2020, 1, 1, 12),
          startTime: DateTime(2020, 1, 1, 12),
          endTime: DateTime(2020, 1, 2, 12))
    ]);

    expect(entry, isA<StatusLogEntry>());
  });

  group('traverseParallelLoad', () {
    test('loads and visits all goals in tree', () async {
      // Create state with first client
      final sharedStore = MemoryLocalStore();
      final persistence = MemoryPersistenceService();
      final client1 =
          SyncClient(localStore: sharedStore, persistenceService: persistence);
      await client1.init();

      await client1.modifyGoal(GoalDelta(id: '0', text: 'root'));

      // Create a tree: 0 -> 1 -> 3
      //                   -> 2 -> 4
      await client1.modifyGoals([
        GoalDelta(
            id: '1',
            text: 'child1',
            logEntry: AddParentLogEntry(
                id: 'rel1', parentId: '0', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '2',
            text: 'child2',
            logEntry: AddParentLogEntry(
                id: 'rel2', parentId: '0', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '3',
            text: 'grandchild1',
            logEntry: AddParentLogEntry(
                id: 'rel3', parentId: '1', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '4',
            text: 'grandchild2',
            logEntry: AddParentLogEntry(
                id: 'rel4', parentId: '2', creationTime: DateTime(2020, 1, 1))),
      ]);

      // Ensure all ops are persisted
      await persistence.settled;
      await client1.sync();

      // Load from second client using shared store
      final client2 =
          SyncClient(localStore: sharedStore, persistenceService: persistence);
      await client2.init();

      final visited = <String>[];

      await traverseParallelLoad(
        [
          GoalPath(['0'])
        ],
        client2.loadGoal,
        onVisit: (path, {required isLeaf}) {
          visited.add(path.last);
          return TraversalDecision.continueTraversal;
        },
      );

      expect(visited, containsAll(['0', '1', '2', '3', '4']));
      expect(visited.length, 5);
    });

    test('loads and visits all goals in deeper tree', () async {
      // Create state with first client
      final sharedStore = MemoryLocalStore();
      final persistence = MemoryPersistenceService();
      final client1 =
          SyncClient(localStore: sharedStore, persistenceService: persistence);
      await client1.init();

      await client1.modifyGoal(GoalDelta(id: '0', text: 'root'));

      // Create a tree: 0 -> 1 -> 3 -> 5
      //                  -> 2 -> 4 -> 6
      await client1.modifyGoals([
        GoalDelta(
            id: '1',
            text: 'child1',
            logEntry: AddParentLogEntry(
                id: 'rel1', parentId: '0', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '2',
            text: 'child2',
            logEntry: AddParentLogEntry(
                id: 'rel2', parentId: '0', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '3',
            text: 'grandchild1',
            logEntry: AddParentLogEntry(
                id: 'rel3', parentId: '1', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '4',
            text: 'grandchild2',
            logEntry: AddParentLogEntry(
                id: 'rel4', parentId: '2', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '5',
            text: 'great-grandchild1',
            logEntry: AddParentLogEntry(
                id: 'rel5', parentId: '3', creationTime: DateTime(2020, 1, 1))),
        GoalDelta(
            id: '6',
            text: 'great-grandchild2',
            logEntry: AddParentLogEntry(
                id: 'rel6', parentId: '4', creationTime: DateTime(2020, 1, 1))),
      ]);

      // Ensure all ops are persisted
      await persistence.settled;
      await client1.sync();
      await client1.sync();

      // Load from second client using shared store
      final client2 =
          SyncClient(localStore: sharedStore, persistenceService: persistence);
      await client2.init();

      final visited = <String>[];

      await traverseParallelLoad(
        [
          GoalPath(['0'])
        ],
        client2.loadGoal,
        onVisit: (path, {required isLeaf}) {
          visited.add(path.last);
          return TraversalDecision.continueTraversal;
        },
      );

      expect(visited, containsAll(['0', '1', '2', '3', '4', '5', '6']));
      expect(visited.length, 7);
    });
  });

  group('computeDropGoalEffects', () {
    test('move on goal removes source parent edge and adds destination edge', () {
      final now = DateTime.now();
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final p2 = Goal(id: 'p2', text: 'Parent 2', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');

      final goalMap = {'p1': p1, 'p2': p2, 'c1': c1};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p2']),
        isAdditive: false,
      );

      expect(deltas.length, equals(2));
      final removeEntry = deltas.firstWhere((d) => d.logEntry is RemoveParentLogEntry).logEntry as RemoveParentLogEntry;
      final addEntry = deltas.firstWhere((d) => d.logEntry is AddParentLogEntry).logEntry as AddParentLogEntry;
      expect(removeEntry.parentId, equals('p1'));
      expect(addEntry.parentId, equals('p2'));
    });

    test('additive drop on goal preserves source parent and adds destination edge', () {
      final now = DateTime.now();
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final p2 = Goal(id: 'p2', text: 'Parent 2', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');

      final goalMap = {'p1': p1, 'p2': p2, 'c1': c1};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p2']),
        isAdditive: true,
      );

      expect(deltas.length, equals(1));
      expect(deltas.where((d) => d.logEntry is RemoveParentLogEntry), isEmpty);
      final addEntry = deltas.first.logEntry as AddParentLogEntry;
      expect(addEntry.parentId, equals('p2'));
    });

    test('additive drop on existing parent or cycle is rejected with zero effects', () {
      final now = DateTime.now();
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');

      final goalMap = {'p1': p1, 'c1': c1};

      // Duplicate drop
      final dupDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        dropPath: GoalPath(const ['p1']),
        isAdditive: true,
      );
      expect(dupDeltas, isEmpty);

      // Cycle drop
      final cycleDeltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1']),
        dropPath: GoalPath(const ['p1', 'c1']),
        isAdditive: true,
      );
      expect(cycleDeltas, isEmpty);
    });

    test('additive drop on separator under already-existing parent produces zero effects and no priority mutation', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      final c2 = Goal(id: 'c2', text: 'Child 2', creationTime: now);
      c1.addSuperGoal('p1');
      c2.addSuperGoal('p1');
      p1.addSubGoal('c1');
      p1.addSubGoal('c2');
      c1.prependEntry(PriorityLogEntry(id: 'p-c1', creationTime: now, priority: 100.0, path: GoalPath(const ['p1'])));
      c2.prependEntry(PriorityLogEntry(id: 'p-c2', creationTime: now, priority: 200.0, path: GoalPath(const ['p1'])));

      final goalMap = {'p1': p1, 'c1': c1, 'c2': c2};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1', 'c1']),
        nextDropPath: GoalPath(const ['p1', 'c2']),
        isAdditive: true,
      );

      expect(deltas, isEmpty,
          reason: 'Additive separator drop on existing destination parent must produce zero effects');
    });

    test('normal drag on separator under same parent reorders with priority update', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      final c2 = Goal(id: 'c2', text: 'Child 2', creationTime: now);
      c1.addSuperGoal('p1');
      c2.addSuperGoal('p1');
      p1.addSubGoal('c1');
      p1.addSubGoal('c2');
      c1.prependEntry(PriorityLogEntry(id: 'p-c1', creationTime: now, priority: 100.0, path: GoalPath(const ['p1'])));
      c2.prependEntry(PriorityLogEntry(id: 'p-c2', creationTime: now, priority: 200.0, path: GoalPath(const ['p1'])));

      final goalMap = {'p1': p1, 'c1': c1, 'c2': c2};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['p1', 'c1']),
        nextDropPath: GoalPath(const ['p1', 'c2']),
        isAdditive: false,
      );

      expect(deltas.length, equals(1));
      expect(deltas.first.id, equals('c1'));
      expect(deltas.first.logEntry, isA<PriorityLogEntry>());
      final pEntry = deltas.first.logEntry as PriorityLogEntry;
      expect(pEntry.priority, equals(150.0));
    });

    test('additive drop on root separator produces zero effects and no priority mutation', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final r1 = Goal(id: 'r1', text: 'Root 1', creationTime: now);
      final r2 = Goal(id: 'r2', text: 'Root 2', creationTime: now);
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');
      r1.prependEntry(PriorityLogEntry(id: 'p-r1', creationTime: now, priority: 10.0));
      r2.prependEntry(PriorityLogEntry(id: 'p-r2', creationTime: now, priority: 20.0));

      final goalMap = {'r1': r1, 'r2': r2, 'p1': p1, 'c1': c1};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['r1']),
        nextDropPath: GoalPath(const ['r2']),
        isAdditive: true,
      );

      expect(deltas, isEmpty,
          reason: 'Additive drop to root separator must produce zero effects because root has no edge representation');
    });

    test('normal drag of child to root separator removes parent edge and assigns root priority', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final r1 = Goal(id: 'r1', text: 'Root 1', creationTime: now);
      final r2 = Goal(id: 'r2', text: 'Root 2', creationTime: now);
      final p1 = Goal(id: 'p1', text: 'Parent 1', creationTime: now);
      final c1 = Goal(id: 'c1', text: 'Child 1', creationTime: now);
      c1.addSuperGoal('p1');
      p1.addSubGoal('c1');
      r1.prependEntry(PriorityLogEntry(id: 'p-r1', creationTime: now, priority: 10.0));
      r2.prependEntry(PriorityLogEntry(id: 'p-r2', creationTime: now, priority: 20.0));

      final goalMap = {'r1': r1, 'r2': r2, 'p1': p1, 'c1': c1};

      final deltas = computeDropGoalEffects(
        goalMap,
        GoalPath(const ['p1', 'c1']),
        prevDropPath: GoalPath(const ['r1']),
        nextDropPath: GoalPath(const ['r2']),
        isAdditive: false,
      );

      expect(deltas.length, equals(2));
      final removeEntry = deltas.firstWhere((d) => d.logEntry is RemoveParentLogEntry).logEntry as RemoveParentLogEntry;
      final pEntry = deltas.firstWhere((d) => d.logEntry is PriorityLogEntry).logEntry as PriorityLogEntry;
      expect(removeEntry.parentId, equals('p1'));
      expect(pEntry.priority, equals(15.0));
      expect(pEntry.path, isNull, reason: 'Root priority entry must have null path');
    });
  });
}
