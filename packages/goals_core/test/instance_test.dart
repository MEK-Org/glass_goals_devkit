import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

Map<String, Goal> testGoals() {
  final testRootGoal =
      Goal(id: '0', text: 'root', creationTime: DateTime(2020, 1, 1));

  final goals = <String, Goal>{};
  goals[testRootGoal.id] = testRootGoal;

  return goals;
}

void main() {
  test('create instance status entry adds new goal to goal map', () async {
    final client = SyncClient();

    await client.init();
    await client.sync();

    await client.modifyGoal(
      GoalDelta(
          id: '0',
          logEntry: CreateInstanceLogEntry(
            id: '1',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
    );

    final goals = client.stateSubject.value;

    expect(goals['0'], isNotNull);
    expect(goals['1'], isA<GoalInstance>());
  });

  test('setting status on origin does not set status on instance', () async {
    final client = SyncClient();

    await client.init();

    await client.modifyGoals([
      GoalDelta(
          id: '0',
          logEntry: CreateInstanceLogEntry(
            id: '1',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: '0',
          logEntry: ClearStatusLogEntry(
            id: '2',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
    ]);

    final goals = client.stateSubject.value;

    expect(
        getGoalStatus(WorldContext(time: DateTime(2020, 1, 1, 13)), goals['0']!,
            goalMap: goals),
        isNull);

    final instanceStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['1']!,
        goalMap: goals);

    expect(instanceStatus, isA<StatusLogEntry>());
  });

  test('setting status on instance subgoal does not affect origin subgoal',
      () async {
    final client = SyncClient();

    await client.init();
    await client.sync();

    await client.modifyGoals([
      GoalDelta(
          id: '0',
          logEntry: CreateInstanceLogEntry(
            id: '1',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: '2',
          logEntry: AddParentLogEntry(
            id: '2',
            parentId: '0',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
        id: '2',
        logEntry: StatusLogEntry(
          id: '4',
          creationTime: DateTime(2020, 1, 1, 12),
          status: GoalStatus.done,
          path: ['1', '2'],
        ),
      ),
    ]);

    final goals = client.stateSubject.value;

    final originStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['2']!,
        goalMap: goals);

    expect(originStatus, isA<StatusLogEntry>());
    expect(originStatus!.status, isNull);

    final instanceStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['2']!,
        goalMap: goals, path: GoalPath(['1', '2']));

    expect(instanceStatus, isA<StatusLogEntry>());
    expect(instanceStatus!.status, GoalStatus.done);
  });

  test('get instance path', () async {
    final client = SyncClient();

    await client.init();
    await client.sync();

    await client.modifyGoals([
      GoalDelta(
          id: '0',
          logEntry: CreateInstanceLogEntry(
            id: '1',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: '2',
          logEntry: AddParentLogEntry(
            id: '2',
            parentId: '0',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
    ]);

    final goals = client.stateSubject.value;

    expect(getLogEntryPath(goals, GoalPath(['1', '2'])), equals(['1', '2']));
  });

  test('get instance path, non instance', () async {
    Goal parent =
        Goal(id: 'parent', text: 'parent', creationTime: DateTime(2020, 1, 1));
    Goal child =
        Goal(id: 'child', text: 'child', creationTime: DateTime(2020, 1, 1));

    AddParentLogEntry addParentLogEntry = AddParentLogEntry(
        id: '1', creationTime: DateTime(2020, 1, 1), parentId: 'parent');

    parent.addSubGoal(child.id, addParentLogEntry);
    child.addSuperGoal(parent.id, addParentLogEntry);

    expect(
        getLogEntryPath({parent.id: parent, child.id: child},
            GoalPath([parent.id, child.id])),
        isNull);
  });

  test('get instance path, nested instance', () async {
    final client = SyncClient();

    await client.init();

    await client.modifyGoals([
      GoalDelta(
          id: 'template',
          logEntry: CreateInstanceLogEntry(
            id: 'instance',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'template-child',
          logEntry: AddParentLogEntry(
            id: '2',
            parentId: 'template',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'super-template',
          logEntry: CreateInstanceLogEntry(
            id: 'super-instance',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'instance',
          logEntry: AddParentLogEntry(
            id: '3',
            parentId: 'super-template',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
        id: 'super-instance-parent',
      ),
      GoalDelta(
          id: 'super-instance',
          logEntry: AddParentLogEntry(
            id: '4',
            parentId: 'super-instance-parent',
            creationTime: DateTime(2020, 1, 1, 12),
          ))
    ]);

    final goals = client.stateSubject.value;

    expect(
        getLogEntryPath(
            goals,
            GoalPath([
              "super-instance-parent",
              "super-instance",
              "instance",
              "template-child"
            ])),
        equals(["instance", "template-child"]));
    expect(
        getFullInstancePath(
            goals,
            GoalPath([
              "super-instance-parent",
              "super-instance",
              "instance",
              "template-child"
            ])),
        equals(["super-instance", "instance", "template-child"]));
  });

  test('doubly nested instance statuses do not go back', () async {
    final client = SyncClient();

    await client.init();
    await client.sync();

    await client.modifyGoals([
      GoalDelta(
          id: 'template',
          logEntry: CreateInstanceLogEntry(
            id: 'instance',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'template-child',
          logEntry: AddParentLogEntry(
            id: '2',
            parentId: 'template',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'super-template',
          logEntry: CreateInstanceLogEntry(
            id: 'super-instance',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
          id: 'instance',
          logEntry: AddParentLogEntry(
            id: '3',
            parentId: 'super-template',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
        id: 'super-instance-parent',
      ),
      GoalDelta(
          id: 'super-instance',
          logEntry: AddParentLogEntry(
            id: '4',
            parentId: 'super-instance-parent',
            creationTime: DateTime(2020, 1, 1, 12),
          )),
      GoalDelta(
        id: 'template-child',
        logEntry: StatusLogEntry(
          id: '4',
          creationTime: DateTime(2020, 1, 1, 12),
          status: GoalStatus.done,
          path: ['super-instance', 'instance', 'template-child'],
        ),
      ),
    ]);

    final goals = client.stateSubject.value;

    // this is the status as reported by the original child goal
    final originStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['template-child']!,
        goalMap: goals);

    // this is the status as reported in the context of the template
    final templateStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['template-child']!,
        goalMap: goals, path: GoalPath(['template', 'template-child']));

    // this is the status as reported in the context of the instance that lives inside the super-template
    final instanceStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['template-child']!,
        goalMap: goals, path: GoalPath(['instance', 'template-child']));

    // this is the status as reported in the context of the super-template which contains the instance of the inner template
    final superTemplateStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['template-child']!,
        goalMap: goals,
        path: GoalPath(['super-template', 'instance', 'template-child']));

    // this is the status as reported in the context of the super-instance which contains the instance of the inner template
    // this is the only one that should be considered done
    final superInstanceStatus = getGoalStatus(
        WorldContext(time: DateTime(2020, 1, 1, 13)), goals['template-child']!,
        goalMap: goals,
        path: GoalPath(['super-instance', 'instance', 'template-child']));

    expect(originStatus, isA<StatusLogEntry>());
    expect(originStatus!.status, isNull);

    expect(templateStatus, isA<StatusLogEntry>());
    expect(templateStatus!.status, isNull);

    expect(instanceStatus, isA<StatusLogEntry>());
    expect(instanceStatus!.status, isNull);

    expect(superTemplateStatus, isA<StatusLogEntry>());
    expect(superTemplateStatus!.status, isNull);

    expect(superInstanceStatus, isA<StatusLogEntry>());
    expect(superInstanceStatus!.status, GoalStatus.done);
  });

  test('Rename Instance', () async {
    final ops = [
      "{\"hlcTimestamp\":\"001674571071065:00001:db86cca1-fa15-4f6d-b37e-0d19bfb8f95a\",\"delta\":{\"id\":\"root\",\"text\":\"Test Root\"},\"version\":5,\"type\":\"delta\"}",
      "{\"hlcTimestamp\":\"001738518920078:00000:ZpqP\",\"delta\":{\"id\":\"27eca545-794b-4d3c-885f-4bac17c5a8d2\",\"text\":\"Otherness\"},\"version\":5,\"type\":\"delta\"}",
      "{\"hlcTimestamp\":\"001738518925561:00000:ZpqP\",\"delta\":{\"id\":\"root\",\"logEntry\":{\"type\":\"createInstance\",\"id\":\"be086f75-447e-4d44-b34c-601f5b2ef581\",\"sourceId\":\"27eca545-794b-4d3c-885f-4bac17c5a8d2\",\"creationTime\":\"2025-02-02T17:55:25.559Z\",\"path\":null}},\"version\":5,\"type\":\"delta\"}",
      "{\"hlcTimestamp\":\"001738518925561:00001:ZpqP\",\"delta\":{\"id\":\"be086f75-447e-4d44-b34c-601f5b2ef581\",\"logEntry\":{\"type\":\"addParent\",\"id\":\"f31c4957-9a8a-4d19-b488-3cd44e25fb73\",\"parentId\":\"27eca545-794b-4d3c-885f-4bac17c5a8d2\",\"creationTime\":\"2025-02-02T17:55:25.561Z\",\"isInstance\":false,\"path\":null,\"displayedChildPath\":null}},\"version\":5,\"type\":\"delta\"}",
      "{\"hlcTimestamp\":\"001738518931673:00000:ZpqP\",\"delta\":{\"id\":\"be086f75-447e-4d44-b34c-601f5b2ef581\",\"text\":\"Chortle\"},\"version\":5,\"type\":\"delta\"}",
    ];

    final store = MemoryLocalStore();

    store.setUnsyncedOps(ops.map(Op.fromJson));

    final client = SyncClient(localStore: store);

    await client.init();

    final goals = client.stateSubject.value;

    final instance = goals['be086f75-447e-4d44-b34c-601f5b2ef581'];

    expect(instance, isA<GoalInstance>());

    expect(instance!.text, equals('Chortle'));
  });

  test('Load Instance', () async {
    final ops = [
      "{\"h\":\"001754043632552:00000:xbjU\",\"i\":\"RJMkfzFiwLs3Tg\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"9Mo7WREqDIEISQ\",\"t\":\"Template\"}}",
      "{\"h\":\"001754043637372:00001:xbjU\",\"i\":\"iboHszQsf4JdRA\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"4sSDOHMmZoAvSA\",\"t\":\"Instance Container\"}}",
      "{\"h\":\"001754043637372:00002:xbjU\",\"i\":\"wUYL_ahbs7bRRQ\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"4sSDOHMmZoAvSA\",\"lE\":{\"i\":\"24bLQmKs55xqTQ\",\"cT\":1754043637350,\"t\":\"p\",\"pr\":1754043637350}}}",
      "{\"h\":\"001754043647582:00004:xbjU\",\"i\":\"_ronqBj7j4bfTA\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"9Mo7WREqDIEISQ\",\"lE\":{\"i\":\"bgBJ-cbaoYVUQA\",\"cT\":1754043647547,\"t\":\"cI\"}}}",
      "{\"h\":\"001754043647582:00005:xbjU\",\"i\":\"tYdiHcdKr7-sTw\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"bgBJ-cbaoYVUQA\",\"lE\":{\"i\":\"Y_GBYgN0-bVrTQ\",\"cT\":1754043647547,\"t\":\"aP\",\"pI\":\"4sSDOHMmZoAvSA\"}}}",
      "{\"h\":\"001754043696363:00005:xbjU\",\"i\":\"xsGHi_MMoIUURA\",\"v\":6,\"t\":\"d\",\"d\":{\"i\":\"X5Z-mC-VupZLRg\",\"t\":\"Step 1\",\"lE\":{\"i\":\"bmuFCv20Op_EQg\",\"cT\":1754043696339,\"t\":\"aP\",\"pI\":\"9Mo7WREqDIEISQ\"}}}"
    ];

    final store = MemoryLocalStore();
    final persistenceService = MemoryPersistenceService();

    store.setUnsyncedOps(ops.map(Op.fromJson));

    final client1 =
        SyncClient(localStore: store, persistenceService: persistenceService);

    await client1.init();

    final goals = client1.stateSubject.value;

    final instance = goals['bgBJ-cbaoYVUQA'];

    expect(instance, isA<GoalInstance>());

    expect(instance!.text, equals('Template'));

    await persistenceService.settled;

    final client2 =
        SyncClient(localStore: store, persistenceService: persistenceService);

    await client2.init();
    final goals2 = client2.stateSubject.value;
    final instance2 = goals2['bgBJ-cbaoYVUQA'];
    expect(instance2, isA<GoalInstance>());
    expect(instance2!.text, equals('Template'));
  }, skip: "Not Passing Yet");
}
