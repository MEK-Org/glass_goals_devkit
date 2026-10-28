// Runs the shared sync parity scenarios against the Dart SyncClient, the
// behavioral source for the TypeScript port in packages/goals-core.
//
// The scenarios live in fixtures/sync_parity_scenarios.json and the observed
// output in fixtures/sync_parity_expected.json. The TypeScript suite
// (goals-core/src/sync-client.parity.test.ts) asserts the same expected file,
// so a behavior change on either side fails one of the two suites.
//
// Regenerate the expected output from Dart with:
//   UPDATE_SYNC_PARITY=1 dart test test/sync/sync_parity_fixture_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:goals_core/model.dart' show Goal;
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

const _scenariosPath = 'test/sync/fixtures/sync_parity_scenarios.json';
const _expectedPath = 'test/sync/fixtures/sync_parity_expected.json';

/// Counts per-goal op loads and full-history reads.
class CountingLocalStore extends MemoryLocalStore {
  final Map<String, int> loads = {};
  int getAllOpsCalls = 0;

  @override
  Future<Iterable<Op>> loadOpsForGoal(String goalId) {
    loads[goalId] = (loads[goalId] ?? 0) + 1;
    return super.loadOpsForGoal(goalId);
  }

  @override
  Future<Iterable<Op>> getAllOps() {
    getAllOpsCalls++;
    return super.getAllOps();
  }
}

List<String> _sorted(Iterable<String> ids) => ids.toList()..sort();

String _describeEntry(GoalLogEntry entry) {
  final json = entry.toJsonMap();
  final text = json[TextGoalLogEntry.TEXT_JSON_KEY];
  return text == null
      ? '${json['t']}:${entry.id}'
      : '${json['t']}:${entry.id}:$text';
}

Map<String, dynamic> _describeGoal(Goal goal) => {
      'text': goal.text,
      'parents': _sorted(goal.superGoalIds),
      'children': _sorted(goal.subGoalIds),
      'log': goal.log.map(_describeEntry).toList(),
    };

class _Runner {
  final persistence = MemoryPersistenceService();
  final store = CountingLocalStore();
  SyncClient? client;
  final refs = <String, GoalRef>{};
  final watches = <String, WatchedGoalSet>{};

  /// Lets stream deliveries, echoes and fire-and-forget loads settle. The
  /// caching store batches repo reads on a 10ms timer, so wait past it.
  Future<void> pump() async {
    for (var i = 0; i < 4; i++) {
      await persistence.settled;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> start(int cap) async {
    client = SyncClient(
      persistenceService: persistence,
      localStore: store,
      residentSoftCap: cap,
    );
    await client!.init();
  }

  void stop() {
    client?.dispose();
    client = null;
    refs.clear();
    watches.clear();
  }

  Future<Map<String, dynamic>> snapshot(Map<String, dynamic> step) async {
    final c = client!;
    final state = c.stateSubject.value;
    final result = <String, dynamic>{
      'label': step['label'],
      'state': {
        for (final id in _sorted(state.keys)) id: _describeGoal(state[id]!),
      },
      'resident': c.numResidentGoals,
      'pinned': c.numPinnedGoals,
      'roots': _sorted(c.getRootGoalIds()),
      'unsynced': c.numUnsyncedOps,
      'loads': {
        for (final id in _sorted(store.loads.keys)) id: store.loads[id],
      },
      'getAllOps': store.getAllOpsCalls,
      'refs': {
        for (final alias in _sorted(refs.keys)) alias: refs[alias]!.goal?.text,
      },
      'watches': {
        for (final alias in _sorted(watches.keys))
          alias: {
            'watched': _sorted(watches[alias]!.watchedIds),
            'current': _sorted(watches[alias]!.currentValue.keys),
          },
      },
    };
    if (step['cursor'] == true) {
      result['cursor'] = c.cursor;
    }
    final strings = step['strings'] as List<dynamic>?;
    if (strings != null) {
      result['strings'] = {
        for (final key in strings.cast<String>()) key: await c.loadString(key),
      };
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> run(Map<String, dynamic> scenario) async {
    final snapshots = <Map<String, dynamic>>[];
    final seed = (scenario['seed'] as List<dynamic>)
        .map((json) => Op.fromJsonMap(json))
        .toList();
    await persistence.save(seed);
    await pump();

    for (final step in (scenario['steps'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      switch (step['op']) {
        case 'start':
          await start(step['cap'] ?? 2000);
        case 'restart':
          stop();
          await start(step['cap'] ?? 2000);
        case 'load':
          await client!.loadGoal(step['id']);
        case 'remote':
          await persistence.save((step['ops'] as List<dynamic>)
              .map((json) => Op.fromJsonMap(json))
              .toList());
        case 'modify':
          await client!.modifyGoals([
            for (final delta in step['deltas'] as List<dynamic>)
              (Op.fromJsonMap({
                'h': '000000000000000:00000:fixture',
                'i': 'fixture',
                'v': 6,
                't': 'd',
                'd': delta,
              }) as DeltaOp)
                  .delta,
          ]);
        case 'undo':
          await client!.undo();
        case 'redo':
          await client!.redo();
        case 'ref':
          refs[step['as']] = await client!.loadGoalRef(step['id']);
        case 'release':
          await refs[step['as']]!.dispose();
        case 'watch':
          watches[step['as']] =
              client!.watchGoals((step['ids'] as List<dynamic>).cast());
        case 'watchRemove':
          watches[step['as']]!.remove(step['id']);
        case 'unwatch':
          await watches[step['as']]!.dispose();
        case 'snapshot':
          await pump();
          snapshots.add(await snapshot(step));
        default:
          throw ArgumentError('Unknown step ${step['op']}');
      }
      await pump();
    }
    stop();
    return snapshots;
  }
}

void main() {
  final scenarios = (jsonDecode(File(_scenariosPath).readAsStringSync())
          as Map<String, dynamic>)['scenarios'] as List<dynamic>;
  final update = Platform.environment['UPDATE_SYNC_PARITY'] == '1';
  final expectedFile = File(_expectedPath);
  final expected = !update && expectedFile.existsSync()
      ? jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  final observed = <String, dynamic>{};

  Future<List<Map<String, dynamic>>> runQuietly(Map<String, dynamic> s) =>
      runZoned(() => _Runner().run(s),
          zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {}));

  for (final scenario in scenarios.cast<Map<String, dynamic>>()) {
    final name = scenario['name'] as String;
    test(name, () async {
      final snapshots = await runQuietly(scenario);
      observed[name] = snapshots;
      if (!update) {
        expect(jsonDecode(jsonEncode(snapshots)), equals(expected[name]));
      }
    });
  }

  tearDownAll(() {
    if (update) {
      expectedFile.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(observed)}\n');
    }
  });
}
