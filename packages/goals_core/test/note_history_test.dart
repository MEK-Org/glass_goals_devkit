import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces chained note updates and archives by the current identity',
      () {
    final goal = Goal(
      id: 'goal',
      text: 'Goal',
      creationTime: DateTime(2026),
    );
    final note0 = NoteLogEntry(
      id: 'note-0',
      text: 'first revision',
      creationTime: DateTime(2026, 1, 1, 9),
    );
    final note1 = NoteLogEntry(
      id: 'note-1',
      text: 'second revision',
      updateNoteEntryId: note0.id,
      creationTime: DateTime(2026, 1, 1, 10),
    );
    final note2 = NoteLogEntry(
      id: 'note-2',
      text: 'latest revision',
      updateNoteEntryId: note1.id,
      creationTime: DateTime(2026, 1, 1, 11),
    );
    goal
      ..prependEntry(note0)
      ..prependEntry(note1)
      ..prependEntry(note2);

    final displayedNotes = computeFlatHistoryLog(
      WorldContext(time: DateTime(2026, 1, 1, 12)),
      GoalPath([goal.id]),
      {goal.id: goal},
    ).whereType<DetailViewLogEntryItem>().toList();

    expect(displayedNotes, hasLength(1));
    final presentedNote = displayedNotes.single.entry as NoteLogEntry;
    expect(presentedNote.id, note2.id);
    expect(presentedNote.text, note2.text);

    goal.prependEntry(ArchiveNoteLogEntry(
      id: presentedNote.id,
      creationTime: DateTime(2026, 1, 1, 12),
    ));

    final historyAfterArchive = computeFlatHistoryLog(
      WorldContext(time: DateTime(2026, 1, 1, 13)),
      GoalPath([goal.id]),
      {goal.id: goal},
    );
    expect(historyAfterArchive.whereType<DetailViewLogEntryItem>(), isEmpty);
  });
}
