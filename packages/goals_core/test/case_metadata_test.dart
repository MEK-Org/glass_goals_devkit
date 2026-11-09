import 'package:goals_core/model.dart';
import 'package:goals_types/goals_types.dart';
import 'package:goals_types/src/version.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    GoalLogEntry.registerModule(CaseLogEntryModule());
  });

  test('CaseGoalLogEntry round-trips through the case module', () {
    final entry = CaseGoalLogEntry(
      id: 'case-entry',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      name: 'Authors Guild v. Google, Inc.',
      court: '2d Cir.',
      year: 2015,
      decisionDate: 'October 16, 2015',
    );

    final json = entry.toJsonMap();
    expect(json[GoalLogEntry.TYPE_JSON_KEY], CASE_ENTRY_TYPE);
    expect(json[CaseGoalLogEntry.NAME_JSON_KEY], 'Authors Guild v. Google, Inc.');
    expect(json[CaseGoalLogEntry.COURT_JSON_KEY], '2d Cir.');
    expect(json[CaseGoalLogEntry.YEAR_JSON_KEY], 2015);
    expect(json[CaseGoalLogEntry.DECISION_DATE_JSON_KEY], 'October 16, 2015');

    final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
    expect(parsed, isA<CaseGoalLogEntry>());
    expect(parsed, entry);
  });

  test('ReporterGoalLogEntry round-trips through the case module', () {
    final entry = ReporterGoalLogEntry(
      id: 'reporter-entry',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      reporter: '804 F.3d',
      startPage: 202,
      reporterIndex: 0,
      caseGoalId: 'case-goal-id',
    );

    final json = entry.toJsonMap();
    expect(json[GoalLogEntry.TYPE_JSON_KEY], REPORTER_ENTRY_TYPE);
    expect(json[ReporterGoalLogEntry.REPORTER_JSON_KEY], '804 F.3d');
    expect(json[ReporterGoalLogEntry.START_PAGE_JSON_KEY], 202);
    expect(json[ReporterGoalLogEntry.REPORTER_INDEX_JSON_KEY], 0);
    expect(json[ReporterGoalLogEntry.CASE_GOAL_ID_JSON_KEY], 'case-goal-id');

    final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
    expect(parsed, isA<ReporterGoalLogEntry>());
    expect(parsed, entry);
  });

  test('getCaseEntry and getReporterEntries query goal log', () {
    final goal = Goal(
      id: 'case-goal',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final caseEntry = CaseGoalLogEntry(
      id: 'case-entry',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      name: 'Authors Guild v. Google, Inc.',
      court: '2d Cir.',
      year: 2015,
    );
    final rep0 = ReporterGoalLogEntry(
      id: 'rep-0',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      reporter: '804 F.3d',
      startPage: 202,
      reporterIndex: 0,
    );
    final rep1 = ReporterGoalLogEntry(
      id: 'rep-1',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      reporter: '2015 U.S. App. LEXIS 17988',
      startPage: 1,
      reporterIndex: 1,
    );

    goal.prependEntry(rep1);
    goal.prependEntry(caseEntry);
    goal.prependEntry(rep0);

    expect(getCaseEntry(goal), caseEntry);
    final reporters = getReporterEntries(goal);
    expect(reporters.length, 2);
    expect(reporters[0].reporterIndex, 0);
    expect(reporters[0].reporter, '804 F.3d');
    expect(reporters[1].reporterIndex, 1);
    expect(reporters[1].reporter, '2015 U.S. App. LEXIS 17988');
  });
}
