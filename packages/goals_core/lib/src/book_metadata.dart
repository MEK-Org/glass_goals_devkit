import 'package:goals_types/goals_types.dart';

const BOOK_SECTION_ENTRY_TYPE = 'bS';

class BookSectionLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 1;
  static const START_PAGE_JSON_KEY = 'sP';
  static const END_PAGE_JSON_KEY = 'eP';
  static const START_PAGE_FORMAT_JSON_KEY = 'sPF';
  static const END_PAGE_FORMAT_JSON_KEY = 'ePF';
  static const BOOK_GOAL_ID_JSON_KEY = 'bI';

  final int startPage;
  final int? endPage;
  final String startPageFormat;
  final String? endPageFormat;
  final String? bookGoalId;

  const BookSectionLogEntry({
    required super.id,
    required super.creationTime,
    required this.startPage,
    this.endPage,
    this.startPageFormat = 'arabic',
    this.endPageFormat,
    this.bookGoalId,
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        startPage,
        endPage,
        startPageFormat,
        endPageFormat,
        bookGoalId
      ];

  static BookSectionLogEntry fromJsonMap(dynamic json, int? version) {
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    return BookSectionLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      startPage: json[START_PAGE_JSON_KEY] is int
          ? json[START_PAGE_JSON_KEY]
          : int.parse(json[START_PAGE_JSON_KEY].toString()),
      endPage: json[END_PAGE_JSON_KEY],
      startPageFormat:
          json[START_PAGE_FORMAT_JSON_KEY] ?? json['pF'] ?? 'arabic',
      endPageFormat: json[END_PAGE_FORMAT_JSON_KEY],
      bookGoalId: json[BOOK_GOAL_ID_JSON_KEY],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: BOOK_SECTION_ENTRY_TYPE,
      START_PAGE_JSON_KEY: startPage,
      if (endPage != null) END_PAGE_JSON_KEY: endPage,
      START_PAGE_FORMAT_JSON_KEY: startPageFormat,
      if (endPageFormat != null) END_PAGE_FORMAT_JSON_KEY: endPageFormat,
      if (bookGoalId != null) BOOK_GOAL_ID_JSON_KEY: bookGoalId,
    };
  }
}

class BookLogEntryModule implements LogEntryModule {
  @override
  GoalLogEntry? fromJsonMap(dynamic json, int? version) {
    if (json is Map &&
        json[GoalLogEntry.TYPE_JSON_KEY] == BOOK_SECTION_ENTRY_TYPE) {
      return BookSectionLogEntry.fromJsonMap(json, version);
    }
    return null;
  }
}
