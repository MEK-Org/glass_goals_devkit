import 'dart:convert';
import 'dart:io';

import 'package:goals_core/model.dart';
import 'package:goals_types/goals_types.dart';
import 'package:test/test.dart';

/// Operation-level DocNoteLogEntry wire coverage. The fixture is shared with
/// goals-core/src/doc-note-conversion.test.ts, so a DeltaOp written by either
/// language is read back with its kind, exact display value and path.
void main() {
  setUpAll(() {
    GoalLogEntry.registerModule(DocNoteLogEntryModule());
  });

  final fixture = jsonDecode(
          File('test/fixtures/doc_note_wire_ops.json').readAsStringSync())
      as Map<String, dynamic>;
  final ops = (fixture['ops'] as List).cast<Map<String, dynamic>>();

  test('fixture covers every kind and display value', () {
    expect(ops, hasLength(DocNoteKind.values.length * 3));
  });

  for (final wire in ops) {
    final lE = wire['d']['lE'] as Map<String, dynamic>;
    test('reads and rewrites ${lE['k']} × ${jsonEncode(lE['dV'])}', () {
      final op = Op.fromJson(jsonEncode(wire));
      expect(op, isA<DeltaOp>());
      final entry = (op as DeltaOp).delta.logEntry;
      expect(entry, isA<DocNoteLogEntry>());
      entry as DocNoteLogEntry;
      expect(entry.kind.wireValue, lE['k']);
      expect(entry.displayValue, lE['dV']);
      expect(entry.path, lE['p']);
      expect(entry.id, lE['i']);

      // Dart writes back exactly the shape the TypeScript converter reads.
      expect(jsonDecode(op.toJson()), wire);
    });
  }

  test('helper takes the newest configuration in goal.log order', () {
    final first = Op.fromJson(jsonEncode(ops[4])) as DeltaOp; // endnote "#"
    final second = Op.fromJson(jsonEncode(ops[8])) as DeltaOp; // omitted "Note A"
    final firstEntry = first.delta.logEntry!;
    final secondEntry = second.delta.logEntry!;
    // goal.log is newest first; the helper takes the first DocNoteLogEntry.
    expect(getDocNoteEntryFromLog([secondEntry, firstEntry]), secondEntry);
    expect(getDocNoteEntryFromLog([firstEntry]), firstEntry);
    expect(getDocNoteEntryFromLog(const []), isNull);
  });
}
