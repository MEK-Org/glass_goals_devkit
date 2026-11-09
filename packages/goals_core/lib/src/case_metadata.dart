import 'package:goals_types/goals_types.dart';
import 'model.dart';

const CASE_ENTRY_TYPE = 'case';
const REPORTER_ENTRY_TYPE = 'rep';

/// Stores canonical case citation/declaration metadata attached to an extracted case goal.
class CaseGoalLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 1;
  static const NAME_JSON_KEY = 'n';
  static const COURT_JSON_KEY = 'c';
  static const YEAR_JSON_KEY = 'y';
  static const DECISION_DATE_JSON_KEY = 'dD';

  final String name;
  final String? court;
  final int? year;
  final String? decisionDate;

  const CaseGoalLogEntry({
    required super.id,
    required super.creationTime,
    required this.name,
    this.court,
    this.year,
    this.decisionDate,
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        name,
        court,
        year,
        decisionDate,
        path,
      ];

  static int? _parseYear(dynamic val) {
    if (val == null) return null;
    if (val is int) return val;
    return int.tryParse(val.toString());
  }

  static CaseGoalLogEntry fromJsonMap(dynamic json, int? version) {
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    return CaseGoalLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      name: json[NAME_JSON_KEY] ?? json['name'] ?? '',
      court: json[COURT_JSON_KEY] ?? json['court'],
      year: _parseYear(json[YEAR_JSON_KEY] ?? json['year']),
      decisionDate: json[DECISION_DATE_JSON_KEY] ?? json['decisionDate'],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CASE_ENTRY_TYPE,
      NAME_JSON_KEY: name,
      if (court != null) COURT_JSON_KEY: court,
      if (year != null) YEAR_JSON_KEY: year,
      if (decisionDate != null) DECISION_DATE_JSON_KEY: decisionDate,
    };
  }
}

/// Associates a reporter series, start page, and reporter index with a case goal.
class ReporterGoalLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 1;
  static const REPORTER_JSON_KEY = 'r';
  static const START_PAGE_JSON_KEY = 'sP';
  static const REPORTER_INDEX_JSON_KEY = 'rI';
  static const CASE_GOAL_ID_JSON_KEY = 'cGI';

  final String reporter;
  final int startPage;
  final int reporterIndex;
  final String? caseGoalId;

  const ReporterGoalLogEntry({
    required super.id,
    required super.creationTime,
    required this.reporter,
    required this.startPage,
    required this.reporterIndex,
    this.caseGoalId,
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        reporter,
        startPage,
        reporterIndex,
        caseGoalId,
        path,
      ];

  static ReporterGoalLogEntry fromJsonMap(dynamic json, int? version) {
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    final rawStartPage =
        json[START_PAGE_JSON_KEY] ?? json['startPage'];
    final rawReporterIndex =
        json[REPORTER_INDEX_JSON_KEY] ?? json['reporterIndex'];
    return ReporterGoalLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      reporter: json[REPORTER_JSON_KEY] ?? json['reporter'] ?? '',
      startPage: rawStartPage is int
          ? rawStartPage
          : int.parse(rawStartPage.toString()),
      reporterIndex: rawReporterIndex is int
          ? rawReporterIndex
          : int.parse(rawReporterIndex.toString()),
      caseGoalId: json[CASE_GOAL_ID_JSON_KEY] ?? json['caseGoalId'],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: REPORTER_ENTRY_TYPE,
      REPORTER_JSON_KEY: reporter,
      START_PAGE_JSON_KEY: startPage,
      REPORTER_INDEX_JSON_KEY: reporterIndex,
      if (caseGoalId != null) CASE_GOAL_ID_JSON_KEY: caseGoalId,
    };
  }
}

class CaseLogEntryModule implements LogEntryModule {
  @override
  GoalLogEntry? fromJsonMap(dynamic json, int? version) {
    if (json is Map) {
      final type = json[GoalLogEntry.TYPE_JSON_KEY];
      if (type == CASE_ENTRY_TYPE) {
        return CaseGoalLogEntry.fromJsonMap(json, version);
      }
      if (type == REPORTER_ENTRY_TYPE) {
        return ReporterGoalLogEntry.fromJsonMap(json, version);
      }
    }
    return null;
  }
}

/// Returns the most recent [CaseGoalLogEntry] on [goal], if any.
CaseGoalLogEntry? getCaseEntry(Goal goal) {
  for (final entry in goal.log) {
    if (entry is CaseGoalLogEntry) {
      return entry;
    }
  }
  return null;
}

/// Returns all [ReporterGoalLogEntry]s on [goal], sorted by [ReporterGoalLogEntry.reporterIndex].
List<ReporterGoalLogEntry> getReporterEntries(Goal goal) {
  final entries = <ReporterGoalLogEntry>[];
  for (final entry in goal.log) {
    if (entry is ReporterGoalLogEntry) {
      entries.add(entry);
    }
  }
  entries.sort((a, b) => a.reporterIndex.compareTo(b.reporterIndex));
  return entries;
}
