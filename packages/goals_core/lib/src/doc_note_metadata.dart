import 'package:goals_types/goals_types.dart';
import 'model.dart';

const DOC_NOTE_ENTRY_TYPE = 'docNote';

enum DocNoteKind {
  footnote('footnote'),
  endnote('endnote'),
  omittedFromExport('omittedFromExport');

  final String wireValue;
  const DocNoteKind(this.wireValue);

  static const omit = DocNoteKind.omittedFromExport;
  static const omitted = DocNoteKind.omittedFromExport;

  static DocNoteKind? fromWire(dynamic value) {
    return null; // Stub for red regression
  }
}

class DocNoteLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 1;
  static const KIND_JSON_KEY = 'k';
  static const NOTE_KIND_JSON_KEY = 'k';
  static const DISPLAY_VALUE_JSON_KEY = 'dV';
  static const DISPLAY_JSON_KEY = 'dV';

  final DocNoteKind kind;
  final String displayValue;

  const DocNoteLogEntry({
    required super.id,
    required super.creationTime,
    required this.kind,
    required this.displayValue,
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        kind,
        displayValue,
        path,
      ];

  static DocNoteLogEntry fromJsonMap(dynamic json, int? version) {
    throw UnimplementedError('Stub for red regression');
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {}; // Stub for red regression
  }
}

class DocNoteLogEntryModule implements LogEntryModule {
  @override
  GoalLogEntry? fromJsonMap(dynamic json, int? version) {
    return null; // Stub for red regression
  }
}

DocNoteLogEntry? getDocNoteEntry(Goal goal) {
  return null; // Stub for red regression
}

DocNoteLogEntry? getDocNoteEntryFromLog(Iterable<GoalLogEntry> log) {
  return null; // Stub for red regression
}

const getDocNoteLogEntry = getDocNoteEntry;
