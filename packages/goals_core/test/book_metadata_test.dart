import 'package:goals_core/model.dart';
import 'package:goals_types/goals_types.dart';
import 'package:goals_types/src/version.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    GoalLogEntry.registerModule(BookLogEntryModule());
  });

  test('BookLogEntry round-trips through the book module', () {
    final entry = BookLogEntry(
      id: 'book-entry',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    final json = entry.toJsonMap();
    expect(json[GoalLogEntry.TYPE_JSON_KEY], BOOK_ENTRY_TYPE);

    final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
    expect(parsed, isA<BookLogEntry>());
    expect(parsed, entry);
  });

  test('BookSectionLogEntry still parses through the book module', () {
    final entry = BookSectionLogEntry(
      id: 'section-entry',
      creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      startPage: 3,
      bookGoalId: 'book',
    );

    final parsed = GoalLogEntry.fromJsonMap(entry.toJsonMap(), TYPES_VERSION);
    expect(parsed, isA<BookSectionLogEntry>());
    expect(parsed, entry);
  });
}
