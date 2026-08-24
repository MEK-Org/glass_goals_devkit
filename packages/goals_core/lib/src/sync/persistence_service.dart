import 'dart:async';
import 'dart:math' show min;

import 'package:collection/collection.dart';
import 'package:goals_core/src/util/string_utils.dart';
import 'package:goals_types/goals_types.dart' show Op;

class LoadOpsResp {
  final List<Op> ops;

  /// An opaque string that can be used to represent what has been fetched so
  /// far. This will be null iff there have been no ops for this user.
  final String? cursor;

  LoadOpsResp({required this.ops, this.cursor});
}

abstract class PersistenceService {
  Future<void> save(Iterable<Op> ops);
  Future<LoadOpsResp> load({String? cursor, int? limit});

  Future<String?> loadString(String entryId);

  // returns the total number of ops that the user has access to until cursor
  Future<int> count({String? cursor});

  Stream<(Iterable<Op> op, String cursor)> stream(String? cursor);
}

class MemoryPersistenceService implements PersistenceService {
  List<Op> ops = [];
  Map<String, String> strings = {};
  final _opStreamController =
      StreamController<(Iterable<Op>, String)>.broadcast();

  String? maxHlc;

  MemoryPersistenceService({List<Map<String, dynamic>> ops = const []}) {
    for (final op in ops) {
      this.ops.add(Op.fromJsonMap(op));
    }
  }

  final _publishFutures = <Future<void>>[];

  Future<void> get settled async {
    await Future.wait(_publishFutures);
    _publishFutures.clear();
  }

  String get _cursor => "$maxHlc";

  @override
  Future<LoadOpsResp> load({String? cursor, int? limit}) async {
    if (ops.isEmpty) {
      return LoadOpsResp(ops: []);
    }
    Iterable<Op> result = [];
    final startIndex = ops.indexWhere(
        (op) => cursor == null || op.hlcTimestamp.comesAfter(cursor));
    if (startIndex != -1) {
      result = ops.skip(startIndex);
    }
    if (limit != null) {
      result = result.take(limit);
    }
    final resultCursor = result.isNotEmpty ? result.last.hlcTimestamp : cursor;
    return LoadOpsResp(
      ops: result.toList(),
      cursor: resultCursor,
    );
  }

  @override
  Future<void> save(Iterable<Op> ops) async {
    final newOpsMap = {for (var op in ops) op.id: op};
    for (final op in ops) {
      newOpsMap[op.id] = op;
      final result = Op.extractEntryTextField(op.toJsonMap());
      if (result != null) {
        final (entryId, text) = result;
        strings[entryId] = text;
      }
      if (maxHlc == null || op.hlcTimestamp.comesAfter(maxHlc!)) {
        maxHlc = op.hlcTimestamp;
      }
    }

    this.ops = newOpsMap.values
        .sorted((a, b) => a.hlcTimestamp.compareTo(b.hlcTimestamp))
        .toList();

    // Notify listeners across an async event loop
    _publishFutures.add(Future.delayed(Duration.zero, () {
      _opStreamController.add((ops, _cursor));
    }));
  }

  @override
  Future<int> count({String? cursor}) async {
    return cursor != null ? int.parse(cursor) : ops.length;
  }

  @override
  Future<List<String>> listOpIds({String? cursor, int? limit}) async {
    if (ops.isEmpty) {
      return [];
    }
    Iterable<Op> result = ops;
    if (cursor != null) {
      final startIndex =
          ops.indexWhere((op) => op.hlcTimestamp.comesAfter(cursor));
      if (startIndex != -1) {
        result = ops.skip(startIndex);
      } else {
        result = [];
      }
    }
    if (limit != null) {
      result = result.take(limit);
    }
    return result.map((op) => op.hlcTimestamp).toList();
  }

  @override
  Future<String?> loadString(String entryId) {
    return Future.value(strings[entryId]);
  }

  @override
  Stream<(Iterable<Op>, String)> stream(_) {
    return _opStreamController.stream;
  }
}
