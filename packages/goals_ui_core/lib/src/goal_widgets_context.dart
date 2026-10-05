import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Widget;
import 'package:goals_core/sync.dart' show SyncClient;

import 'services/cloudstore_service.dart' show CloudstoreService;
import 'services/document_service.dart' show DocumentService;
import 'services/pending_operation_service.dart' show PendingOperationService;

/// Coordinates one pending UI row with its authoritative tree row by id.
class PendingGoalRegistry {
  final Set<String> _registeredGoalIds = {};
  final Set<String> _renderedGoalIds = {};

  bool isRendered(String goalId) => _renderedGoalIds.contains(goalId);

  void register(String goalId) {
    _registeredGoalIds.add(goalId);
  }

  void acknowledge(String goalId) {
    if (_registeredGoalIds.contains(goalId)) {
      _renderedGoalIds.add(goalId);
    }
  }

  void forget(String goalId) {
    _registeredGoalIds.remove(goalId);
    _renderedGoalIds.remove(goalId);
  }

  void dispose() {
    _registeredGoalIds.clear();
    _renderedGoalIds.clear();
  }
}

/// App-wide dependency context for the goals widget package.
///
/// Bundles the services that goal-rendering widgets (Breadcrumb, GoalItem,
/// CurrentStatusChip, FlattenedGoalTree, etc.) need to read goal state and
/// dispatch mutations. Provide it once near the app root — typically right
/// inside the app's own context widget — so descendants can look it up
/// regardless of whether they happen to sit inside a FlattenedGoalTree.
class GoalWidgetsContext extends InheritedWidget {
  final SyncClient syncClient;
  final CloudstoreService? cloudstoreService;
  final DocumentService? documentService;
  final PendingOperationService? pendingOperationService;
  final PendingGoalRegistry? pendingGoalRegistry;

  const GoalWidgetsContext({
    super.key,
    required this.syncClient,
    this.cloudstoreService,
    this.documentService,
    this.pendingOperationService,
    this.pendingGoalRegistry,
    required Widget child,
  }) : super(child: child);

  static GoalWidgetsContext of(BuildContext context) {
    final maybe = maybeOf(context);
    if (maybe == null) {
      throw StateError('GoalWidgetsContext not found in widget tree');
    }
    return maybe;
  }

  static GoalWidgetsContext? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GoalWidgetsContext>();
  }

  @override
  bool updateShouldNotify(covariant GoalWidgetsContext oldWidget) {
    return syncClient != oldWidget.syncClient ||
        cloudstoreService != oldWidget.cloudstoreService ||
        documentService != oldWidget.documentService ||
        pendingOperationService != oldWidget.pendingOperationService ||
        pendingGoalRegistry != oldWidget.pendingGoalRegistry;
  }
}
