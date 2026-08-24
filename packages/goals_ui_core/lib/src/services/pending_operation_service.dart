import 'dart:async' show Stream;

import 'package:goals_core/model.dart' show Goal;
import 'package:rxdart/rxdart.dart' show ValueStream;

enum PendingOperationStatus {
  pending,
  inProgress,
  completed,
  failed,
}

abstract class PendingOperationInfo {
  String get id;
  String get description;
  PendingOperationStatus get status;
  Object? get progress;
  Object? get result;
  Object? get error;
  String? get goalId;
  String? get operationId;
  String? get operationType;
  bool get isPersistent;
  DateTime get startTime;
}

/// Optional async-operation tracking used for long-running UX affordances.
abstract class PendingOperationService {
  ValueStream<List<PendingOperationInfo>> get operations;

  String register<P, R>(String description);
  void update<P, R>(String id, {P? progress, String? description});
  void complete<P, R>(String id, {R? result});
  void fail(String id, dynamic error);
  void remove(String id);

  String registerPersistent({
    required String description,
    required String goalId,
    required String operationId,
    required String operationType,
  });

  void restoreFromHive();
  void subscribeToGoalState(Stream<Map<String, Goal>> goalStateStream);
  void dispose();
}
