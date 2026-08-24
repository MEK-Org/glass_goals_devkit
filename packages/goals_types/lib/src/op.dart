import 'dart:convert' show jsonDecode, jsonEncode;
import 'package:goals_types_05/goals_types.dart' as prev_goal_types;
import 'package:equatable/equatable.dart' show Equatable;
import 'version.dart' show TYPES_VERSION;

enum GoalStatus {
  pending,
  active,
  done,
  archived,
}

extension JsonStatus on GoalStatus {
  String toJson() {
    switch (this) {
      case GoalStatus.pending:
        return 'p';
      case GoalStatus.active:
        return 'a';
      case GoalStatus.done:
        return 'd';
      case GoalStatus.archived:
        return 'ar';
    }
  }

  static GoalStatus fromJson(String json) {
    switch (json) {
      case 'p':
        return GoalStatus.pending;
      case 'a':
        return GoalStatus.active;
      case 'd':
        return GoalStatus.done;
      case 'ar':
        return GoalStatus.archived;
      default:
        throw Exception('Unknown status: $json');
    }
  }
}

GoalStatus? fromPreviousGoalStatus(prev_goal_types.GoalStatus? status) {
  switch (status) {
    case prev_goal_types.GoalStatus.pending:
      return GoalStatus.pending;
    case prev_goal_types.GoalStatus.active:
      return GoalStatus.active;
    case prev_goal_types.GoalStatus.done:
      return GoalStatus.done;
    case prev_goal_types.GoalStatus.archived:
      return GoalStatus.archived;
    case null:
      return null;
  }
}

const NOTE_ENTRY_TYPE = 'n';
const ARCHIVE_NOTE_ENTRY_TYPE = 'aN';

const STATUS_ENTRY_TYPE = 's';
const CLEAR_STATUS_ENTRY_TYPE = 'cS';
const ARCHIVE_STATUS_ENTRY_TYPE = 'aS';
const ADD_STATUS_INTENTION_ENTRY_TYPE = 'aSI';
const ADD_STATUS_REFLECTION_ENTRY_TYPE = 'aSR';

const SET_PARENT_ENTRY_TYPE = 'sP';
const ADD_PARENT_ENTRY_TYPE = 'aP';
const REMOVE_PARENT_ENTRY_TYPE = 'rP';
const PARENT_CONTEXT_COMMENT_ENTRY_TYPE = 'pCC';

const PRIORITY_ENTRY_TYPE = 'p';

const MAKE_ANCHOR_ENTRY_TYPE = 'mA';
const CLEAR_ANCHOR_ENTRY_TYPE = 'cA';

const SET_SUMMARY_ENTRY_TYPE = 'su';
const CLEAR_SUMMARY_ENTRY_TYPE = 'cSu';

const DOCUMENT_CONTENTS_ENTRY_TYPE = 'd';
const CLEAR_DOCUMENT_CONTENTS_ENTRY_TYPE = 'cD';

const CREATE_INSTANCE_ENTRY_TYPE = 'cI';

const LONG_RUNNING_OPERATION_ENTRY_TYPE = 'lRO';

const COURSE_METADATA_ENTRY_TYPE = 'cM';
const READING_ASSIGNMENT_ENTRY_TYPE = 'rA';

abstract class GoalLogEntry extends Equatable {
  static const FIRST_VERSION = 3;
  static const TYPE_JSON_KEY = 't';
  static const ID_JSON_KEY = 'i';
  static const CREATION_TIME_JSON_KEY = 'cT';
  static const PATH_JSON_KEY = 'p';
  final DateTime creationTime;
  final String id;

  /// This is the full path to this note including the id of the note itself.
  final List<String>? path;
  const GoalLogEntry({required this.creationTime, required this.id, this.path});

  static final List<LogEntryModule> _modules = [];

  static void registerModule(LogEntryModule module) {
    _modules.add(module);
  }

  static GoalLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version == null || version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }

    if (json is! Map) {
      throw Exception('Invalid data: $json is not a map');
    }

    final type = json[TYPE_JSON_KEY];
    if (type == null) {
      throw Exception('Invalid data: $json is missing type');
    }

    for (final module in _modules) {
      final entry = module.fromJsonMap(json, version);
      if (entry != null) {
        return entry;
      }
    }

    switch (type) {
      case NOTE_ENTRY_TYPE:
        return NoteLogEntry.fromJsonMap(json, version);
      case ARCHIVE_NOTE_ENTRY_TYPE:
        return ArchiveNoteLogEntry.fromJsonMap(json, version);
      case STATUS_ENTRY_TYPE:
        return StatusLogEntry.fromJsonMap(json, version);
      case CLEAR_STATUS_ENTRY_TYPE:
        return ClearStatusLogEntry.fromJsonMap(json, version);
      case ARCHIVE_STATUS_ENTRY_TYPE:
        return ArchiveStatusLogEntry.fromJsonMap(json, version);
      case ADD_STATUS_INTENTION_ENTRY_TYPE:
        return AddStatusIntentionLogEntry.fromJsonMap(json, version);
      case ADD_STATUS_REFLECTION_ENTRY_TYPE:
        return AddStatusReflectionLogEntry.fromJsonMap(json, version);
      case SET_PARENT_ENTRY_TYPE:
        return SetParentLogEntry.fromJsonMap(json, version);
      case ADD_PARENT_ENTRY_TYPE:
        return AddParentLogEntry.fromJsonMap(json, version);
      case REMOVE_PARENT_ENTRY_TYPE:
        return RemoveParentLogEntry.fromJsonMap(json, version);
      case PARENT_CONTEXT_COMMENT_ENTRY_TYPE:
        return ParentContextCommentEntry.fromJsonMap(json, version);
      case PRIORITY_ENTRY_TYPE:
        return PriorityLogEntry.fromJsonMap(json, version);
      case MAKE_ANCHOR_ENTRY_TYPE:
        return MakeAnchorLogEntry.fromJsonMap(json, version);
      case CLEAR_ANCHOR_ENTRY_TYPE:
        return ClearAnchorLogEntry.fromJsonMap(json, version);
      case SET_SUMMARY_ENTRY_TYPE:
        return SetSummaryEntry.fromJsonMap(json, version);
      case CLEAR_SUMMARY_ENTRY_TYPE:
        return ClearSummaryEntry.fromJsonMap(json, version);
      case DOCUMENT_CONTENTS_ENTRY_TYPE:
        return DocumentContentsEntry.fromJsonMap(json, version);
      case CLEAR_DOCUMENT_CONTENTS_ENTRY_TYPE:
        return ClearDocumentContentsEntry.fromJsonMap(json, version);
      case CREATE_INSTANCE_ENTRY_TYPE:
        return CreateInstanceLogEntry.fromJsonMap(json, version);
      case LONG_RUNNING_OPERATION_ENTRY_TYPE:
        return LongRunningOperationEntry.fromJsonMap(json, version);
      case COURSE_METADATA_ENTRY_TYPE:
        return CourseMetadataLogEntry.fromJsonMap(json, version);
      case READING_ASSIGNMENT_ENTRY_TYPE:
        return ReadingAssignmentLogEntry.fromJsonMap(json, version);
      default:
        throw Exception('Invalid data: $json has unknown type: $type');
    }
  }

  Map<String, dynamic> toJsonMap() {
    return {
      ID_JSON_KEY: id,
      CREATION_TIME_JSON_KEY: creationTime.millisecondsSinceEpoch,
      if (path != null) PATH_JSON_KEY: path,
    };
  }

  static GoalLogEntry? fromPrevious(prev_goal_types.GoalLogEntry? legacyEntry) {
    if (legacyEntry == null) {
      return null;
    }
    if (legacyEntry is prev_goal_types.StatusLogEntry) {
      return StatusLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ArchiveNoteLogEntry) {
      return ArchiveNoteLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.NoteLogEntry) {
      return NoteLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.SetParentLogEntry) {
      return SetParentLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ArchiveStatusLogEntry) {
      return ArchiveStatusLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.PriorityLogEntry) {
      return PriorityLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.SetSummaryEntry) {
      return SetSummaryEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ClearSummaryEntry) {
      return ClearSummaryEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.MakeAnchorLogEntry) {
      return MakeAnchorLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ClearAnchorLogEntry) {
      return ClearAnchorLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.AddParentLogEntry) {
      return AddParentLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.CreateInstanceLogEntry) {
      return CreateInstanceLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ClearStatusLogEntry) {
      return ClearStatusLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.AddStatusIntentionLogEntry) {
      return AddStatusIntentionLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.AddStatusReflectionLogEntry) {
      return AddStatusReflectionLogEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ParentContextCommentEntry) {
      return ParentContextCommentEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.DocumentContentsEntry) {
      return DocumentContentsEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.ClearDocumentContentsEntry) {
      return ClearDocumentContentsEntry.fromPrevious(legacyEntry);
    } else if (legacyEntry is prev_goal_types.RemoveParentLogEntry) {
      return RemoveParentLogEntry.fromPrevious(legacyEntry);
    } else {
      throw Exception('Unknown type: ${legacyEntry.runtimeType}');
    }
  }
}

// I absolutely hate this approach but dart doesn't have structural typing
// so this is the best I can come up with for now.
// The reason I'm doing this is so that we can pass in multiple
// Log Entry Types to the goal summary renderer.
abstract class TextGoalLogEntry extends GoalLogEntry {
  static const TEXT_JSON_KEY = 'te';
  final String? text;

  const TextGoalLogEntry(
      {required super.creationTime, required super.id, super.path, this.text});

  @override
  toJsonMap() {
    return {
      ...super.toJsonMap(),
      if (text != null) TEXT_JSON_KEY: text,
    };
  }
}

class PriorityLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 4;
  static const PRIORITY_JSON_KEY = 'pr';
  final double? priority;
  const PriorityLogEntry({
    required super.creationTime,
    required super.id,
    required this.priority,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime, priority];

  static PriorityLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return PriorityLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      priority: json[PRIORITY_JSON_KEY]?.toDouble(),
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: PRIORITY_ENTRY_TYPE,
      if (priority != null) PRIORITY_JSON_KEY: priority,
    };
  }

  static PriorityLogEntry fromPrevious(
      prev_goal_types.PriorityLogEntry legacyEntry) {
    return PriorityLogEntry(
      id: legacyEntry.id,
      priority: legacyEntry.priority,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class NoteLogEntry extends TextGoalLogEntry {
  static const FIRST_VERSION = 3;
  static const UPDATE_NOTE_ENTRY_ID_JSON_KEY = 'u';

  /// If supplied, this is the id of the note entry that this entry is updating.
  /// Otherwise, this is a new note entry.
  final String? updateNoteEntryId;

  const NoteLogEntry({
    required super.creationTime,
    required super.id,
    required super.text,
    this.updateNoteEntryId,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime, text];

  static NoteLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return NoteLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      text: json[TextGoalLogEntry.TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
      updateNoteEntryId: json[UPDATE_NOTE_ENTRY_ID_JSON_KEY],
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: NOTE_ENTRY_TYPE,
      if (updateNoteEntryId != null)
        UPDATE_NOTE_ENTRY_ID_JSON_KEY: updateNoteEntryId,
    };
  }

  static NoteLogEntry? fromPrevious(prev_goal_types.NoteLogEntry? legacyEntry) {
    if (legacyEntry == null) {
      return null;
    }

    return NoteLogEntry(
      id: legacyEntry.id,
      text: legacyEntry.text,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class SetSummaryEntry extends TextGoalLogEntry {
  static const FIRST_VERSION = 5;
  const SetSummaryEntry({
    required super.creationTime,
    required super.id,
    required super.text,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime, text];

  static SetSummaryEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return SetSummaryEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      text: json[TextGoalLogEntry.TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: SET_SUMMARY_ENTRY_TYPE,
    };
  }

  static SetSummaryEntry fromPrevious(
      prev_goal_types.SetSummaryEntry legacyEntry) {
    return SetSummaryEntry(
      id: legacyEntry.id,
      text: legacyEntry.text,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class ClearSummaryEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  const ClearSummaryEntry({
    required super.creationTime,
    required super.id,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static ClearSummaryEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ClearSummaryEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CLEAR_SUMMARY_ENTRY_TYPE,
    };
  }

  static ClearSummaryEntry fromPrevious(
      prev_goal_types.ClearSummaryEntry legacyEntry) {
    return ClearSummaryEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class ArchiveNoteLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 3;
  const ArchiveNoteLogEntry({
    required super.creationTime,
    required super.id,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static ArchiveNoteLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ArchiveNoteLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: ARCHIVE_NOTE_ENTRY_TYPE,
    };
  }

  static ArchiveNoteLogEntry fromPrevious(
      prev_goal_types.ArchiveNoteLogEntry legacyEntry) {
    return ArchiveNoteLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

/// This log entry sets the parent of a goal, clearing other parents, if any.
class SetParentLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 4;
  final String? parentId;
  static const PARENT_ID_JSON_KEY = 'pI';
  const SetParentLogEntry({
    required super.id,
    required super.creationTime,
    required this.parentId,
    super.path,
  });

  @override
  List<Object?> get props => [id, parentId, creationTime];

  static SetParentLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return SetParentLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      parentId: json[PARENT_ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: SET_PARENT_ENTRY_TYPE,
      PARENT_ID_JSON_KEY: parentId,
    };
  }

  static GoalLogEntry fromPrevious(
      prev_goal_types.SetParentLogEntry legacyEntry) {
    return SetParentLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      parentId: legacyEntry.parentId,
    );
  }
}

class MakeAnchorLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  const MakeAnchorLogEntry({
    required super.id,
    required super.creationTime,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static MakeAnchorLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return MakeAnchorLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>()?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: MAKE_ANCHOR_ENTRY_TYPE,
    };
  }

  static MakeAnchorLogEntry fromPrevious(
      prev_goal_types.MakeAnchorLogEntry legacyEntry) {
    return MakeAnchorLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class ClearAnchorLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  const ClearAnchorLogEntry({
    required super.id,
    required super.creationTime,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static ClearAnchorLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ClearAnchorLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CLEAR_ANCHOR_ENTRY_TYPE,
    };
  }

  static ClearAnchorLogEntry fromPrevious(
      prev_goal_types.ClearAnchorLogEntry legacyEntry) {
    return ClearAnchorLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

/// This log entry adds a parent to a goal.
class AddParentLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  static const PARENT_ID_JSON_KEY = 'pI';
  static const DISPLAYED_CHILD_PATH_JSON_KEY = 'dCP';
  static const IS_SLICE_JSON_KEY = 'iS';
  final String parentId;
  final bool isSlice;

  // This allows users to incorporate additional path context into the child
  final List<String>? displayedChildPath;
  const AddParentLogEntry({
    required super.id,
    required super.creationTime,
    required this.parentId,
    this.isSlice = false,
    super.path,
    this.displayedChildPath,
  });

  @override
  List<Object?> get props => [id, parentId, creationTime];

  static AddParentLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return AddParentLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      parentId: json[PARENT_ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      isSlice: json[IS_SLICE_JSON_KEY] ?? false,
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
      displayedChildPath: json[DISPLAYED_CHILD_PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: ADD_PARENT_ENTRY_TYPE,
      PARENT_ID_JSON_KEY: parentId,
      if (isSlice) IS_SLICE_JSON_KEY: isSlice,
      if (displayedChildPath != null)
        DISPLAYED_CHILD_PATH_JSON_KEY: displayedChildPath,
    };
  }

  @override
  String toString() {
    return 'AddParentLogEntry: $parentId {id: $id, creationTime: $creationTime, isInstance: $isSlice, path: $path, displayedChildPath: $displayedChildPath}';
  }

  static GoalLogEntry fromPrevious(
      prev_goal_types.AddParentLogEntry legacyEntry) {
    if (legacyEntry.parentId == null) {
      return SetParentLogEntry(
        id: legacyEntry.id,
        creationTime: legacyEntry.creationTime,
        path: legacyEntry.path,
        parentId: legacyEntry.parentId,
      );
    }
    return AddParentLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      parentId: legacyEntry.parentId!,
      isSlice: legacyEntry.isSlice,
    );
  }
}

class CreateInstanceLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;

  const CreateInstanceLogEntry({
    required super.id,
    required super.creationTime,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static CreateInstanceLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return CreateInstanceLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CREATE_INSTANCE_ENTRY_TYPE,
    };
  }

  @override
  String toString() {
    return 'CreateInstanceLogEntry: {id: $id, creationTime: $creationTime, path: $path}';
  }

  static CreateInstanceLogEntry fromPrevious(
      prev_goal_types.CreateInstanceLogEntry legacyEntry) {
    return CreateInstanceLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

class RemoveParentLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  static const PARENT_ID_JSON_KEY = 'pI';
  final String parentId;
  const RemoveParentLogEntry({
    required super.id,
    required super.creationTime,
    required this.parentId,
    super.path,
  });

  @override
  List<Object?> get props => [id, parentId, creationTime];

  static RemoveParentLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return RemoveParentLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      parentId: json[PARENT_ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: REMOVE_PARENT_ENTRY_TYPE,
      PARENT_ID_JSON_KEY: parentId,
    };
  }

  static RemoveParentLogEntry fromPrevious(
      prev_goal_types.RemoveParentLogEntry legacyEntry) {
    return RemoveParentLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      parentId: legacyEntry.parentId,
    );
  }
}

class StatusLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 2;

  static const STATUS_JSON_KEY = 's';
  static const START_TIME_JSON_KEY = 'sT';
  static const END_TIME_JSON_KEY = 'eT';

  // a status log entry with a null status basically unsets the status
  // during the period it applies to.
  final GoalStatus? status;
  final DateTime? startTime;
  final DateTime? endTime;
  const StatusLogEntry({
    required super.id,
    required super.creationTime,
    this.status,
    this.startTime,
    this.endTime,
    super.path,
  });

  static StatusLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return StatusLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY]!,
      status: json[STATUS_JSON_KEY] != null
          ? JsonStatus.fromJson(json[STATUS_JSON_KEY])
          : null,
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]!),
      startTime: json[START_TIME_JSON_KEY] != null
          ? DateTime.fromMillisecondsSinceEpoch(json[START_TIME_JSON_KEY])
          : null,
      endTime: json[END_TIME_JSON_KEY] != null
          ? DateTime.fromMillisecondsSinceEpoch(json[END_TIME_JSON_KEY])
          : null,
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  static StatusLogEntry fromJson(String json, int? version) {
    return fromJsonMap(jsonDecode(json), version);
  }

  static StatusLogEntry fromPrevious(
      prev_goal_types.StatusLogEntry legacyEntry) {
    return StatusLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      status: fromPreviousGoalStatus(legacyEntry.status),
      startTime: legacyEntry.startTime,
      endTime: legacyEntry.endTime,
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: STATUS_ENTRY_TYPE,
      if (status != null) STATUS_JSON_KEY: status!.toJson(),
      if (startTime != null)
        START_TIME_JSON_KEY: startTime!.millisecondsSinceEpoch,
      if (endTime != null) END_TIME_JSON_KEY: endTime!.millisecondsSinceEpoch,
    };
  }

  @override
  List<Object?> get props => [id, status, startTime, endTime, creationTime];

  @override
  String toString() {
    return 'Status: $status ${startTime != null ? 'from $startTime' : ''} ${endTime != null ? 'until $endTime' : ''} {id: $id, creationTime: $creationTime, path: $path}';
  }
}

/// This entry is for archiving a particular status log entry.
class ArchiveStatusLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 4;
  const ArchiveStatusLogEntry({
    required super.creationTime,
    required super.id,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static ArchiveStatusLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ArchiveStatusLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: ARCHIVE_STATUS_ENTRY_TYPE,
    };
  }

  static ArchiveStatusLogEntry fromPrevious(
      prev_goal_types.ArchiveStatusLogEntry legacyEntry) {
    return ArchiveStatusLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

/// This is for removing all statuses from a goal.
class ClearStatusLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;
  const ClearStatusLogEntry({
    required super.creationTime,
    required super.id,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime];

  static ClearStatusLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ClearStatusLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CLEAR_STATUS_ENTRY_TYPE,
    };
  }

  static ClearStatusLogEntry fromPrevious(
      prev_goal_types.ClearStatusLogEntry legacyEntry) {
    return ClearStatusLogEntry(
      creationTime: legacyEntry.creationTime,
      id: legacyEntry.id,
      path: legacyEntry.path,
    );
  }
}

class AddStatusIntentionLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 4;
  static const INTENTION_TEXT_JSON_KEY = 'iT';
  static const STATUS_ID_JSON_KEY = 'sI';

  final String intentionText;

  // The id of the StatusLogEntry this is being added to.
  final String statusId;
  const AddStatusIntentionLogEntry({
    required super.id,
    required super.creationTime,
    required this.intentionText,
    required this.statusId,
    super.path,
  });

  @override
  List<Object?> get props => [id];

  static AddStatusIntentionLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return AddStatusIntentionLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      intentionText: json[INTENTION_TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      statusId: json[STATUS_ID_JSON_KEY],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: ADD_STATUS_INTENTION_ENTRY_TYPE,
      INTENTION_TEXT_JSON_KEY: intentionText,
      STATUS_ID_JSON_KEY: statusId,
    };
  }

  static AddStatusIntentionLogEntry fromPrevious(
      prev_goal_types.AddStatusIntentionLogEntry legacyEntry) {
    return AddStatusIntentionLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      intentionText: legacyEntry.intentionText,
      statusId: legacyEntry.statusId,
    );
  }
}

class AddStatusReflectionLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 4;
  static const REFLECTION_TEXT_JSON_KEY = 'rT';
  static const STATUS_ID_JSON_KEY = 'sI';

  final String reflectionText;

  // The id of the StatusLogEntry this is being added to.
  final String statusId;
  const AddStatusReflectionLogEntry({
    required super.id,
    required super.creationTime,
    required this.reflectionText,
    required this.statusId,
    super.path,
  });

  @override
  List<Object?> get props => [id];

  static AddStatusReflectionLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return AddStatusReflectionLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      reflectionText: json[REFLECTION_TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      statusId: json[STATUS_ID_JSON_KEY],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: ADD_STATUS_REFLECTION_ENTRY_TYPE,
      REFLECTION_TEXT_JSON_KEY: reflectionText,
      STATUS_ID_JSON_KEY: statusId,
    };
  }

  static AddStatusReflectionLogEntry fromPrevious(
      prev_goal_types.AddStatusReflectionLogEntry legacyEntry) {
    return AddStatusReflectionLogEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      reflectionText: legacyEntry.reflectionText,
      statusId: legacyEntry.statusId,
    );
  }
}

class ParentContextCommentEntry extends TextGoalLogEntry {
  static const FIRST_VERSION = 5;
  static const PARENT_ID_JSON_KEY = 'pI';

  // The id of the parent goal this comment is being added to.
  // TODO: should this just live on the add parent log entry?
  final String parentId;
  const ParentContextCommentEntry({
    required super.id,
    required super.creationTime,
    required this.parentId,
    super.text,
    super.path,
  });

  @override
  List<Object?> get props => [id];

  static ParentContextCommentEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ParentContextCommentEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      text: json[TextGoalLogEntry.TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      parentId: json[PARENT_ID_JSON_KEY],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: PARENT_CONTEXT_COMMENT_ENTRY_TYPE,
      PARENT_ID_JSON_KEY: parentId,
    };
  }

  static ParentContextCommentEntry fromPrevious(
      prev_goal_types.ParentContextCommentEntry legacyEntry) {
    return ParentContextCommentEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      parentId: legacyEntry.parentId,
      text: legacyEntry.text,
    );
  }
}

class DocumentContentsEntry extends TextGoalLogEntry {
  static const FIRST_VERSION = 5;

  const DocumentContentsEntry({
    required super.id,
    required super.creationTime,
    super.text,
    super.path,
  });

  @override
  List<Object?> get props => [id];

  static DocumentContentsEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return DocumentContentsEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      text: json[TextGoalLogEntry.TEXT_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: DOCUMENT_CONTENTS_ENTRY_TYPE,
    };
  }

  @override
  String toString() {
    return 'DocumentContents: $text {id: $id, creationTime: $creationTime, path: $path}';
  }

  static DocumentContentsEntry fromPrevious(
      prev_goal_types.DocumentContentsEntry legacyEntry) {
    return DocumentContentsEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
      text: legacyEntry.text,
    );
  }
}

class ClearDocumentContentsEntry extends GoalLogEntry {
  static const FIRST_VERSION = 5;

  const ClearDocumentContentsEntry({
    required super.id,
    required super.creationTime,
    super.path,
  });

  @override
  List<Object?> get props => [id];

  static ClearDocumentContentsEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ClearDocumentContentsEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
              json[GoalLogEntry.CREATION_TIME_JSON_KEY])
          .toLocal(),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: CLEAR_DOCUMENT_CONTENTS_ENTRY_TYPE,
    };
  }

  static ClearDocumentContentsEntry fromPrevious(
      prev_goal_types.ClearDocumentContentsEntry legacyEntry) {
    return ClearDocumentContentsEntry(
      id: legacyEntry.id,
      creationTime: legacyEntry.creationTime,
      path: legacyEntry.path,
    );
  }
}

enum OperationStatus {
  pending,
  running,
  completed,
  failed,
}

extension JsonOperationStatus on OperationStatus {
  String toJson() {
    switch (this) {
      case OperationStatus.pending:
        return 'p';
      case OperationStatus.running:
        return 'r';
      case OperationStatus.completed:
        return 'c';
      case OperationStatus.failed:
        return 'f';
    }
  }

  static OperationStatus fromJson(String json) {
    switch (json) {
      case 'p':
        return OperationStatus.pending;
      case 'r':
        return OperationStatus.running;
      case 'c':
        return OperationStatus.completed;
      case 'f':
        return OperationStatus.failed;
      default:
        throw Exception('Unknown operation status: $json');
    }
  }
}

class LongRunningOperationEntry extends GoalLogEntry {
  static const FIRST_VERSION = 6;
  static const OPERATION_ID_JSON_KEY = 'oId';
  static const OPERATION_TYPE_JSON_KEY = 'oT';
  static const STATUS_JSON_KEY = 's';
  static const ERROR_MESSAGE_JSON_KEY = 'eM';
  static const RESULT_DATA_JSON_KEY = 'rD';

  final String operationId;
  final String operationType;
  final OperationStatus status;
  final String? errorMessage;
  final Map<String, dynamic>? resultData;

  const LongRunningOperationEntry({
    required super.id,
    required super.creationTime,
    required this.operationId,
    required this.operationType,
    required this.status,
    this.errorMessage,
    this.resultData,
    super.path,
  });

  @override
  List<Object?> get props =>
      [id, operationId, operationType, status, errorMessage, resultData];

  static LongRunningOperationEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return LongRunningOperationEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      operationId: json[OPERATION_ID_JSON_KEY],
      operationType: json[OPERATION_TYPE_JSON_KEY],
      status: JsonOperationStatus.fromJson(json[STATUS_JSON_KEY]),
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]),
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
      errorMessage: json[ERROR_MESSAGE_JSON_KEY],
      resultData: json[RESULT_DATA_JSON_KEY]?.cast<String, dynamic>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: LONG_RUNNING_OPERATION_ENTRY_TYPE,
      OPERATION_ID_JSON_KEY: operationId,
      OPERATION_TYPE_JSON_KEY: operationType,
      STATUS_JSON_KEY: status.toJson(),
      if (errorMessage != null) ERROR_MESSAGE_JSON_KEY: errorMessage,
      if (resultData != null) RESULT_DATA_JSON_KEY: resultData,
    };
  }

  @override
  String toString() {
    return 'LongRunningOperationEntry: $operationType [$status] {id: $id, operationId: $operationId, creationTime: $creationTime, path: $path}';
  }
}

/// Marks a goal as a course with linked casebook(s)
class CourseMetadataLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 6;
  static const TEXTBOOK_GOAL_IDS_JSON_KEY = 'tGI';

  final List<String> textbookGoalIds;

  const CourseMetadataLogEntry({
    required super.id,
    required super.creationTime,
    required this.textbookGoalIds,
    super.path,
  });

  @override
  List<Object?> get props => [id, creationTime, textbookGoalIds];

  static CourseMetadataLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return CourseMetadataLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]),
      textbookGoalIds:
          (json[TEXTBOOK_GOAL_IDS_JSON_KEY] as List?)?.cast<String>() ?? [],
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: COURSE_METADATA_ENTRY_TYPE,
      TEXTBOOK_GOAL_IDS_JSON_KEY: textbookGoalIds,
    };
  }

  @override
  String toString() {
    return 'CourseMetadataLogEntry: {id: $id, textbookGoalIds: $textbookGoalIds}';
  }
}

/// Records a reading assignment (page range) on a class session goal
class ReadingAssignmentLogEntry extends GoalLogEntry {
  static const FIRST_VERSION = 6;
  static const TEXTBOOK_GOAL_ID_JSON_KEY = 'tGI';
  static const START_PAGE_JSON_KEY = 'sP';
  static const END_PAGE_JSON_KEY = 'eP';
  static const START_PAGE_FORMAT_JSON_KEY = 'sPF';
  static const END_PAGE_FORMAT_JSON_KEY = 'ePF';

  final String textbookGoalId;
  final int startPage;
  final int endPage;
  final String startPageFormat; // 'arabic' or 'roman'
  final String endPageFormat; // 'arabic' or 'roman'

  const ReadingAssignmentLogEntry({
    required super.id,
    required super.creationTime,
    required this.textbookGoalId,
    required this.startPage,
    required this.endPage,
    this.startPageFormat = 'arabic',
    this.endPageFormat = 'arabic',
    super.path,
  });

  @override
  List<Object?> get props => [
        id,
        creationTime,
        textbookGoalId,
        startPage,
        endPage,
        startPageFormat,
        endPageFormat,
      ];

  static ReadingAssignmentLogEntry fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }

    if (version != null && version < FIRST_VERSION) {
      throw Exception(
          'Invalid data: $version is before first version: $FIRST_VERSION');
    }
    return ReadingAssignmentLogEntry(
      id: json[GoalLogEntry.ID_JSON_KEY],
      creationTime: DateTime.fromMillisecondsSinceEpoch(
          json[GoalLogEntry.CREATION_TIME_JSON_KEY]),
      textbookGoalId: json[TEXTBOOK_GOAL_ID_JSON_KEY],
      startPage: json[START_PAGE_JSON_KEY],
      endPage: json[END_PAGE_JSON_KEY],
      startPageFormat: json[START_PAGE_FORMAT_JSON_KEY] ?? 'arabic',
      endPageFormat: json[END_PAGE_FORMAT_JSON_KEY] ?? 'arabic',
      path: json[GoalLogEntry.PATH_JSON_KEY]?.cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      GoalLogEntry.TYPE_JSON_KEY: READING_ASSIGNMENT_ENTRY_TYPE,
      TEXTBOOK_GOAL_ID_JSON_KEY: textbookGoalId,
      START_PAGE_JSON_KEY: startPage,
      END_PAGE_JSON_KEY: endPage,
      START_PAGE_FORMAT_JSON_KEY: startPageFormat,
      END_PAGE_FORMAT_JSON_KEY: endPageFormat,
    };
  }

  @override
  String toString() {
    return 'ReadingAssignmentLogEntry: {id: $id, textbookGoalId: $textbookGoalId, pages: $startPage-$endPage}';
  }
}

class GoalDelta extends Equatable {
  static const ID_FIELD_NAME = 'i';
  static const TEXT_FIELD_NAME = 't';
  static const LOG_ENTRY_FIELD_NAME = 'lE';

  final String id;
  final String? text;
  final GoalLogEntry? logEntry;
  const GoalDelta({required this.id, this.text, this.logEntry});

  static GoalDelta fromJson(String jsonString, int? version) {
    return fromJsonMap(jsonDecode(jsonString), version);
  }

  static GoalDelta fromJsonMap(dynamic json, int? version) {
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }
    if (version == null || version < TYPES_VERSION) {
      if (json is Map) {
        return fromPrevious(
            prev_goal_types.GoalDelta.fromJson(jsonEncode(json), version));
      } else {
        return fromPrevious(prev_goal_types.GoalDelta.fromJson(json, version));
      }
    }
    return GoalDelta(
      id: json[ID_FIELD_NAME],
      text: json[TEXT_FIELD_NAME],
      logEntry: json[LOG_ENTRY_FIELD_NAME] != null
          ? GoalLogEntry.fromJsonMap(json[LOG_ENTRY_FIELD_NAME], version)
          : null,
    );
  }

  static GoalDelta fromPrevious(prev_goal_types.GoalDelta legacyGoalDelta) {
    if (legacyGoalDelta.logEntry != null) {
      return GoalDelta(
          id: legacyGoalDelta.id,
          text: legacyGoalDelta.text,
          logEntry: GoalLogEntry.fromPrevious(legacyGoalDelta.logEntry));
    } else {
      return GoalDelta(id: legacyGoalDelta.id, text: legacyGoalDelta.text);
    }
  }

  static Map<String, dynamic> toJsonMap(GoalDelta delta) {
    final Map<String, dynamic> json = {
      ID_FIELD_NAME: delta.id,
    };
    if (delta.text != null) {
      json[TEXT_FIELD_NAME] = delta.text!;
    }
    if (delta.logEntry != null) {
      json[LOG_ENTRY_FIELD_NAME] = delta.logEntry!.toJsonMap();
    }
    return json;
  }

  static String toJson(GoalDelta delta) {
    return jsonEncode(toJsonMap(delta));
  }

  @override
  List<Object?> get props => [id, text, logEntry];
}

enum OpType {
  delta,
  disableOp,
  enableOp,
}

const DELTA_OP_TYPE = 'd';
const DISABLE_OP_TYPE = 'dO';
const ENABLE_OP_TYPE = 'eO';

abstract class Op extends Equatable {
  final String hlcTimestamp;
  final String id;
  final int version = TYPES_VERSION;
  static const HLC_JSON_KEY = 'h';
  static const ID_JSON_KEY = 'i';
  static const VERSION_JSON_KEY = 'v';
  static const TYPE_JSON_KEY = 't';

  static const LEGACY_VERSION_JSON_KEY = 'version';

  const Op({required this.hlcTimestamp, required this.id});

  String toJson() {
    return jsonEncode(toJsonMap());
  }

  Map<String, dynamic> toJsonMap() {
    return {
      HLC_JSON_KEY: hlcTimestamp,
      ID_JSON_KEY: id,
      VERSION_JSON_KEY: version,
    };
  }

  static Op fromJson(String jsonString) {
    return fromJsonMap(jsonDecode(jsonString));
  }

  /// Removes the text field from the log entry in the delta
  /// and returns the id and text of the entry if it exists.
  static (String, String)? extractEntryTextField(
      Map<String, dynamic> opJsonMap) {
    final deltaJsonMap = opJsonMap[DeltaOp.DELTA_JSON_KEY];
    if (deltaJsonMap == null) {
      return null;
    }
    if (deltaJsonMap is! Map) {
      throw Exception('Invalid data: $deltaJsonMap is not a map');
    }
    final logEntry = deltaJsonMap[GoalDelta.LOG_ENTRY_FIELD_NAME];
    if (logEntry == null) {
      return null;
    }
    if (logEntry is! Map) {
      throw Exception('Invalid data: $logEntry is not a map');
    }
    final text = logEntry[TextGoalLogEntry.TEXT_JSON_KEY];
    if (text == null) {
      return null;
    }
    final entryId = logEntry[GoalLogEntry.ID_JSON_KEY];
    logEntry[TextGoalLogEntry.TEXT_JSON_KEY] = null;
    return (entryId, text);
  }

  static Op fromJsonMap(dynamic json) {
    // This is a hack to support both the old and new version of the json.
    final int? version =
        json[VERSION_JSON_KEY] ?? json[LEGACY_VERSION_JSON_KEY];
    if (version != null && version > TYPES_VERSION) {
      throw Exception('Unsupported version: $version');
    }
    if (version == null || version < TYPES_VERSION) {
      if (json is Map) {
        return fromPrevious(prev_goal_types.Op.fromJsonMap(json));
      } else {
        return fromPrevious(prev_goal_types.Op.fromJson(json));
      }
    }
    final type = json[TYPE_JSON_KEY];
    if (type == null) {
      throw Exception('Invalid data: $json is missing type');
    }

    switch (type) {
      case DELTA_OP_TYPE:
        return DeltaOp.fromJsonMap(json);
      case DISABLE_OP_TYPE:
        return DisableOp.fromJsonMap(json);
      case ENABLE_OP_TYPE:
        return EnableOp.fromJsonMap(json);
      default:
        throw Exception('Invalid data: $json has unknown type: $type');
    }
  }

  static Op fromPrevious(prev_goal_types.Op legacyOp) {
    switch (legacyOp) {
      case prev_goal_types.DeltaOp():
        return DeltaOp.fromPrevious(legacyOp);
      case prev_goal_types.DisableOp():
        return DisableOp.fromPrevious(legacyOp);
      case prev_goal_types.EnableOp():
        return EnableOp.fromPrevious(legacyOp);
      default:
        throw Exception(
            'Invalid data: $legacyOp has unknown type: ${legacyOp.runtimeType}');
    }
  }

  @override
  List<Object?> get props => [id];
}

class DeltaOp extends Op {
  static const DELTA_JSON_KEY = 'd';
  final GoalDelta delta;
  const DeltaOp({
    required super.hlcTimestamp,
    required this.delta,
    required super.id,
  });

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      Op.TYPE_JSON_KEY: DELTA_OP_TYPE,
      DELTA_JSON_KEY: GoalDelta.toJsonMap(delta),
    };
  }

  static DeltaOp fromJsonMap(dynamic json) {
    final int? version =
        json[Op.VERSION_JSON_KEY] ?? json[Op.LEGACY_VERSION_JSON_KEY];
    return DeltaOp(
        hlcTimestamp: json[Op.HLC_JSON_KEY],
        id: json[Op.ID_JSON_KEY] ?? json[Op.HLC_JSON_KEY],
        delta: GoalDelta.fromJsonMap(json[DELTA_JSON_KEY], version));
  }

  static DeltaOp fromJson(String jsonString) {
    return fromJsonMap(jsonDecode(jsonString));
  }

  static DeltaOp fromPrevious(prev_goal_types.DeltaOp legacyOp) {
    return DeltaOp(
      hlcTimestamp: legacyOp.hlcTimestamp,
      id: legacyOp.hlcTimestamp,
      delta: GoalDelta.fromPrevious(legacyOp.delta),
    );
  }
}

class DisableOp extends Op {
  final String opId;
  static const OP_ID_JSON_KEY = 'oI';
  const DisableOp(
      {required hlcTimestamp, required this.opId, required super.id})
      : super(hlcTimestamp: hlcTimestamp);

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      Op.TYPE_JSON_KEY: DISABLE_OP_TYPE,
      OP_ID_JSON_KEY: opId,
    };
  }

  static DisableOp fromJsonMap(dynamic json) {
    return DisableOp(
      hlcTimestamp: json[Op.HLC_JSON_KEY],
      id: json[GoalLogEntry.ID_JSON_KEY] ?? json[Op.HLC_JSON_KEY],
      opId: json[OP_ID_JSON_KEY],
    );
  }

  static DisableOp fromJson(String jsonString) {
    return fromJsonMap(jsonDecode(jsonString));
  }

  static DisableOp fromPrevious(prev_goal_types.DisableOp legacyOp) {
    return DisableOp(
      hlcTimestamp: legacyOp.hlcTimestamp,
      opId: legacyOp.hlcToDisable,
      id: legacyOp.hlcTimestamp,
    );
  }
}

class EnableOp extends Op {
  static const OP_ID_JSON_KEY = 'oI';

  final String opId;
  const EnableOp({
    required hlcTimestamp,
    required this.opId,
    required super.id,
  }) : super(
          hlcTimestamp: hlcTimestamp,
        );

  @override
  Map<String, dynamic> toJsonMap() {
    return {
      ...super.toJsonMap(),
      Op.TYPE_JSON_KEY: ENABLE_OP_TYPE,
      OP_ID_JSON_KEY: opId,
    };
  }

  static EnableOp fromJsonMap(dynamic json) {
    return EnableOp(
      id: json[GoalLogEntry.ID_JSON_KEY] ?? json[Op.HLC_JSON_KEY],
      hlcTimestamp: json[Op.HLC_JSON_KEY],
      opId: json[OP_ID_JSON_KEY],
    );
  }

  static EnableOp fromJson(String jsonString) {
    return fromJsonMap(jsonDecode(jsonString));
  }

  static EnableOp fromPrevious(prev_goal_types.EnableOp legacyOp) {
    return EnableOp(
      hlcTimestamp: legacyOp.hlcTimestamp,
      opId: legacyOp.hlcToEnable,
      id: legacyOp.hlcTimestamp,
    );
  }
}

List<String> getAffectedGoalIdsFromDeltaOp(DeltaOp op) {
  final List<String> affectedGoalIds = [op.delta.id];
  final logEntry = op.delta.logEntry;

  switch (logEntry) {
    case SetParentLogEntry(parentId: final parentId):
      if (parentId != null) {
        affectedGoalIds.insert(0, parentId);
      }
      break;
    case AddParentLogEntry(parentId: final parentId) ||
          RemoveParentLogEntry(parentId: final parentId):
      affectedGoalIds.insert(0, parentId);
      break;
  }

  return affectedGoalIds;
}

abstract class LogEntryModule {
  GoalLogEntry? fromJsonMap(dynamic json, int? version);
}
