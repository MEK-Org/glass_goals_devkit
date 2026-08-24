import 'package:goals_types/goals_types.dart';

const SYLLABUS_PARSE_RESULT_ENTRY_TYPE = 'sPR';

/// Represents a single class in the syllabus parse result mapping
class ClassMapping {
  static const CLASS_NUMBER_JSON_KEY = 'cN';
  static const GOAL_ID_JSON_KEY = 'gI';
  static const DATE_JSON_KEY = 'd';
  static const TOPIC_JSON_KEY = 'tp';

  final int classNumber;
  final String goalId;
  final String? date;
  final String topic;

  const ClassMapping({
    required this.classNumber,
    required this.goalId,
    this.date,
    required this.topic,
  });

  static ClassMapping fromJsonMap(dynamic json) {
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    return ClassMapping(
      classNumber: json[CLASS_NUMBER_JSON_KEY],
      goalId: json[GOAL_ID_JSON_KEY],
      date: json[DATE_JSON_KEY],
      topic: json[TOPIC_JSON_KEY],
    );
  }

  Map<String, dynamic> toJsonMap() {
    return {
      CLASS_NUMBER_JSON_KEY: classNumber,
      GOAL_ID_JSON_KEY: goalId,
      if (date != null) DATE_JSON_KEY: date,
      TOPIC_JSON_KEY: topic,
    };
  }
}

/// Stores syllabus parse results for update diffing
class SyllabusParseResultLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 1;
  static const CLASSES_FOLDER_GOAL_ID_JSON_KEY = 'cfGI';
  static const TEXTBOOK_GOAL_ID_JSON_KEY = 'tGI';
  static const CLASS_MAPPING_JSON_KEY = 'cM';
  static const ASSET_FILENAME_JSON_KEY = 'aF';

  final String classesFolderGoalId;
  final String textbookGoalId;
  final List<ClassMapping> classMapping;
  final String assetFilename;

  const SyllabusParseResultLogEntry({
    required super.id,
    required super.creationTime,
    required this.classesFolderGoalId,
    required this.textbookGoalId,
    required this.classMapping,
    required this.assetFilename,
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        classesFolderGoalId,
        textbookGoalId,
        classMapping,
        assetFilename,
      ];

  static SyllabusParseResultLogEntry fromJsonMap(dynamic json, int? version) {
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    final classMappingJson = json[CLASS_MAPPING_JSON_KEY] as List;
    return SyllabusParseResultLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      classesFolderGoalId: json[CLASSES_FOLDER_GOAL_ID_JSON_KEY],
      textbookGoalId: json[TEXTBOOK_GOAL_ID_JSON_KEY],
      classMapping:
          classMappingJson.map((e) => ClassMapping.fromJsonMap(e)).toList(),
      assetFilename: json[ASSET_FILENAME_JSON_KEY],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: SYLLABUS_PARSE_RESULT_ENTRY_TYPE,
      CLASSES_FOLDER_GOAL_ID_JSON_KEY: classesFolderGoalId,
      TEXTBOOK_GOAL_ID_JSON_KEY: textbookGoalId,
      CLASS_MAPPING_JSON_KEY: classMapping.map((e) => e.toJsonMap()).toList(),
      ASSET_FILENAME_JSON_KEY: assetFilename,
    };
  }
}

class CourseLogEntryModule implements LogEntryModule {
  @override
  GoalLogEntry? fromJsonMap(dynamic json, int? version) {
    if (json is Map &&
        json[GoalLogEntry.TYPE_JSON_KEY] == SYLLABUS_PARSE_RESULT_ENTRY_TYPE) {
      return SyllabusParseResultLogEntry.fromJsonMap(json, version);
    }
    return null;
  }
}
