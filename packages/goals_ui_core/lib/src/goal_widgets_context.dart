import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Widget, WidgetsBinding;
import 'package:goals_core/sync.dart' show SyncClient;

import 'services/cloudstore_service.dart' show CloudstoreService;
import 'services/document_service.dart' show DocumentService;
import 'services/pending_operation_service.dart' show PendingOperationService;

/// Coordinates one pending UI row with its authoritative tree row by id.
class PendingGoalRegistry {
  final Set<String> _registeredGoalIds = {};
  final Set<String> _renderedGoalIds = {};

  /// Retiring ids with the callback that drops their pending row once every
  /// attached tree has proven it will not render them.
  final Map<String, void Function()> _onUnrenderable = {};

  /// Attached trees whose post-success pass is still owed, per retiring id.
  final Map<String, Set<Object>> _awaitedPasses = {};

  /// Ids each tree visited without loaded goal data in its latest pass.
  final Map<Object, Set<String>> _loadingByTree = {};
  final Map<Object, void Function()> _trees = {};

  bool isRendered(String goalId) => _renderedGoalIds.contains(goalId);

  /// Whether [tree] reported a retiring goal as still loading.
  bool isLoadingFor(Object tree) =>
      _loadingByTree[tree]?.any(_onUnrenderable.containsKey) ?? false;

  void register(String goalId) {
    _registeredGoalIds.add(goalId);
    _onUnrenderable.remove(goalId);
    _awaitedPasses.remove(goalId);
  }

  void acknowledge(String goalId) {
    if (_registeredGoalIds.contains(goalId)) {
      _renderedGoalIds.add(goalId);
    }
  }

  /// Lets [tree] take part in retirement; [renderPass] must flatten it
  /// synchronously and report via [completeRenderPass].
  void attachTree(Object tree, void Function() renderPass) {
    _trees[tree] = renderPass;
  }

  void detachTree(Object tree) {
    _trees.remove(tree);
    _loadingByTree.remove(tree);
    for (final awaited in _awaitedPasses.values) {
      awaited.remove(tree);
    }
    _evaluateAll();
  }

  /// Starts retiring [goalId] after its save succeeded. At the end of the next
  /// frame, once the trees have rebuilt with the saved state, every attached
  /// tree runs a fresh pass. A rendered goal hands off through [isRendered];
  /// one that no tree renders or is still loading calls [onUnrenderable].
  void beginRetirement(String goalId, void Function() onUnrenderable) {
    if (!_registeredGoalIds.contains(goalId)) return;
    _onUnrenderable[goalId] = onUnrenderable;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_onUnrenderable[goalId] != onUnrenderable) return;
      _awaitedPasses[goalId] = {..._trees.keys};
      for (final renderPass in _trees.values.toList()) {
        renderPass();
      }
      _evaluate(goalId);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Records [tree]'s latest pass. [loadingGoalIds] are ids it reached but has
  /// not loaded yet; they may still render, so they are not proven absent.
  void completeRenderPass(Object tree,
      {Set<String> loadingGoalIds = const {}}) {
    _loadingByTree[tree] = loadingGoalIds;
    for (final awaited in _awaitedPasses.values) {
      awaited.remove(tree);
    }
    _evaluateAll();
  }

  void _evaluateAll() {
    for (final goalId in _awaitedPasses.keys.toList()) {
      _evaluate(goalId);
    }
  }

  void _evaluate(String goalId) {
    final awaited = _awaitedPasses[goalId];
    if (awaited == null ||
        awaited.isNotEmpty ||
        _renderedGoalIds.contains(goalId) ||
        _loadingByTree.values.any((ids) => ids.contains(goalId))) {
      return;
    }
    _awaitedPasses.remove(goalId);
    final onUnrenderable = _onUnrenderable.remove(goalId);
    if (onUnrenderable == null) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // A pass from didUpdateWidget runs mid-build; drop the row after it.
      WidgetsBinding.instance.addPostFrameCallback((_) => onUnrenderable());
    } else {
      onUnrenderable();
    }
  }

  void forget(String goalId) {
    _registeredGoalIds.remove(goalId);
    _renderedGoalIds.remove(goalId);
    _onUnrenderable.remove(goalId);
    _awaitedPasses.remove(goalId);
  }

  void dispose() {
    _registeredGoalIds.clear();
    _renderedGoalIds.clear();
    _onUnrenderable.clear();
    _awaitedPasses.clear();
    _loadingByTree.clear();
    _trees.clear();
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
