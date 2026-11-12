import 'package:goals_types/goals_types.dart';
import 'model.dart';

const DOC_NOTE_ENTRY_TYPE = 'docNote';
const DOC_NOTE_ALIAS_ENTRY_TYPE = 'dN';

/// Note kind configuration for a document note goal.
enum DocNoteKind {
  footnote('footnote'),
  endnote('endnote'),
  omittedFromExport('omittedFromExport');

  final String wireValue;
  const DocNoteKind(this.wireValue);

  static const omit = DocNoteKind.omittedFromExport;
  static const omitted = DocNoteKind.omittedFromExport;
  static const omitFromExport = DocNoteKind.omittedFromExport;

  static DocNoteKind? fromWire(dynamic value) {
    if (value == null) return null;
    if (value is DocNoteKind) return value;
    final s = value.toString();
    if (s == 'footnote' || s == 'Footnote') return DocNoteKind.footnote;
    if (s == 'endnote' || s == 'Endnote') return DocNoteKind.endnote;
    if (s == 'omittedFromExport' ||
        s == 'omit' ||
        s == 'omitted' ||
        s == 'omitFromExport' ||
        s == 'OmittedFromExport') {
      return DocNoteKind.omittedFromExport;
    }
    return null;
  }
}

/// Stores note-goal document configuration: note kind (footnote, endnote, or
/// omittedFromExport) and exact chip/note display value (empty for blank chip,
/// '#' for automatic numbering, or a literal label).
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
    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }
    final rawKind = json[KIND_JSON_KEY] ?? json['kind'] ?? json['noteKind'];
    final kind = DocNoteKind.fromWire(rawKind);
    if (kind == null) {
      throw Exception('Invalid data: $json has invalid note kind: $rawKind');
    }
    final rawDisplay = json[DISPLAY_VALUE_JSON_KEY] ??
        json['displayValue'] ??
        json['display'] ??
        '';
    return DocNoteLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY] ?? json['id'],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY] ?? json['creationTime']),
      kind: kind,
      displayValue: rawDisplay.toString(),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: DOC_NOTE_ENTRY_TYPE,
      KIND_JSON_KEY: kind.wireValue,
      DISPLAY_VALUE_JSON_KEY: displayValue,
    };
  }
}

class DocNoteLogEntryModule implements LogEntryModule {
  @override
  GoalLogEntry? fromJsonMap(dynamic json, int? version) {
    if (json is Map) {
      final type = json[GoalLogEntry.TYPE_JSON_KEY] ?? json['type'];
      if (type == DOC_NOTE_ENTRY_TYPE || type == DOC_NOTE_ALIAS_ENTRY_TYPE) {
        return DocNoteLogEntry.fromJsonMap(json, version);
      }
    }
    return null;
  }
}

/// Returns the currently effective [DocNoteLogEntry] for [goal], or `null` if none exists.
DocNoteLogEntry? getDocNoteEntry(Goal goal) {
  return getDocNoteEntryFromLog(goal.log);
}

/// Returns the currently effective [DocNoteLogEntry] from a log sequence, or `null` if none exists.
DocNoteLogEntry? getDocNoteEntryFromLog(Iterable<GoalLogEntry> log) {
  for (final entry in log) {
    if (entry is DocNoteLogEntry) {
      return entry;
    }
  }
  return null;
}

const getDocNoteLogEntry = getDocNoteEntry;
