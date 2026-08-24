import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show File;

import 'package:collection/collection.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_core/util.dart';
import 'package:hlc/hlc.dart' show HLC;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart' show Namespace, Uuid;

// Helper function to initialize a SyncClient and add a root goal.
Future<SyncClient> _initializeClientWithRootGoal(SyncClient client) async {
  await client.init();
  // Create the 'root' goal with id '0' and text 'root'
  await client.modifyGoal(GoalDelta(id: '0', text: 'root'));
  return client;
}

Future<Iterable<Op>> readJsonFile(String filePath) async {
  final input = await File(filePath).readAsString();
  return (jsonDecode(input) as List).cast<String>().map((opString) {
    try {
      return Op.fromJson(opString);
    } catch (e) {
      print('Error parsing op: $opString');
      rethrow;
    }
  });
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

  test('compressHistory', () async {
    final ops = await readJsonFile('test/data/2025.05.12_backup.json');

    final store = MemoryLocalStore();

    await store.setUnsyncedOps(ops);

    final client = SyncClient(localStore: store);

    await client.init();
    await client.sync();
    await client.sync();

    final state = client.stateSubject.value;

    final compressed = await computeCompressedHistory(state, client.loadString);

    // write compressed ops to file
    final compressedOps = compressed.map((op) => op.toJson()).toList();
    final compressedJson = jsonEncode(compressedOps);
    final compressedFile = File('test/data/compressed_backup.json');
    await compressedFile.writeAsString(compressedJson);

    print("Num Ops Before: ${ops.length}");
    print("Num Ops After: ${compressed.length}");

    final compressedStore = MemoryLocalStore();

    compressedStore.setUnsyncedOps(compressed);
    final compressedClient = SyncClient(localStore: compressedStore);

    await compressedClient.init();
    await client.sync();
    await client.sync();

    final compressedState = compressedClient.stateSubject.value;

    expect(compressedState.length, equals(state.length),
        reason:
            'The compressed state should have the same number of goals as the original state.');

    final originalPaths = <GoalPath>{};
    final originalTranslatedPaths = <GoalPath>{};

    for (final goalId in state.values
        .where((goal) {
          for (final entry in goal.superGoalRelationships.entries) {
            if (state.containsKey(entry.key) &&
                    entry.value is! AddParentLogEntry ||
                !(entry.value as AddParentLogEntry).isSlice) {
              return false;
            }
          }
          return true;
        })
        .map((e) => e.id)
        .sorted(
          (a, b) => Cupid.toNewId(a).compareTo(Cupid.toNewId(b)),
        )) {
      traverseDown(
        state,
        goalId,
        childTraversalComparator: (goalA, goalB) =>
            Cupid.toNewId(goalA.goalId).compareTo(Cupid.toNewId(goalB.goalId)),
        onVisit: (path, {required childIndex, required isLeaf}) {
          originalTranslatedPaths.add(GoalPath([...path.map(Cupid.toNewId)]));
          originalPaths.add(path);
        },
      );
    }

    final compressedPaths = <GoalPath>{};

    for (final goalId in compressedState.values
        .where((goal) {
          for (final entry in goal.superGoalRelationships.entries) {
            if (compressedState.containsKey(entry.key) &&
                    entry.value is! AddParentLogEntry ||
                !(entry.value as AddParentLogEntry).isSlice) {
              return false;
            }
          }
          return true;
        })
        .map((e) => e.id)
        .sorted(
          (a, b) => a.compareTo(b),
        )) {
      traverseDown(
        compressedState,
        goalId,
        childTraversalComparator: (goalA, goalB) =>
            goalA.goalId.compareTo(goalB.goalId),
        onVisit: (path, {required childIndex, required isLeaf}) {
          compressedPaths.add(path);
        },
      );
    }

    final missing = originalTranslatedPaths.difference(compressedPaths);

    if (missing.isNotEmpty) {
      print("Missing paths:");
      int num = 0;
      for (final path in missing) {
        debugPrintPath(compressedState, path);
        print(path.goalId);
        if (num > 10) {
          break;
        }
        num++;
      }
    }

    final extra = compressedPaths.difference(originalTranslatedPaths);

    if (extra.isNotEmpty) {
      print("Extra paths:");
      int num = 0;
      for (final path in extra) {
        debugPrintPath(compressedState, path);
        print(path.goalId);
        if (num > 10) {
          break;
        }
        num++;
      }
    }

    expect(missing, isEmpty,
        reason:
            'The compressed state is missing paths that were in the original state.');
    expect(extra, isEmpty,
        reason:
            'The compressed state has extra paths that were not in the original state.');

    final diffs = <String, Set<String>>{};
    for (final (i, originalPath) in originalPaths.indexed) {
      final newPath = compressedPaths.elementAt(i);
      final wc = WorldContext.now();
      final goalDiffs = await diffGoals(
          wc,
          state,
          originalPath,
          compressedState,
          newPath,
          client.loadString,
          compressedClient.loadString);
      if (goalDiffs.isNotEmpty) {
        diffs[getDebugString(compressedState, newPath)] = goalDiffs;
      }
    }
    final diffCounts = <String, int>{};
    for (final MapEntry(value: diffs) in diffs.entries) {
      for (final goalDiff in diffs) {
        final diff = goalDiff.toString();
        if (diffCounts.containsKey(diff)) {
          diffCounts[diff] = diffCounts[diff]! + 1;
        } else {
          diffCounts[diff] = 1;
        }
      }
    }

    print("Diff Counts:");
    print(diffCounts);
  }, skip: "This test is pretty out of date but may still be worth keeping.");

  test('do summary migration', () async {
    final ops = await readJsonFile('test/data/2025.05.12_backup.json');

    final store = MemoryLocalStore();

    store.setUnsyncedOps(ops);

    final client = SyncClient(localStore: store);

    await client.init();
    await client.sync();
    await client.sync();

    final goalMap = await client.stateSubject.first;

    final deltas = <GoalDelta>[];
    final docContents = <GoalPath, List<String>>{};
    final pathSummaries = <GoalPath, String>{};
    var hadParentContext = 0;
    var hadSummary = 0;
    var addedToParent = 0;
    var totalPathsVisited = 0;
    var uniqueEntryPathsVisited = 0;
    final migratedPaths = <GoalPath>{};

    for (final goal in getRootGoals(goalMap)) {
      await traverseDownAsync(
        goalMap,
        GoalPath([goal.id]),
        onVisit: (path, {required bool isLeaf, required int childIndex}) async {
          final goal = goalMap[path.goalId];
          final entryPath =
              getLogEntryPath(goalMap, path) ?? GoalPath([path.goalId]);

          totalPathsVisited++;

          // we default to this being the goal itself,
          // but if the goal has children, we create a new goal to hold the summary
          String? summaryGoalId;
          String? newParentContextGoalId;
          final doc = docContents[path] ?? [];

          if (!pathSummaries.containsKey(entryPath)) {
            final summary = hasSummary(goalMap, path);
            final summaryText = (summary == null ||
                    (summary.path ?? GoalPath([path.goalId])) != entryPath)
                ? null
                : await client.loadString(summary.id);
            if (summaryText != null) {
              hadSummary++;
              migratedPaths.add(path);

              // create new goal with summary as doc contents
              // add as child to this goal
              // add composition reference to summary
              deltas.add(GoalDelta(
                  id: path.goalId,
                  logEntry: ClearSummaryEntry(
                    id: Uuid()
                        .v5(Namespace.url.value, "$entryPath-clear-summary"),
                    creationTime: DateTime.now(),
                    path: getLogEntryPath(goalMap, path),
                  )));
              if (!isLeaf) {
                summaryGoalId = Uuid()
                    .v5(Namespace.url.value, "$entryPath-summary-goal-id");
                pathSummaries[entryPath] = summaryGoalId;
                deltas.addAll([
                  GoalDelta(
                      id: summaryGoalId,
                      text: "Summary",
                      logEntry: AddParentLogEntry(
                        id: Uuid().v5(Namespace.url.value,
                            "$entryPath-add-summary-child"),
                        parentId: path.goalId,
                        creationTime: summary!.creationTime,
                        path: getLogEntryPath(goalMap, path),
                      )),
                  GoalDelta(
                      id: summaryGoalId,
                      logEntry: DocumentContentsEntry(
                        id: Uuid().v5(Namespace.url.value,
                            "$entryPath-set-document-contents"),
                        text: summaryText,
                        creationTime: summary.creationTime,
                        path: getLogEntryPath(goalMap, path),
                      )),
                ]);
                doc.add("#${GoalPath([summaryGoalId])}/comp#");
              } else {
                summaryGoalId = path.goalId;
                doc.add(summaryText);
              }
            }
          } else {
            summaryGoalId = pathSummaries[entryPath];
          }

          uniqueEntryPathsVisited++;

          final parentContext = hasParentContext(goal, path.parentId);

          final parentContextComment = (parentContext == null ||
                  (parentContext.path ?? GoalPath([path.goalId])) != entryPath)
              ? null
              : await client.loadString(parentContext.id);

          if (parentContextComment != null) {
            newParentContextGoalId = Uuid().v5(Namespace.url.value,
                "$entryPath-${path.parentId}-parent-context-goal-id");
            hadParentContext++;
            migratedPaths.add(path);
            final parentGoalName = goalMap[path.parentId]?.text ?? "Parent";

            // create new goal with parent context as doc contents
            // add as child to this goal
            // add composition reference to parent context
            deltas.addAll([
              GoalDelta(
                id: newParentContextGoalId,
                text: "Comment about $parentGoalName",
                logEntry: AddParentLogEntry(
                  id: Uuid().v5(Namespace.url.value,
                      "$newParentContextGoalId-add-parent"),
                  parentId: path.goalId,
                  creationTime: parentContext!.creationTime,
                  path: getLogEntryPath(goalMap, path),
                ),
              ),
              GoalDelta(
                  id: newParentContextGoalId,
                  logEntry: DocumentContentsEntry(
                    id: Uuid().v5(Namespace.url.value,
                        "$newParentContextGoalId-set-document-contents"),
                    text: parentContextComment,
                    creationTime: parentContext.creationTime,
                    path: getLogEntryPath(goalMap, path),
                  )),
              GoalDelta(
                id: path.goalId,
                logEntry: ParentContextCommentEntry(
                  id: Uuid().v5(Namespace.url.value,
                      "$newParentContextGoalId-clear-parent-context"),
                  text: null,
                  creationTime: DateTime.now(),
                  parentId: path.parentId!,
                ),
              )
            ]);

            doc.addAll([
              "",
              "# #${GoalPath([path.parentId!])}/name#",
              "#${GoalPath([newParentContextGoalId])}/comp#",
            ]);
          }
          if (doc.isNotEmpty) {
            docContents[entryPath] = doc;
          }

          if (path.parentId == null) {
            return TraversalDecision.continueTraversal;
          }
          final parentDoc = docContents[
              getLogEntryPath(goalMap, path.parentPath) ??
                  GoalPath([path.parentId!])];
          if (parentDoc != null &&
              (summaryGoalId != null || newParentContextGoalId != null)) {
            migratedPaths.add(path.parentPath);
            addedToParent++;
            parentDoc.addAll([
              "",
              "# #${GoalPath([path.goalId])}/name#",
              if (summaryGoalId != null) "#${GoalPath([summaryGoalId])}/comp#",
              if (newParentContextGoalId != null)
                "> #${GoalPath([newParentContextGoalId])}/comp#",
            ]);
          }
        },
        onDepart: (path,
            {required bool isLeaf, required int childIndex}) async {
          final entryPath =
              getLogEntryPath(goalMap, path) ?? GoalPath([path.goalId]);
          final doc = docContents[entryPath];
          if (doc == null || doc.isEmpty) {
            return;
          }
          deltas.add(GoalDelta(
              id: path.goalId,
              logEntry: DocumentContentsEntry(
                id: Uuid().v5(
                    Namespace.url.value, "$entryPath-set-document-contents"),
                text: doc.join("\n"),
                creationTime: DateTime.now(),
                path: getLogEntryPath(goalMap, path),
              )));
        },
        childTraversalComparator: getPriorityComparator(goalMap),
      );
    }

    final migrationOps = <Op>[];
    var hlc = HLC.now('migration');
    final deltaSet = <String>{};

    for (final delta in deltas.reversed) {
      if (delta.logEntry == null) {
        print("Delta ${delta.id} has no log entry. This should not happen.");
        throw Exception(
            "Delta ${delta.id} has no log entry. This should not happen.");
      }
      if (deltaSet.contains(delta.logEntry!.id)) {
        continue;
      }
      deltaSet.add(delta.logEntry!.id);
      final op = DeltaOp(
        delta: delta,
        id: Cupid.random().encode(),
        hlcTimestamp: hlc.pack(),
      );
      hlc = hlc.increment();
      migrationOps.add(op);
    }

    print("Num Migration Ops: ${migrationOps.length}");
    print("Num Paths Visited: $totalPathsVisited");
    print("Num Unique Paths Visited: $uniqueEntryPathsVisited");
    print("Num Had Parent Context: $hadParentContext");
    print("Num Had Summary: $hadSummary");
    print("Num Added to Parent: $addedToParent");

    // write migration ops to file
    final migrationFile = File('test/data/summary_migration.json');
    await migrationFile.writeAsString(
        jsonEncode(migrationOps.map((op) => op.toJson()).toList()));

    // write list of migrated paths to file
    final migratedPathsFile = File('test/data/migrated_paths.json');
    await migratedPathsFile.writeAsString(jsonEncode(
        migratedPaths.map((path) => getDebugString(goalMap, path)).toList()));
  }, skip: "Not really a test.");

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
}
