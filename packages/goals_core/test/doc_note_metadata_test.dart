import 'package:goals_core/model.dart';
import 'package:goals_types/goals_types.dart';
import 'package:goals_types/src/version.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    GoalLogEntry.registerModule(DocNoteLogEntryModule());
  });

  group('DocNoteLogEntry round-trips', () {
    test('footnote with custom display value round-trips through module', () {
      final entry = DocNoteLogEntry(
        id: 'note-entry-1',
        creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
        kind: DocNoteKind.footnote,
        displayValue: '[1]',
      );

      final json = entry.toJsonMap();
      expect(json[GoalLogEntry.TYPE_JSON_KEY], DOC_NOTE_ENTRY_TYPE);
      expect(json[DocNoteLogEntry.KIND_JSON_KEY], 'footnote');
      expect(json[DocNoteLogEntry.DISPLAY_VALUE_JSON_KEY], '[1]');

      final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
      expect(parsed, isA<DocNoteLogEntry>());
      expect(parsed, entry);
    });

    test('endnote with empty blank chip round-trips through module', () {
      final entry = DocNoteLogEntry(
        id: 'note-entry-2',
        creationTime: DateTime.fromMillisecondsSinceEpoch(2000),
        kind: DocNoteKind.endnote,
        displayValue: '',
      );

      final json = entry.toJsonMap();
      expect(json[GoalLogEntry.TYPE_JSON_KEY], DOC_NOTE_ENTRY_TYPE);
      expect(json[DocNoteLogEntry.KIND_JSON_KEY], 'endnote');
      expect(json[DocNoteLogEntry.DISPLAY_VALUE_JSON_KEY], '');

      final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
      expect(parsed, isA<DocNoteLogEntry>());
      expect(parsed, entry);
    });

    test('omittedFromExport with # auto-numbering round-trips through module', () {
      final entry = DocNoteLogEntry(
        id: 'note-entry-3',
        creationTime: DateTime.fromMillisecondsSinceEpoch(3000),
        kind: DocNoteKind.omittedFromExport,
        displayValue: '#',
      );

      final json = entry.toJsonMap();
      expect(json[GoalLogEntry.TYPE_JSON_KEY], DOC_NOTE_ENTRY_TYPE);
      expect(json[DocNoteLogEntry.KIND_JSON_KEY], 'omittedFromExport');
      expect(json[DocNoteLogEntry.DISPLAY_VALUE_JSON_KEY], '#');

      final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION);
      expect(parsed, isA<DocNoteLogEntry>());
      expect(parsed, entry);
    });
  });

  group('DocNoteLogEntry wire variations and aliases', () {
    test('parses dN wire type and alias kind values', () {
      final wireOmit = {
        'i': 'note-wire-1',
        'cT': 1000,
        't': 'dN',
        'k': 'omit',
        'dV': '#',
      };
      final parsedOmit = GoalLogEntry.fromJsonMap(wireOmit, TYPES_VERSION) as DocNoteLogEntry;
      expect(parsedOmit.kind, DocNoteKind.omittedFromExport);
      expect(parsedOmit.displayValue, '#');

      final wireOmitted = {
        'i': 'note-wire-2',
        'cT': 2000,
        't': DOC_NOTE_ENTRY_TYPE,
        'k': 'omitted',
        'dV': '',
      };
      final parsedOmitted = GoalLogEntry.fromJsonMap(wireOmitted, TYPES_VERSION) as DocNoteLogEntry;
      expect(parsedOmitted.kind, DocNoteKind.omittedFromExport);
      expect(parsedOmitted.displayValue, '');

      final wireFootnoteCap = {
        'i': 'note-wire-3',
        'cT': 3000,
        't': DOC_NOTE_ENTRY_TYPE,
        'k': 'Footnote',
        'dV': 'literal',
      };
      final parsedFootnote = GoalLogEntry.fromJsonMap(wireFootnoteCap, TYPES_VERSION) as DocNoteLogEntry;
      expect(parsedFootnote.kind, DocNoteKind.footnote);
      expect(parsedFootnote.displayValue, 'literal');
    });

    test('parses full property names fallback', () {
      final json = {
        'id': 'note-full-1',
        'creationTime': 4000,
        'type': 'docNote',
        'kind': 'endnote',
        'displayValue': 'custom',
      };
      final parsed = DocNoteLogEntry.fromJsonMap(json, TYPES_VERSION);
      expect(parsed.id, 'note-full-1');
      expect(parsed.kind, DocNoteKind.endnote);
      expect(parsed.displayValue, 'custom');
    });
  });

  group('getDocNoteEntry query and log ordering', () {
    test('returns null when goal has no doc note entry (legacy absence)', () {
      final goal = Goal(
        id: 'legacy-goal',
        creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(getDocNoteEntry(goal), isNull);
    });

    test('returns currently effective entry and handles undo / log ordering', () {
      final goal = Goal(
        id: 'doc-note-goal',
        creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
      );

      final entry1 = DocNoteLogEntry(
        id: 'entry-1',
        creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
        kind: DocNoteKind.footnote,
        displayValue: '',
      );
      final entry2 = DocNoteLogEntry(
        id: 'entry-2',
        creationTime: DateTime.fromMillisecondsSinceEpoch(2000),
        kind: DocNoteKind.endnote,
        displayValue: '#',
      );
      final entry3 = DocNoteLogEntry(
        id: 'entry-3',
        creationTime: DateTime.fromMillisecondsSinceEpoch(3000),
        kind: DocNoteKind.omittedFromExport,
        displayValue: 'omitted-note',
      );

      // Prepend entry1
      goal.prependEntry(entry1);
      expect(getDocNoteEntry(goal), entry1);
      expect(getDocNoteEntry(goal)?.kind, DocNoteKind.footnote);
      expect(getDocNoteEntry(goal)?.displayValue, '');

      // Prepend entry2 (updates configuration)
      goal.prependEntry(entry2);
      expect(getDocNoteEntry(goal), entry2);
      expect(getDocNoteEntry(goal)?.kind, DocNoteKind.endnote);
      expect(getDocNoteEntry(goal)?.displayValue, '#');

      // Prepend entry3 (updates configuration again)
      goal.prependEntry(entry3);
      expect(getDocNoteEntry(goal), entry3);
      expect(getDocNoteEntry(goal)?.kind, DocNoteKind.omittedFromExport);
      expect(getDocNoteEntry(goal)?.displayValue, 'omitted-note');

      // Undo entry3 (simulated by removing latest entry at index 0)
      goal.log.removeAt(0);
      expect(getDocNoteEntry(goal), entry2);
      expect(getDocNoteEntry(goal)?.kind, DocNoteKind.endnote);
      expect(getDocNoteEntry(goal)?.displayValue, '#');

      // Undo entry2
      goal.log.removeAt(0);
      expect(getDocNoteEntry(goal), entry1);
      expect(getDocNoteEntry(goal)?.kind, DocNoteKind.footnote);
      expect(getDocNoteEntry(goal)?.displayValue, '');

      // Undo entry1
      goal.log.removeAt(0);
      expect(getDocNoteEntry(goal), isNull);
    });

    test('preserves exact display strings byte-for-byte', () {
      final complexStrings = [
        '',
        '#',
        '   leading and trailing spaces   ',
        '§ 4.2',
        'a & b < c > "d"',
        '^footnote-1',
        '中文',
      ];

      for (final text in complexStrings) {
        final entry = DocNoteLogEntry(
          id: 'test-exact',
          creationTime: DateTime.fromMillisecondsSinceEpoch(1000),
          kind: DocNoteKind.footnote,
          displayValue: text,
        );
        final json = entry.toJsonMap();
        expect(json[DocNoteLogEntry.DISPLAY_VALUE_JSON_KEY], text);
        final parsed = GoalLogEntry.fromJsonMap(json, TYPES_VERSION) as DocNoteLogEntry;
        expect(parsed.displayValue, text);
      }
    });
  });
}
