import 'dart:developer' show log;
import 'dart:math' show max, min;

import 'package:goals_core/src/util/cancellation_token.dart'
    show CancellationToken;
import 'package:goals_core/src/util/compressed_uuid.dart';
import 'package:goals_types/goals_types.dart';
import 'package:collection/collection.dart'
    show IterableExtension, IterableZip, DeepCollectionEquality;
import 'package:hlc/hlc.dart' show HLC;
import 'package:sortedmap/sortedmap.dart' show SortedMap;
import 'package:concurrent_queue/concurrent_queue.dart' show ConcurrentQueue;

import '../model.dart'
    show
        BookSectionLogEntry,
        SyllabusParseResultLogEntry,
        Goal,
        GoalInstance,
        GoalPath,
        WorldContext;

Map<String, Goal> getTransitiveSubGoals(
    Map<String, Goal> goalMap, String rootGoalId,
    {bool Function(Goal)? predicate}) {
  return _getTransitiveGoals(goalMap, rootGoalId,
      predicate: predicate, direction: TraversalDirection.down);
}

List<GoalPath> getTransitiveSubGoalPaths(
    Map<String, Goal> goalMap, String rootGoalId,
    {bool Function(Goal)? predicate}) {
  return _getTransitiveGoalPaths(goalMap, rootGoalId,
      predicate: predicate, direction: TraversalDirection.down);
}

Map<String, Goal> getTransitiveSuperGoals(
    Map<String, Goal> goalMap, String rootGoalId,
    {bool Function(Goal)? predicate}) {
  return _getTransitiveGoals(goalMap, rootGoalId,
      predicate: predicate, direction: TraversalDirection.up);
}

Map<String, Goal> getTransitiveInstances(
    Map<String, Goal> goalMap, String rootGoalId) {
  final goal = goalMap[rootGoalId]!;
  final queue = [...goal.log.whereType<CreateInstanceLogEntry>()];
  final result = <String, Goal>{};

  // we create a flattened list of the instance hierarchy
  while (queue.isNotEmpty) {
    final entry = queue.removeAt(0);
    if (result.containsKey(entry.id)) {
      continue;
    }
    final instance = goalMap[entry.id]!;
    result[entry.id] = instance;
    queue.addAll(instance.log.whereType<CreateInstanceLogEntry>());
  }

  return result;
}

Map<String, Goal> filterDoneAndArchivedGoals(
    WorldContext ctx, Map<String, Goal> goalMap) {
  final rootGoals = goalMap.values.where((goal) {
    for (final entry in goal.superGoalRelationships.entries) {
      if (goalMap.containsKey(entry.key) && entry.value == null ||
          entry.value is! AddParentLogEntry ||
          !(entry.value as AddParentLogEntry).isSlice) {
        return false;
      }
    }
    return true;
  });

  final result = <String, Goal>{};
  for (final goal in rootGoals) {
    traverseDown(
      goalMap,
      goal.id,
      onVisit: (GoalPath path,
          {required bool isLeaf, required int childIndex}) {
        final goal = goalMap[path.goalId];
        if (goal == null) {
          return TraversalDecision.dontRecurse;
        }

        final status = getGoalStatus(ctx, goal, path: path, goalMap: goalMap);

        switch (status?.status) {
          case GoalStatus.done:
          case GoalStatus.archived:
            return TraversalDecision.dontRecurse;
          default:
            result[goal.id] = goal;
            return TraversalDecision.continueTraversal;
        }
      },
    );
  }

  return result;
}

enum TraversalDirection {
  up,
  down,
}

enum TraversalOrder {
  depthFirst,
  breadthFirst,
}

Map<String, Goal> _getTransitiveGoals(
  Map<String, Goal> goalMap,
  String rootGoalId, {
  bool Function(Goal)? predicate,
  required TraversalDirection direction,
}) {
  // don't apply the predicate to the root goal

  if (goalMap[rootGoalId] == null) {
    return {};
  }
  final result = <String, Goal>{rootGoalId: goalMap[rootGoalId]!};

  final getNextIds = direction == TraversalDirection.up
      ? (Goal goal) => goal.superGoalIds
      : (Goal goal) => goal.subGoalIds;

  final queue = <String>[...(getNextIds(goalMap[rootGoalId]!))];
  while (queue.isNotEmpty) {
    final goalId = queue.removeLast();
    final goal = goalMap[goalId];

    if (goal == null || predicate != null && !predicate(goal)) {
      continue;
    }
    result[goalId] = goal;
    queue.addAll(getNextIds(goal));
  }
  return result;
}

List<GoalPath> _getTransitiveGoalPaths(
  Map<String, Goal> goalMap,
  String rootGoalId, {
  bool Function(Goal)? predicate,
  required TraversalDirection direction,
}) {
  // don't apply the predicate to the root goal

  if (goalMap[rootGoalId] == null) {
    return [];
  }
  final result = <GoalPath>[];

  _traverse(goalMap, [
    GoalPath([rootGoalId])
  ], onVisit: (GoalPath path, {required bool isLeaf, required int childIndex}) {
    final goal = goalMap[path.goalId];
    if (goal == null) {
      return TraversalDecision.dontRecurse;
    }

    if (predicate == null || predicate(goal)) {
      result.add(path);
    }
    return TraversalDecision.continueTraversal;
  }, direction: direction);

  return result;
}

Map<String, Goal> getGoalsMatchingPredicate(
    Map<String, Goal> goalMap, bool Function(Goal) predicate) {
  final result = <String, Goal>{};
  for (final goal in goalMap.values) {
    if (predicate(goal)) {
      result[goal.id] = goal;
    }
  }
  return result;
}

Goal? getActiveGoalExpiringSoonest(
    WorldContext context, Map<String, Goal> goalMap) {
  Goal? result;
  StatusLogEntry? resultActiveStatus;
  for (final goal in goalMap.values) {
    final activeStatus = goalHasStatus(context, goal, GoalStatus.active);
    if (activeStatus == null) {
      continue;
    }

    if ((result == null && resultActiveStatus == null) ||
        activeStatus.endTime != null &&
            (resultActiveStatus!.endTime == null ||
                activeStatus.endTime!.isBefore(resultActiveStatus.endTime!))) {
      result = goal;
      resultActiveStatus = activeStatus;
    }
  }

  return result;
}

Comparator<Goal> activeGoalExpiringSoonestComparator(WorldContext context) {
  return (Goal a, Goal b) {
    if (a.id == b.id) {
      return 0;
    }
    final aStatus = getGoalStatus(context, a);
    final bStatus = getGoalStatus(context, b);
    if (aStatus?.status != GoalStatus.active &&
        bStatus?.status != GoalStatus.active) {
      return 0;
    }
    if (aStatus?.status == GoalStatus.active &&
        bStatus?.status != GoalStatus.active) {
      return -1;
    }
    if (bStatus?.status == GoalStatus.active &&
        aStatus?.status != GoalStatus.active) {
      return 1;
    }
    if (aStatus?.endTime == null && bStatus?.endTime == null) {
      return 0;
    }
    if (aStatus?.endTime == null && bStatus?.endTime != null) {
      return 1;
    }
    if (bStatus?.endTime == null && aStatus?.endTime != null) {
      return -1;
    }
    return aStatus!.endTime!.compareTo(bStatus!.endTime!);
  };
}

enum TraversalDecision {
  /// indicates that we should continue traversing normally
  continueTraversal,

  /// indicates that we should stop traversing completely
  stopTraversal,

  /// indicates that we should not visit this node's children or parents (depending on traversal direction)
  dontRecurse,
}

/// This function returns whether or not the traversal should stop. If true, the traversal will stop.
void _traverse(
  Map<String, Goal> goalMap,
  Iterable<GoalPath> rootGoalPaths, {
  required OnVisit onVisit,
  OnDepart? onDepart,
  int Function(GoalPath goalA, GoalPath goalB)? traversalComparator,
  TraversalDirection direction = TraversalDirection.down,
  TraversalOrder order = TraversalOrder.breadthFirst,
}) {
  assert(order != TraversalOrder.breadthFirst || onDepart == null,
      'onDepart callback is not supported with breadth-first traversal.');

  // Use a queue for iterative traversal
  final List<_qi> queue = rootGoalPaths
      .mapIndexed((i, path) => _qi(i, path))
      .toList(growable: true);
  final Set<String> visited = {};

  while (queue.isNotEmpty) {
    final _qi(
      childIndex: currentChildIndex,
      path: currentPath,
      onDepartParent: onDepartParent
    ) = queue.removeAt(0);

    final goalId = direction == TraversalDirection.up
        ? currentPath.first
        : currentPath.last;

    // Avoid cycles by using a unique key for each path
    final pathKey = currentPath.join('/');
    if (visited.contains(pathKey)) {
      continue;
    }
    visited.add(pathKey);

    final headGoal = goalMap[goalId];
    if (headGoal == null) {
      continue;
    }

    // Detect cycles in the path
    final prevPath = direction == TraversalDirection.up
        ? currentPath.sublist(1)
        : currentPath.sublist(0, currentPath.length - 1);

    if (prevPath.contains(goalId)) {
      final index = prevPath.indexOf(goalId);
      final cycle = direction == TraversalDirection.up
          ? currentPath.sublist(index)
          : currentPath.sublist(0, index + 1);
      log('Cycle detected in goal traversal: ${cycle.map((element) => element.split('-')[0]).toList()}');
      continue;
    }

    final nextPaths = direction == TraversalDirection.up
        ? headGoal.superGoalIds
            .map((goalId) => GoalPath([goalId, ...currentPath]))
            .sorted(traversalComparator ?? (a, b) => 0)
        : headGoal.subGoalIds
            .map((goalId) => GoalPath([...currentPath, goalId]))
            .sorted(traversalComparator ?? (a, b) => 0);

    final decision = onVisit(
      currentPath,
      isLeaf: nextPaths.isEmpty,
      childIndex: currentChildIndex,
    );
    thisOnDepart() {
      onDepart?.call(currentPath,
          isLeaf: nextPaths.isEmpty, childIndex: currentChildIndex);
      onDepartParent?.call();
    }

    if (decision == TraversalDecision.dontRecurse) {
      thisOnDepart();
      continue;
    } else if (decision == TraversalDecision.stopTraversal) {
      thisOnDepart();
      return;
    }

    if (nextPaths.isEmpty) {
      thisOnDepart();
      continue;
    }

    for (final (i, path) in order == TraversalOrder.breadthFirst
        ? nextPaths.indexed
        : nextPaths.reversed.indexed) {
      if (order == TraversalOrder.breadthFirst) {
        queue
            .add(_qi(i, path, i == nextPaths.length - 1 ? thisOnDepart : null));
      } else {
        queue.insert(0,
            _qi(nextPaths.length - i - 1, path, i == 0 ? thisOnDepart : null));
      }
    }
  }
}

// Define a small data class for queue items
class _qia {
  final int childIndex;
  final GoalPath path;
  final Future<void> Function()? onDepartParent;

  _qia(this.childIndex, this.path, [this.onDepartParent]);
}

class _qi {
  final int childIndex;
  final GoalPath path;
  final void Function()? onDepartParent;

  _qi(this.childIndex, this.path, [this.onDepartParent]);
}

Future<bool> _traverseAsync(
  Map<String, Goal> goalMap,
  Iterable<GoalPath> rootGoalPath,
  Future<Goal?> Function(String goalId) loadGoal, {
  OnVisitAsync? onVisit,
  OnDepartAsync? onDepart,
  int Function(GoalPath goalA, GoalPath goalB)? traversalComparator,
  TraversalDirection direction = TraversalDirection.down,
  TraversalOrder order = TraversalOrder.breadthFirst,
  int childIndex = 0,
  CancellationToken? cancellationToken,
}) async {
  assert(order != TraversalOrder.breadthFirst || onDepart == null,
      'onDepart callback is not supported with breadth-first traversal.');

  final List<_qia> queue =
      rootGoalPath.mapIndexed((i, path) => _qia(childIndex + i, path)).toList();
  final Set<String> visited = {};

  while (queue.isNotEmpty && cancellationToken?.isCancelled != true) {
    final _qia(
      childIndex: childIndex,
      path: currentPath,
      onDepartParent: onDepartParent
    ) = queue.removeAt(0);
    final goalId = direction == TraversalDirection.up
        ? currentPath.first
        : currentPath.last;

    // Avoid cycles by using a unique key for each path
    final pathKey = currentPath.join('/');
    if (visited.contains(pathKey)) {
      continue;
    }
    visited.add(pathKey);

    // After loadGoal, goalMap (derived from stateSubject.value) should have the updated goal.
    // Re-fetch goalMap in case loadGoal modified it.
    final headGoal = goalMap[goalId] ?? await loadGoal(goalId);

    // if the goal doesn't exist in the map we'll just skip it.
    if (headGoal == null) {
      continue;
    }

    final prevPath = direction == TraversalDirection.up
        ? currentPath.sublist(1)
        : currentPath.sublist(0, currentPath.length - 1);

    if (prevPath.contains(goalId)) {
      final index = prevPath.indexOf(goalId);
      final cycle = direction == TraversalDirection.up
          ? currentPath.sublist(index)
          : currentPath.sublist(0, index + 1);
      log('Cycle detected in goal traversal: ${cycle.map((element) => element.split('-')[0]).toList()}');
      continue;
    }

    final nextPaths = direction == TraversalDirection.up
        ? headGoal.superGoalIds
            .map((superGoalId) => GoalPath([superGoalId, ...currentPath]))
            .sorted(traversalComparator ?? (a, b) => 0)
        : headGoal.subGoalIds
            .map((subGoalId) => GoalPath([...currentPath, subGoalId]))
            .sorted(traversalComparator ?? (a, b) => 0);

    final decision = await onVisit?.call(currentPath,
        isLeaf: nextPaths.isEmpty, childIndex: childIndex);
    if (decision == TraversalDecision.dontRecurse) {
      await onDepart?.call(currentPath,
          isLeaf: nextPaths.isEmpty, childIndex: childIndex);
      continue;
    } else if (decision == TraversalDecision.stopTraversal) {
      await onDepart?.call(currentPath,
          isLeaf: nextPaths.isEmpty, childIndex: childIndex);
      return true;
    }

    thisOnDepart() async {
      await onDepart?.call(currentPath,
          isLeaf: nextPaths.isEmpty, childIndex: childIndex);
      await onDepartParent?.call();
    }

    if (nextPaths.isEmpty) {
      await thisOnDepart();
      continue;
    }

    for (final (i, path) in order == TraversalOrder.breadthFirst
        ? nextPaths.indexed
        : nextPaths.reversed.indexed) {
      if (order == TraversalOrder.breadthFirst) {
        queue.add(
            _qia(i, path, i == nextPaths.length - 1 ? thisOnDepart : null));
      } else {
        queue.insert(0, _qia(i, path, i == 0 ? thisOnDepart : null));
      }
    }
  }

  return false;
}

typedef OnVisit = TraversalDecision? Function(GoalPath path,
    {required bool isLeaf, required int childIndex});
typedef OnDepart = Function(GoalPath path,
    {required bool isLeaf, required int childIndex});

typedef OnVisitAsync = Future<TraversalDecision?> Function(GoalPath path,
    {required bool isLeaf, required int childIndex});
typedef OnDepartAsync = Future<void> Function(GoalPath path,
    {required bool isLeaf, required int childIndex});

typedef OnVisitParallelLoad = TraversalDecision? Function(GoalPath path,
    {required bool isLeaf});

void traverseDown(
  Map<String, Goal> goalMap,
  String? rootGoalId, {
  /// callback for when a goal is visited. By default, the traversal will
  /// continue but traversing the children can be stopped by returning
  /// [TraversalDecision.dontRecurse] and the entire traversal can be stopped by
  /// returning [TraversalDecision.stopTraversal]
  required OnVisit onVisit,

  /// callback for after a goals children have been visited
  OnDepart? onDepart,
  int Function(GoalPath goalA, GoalPath goalB)? childTraversalComparator,
  TraversalOrder order = TraversalOrder.breadthFirst,
}) {
  _traverse(
    goalMap,
    [
      if (rootGoalId != null) GoalPath([rootGoalId])
    ],
    onVisit: onVisit,
    onDepart: onDepart,
    traversalComparator: childTraversalComparator,
    order: order,
  );
}

Future<void> traverseDownAsync(
  Map<String, Goal> goalMap,
  GoalPath? rootGoalPath, {
  Future<Goal?> Function(String)? loadGoal,

  /// callback for when a goal is visited. By default, the traversal will
  /// continue but traversing the children can be stopped by returning
  /// [TraversalDecision.dontRecurse] and the entire traversal can be stopped by
  /// returning [TraversalDecision.stopTraversal]
  required OnVisitAsync onVisit,

  /// callback for after a goals children have been visited
  OnDepartAsync? onDepart,
  TraversalOrder order = TraversalOrder.breadthFirst,
  int Function(GoalPath goalA, GoalPath goalB)? childTraversalComparator,
  int childIndex = 0,
}) async {
  loadGoal ??= (goalId) => Future.value(null);
  await _traverseAsync(
      goalMap, [if (rootGoalPath != null) rootGoalPath], loadGoal,
      onVisit: onVisit,
      onDepart: onDepart,
      order: order,
      traversalComparator: childTraversalComparator,
      childIndex: childIndex);
}

Future<void> traverseAll(
    Map<String, Goal> goalMap, Iterable<GoalPath> rootGoalPaths,
    {required OnVisit onVisit,
    OnDepart? onDepart,
    TraversalOrder order = TraversalOrder.breadthFirst,
    TraversalDirection direction = TraversalDirection.down,
    int Function(GoalPath goalA, GoalPath goalB)?
        childTraversalComparator}) async {
  _traverse(
    goalMap,
    rootGoalPaths,
    onVisit: onVisit,
    order: order,
    direction: direction,
    onDepart: onDepart,
    traversalComparator: childTraversalComparator,
  );
}

Future<void> traverseAllAsync(
    Map<String, Goal> goalMap, Iterable<GoalPath> rootGoalPaths,
    {Future<Goal?> Function(String)? loadGoal,
    OnVisitAsync? onVisit,
    OnDepartAsync? onDepart,
    TraversalOrder order = TraversalOrder.breadthFirst,
    TraversalDirection direction = TraversalDirection.down,
    int Function(GoalPath goalA, GoalPath goalB)? childTraversalComparator,
    CancellationToken? cancellationToken}) async {
  loadGoal ??= (goalId) => Future.value(null);
  await _traverseAsync(
    goalMap,
    rootGoalPaths,
    loadGoal,
    onVisit: onVisit,
    order: order,
    direction: direction,
    onDepart: onDepart,
    traversalComparator: childTraversalComparator,
    cancellationToken: cancellationToken,
  );
}

void traverseUp(
  Map<String, Goal> goalMap,
  String? rootGoalId, {
  /// callback for when a goal is visited. By default, the traversal will
  /// continue but traversing the children can be stopped by returning
  /// [TraversalDecision.dontRecurse] and the entire traversal can be stopped by
  /// returning [TraversalDecision.stopTraversal]
  required OnVisit onVisit,

  /// callback for after a goals children have been visited
  OnDepart? onDepart,
  int Function(GoalPath goalA, GoalPath goalB)? childTraversalComparator,
}) {
  _traverse(
    goalMap,
    [
      if (rootGoalId != null) GoalPath([rootGoalId])
    ],
    onVisit: onVisit,
    onDepart: onDepart,
    traversalComparator: childTraversalComparator,
    direction: TraversalDirection.up,
  );
}

/// Parallel goal loading traversal optimized for batching IndexedDB reads.
///
/// This function traverses the goal tree and aggressively issues load requests
/// for all children without waiting for them to complete. This allows the
/// batching queue system in LocalStore to combine multiple requests into a
/// single IndexedDB transaction.
///
/// Key differences from traverseAllAsync:
/// - Issues all child load requests immediately without awaiting
/// - onVisit is synchronous and returns immediately
/// - Maximizes batching opportunities for IndexedDB reads
/// - Does not wait for previous goals to load before issuing new requests
///
/// The traversal processes goals as they become available, issuing load
/// requests for their children immediately. This creates waves of parallel
/// requests that get batched together by the queue system.
Future<void> traverseParallelLoad(
  Iterable<GoalPath> rootGoalPaths,
  Future<Goal?> Function(String goalId) loadGoal, {
  required OnVisitParallelLoad onVisit,
  TraversalDirection direction = TraversalDirection.down,
  int Function(GoalPath goalA, GoalPath goalB)? childTraversalComparator,
  CancellationToken? cancellationToken,
}) async {
  final Set<String> visited = {};

  ConcurrentQueue queue = ConcurrentQueue(
    concurrency: double.maxFinite.toInt(),
  );

  processItem(GoalPath path) async {
    // Check cancellation before starting work
    if (cancellationToken?.isCancelled == true) {
      return;
    }

    final goalId = direction == TraversalDirection.up ? path.first : path.last;

    // Avoid cycles
    final pathKey = path.join('/');
    if (visited.contains(pathKey)) {
      return;
    }
    visited.add(pathKey);

    // Wait for this specific goal to load
    final headGoal = await loadGoal(goalId);

    // Check cancellation after async operation
    if (cancellationToken?.isCancelled == true) {
      return;
    }

    if (headGoal == null) {
      return;
    }

    // Check for cycles
    final prevPath = direction == TraversalDirection.up
        ? path.sublist(1)
        : path.sublist(0, path.length - 1);

    if (prevPath.contains(goalId)) {
      final index = prevPath.indexOf(goalId);
      final cycle = direction == TraversalDirection.up
          ? path.sublist(index)
          : path.sublist(0, index + 1);
      log('Cycle detected in goal traversal: ${cycle.map((e) => e.split('-')[0]).toList()}');
      return;
    }

    // Get next paths
    final nextPaths = direction == TraversalDirection.up
        ? headGoal.superGoalIds
            .map((superGoalId) => GoalPath([superGoalId, ...path]))
            .sorted(childTraversalComparator ?? (a, b) => 0)
        : headGoal.subGoalIds
            .map((subGoalId) => GoalPath([...path, subGoalId]))
            .sorted(childTraversalComparator ?? (a, b) => 0);

    // Call the synchronous onVisit callback
    final decision = onVisit(path, isLeaf: nextPaths.isEmpty);

    if (decision == TraversalDecision.stopTraversal) {
      return;
    }

    // Check cancellation before queuing more work
    if (cancellationToken?.isCancelled == true) {
      return;
    }

    // decision can be null in which case we continue traversal
    if (decision != TraversalDecision.dontRecurse && nextPaths.isNotEmpty) {
      // Add children to queue for processing
      queue.addAll(nextPaths
          .map((path) => () async => await processItem(path))
          .toList());
    }
  }

  // add initial items to the queue
  for (final path in rootGoalPaths) {
    queue.add(() async => await processItem(path));
  }

  await queue.onIdle();
}

dynamic _findAncestors(Map<String, Goal> goalMap, Set<String> frontierIds,
    Map<String, int> seenIds,
    [depth = 1]) {
  if (frontierIds.isEmpty) {
    return;
  }

  Set<String> newFrontierIds = {};
  for (final parentId in frontierIds) {
    final parent = goalMap[parentId];
    if (parent == null) {
      print('Parent goal not found: $parentId');
      throw Exception('Parent goal not found: $parentId');
    }
    for (final superGoalId in parent.superGoalIds) {
      if (!seenIds.containsKey(superGoalId)) {
        newFrontierIds.add(superGoalId);
        seenIds[superGoalId] = depth;
      }
    }
  }

  return _findAncestors(goalMap, newFrontierIds, seenIds, depth + 1);
}

List<Goal> findCommonPrefix(
    Iterable<Goal> ancestryA, Iterable<Goal> ancestryB) {
  final result = <Goal>[];
  for (final [ancestorA, ancestorB] in IterableZip([ancestryA, ancestryB])) {
    if (ancestorA.id == ancestorB.id) {
      result.add(ancestorA);
    } else {
      break;
    }
  }
  return result;
}

Map<String, int> _intersectKeys(Map<String, int> a, Map<String, int> b) {
  final result = <String, int>{};
  for (final key in a.keys) {
    if (b.containsKey(key)) {
      result[key] = max(a[key]!, b[key]!);
    }
  }
  return result;
}

String? findLatestCommonAncestor(
    Map<String, Goal> goalMap, Iterable<Goal> goals) {
  if (goals.isEmpty) {
    return null;
  }

  Map<String, int>? commonAncestryOverlap;

  for (final goal in goals) {
    final ancestors = <String, int>{goal.id: 0};
    _findAncestors(goalMap, {goal.id}, ancestors);

    if (commonAncestryOverlap == null) {
      commonAncestryOverlap = ancestors;
      continue;
    }

    commonAncestryOverlap = _intersectKeys(commonAncestryOverlap, ancestors);
  }

  if (commonAncestryOverlap!.isEmpty) {
    return null;
  }

  int? minDepth;
  String? maxDepthAncestorId;
  for (final entry in commonAncestryOverlap.entries) {
    if (minDepth == null ||
        entry.value < minDepth ||
        maxDepthAncestorId == null) {
      minDepth = entry.value;
      maxDepthAncestorId = entry.key;
    }
  }

  return maxDepthAncestorId;
}

/// The logic for goals requiring attention is as follows:
///  - Show all active tasks
///  - Don't show tasks if any of their children are marked active
///  - Show tasks that don't currently have a setting (e.g. they were previously active and have become inactive)
///  - don't show any tasks under a snoozed task.
Map<String, Goal> getGoalsRequiringAttention(
    WorldContext context, Map<String, Goal> goalMap) {
  /// The logic for goals requiring attention is as follows:
  ///  - Show all active tasks
  ///  - Don't show tasks if any of their children are marked active
  ///  - Show tasks that don't currently have a setting (i.e. they were previously active and have become inactive)
  final result = <String, Goal>{};
  final rootsRequiringAttention =
      getGoalsMatchingPredicate(goalMap, (Goal goal) {
    final status = getGoalStatus(context, goal);
    for (final superGoalId in goal.superGoalIds) {
      if (goalMap.containsKey(superGoalId)) {
        return false;
      }
    }
    return status?.status == null;
  });

  for (final goalId in rootsRequiringAttention.keys) {
    traverseDown(
      goalMap,
      goalId,
      onVisit: (GoalPath path,
          {required bool isLeaf, required int childIndex}) {
        final goal = goalMap[path.goalId];
        if (goal == null) {
          return TraversalDecision.dontRecurse;
        }

        final parentRltnPath = getPathParentEntry(goalMap, path)?.path;
        if (parentRltnPath != null &&
            !path.trailingGoalPath.containsPath(parentRltnPath)) {
          return TraversalDecision.dontRecurse;
        }

        // TODO: figure out why this doesn't work when supplying the paths
        final status = getGoalStatus(context, goal);

        // goals without a status are "transparent". In other words, we'll
        // continue searching within them, but we won't add them to the result.
        if (status == null) {
          return TraversalDecision.continueTraversal;
        }

        // this may not be correct in a world where we have path children
        if (result.containsKey(path.goalId)) {
          return TraversalDecision.dontRecurse;
        }

        switch (status.status) {
          case null:
            result[path.goalId] = goal;
            return TraversalDecision.continueTraversal;
          case GoalStatus.active:
          case GoalStatus.pending:
          case GoalStatus.done:
          case GoalStatus.archived:
            return TraversalDecision.dontRecurse;
        }
      },
    );
  }

  return result;
}

Map<String, Goal> getPreviouslyActiveGoals(
    WorldContext context, Map<String, Goal> goalMap) {
  final previouslyActiveGoals = getGoalsMatchingPredicate(goalMap, (Goal goal) {
    if (getGoalStatus(context, goal)?.status != null) {
      return false;
    }

    Set<String> archivedStatuses = {};
    for (final entry in goal.log.reversed) {
      if (entry is ArchiveStatusLogEntry) {
        archivedStatuses.add(entry.id);
      }
      if (entry is StatusLogEntry &&
          entry.status == GoalStatus.active &&
          !archivedStatuses.contains(entry.id)) {
        return true;
      }
    }
    return false;
  });

  for (final goal in goalMap.values) {
    if (getGoalStatus(context, goal)?.status == GoalStatus.pending) {
      for (final snoozedSubgoal
          in getTransitiveSubGoals(goalMap, goal.id).keys) {
        previouslyActiveGoals.remove(snoozedSubgoal);
      }
    }
  }
  return previouslyActiveGoals;
}

Iterable<Goal> getRootGoals(Map<String, Goal> goalMap) {
  return goalMap.values.where((goal) {
    for (final entry in goal.superGoalRelationships.entries) {
      if (goalMap.containsKey(entry.key) && entry.value == null ||
          entry.value is! AddParentLogEntry ||
          !(entry.value as AddParentLogEntry).isSlice) {
        return false;
      }
    }
    return true;
  });
}

// Currently, current goal status is just a function of time.
StatusLogEntry? getGoalStatus(
  WorldContext context,
  Goal goal, {
  GoalPath? path,
  Map<String, Goal>? goalMap,
}) {
  final now = context.time;

  Set<String> archivedStatuses = {};
  for (final entry in goal.log) {
    if (entry is! StatusLogEntry &&
        entry is! ArchiveStatusLogEntry &&
        entry is! ClearStatusLogEntry) {
      continue;
    }
    final entryPath = entry.path;

    // determine whether we should apply "pathless" status entries to this goal.
    // the logic is as follows:
    //  - if this is not within an instance, we should apply the status
    //  - if this is within an instance, but it is specific to that instance (i.e. not duplicated from the parent instance), we should apply the status
    //  - if this is an instance itself, do not apply the status
    //  - if this is a subgoal that has been forwarded from the original and the status is archived, apply the status
    //  - if this is a subgoal that has been forwarded from the original goal, do not apply the status
    if (path != null && entryPath == null) {
      final pathParentEntry = getPathParentEntry(goalMap!, path);
      final instancePath = getFullInstancePath(goalMap, path);
      final isInstanceSpecific = pathParentEntry?.path != null;
      final isGoalInstance = pathParentEntry?.isSlice ?? false;
      if ((instancePath != null &&
              !isInstanceSpecific &&
              (entry is! StatusLogEntry ||
                  entry.status != GoalStatus.archived)) ||
          isGoalInstance) {
        continue;
      }
    }

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && (path == null || !path.containsPath(entryPath))) {
      continue;
    }
    if (entry is ClearStatusLogEntry) {
      return null;
    }
    if (entry is StatusLogEntry &&
        !archivedStatuses.contains(entry.id) &&
        (entry.startTime == null || entry.startTime!.isBefore(now)) &&
        (entry.endTime == null || entry.endTime!.isAfter(now))) {
      return entry;
    }
    if (entry is ArchiveStatusLogEntry) {
      archivedStatuses.add(entry.id);
    }
  }
  return StatusLogEntry(
      id: 'default-status', creationTime: DateTime(1970, 1, 1), status: null);
}

int Function(GoalPath, GoalPath) getPriorityComparator(
    Map<String, Goal> goalMap) {
  return (GoalPath goalA, GoalPath goalB) {
    final defaultPriority = double.infinity;
    return (getGoalPriority(goalMap, goalA) ?? defaultPriority)
        .compareTo(getGoalPriority(goalMap, goalB) ?? defaultPriority);
  };
}

PriorityLogEntry? getGoalPriorityEntry(
    Map<String, Goal> goalMap, GoalPath? path) {
  if (path == null) {
    return null;
  }
  final goal = goalMap[path.goalId];

  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    if (entry is! PriorityLogEntry) {
      continue;
    }
    final entryPath = entry.path;

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && !path.containsPath(entryPath)) {
      continue;
    }
    return entry;
  }

  return null;
}

double? getGoalPriority(Map<String, Goal> goalMap, GoalPath? path) {
  if (path == null) {
    return null;
  }
  final goal = goalMap[path.goalId];

  if (goal == null) {
    return null;
  }

  return getGoalPriorityEntry(goalMap, path)?.priority ??
      goal.creationTime.millisecondsSinceEpoch.toDouble();
}

StatusLogEntry? goalHasStatus(
    WorldContext context, Goal goal, GoalStatus status) {
  final statusLogEntry = getGoalStatus(context, goal);
  if (statusLogEntry?.status == status) {
    return statusLogEntry;
  }
  return null;
}

// should I be accepting the world context here and using it to determine the current time?
MakeAnchorLogEntry? isAnchor(Goal? goal) {
  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    if (entry is MakeAnchorLogEntry) {
      return entry;
    }

    if (entry is ClearAnchorLogEntry) {
      return null;
    }
  }

  return null;
}

/// Returns the portion of this path that includes
/// entries that affect how the goal is shown in the tree views.
List<GoalLogEntry> getAbbreviatedLogEntries(
    WorldContext ctx, Iterable<GoalLogEntry> log) {
  PriorityLogEntry? priorityEntry;
  bool sawPriorityEntry = false;
  MakeAnchorLogEntry? anchorEntry;
  bool sawAnchorEntry = false;
  DocumentContentsEntry? documentContentsEntry;
  bool sawDocumentEntry = false;
  final pathStatuses = <GoalPath, dynamic>{};
  Set<String> archivedStatuses = {};
  for (final entry in log.sorted(
    (a, b) => b.creationTime.compareTo(a.creationTime),
  )) {
    if (entry is ArchiveStatusLogEntry) {
      archivedStatuses.add(entry.id);
    } else if ((entry is MakeAnchorLogEntry || entry is ClearAnchorLogEntry) &&
        sawAnchorEntry != true) {
      sawAnchorEntry = true;
      if (entry is MakeAnchorLogEntry) {
        anchorEntry = entry;
      }
    } else if (entry is PriorityLogEntry && !sawPriorityEntry) {
      sawPriorityEntry = true;
      if (entry.priority != null) {
        priorityEntry = entry;
      }
    }
    if (entry is ClearDocumentContentsEntry && !sawDocumentEntry) {
      sawDocumentEntry = true;
    } else if (entry is DocumentContentsEntry && !sawDocumentEntry) {
      sawDocumentEntry = true;
      documentContentsEntry = entry;
    }
    final entryPath = GoalPath(entry.path ?? []);
    if (pathStatuses.containsKey(entryPath)) {
      continue;
    }
    if (entry is ClearStatusLogEntry) {
      pathStatuses[entryPath] = entry;
    } else if (entry is StatusLogEntry &&
        !archivedStatuses.contains(entry.id) &&
        entry.status != null) {
      if ((entry.startTime == null || entry.startTime!.isBefore(ctx.time)) &&
          (entry.endTime == null || entry.endTime!.isAfter(ctx.time))) {
        pathStatuses[entryPath] = entry;
      }
    }
  }

  return [
    if (priorityEntry != null) priorityEntry,
    if (anchorEntry != null) anchorEntry,
    if (documentContentsEntry != null) documentContentsEntry,
    ...pathStatuses.values,
  ];
}

SetSummaryEntry? hasSummary(
  Map<String, Goal> goalMap,
  GoalPath path,
) {
  final goal = goalMap[path.goalId];
  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    final entryPath = entry.path;

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && path.containsPath(entryPath) == false) {
      continue;
    }
    if (entry is ClearSummaryEntry) {
      return null;
    }
    if (entry is SetSummaryEntry) {
      return entry;
    }
  }

  return null;
}

GoalLogEntry? getDocumentEntry(
  GoalPath? path, {
  required Map<String, Goal> goalMap,
}) {
  if (path == null) {
    return null;
  }

  final goal = goalMap[path.goalId];

  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    final entryPath = entry.path;

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && !path.containsPath(entryPath)) {
      continue;
    }

    if (entry is ClearDocumentContentsEntry) {
      return entry;
    }
    if (entry is DocumentContentsEntry) {
      return entry;
    }
  }

  return null;
}

ParentContextCommentEntry? hasParentContext(Goal? goal, String? parentId) {
  if (goal == null || parentId == null) {
    return null;
  }

  for (final entry in goal.log) {
    if (entry is ParentContextCommentEntry && entry.parentId == parentId) {
      if (entry.text?.isEmpty == true) {
        return null;
      }
      return entry;
    }
  }

  return null;
}

Map<String, ParentContextCommentEntry> getAllParentContext(Goal? goal) {
  final result = <String, ParentContextCommentEntry>{};

  if (goal == null) {
    return result;
  }

  for (final entry in goal.log) {
    if (entry is ParentContextCommentEntry &&
        !result.containsKey(entry.parentId)) {
      result[entry.parentId] = entry;
    }
  }

  return result;
}

/// Returns the portion of this path that is an "instance path". In other words,
/// it's a path where the first goalid in the path has an instance child.
/// If this path has more than one instance on it, it will return
/// the instance path starting from the last instance parent.
GoalPath? getLogEntryPath(Map<String, Goal> goalMap, GoalPath? path) {
  if (path == null) {
    return null;
  }
  List<String>? instancePath;
  final trailingGoalPath = path.trailingGoalPath;

  // iterate over the parent path to see if any of
  // the parents are instances. If we see an instance, we set the path on the log entry
  // to the path starting from that first instance parent.
  for (final (i, pathPart) in trailingGoalPath.indexed) {
    final goal = goalMap[pathPart];
    if (goal == null) {
      return null;
    }
    if (goal is GoalInstance) {
      instancePath = trailingGoalPath.sublist(i);
    } else if (i < trailingGoalPath.length - 1) {
      final addParentEntry = goal.subGoalRelationships[trailingGoalPath[i + 1]];
      if (addParentEntry is AddParentLogEntry && addParentEntry.isSlice) {
        instancePath = trailingGoalPath.sublist(i);
      }
    }
  }
  return instancePath != null ? GoalPath(instancePath) : null;
}

/// Returns the portion of this path that is an "instance path". In other words,
/// it's a path where the first goalid in the path has an instance child.
///
/// If this path has more than one instance on it, it will return the path
/// starting from the first instance parent.
GoalPath? getFullInstancePath(Map<String, Goal> goalMap, GoalPath? path) {
  if (path == null) {
    return null;
  }
  List<String>? instancePath;
  final trailingGoalPath = path.trailingGoalPath;

  // iterate over the parent path to see if any of
  // the parents are instances. If we see an instance, we set the path on the log entry
  // to the path starting from that first instance parent.
  for (final (i, pathPart) in trailingGoalPath.indexed) {
    final goal = goalMap[pathPart];
    if (goal is GoalInstance) {
      instancePath = trailingGoalPath.sublist(i);
      break;
    }
  }
  return instancePath != null ? GoalPath(instancePath) : null;
}

AddParentLogEntry? getPathParentEntry(
    Map<String, Goal> goalMap, GoalPath? path) {
  if (path == null) {
    return null;
  }
  final trailingGoalPath = path.trailingGoalPath;
  if (trailingGoalPath.length < 2) {
    return null;
  }

  final goal = goalMap[trailingGoalPath.last];
  if (goal == null) {
    return null;
  }

  final addParentEntry = goal
      .superGoalRelationships[trailingGoalPath[trailingGoalPath.length - 2]];
  if (addParentEntry is AddParentLogEntry) return addParentEntry;
  return null;
}

final GOAL_PATH_REFERENCE_REGEX = RegExp(r'#(gg:\/\/[a-zA-Z0-9_:\/-]+)#');

String replaceGoalPathReferences(
    String docContents, GoalPath Function(GoalPath refPath) mapper) {
  for (final match
      in [...GOAL_PATH_REFERENCE_REGEX.allMatches(docContents)].reversed) {
    final refPath = GoalPath.parse(match.group(1)!);

    if (refPath == null) {
      continue;
    }

    final newRefPath = mapper(refPath);

    docContents = docContents.replaceRange(
        match.start, match.end, '#${newRefPath.toString()}#');
  }
  return docContents;
}

typedef GoalPredicate = bool Function(
    WorldContext context, Map<String, Goal> goalMap, GoalPath path, Goal goal);

GoalPredicate getStatusPredicate(Set<GoalStatus?> statusesToShow) =>
    (WorldContext worldContext, goalMap, GoalPath path, Goal goal) {
      final status =
          getGoalStatus(worldContext, goal, path: path, goalMap: goalMap);
      if (status == null) {
        return true;
      }
      return statusesToShow.contains(status.status);
    };

/// Returns a map of goalId -> newPriority for all siblings that need their
/// priority bumped when inserting between two goals with equal priority.
/// The iteration continues until we find a goal with a priority that doesn't conflict.
Map<String, double> getConflictingPriorityBumps(
  Map<String, Goal> goalMap,
  GoalPath? parentPath,
  GoalPath? pathAfter,
  double newGoalPriority,
) {
  final result = <String, double>{};

  if (pathAfter == null) {
    return result;
  }

  final afterGoal = goalMap[pathAfter.goalId];
  if (afterGoal == null) {
    return result;
  }

  // Get the parent to iterate over siblings
  final parentId = pathAfter.parentId;
  final parent = parentId != null ? goalMap[parentId] : null;

  // Get all sibling goal IDs
  List<String> siblingIds;
  if (parent != null) {
    siblingIds = parent.subGoalIds.toList();
  } else {
    // Root level goals - we need to get them differently
    // For now, we'll just handle the immediate next goal
    final afterPriority = getGoalPriority(goalMap, pathAfter);
    if (afterPriority != null && afterPriority <= newGoalPriority) {
      result[pathAfter.goalId] = newGoalPriority + 1;
    }
    return result;
  }

  // Sort siblings by their current priority
  final siblingPaths =
      siblingIds.map((id) => GoalPath([...?parentPath, id])).toList();

  final priorityComparator = getPriorityComparator(goalMap);
  siblingPaths.sort(priorityComparator);

  // Find the index of pathAfter in the sorted list
  int afterIndex = siblingPaths.indexWhere((p) => p.goalId == pathAfter.goalId);
  if (afterIndex < 0) {
    return result;
  }

  // Iterate from afterIndex onwards, bumping priorities as needed
  double nextRequiredPriority = newGoalPriority + 1;

  for (int i = afterIndex; i < siblingPaths.length; i++) {
    final siblingPath = siblingPaths[i];
    final siblingPriority = getGoalPriority(goalMap, siblingPath);

    if (siblingPriority == null) {
      break;
    }

    // If this sibling's priority would conflict (is <= the new goal or previous bumped goal)
    if (siblingPriority < nextRequiredPriority) {
      result[siblingPath.goalId] = nextRequiredPriority;
      nextRequiredPriority = nextRequiredPriority + 1;
    } else {
      // Found a goal with priority that doesn't conflict - we can stop
      break;
    }
  }

  return result;
}

double? getGoalPriorityBetween(
  Map<String, Goal> goalMap, {
  GoalPath? pathBefore,
  GoalPath? pathAfter,
}) {
  final priorityBefore = getGoalPriority(goalMap, pathBefore);
  final priorityAfter = getGoalPriority(goalMap, pathAfter);

  if (priorityBefore == null && priorityAfter == null) {
    return null;
  }

  if (priorityBefore != null && priorityAfter != null) {
    // If priorities are equal (e.g., both goals were created at the same time
    // and have no explicit priority), we need to create a distinct value.
    // The dropped goal gets priorityBefore + 1, and the caller should also
    // bump nextGoal's priority to priorityBefore + 2 using getNextGoalBumpedPriority().
    if (priorityBefore == priorityAfter) {
      return priorityBefore + 1;
    }
    return (priorityBefore + priorityAfter) / 2;
  } else if (priorityAfter != null) {
    return priorityAfter / 2;
  }

  // the largest priority value (mapping to the lowest priority) is always the current time in millis
  return min(
      priorityBefore! * 2, DateTime.now().millisecondsSinceEpoch.toDouble());
}

Future<Iterable<Op>> computeCompressedHistory(
    Map<String, Goal> goalMap, Future<String?> Function(String) loadString,
    {bool removeArchived = false, DateTime? after}) async {
  // Keep track of the entry objects that we've added
  // and, if we've added the identical entry object, skip it.
  final addedEntries = Set<GoalLogEntry>.identity();

  final opsToCreate = <(GoalDelta, DateTime)>[];

  final archivedToDelete = <String, List<GoalLogEntry>>{};

  for (final goal in goalMap.values
      .sorted((a, b) => a.creationTime.compareTo(b.creationTime))) {
    final entriesToKeep = <GoalLogEntry>[];
    final compressedGoalId = Cupid.toNewId(goal.id);

    Map<String, GoalLogEntry> items = {};
    final paths = <GoalPath>{};
    for (final entry
        in goal is GoalInstance ? goal.selfLog.reversed : goal.log.reversed) {
      if (entry.path != null) {
        paths.add(GoalPath(entry.path!));
      }

      String? textContents;
      if (entry is TextGoalLogEntry) {
        textContents = await loadString(entry.id);
      }
      final compressedEntryId = Cupid.toNewId(entry.id);

      switch (entry) {
        case NoteLogEntry():
          final noteId = entry.updateNoteEntryId != null
              ? Cupid.toNewId(entry.updateNoteEntryId!)
              : compressedEntryId;
          final originalNoteDate = items[noteId]?.creationTime;

          items[noteId] = NoteLogEntry(
            creationTime: originalNoteDate ?? entry.creationTime,
            id: compressedEntryId,
            text: textContents,
            // intentionally drop the path here
          );
          break;
        case ArchiveNoteLogEntry():
          items.remove(compressedEntryId);
          break;
        case ArchiveStatusLogEntry():
          final archivedStatusEntry = items[compressedEntryId];
          if (archivedStatusEntry != null &&
              archivedStatusEntry is StatusLogEntry) {
            items["$compressedEntryId-archive"] = ArchiveStatusLogEntry(
              creationTime: entry.creationTime,
              id: compressedEntryId,
              path: entry.path?.map(Cupid.toNewId).toList(),
            );
          }
          break;
        case StatusLogEntry():
        case ClearStatusLogEntry():
        case CreateInstanceLogEntry():
          final map = entry.toJsonMap();

          map[GoalLogEntry.ID_JSON_KEY] = compressedEntryId;
          map[GoalLogEntry.PATH_JSON_KEY] =
              entry.path?.map(Cupid.toNewId).toList();
          items[compressedEntryId] = GoalLogEntry.fromJsonMap(map, 6);
          break;
        case AddStatusIntentionLogEntry():
          final map = entry.toJsonMap();

          map[GoalLogEntry.ID_JSON_KEY] = compressedEntryId;
          map[GoalLogEntry.PATH_JSON_KEY] =
              entry.path?.map(Cupid.toNewId).toList();
          map[AddStatusIntentionLogEntry.STATUS_ID_JSON_KEY] =
              Cupid.toNewId(entry.statusId);
          items[compressedEntryId] = GoalLogEntry.fromJsonMap(map, 6);
          break;
        case AddStatusReflectionLogEntry():
          final map = entry.toJsonMap();

          map[GoalLogEntry.ID_JSON_KEY] = compressedEntryId;
          map[GoalLogEntry.PATH_JSON_KEY] =
              entry.path?.map(Cupid.toNewId).toList();
          map[AddStatusReflectionLogEntry.STATUS_ID_JSON_KEY] =
              Cupid.toNewId(entry.statusId);
          items[compressedEntryId] = GoalLogEntry.fromJsonMap(map, 6);
          break;

        case ParentContextCommentEntry():
          items[compressedEntryId] = ParentContextCommentEntry(
            creationTime: entry.creationTime,
            id: compressedEntryId,
            text: textContents,
            parentId: Cupid.toNewId(entry.parentId),
            path: entry.path?.map(Cupid.toNewId).toList(),
          );
          break;

        case SetSummaryEntry():
          final compressedEntryPath = entry.path?.map(Cupid.toNewId).toList();
          items["${compressedEntryPath?.toString() ?? compressedGoalId}-summary"] =
              SetSummaryEntry(
            creationTime: entry.creationTime,
            id: compressedEntryId,
            text: textContents,
            path: compressedEntryPath,
          );
          break;
        case ClearSummaryEntry():
          final compressedEntryPath = entry.path?.map(Cupid.toNewId).toList();
          items.remove(
              "${compressedEntryPath?.toString() ?? compressedGoalId}-summary");
          break;

        case MakeAnchorLogEntry():
          items["$compressedGoalId-anchor"] = MakeAnchorLogEntry(
            creationTime: entry.creationTime,
            id: compressedEntryId,
            path: entry.path?.map(Cupid.toNewId).toList(),
          );
          break;
        case ClearAnchorLogEntry():
          items.remove("$compressedGoalId-anchor");
          break;

        case DocumentContentsEntry():
          items["$compressedGoalId-document"] = DocumentContentsEntry(
            creationTime: entry.creationTime,
            id: compressedEntryId,
            text: textContents != null
                ? replaceGoalPathReferences(
                    textContents,
                    (refPath) => GoalPath([
                          ...refPath.map((part) {
                            if (part == 'comp' || part == 'name') {
                              return part;
                            }
                            return Cupid.toNewId(part);
                          })
                        ]))
                : null,
            path: entry.path?.map(Cupid.toNewId).toList(),
          );
          break;
        case ClearDocumentContentsEntry():
          items.remove("$compressedGoalId-document");
          break;
        case PriorityLogEntry():
          final compressedEntryPath = entry.path?.map(Cupid.toNewId).toList();
          items["${compressedEntryPath != null ? GoalPath(compressedEntryPath).toString() : compressedGoalId}-priority"] =
              PriorityLogEntry(
            creationTime: entry.creationTime,
            priority: entry.priority,
            id: compressedEntryId,
            path: entry.path?.map(Cupid.toNewId).toList(),
          );
          break;
      }
    }

    for (final entry in items.values) {
      entriesToKeep.add(entry);
    }

    for (final MapEntry(key: parentId, value: entry)
        in goal.superGoalRelationships.entries) {
      final compressedParentId = Cupid.toNewId(parentId);
      if (goalMap[parentId] != null && entry != null) {
        final entryMap = entry.toJsonMap();
        entryMap[GoalLogEntry.ID_JSON_KEY] = Cupid.toNewId(entry.id);
        entryMap[AddParentLogEntry.PARENT_ID_JSON_KEY] = compressedParentId;
        entryMap[GoalLogEntry.PATH_JSON_KEY] =
            entry.path?.map(Cupid.toNewId).toList();
        entryMap[AddParentLogEntry.DISPLAYED_CHILD_PATH_JSON_KEY] =
            entryMap[AddParentLogEntry.DISPLAYED_CHILD_PATH_JSON_KEY]
                ?.map((e) => Cupid.toNewId(e))
                .toList();

        entriesToKeep.add(GoalLogEntry.fromJsonMap(entryMap, 6));
        final referencedEntriesToRestore = archivedToDelete[compressedParentId];
        if (referencedEntriesToRestore != null) {
          for (final entry in referencedEntriesToRestore) {
            opsToCreate.add((
              GoalDelta(id: compressedParentId, logEntry: entry),
              entry.creationTime
            ));
          }
        }
      }
    }

    if (removeArchived) {
      bool allArchived = true;
      final status = getGoalStatus(WorldContext.now(), goal, goalMap: goalMap);

      if (status != null && status.status != GoalStatus.archived) {
        allArchived = false;
      } else {
        for (final path in paths) {
          final status = getGoalStatus(WorldContext.now(), goal,
              path: path, goalMap: goalMap);
          if (status != null && status.status != GoalStatus.archived) {
            allArchived = false;
            break;
          }
        }
      }

      if (allArchived) {
        archivedToDelete[compressedGoalId] = entriesToKeep;
        continue;
      }
    }

    if (goal is! GoalInstance) {
      opsToCreate.add((
        GoalDelta(id: compressedGoalId, text: goal.text),
        goal.creationTime
      ));
    } else if (goal.text != goal.goal.text) {
      opsToCreate.add((
        GoalDelta(id: compressedGoalId, text: goal.text),
        // kinda gross, but we want to make sure that this definitely comes after the CreateInstanceLogEntry
        goal.creationTime.add(Duration(milliseconds: 1))
      ));
    }

    for (final entry in entriesToKeep) {
      if (addedEntries.contains(entry)) {
        continue;
      }
      addedEntries.add(entry);
      opsToCreate.add((
        GoalDelta(id: compressedGoalId, logEntry: entry),
        entry.creationTime.isAfter(goal.creationTime)
            ? entry.creationTime
            : entry.creationTime.add(Duration(milliseconds: 1))
      ));
    }
  }

  final ops = SortedMap<String, Op>();

  final goalsSeen = <String>{};
  final dependencyMap = <String, List<GoalDelta>>{};
  final sortedOps = opsToCreate.sorted((a, b) => a.$2.compareTo(b.$2));

  HLC? lastHlc;
  for (final (goalDelta, creationTime) in sortedOps) {
    if (lastHlc?.timestamp == creationTime.millisecondsSinceEpoch) {
      lastHlc = lastHlc!.increment();
    } else {
      final opHlc = HLC(
          timestamp: sortedOps.first.$2.millisecondsSinceEpoch,
          count: 0,
          node: "migrate");
      lastHlc = lastHlc != null ? lastHlc.receive(opHlc) : opHlc;
    }
    if (after != null && creationTime.isBefore(after)) {
      continue;
    }

    switch (goalDelta.logEntry) {
      case SetParentLogEntry setParent:
        final parentId = setParent.parentId;
        if (parentId == null) {
          break;
        }
        if (!goalsSeen.contains(setParent.parentId)) {
          try {
            var parentGoal =
                goalMap[Cupid.decode(setParent.parentId!).toUuid()];
            // It's possible that the original id was not a valid UUID
            // In that case, we can't decode the new id to recover the original id
            // so we need to iterate over the goalMap to find the parent goal
            if (parentGoal == null) {
              for (final MapEntry(key: goalId, value: goal)
                  in goalMap.entries) {
                if (Cupid.toNewId(goalId) == setParent.parentId) {
                  parentGoal = goal;
                  break;
                }
              }
            }
            if (parentGoal != null) {
              dependencyMap.putIfAbsent(setParent.parentId!, () => []);
              dependencyMap[setParent.parentId]!.add(goalDelta);
            }
          } catch (e) {
            print('Error decoding parentId: $parentId');
          }

          continue;
        }
        break;
      case AddParentLogEntry addParent:
        if (!goalsSeen.contains(addParent.parentId)) {
          final parentGoal = goalMap[Cupid.decode(addParent.parentId).toUuid()];
          if (parentGoal != null) {
            dependencyMap.putIfAbsent(addParent.parentId, () => []);
            dependencyMap[addParent.parentId]!.add(goalDelta);
          }
          continue;
        }
        break;
      case RemoveParentLogEntry removeParent:
        if (!goalsSeen.contains(removeParent.parentId)) {
          final parentGoal =
              goalMap[Cupid.decode(removeParent.parentId).toUuid()];
          if (parentGoal != null) {
            dependencyMap.putIfAbsent(removeParent.parentId, () => []);
            dependencyMap[removeParent.parentId]!.add(goalDelta);
          }
          continue;
        }
        break;
    }
    goalsSeen.add(goalDelta.id);

    final op = DeltaOp(
      delta: goalDelta,
      id: Cupid.random().encode(),
      hlcTimestamp: lastHlc.pack(),
    );
    ops[op.id] = op;

    final unlockedDependencies = <GoalDelta>[
      ...(dependencyMap[goalDelta.id] ?? [])
    ];
    dependencyMap.remove(goalDelta.id);
    while (unlockedDependencies.isNotEmpty) {
      lastHlc = lastHlc!.increment();
      final dependency = unlockedDependencies.removeAt(0);
      if (dependencyMap[dependency.id] != null) {
        unlockedDependencies.addAll(dependencyMap[dependency.id]!);
        dependencyMap.remove(dependency.id);
      }
      final depOp = DeltaOp(
        delta: dependency,
        id: Cupid.random().encode(),
        hlcTimestamp: lastHlc.pack(),
      );
      ops[depOp.id] = depOp;
    }
  }

  return ops.values;
}

abstract class HistoryItem {
  final GoalPath path;
  final DateTime time;

  const HistoryItem({required this.path, required this.time});
}

class DetailViewLogEntryItem extends HistoryItem {
  final GoalLogEntry entry;
  final bool archived;
  final int depth;

  // This could be either an AddStatusIntentionLogEntry or an AddStatusReflectionLogEntry
  final GoalLogEntry? statusNote;

  const DetailViewLogEntryItem({
    required super.path,
    required this.entry,
    this.archived = false,
    required super.time,
    this.statusNote,
    this.depth = 0,
  });
}

class DetailViewGoalCreationItem extends HistoryItem {
  const DetailViewGoalCreationItem({
    required super.path,
    required super.time,
  });
}

List<HistoryItem> computeFlatHistoryLog(WorldContext worldContext,
    GoalPath rootGoalPath, Map<String, Goal> goalMap) {
  final goal = goalMap[rootGoalPath.goalId];
  if (goal == null) {
    return [];
  }
  Map<String, DetailViewLogEntryItem> items = {};
  for (final entry in goal.log.sortedBy((a) => a.creationTime)) {
    switch (entry) {
      case NoteLogEntry():
        final originalNoteEntry =
            items[entry.updateNoteEntryId ?? entry.id]?.entry;
        var entryPath = entry.path;
        if (items[entry.id] != null) {
          entryPath = items[entry.id]?.entry.path;
        }
        items[originalNoteEntry?.id ?? entry.id] = DetailViewLogEntryItem(
            entry: NoteLogEntry(
              creationTime:
                  originalNoteEntry?.creationTime ?? entry.creationTime,
              id: entry.id,
              text: entry.text,
              path: entryPath,
            ),
            time: originalNoteEntry?.creationTime ?? entry.creationTime,
            path: rootGoalPath);
        break;
      case ArchiveNoteLogEntry():
        items.remove(entry.id);
        break;
      case ArchiveStatusLogEntry():
        final archivedStatusEntry = items[entry.id]?.entry;
        if (archivedStatusEntry != null &&
            archivedStatusEntry is StatusLogEntry) {
          // TODO: I'm not crazy about the way I'm doing this.
          items["${entry.id}-archive"] = DetailViewLogEntryItem(
            entry: archivedStatusEntry,
            time: entry.creationTime,
            archived: true,
            path: rootGoalPath,
          );
        }
      case StatusLogEntry():
        items["${entry.id}-creation"] = DetailViewLogEntryItem(
          entry: entry,
          path: rootGoalPath,
          time: entry.creationTime,
        );

        // Only add an end entry for active statuses.
        if (entry.endTime != null &&
            entry.endTime != entry.creationTime &&
            entry.endTime!.isBefore(worldContext.time) &&
            entry.status == GoalStatus.active &&
            // If the goal is archived or done by the time the status ends, don't show the end entry.
            ![GoalStatus.archived, GoalStatus.done].contains(getGoalStatus(
                    WorldContext(time: entry.endTime!),
                    goalMap[rootGoalPath.goalId]!)
                ?.status)) {
          items["${entry.id}-end"] = DetailViewLogEntryItem(
            entry: entry,
            path: rootGoalPath,
            time: entry.endTime!,
          );
        }

        break;
      case AddStatusIntentionLogEntry():
        final existingItem = items["${entry.statusId}-creation"];
        if (existingItem != null && existingItem.entry is StatusLogEntry) {
          items["${entry.statusId}-creation"] = DetailViewLogEntryItem(
            entry: existingItem.entry,
            path: existingItem.path,
            time: existingItem.time,
            statusNote: entry,
          );
        }
        break;

      case AddStatusReflectionLogEntry():
        // TODO: for done statuses, reflections are shown on the status creation
        //   for active statuses, reflections are shown on the status end
        var existingItem = items["${entry.statusId}-end"];
        var itemKey = "${entry.statusId}-end";

        if (existingItem?.entry is StatusLogEntry &&
            (existingItem!.entry as StatusLogEntry).status !=
                GoalStatus.active) {
          break;
        }

        if (existingItem == null) {
          existingItem = items["${entry.statusId}-creation"];
          itemKey = "${entry.statusId}-creation";
          if (existingItem?.entry is StatusLogEntry &&
              (existingItem!.entry as StatusLogEntry).status !=
                  GoalStatus.done) {
            break;
          }
        }
        if (existingItem != null && existingItem.entry is StatusLogEntry) {
          items[itemKey] = DetailViewLogEntryItem(
            entry: existingItem.entry,
            path: existingItem.path,
            time: existingItem.time,
            statusNote: entry,
          );
        }
        break;

      case LongRunningOperationEntry():
        // Coalesce by operationId - keep the latest status update
        final existingItem = items[entry.operationId];
        if (existingItem == null ||
            entry.creationTime.isAfter(existingItem.time)) {
          items[entry.operationId] = DetailViewLogEntryItem(
            entry: entry,
            path: rootGoalPath,
            time: entry.creationTime,
          );
        }
        break;

      default:
      // ignore: no-empty-block
    }
  }

  final sortedItems = [
    ...items.values.where(
      (element) {
        if (element.entry.path == null) {
          return true;
        }
        return rootGoalPath.trailingGoalPath.containsPath(element.entry.path!);
      },
    ),
    DetailViewGoalCreationItem(path: rootGoalPath, time: goal.creationTime),
  ].toList()
    ..sort((a, b) => b.time.compareTo(a.time));

  return sortedItems;
}

void _stripIds(Map<String, dynamic> map) {
  for (final entry in map.entries) {
    if (entry.value is Map<String, dynamic>) {
      _stripIds(entry.value);
    } else if (entry.key == GoalLogEntry.ID_JSON_KEY) {
      map[entry.key] = Cupid.toNewId(entry.value);
    } else if (entry.key == AddStatusIntentionLogEntry.STATUS_ID_JSON_KEY) {
      map[entry.key] = Cupid.toNewId(entry.value);
    } else if (entry.key == GoalLogEntry.PATH_JSON_KEY && entry.value is List) {
      map[entry.key] = (entry.value as List)
          .map((e) => Cupid.toNewId(e))
          .toList(growable: false);
    } else if (entry.value is String) {
      try {
        map[entry.key] = Cupid.decode(entry.value)
            .encode(format: EncodedCupidFormat.base64Url);
      } catch (e) {
        // not an id
      }
    }
  }
}

Future<Set<String>> diffGoals(
  WorldContext wc,
  Map<String, Goal> goalMapA,
  GoalPath pathA,
  Map<String, Goal> goalMapB,
  GoalPath pathB,
  Future<String?> Function(String) loadStringA,
  Future<String?> Function(String) loadStringB,
) async {
  final goalA = goalMapA[pathA.goalId];
  final goalB = goalMapB[pathB.goalId];

  if (goalA == null || goalB == null) {
    print('Goal not found: ${pathA.goalId}, ${pathB.goalId}');
    throw Exception(
        'One or both goals not found: ${pathA.goalId}, ${pathB.goalId}');
  }

  final diff = <String>{};

  final nameA = goalA.text;
  final nameB = goalB.text;
  if (nameA != nameB) {
    diff.add('name diff');
  }

  final priorityA = getGoalPriorityEntry(goalMapA, pathA);
  final priorityB = getGoalPriorityEntry(goalMapB, pathB);

  if (priorityA == null && priorityB != null) {
    diff.add('priorityA missing');
  } else if (priorityA != null && priorityB == null) {
    diff.add('priorityB missing');
  } else if (priorityA?.priority != null &&
      priorityB?.priority != null &&
      priorityA!.priority != priorityB!.priority) {
    diff.add(
        'priority diff: ${(priorityA.priority! - priorityB.priority!).abs()}');
  }

  final summaryA = hasSummary(goalMapA, pathA);
  final summaryB = hasSummary(goalMapB, pathB);

  if (summaryA != null && summaryB == null) {
    diff.add('summaryB missing');
  } else if (summaryA == null && summaryB != null) {
    diff.add('summaryA missing');
  } else if (summaryA != null && summaryB != null) {
    final summaryTextA = summaryA.text ?? await loadStringA(summaryA.id);
    final summaryTextB = summaryB.text ?? await loadStringB(summaryB.id);
    if (summaryTextA != summaryTextB) {
      diff.add('summary text');
    }
  }

  final anchorA = isAnchor(goalA);
  final anchorB = isAnchor(goalB);

  if (anchorA != null && anchorB == null) {
    diff.add('anchorB missing');
  } else if (anchorA == null && anchorB != null) {
    diff.add('anchorA missing');
  }

  final documentA = getDocumentEntry(pathA, goalMap: goalMapA);
  final documentB = getDocumentEntry(pathB, goalMap: goalMapB);

  if (documentA is DocumentContentsEntry &&
      (documentB == null || documentB is ClearDocumentContentsEntry)) {
    diff.add('documentB missing');
  } else if ((documentA == null || documentA is ClearDocumentContentsEntry) &&
      documentB is DocumentContentsEntry) {
    diff.add('documentA missing');
  } else if (documentA is DocumentContentsEntry &&
      documentB is DocumentContentsEntry) {
    final documentTextA = documentA.text ?? await loadStringA(documentA.id);
    final documentTextB = documentB.text ?? await loadStringB(documentB.id);
    if (documentTextA == null && documentTextB != null) {
      diff.add('documentA missing text');
    } else if (documentTextA != null && documentTextB == null) {
      diff.add('documentB missing text');
    } else if (documentTextA != null && documentTextB != null) {
      final fixedDocumentTextA =
          replaceGoalPathReferences(documentTextA, (refPath) {
        return GoalPath([
          ...refPath.map((part) {
            if (part == 'comp' || part == 'name') {
              return part;
            }
            return Cupid.toNewId(part);
          })
        ]);
      });
      if (documentTextB != fixedDocumentTextA) {
        diff.add('document text');
      }
    }
  }

  final historyItemsA = computeFlatHistoryLog(
    wc,
    pathA,
    goalMapA,
  ).whereType<DetailViewLogEntryItem>().toList();

  historyItemsA.sort((a, b) {
    final cmp = a.time.compareTo(b.time);
    if (cmp != 0) {
      return cmp;
    }
    return Cupid.toNewId(a.entry.id).compareTo(Cupid.toNewId(b.entry.id));
  });

  final historyItemsB = computeFlatHistoryLog(
    wc,
    pathB,
    goalMapB,
  ).whereType<DetailViewLogEntryItem>().toList();

  historyItemsB.sort((a, b) {
    final cmp = a.time.compareTo(b.time);
    if (cmp != 0) {
      return cmp;
    }
    return a.entry.id.compareTo(b.entry.id);
  });

  if (historyItemsA.length != historyItemsB.length) {
    var aIndex = 0;
    var bIndex = 0;
    while (aIndex < historyItemsA.length && bIndex < historyItemsB.length) {
      final itemA = historyItemsA[aIndex];
      final itemB = historyItemsB[bIndex];

      if (itemA.time.isBefore(itemB.time)) {
        diff.add('history B missing A history ${itemA.entry.id}');
        aIndex++;
      } else if (itemA.time.isAfter(itemB.time)) {
        diff.add('history A missing B history index');
        bIndex++;
      } else if (Cupid.toNewId(itemA.entry.id) !=
          Cupid.toNewId(itemB.entry.id)) {
        final aId = Cupid.toNewId(itemA.entry.id);
        final bId = Cupid.toNewId(itemB.entry.id);
        final idCmp = aId.compareTo(bId);
        if (idCmp < 0) {
          diff.add('history B missing A history ${itemA.entry.id}');
          aIndex++;
        } else if (idCmp > 0) {
          diff.add('history A missing B history index');
          bIndex++;
        } else {
          aIndex++;
          bIndex++;
        }
      } else {
        aIndex++;
        bIndex++;
      }
    }
    if (aIndex < historyItemsA.length) {
      for (var i = aIndex; i < historyItemsA.length; i++) {
        diff.add('history B missing A history ${historyItemsA[i].entry.id}');
      }
    } else if (bIndex < historyItemsB.length) {
      for (var i = bIndex; i < historyItemsB.length; i++) {
        diff.add('history A missing B history index');
      }
    }
  } else {
    for (final (i, itemA) in historyItemsA.indexed) {
      final itemB = historyItemsB[i];
      if (itemB.runtimeType != itemA.runtimeType) {
        diff.add('history item type $i');
        continue;
      }

      final entryAJsonMap = itemA.entry.toJsonMap();
      final entryBJsonMap = itemB.entry.toJsonMap();

      _stripIds(entryAJsonMap);
      _stripIds(entryBJsonMap);

      if (!DeepCollectionEquality().equals(entryAJsonMap, entryBJsonMap)) {
        diff.add('history items');
      }

      final statusNoteAJsonMap = itemA.statusNote?.toJsonMap();
      final statusNoteBJsonMap = itemB.statusNote?.toJsonMap();

      if (statusNoteAJsonMap != null && statusNoteBJsonMap == null) {
        diff.add('status note B missing');
      } else if (statusNoteAJsonMap == null && statusNoteBJsonMap != null) {
        diff.add('status note A missing');
      } else if (statusNoteAJsonMap != null && statusNoteBJsonMap != null) {
        _stripIds(statusNoteAJsonMap);
        _stripIds(statusNoteBJsonMap);

        if (!DeepCollectionEquality()
            .equals(statusNoteAJsonMap, statusNoteBJsonMap)) {
          diff.add('status note');
        }
      }
    }
  }

  final parentContextA = getAllParentContext(goalA);
  final parentContextB = getAllParentContext(goalB);

  if (parentContextA.length != parentContextB.length) {
    diff.add('parent context length');
  } else {
    for (final entry in parentContextA.entries) {
      final parentId = entry.key;
      final parentContextEntryA = entry.value;
      final parentContextEntryB = parentContextB[Cupid.toNewId(parentId)];
      if (parentContextEntryB == null) {
        diff.add('parent contextB missing $parentId');
        continue;
      }
      if (await loadStringA(parentContextEntryA.id) !=
          await loadStringB(parentContextEntryB.id)) {
        diff.add('parent context text $parentId');
      }
    }
  }

  return diff;
}

bool isBookSectionGoal(
  Goal? goal,
) {
  if (goal == null) {
    return false;
  }

  for (final entry in goal.log) {
    if (entry is BookSectionLogEntry) {
      return true;
    }
  }

  return false;
}

BookSectionLogEntry? getBookSectionEntry(
  GoalPath? path, {
  required Map<String, Goal> goalMap,
}) {
  if (path == null) {
    return null;
  }

  final goal = goalMap[path.goalId];

  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    final entryPath = entry.path;

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && !path.containsPath(entryPath)) {
      continue;
    }

    if (entry is BookSectionLogEntry) {
      return entry;
    }
  }

  return null;
}

/// Returns the most recent SyllabusParseResultLogEntry for a goal, if any.
SyllabusParseResultLogEntry? getSyllabusParseResultEntry(
  GoalPath? path, {
  required Map<String, Goal> goalMap,
}) {
  if (path == null) {
    return null;
  }

  final goal = goalMap[path.goalId];

  if (goal == null) {
    return null;
  }

  for (final entry in goal.log) {
    final entryPath = entry.path;

    // If the status is for a particular instance skip it unless the user has supplied
    // a path that contains the instance path.
    if (entryPath != null && !path.containsPath(entryPath)) {
      continue;
    }

    if (entry is SyllabusParseResultLogEntry) {
      return entry;
    }
  }

  return null;
}

/// Computes the GoalDeltas needed when dropping a set of goals onto a target goal.
List<GoalDelta> computeDropOnGoalEffects(
  Map<String, Goal> goalMap,
  Set<GoalPath> draggedGoalPaths,
  GoalPath targetGoalPath, {
  bool isAdditive = false,
}) {
  final List<GoalDelta> goalDeltas = [];
  final superGoals = getTransitiveSuperGoals(goalMap, targetGoalPath.goalId);
  for (final path in draggedGoalPaths) {
    final droppedGoal = goalMap[path.goalId];

    if (droppedGoal == null ||
        superGoals.containsKey(path.goalId) ||
        path.goalId == targetGoalPath.goalId ||
        droppedGoal.hasParent(targetGoalPath.goalId)) {
      continue;
    }

    final pathParentPath = path.parentPath;
    final pathParent =
        pathParentPath.isEmpty ? null : goalMap[pathParentPath.goalId];
    if (pathParent == null) {
      goalDeltas.add(GoalDelta(
          id: path.goalId,
          logEntry: AddParentLogEntry(
            id: Cupid.random().encode(),
            parentId: targetGoalPath.goalId,
            creationTime: DateTime.now(),
            path: getLogEntryPath(goalMap, targetGoalPath),
          )));
      continue;
    }

    GoalPath? displayedChildPath;
    if (pathParentPath.isNotEmpty) {
      final pathParentEntry = getPathParentEntry(goalMap, path);
      if (pathParentEntry is AddParentLogEntry) {
        displayedChildPath = pathParentEntry.displayedChildPath != null
            ? GoalPath(pathParentEntry.displayedChildPath!)
            : null;
      }
      if (!isAdditive) {
        goalDeltas.add(GoalDelta(
            id: path.goalId,
            logEntry: RemoveParentLogEntry(
              id: Cupid.random().encode(),
              creationTime: DateTime.now(),
              parentId: pathParentPath.goalId,
              path: getLogEntryPath(goalMap, pathParentPath),
            )));
      }
    }

    goalDeltas.add(GoalDelta(
        id: path.goalId,
        logEntry: AddParentLogEntry(
          id: Cupid.random().encode(),
          parentId: targetGoalPath.goalId,
          creationTime: DateTime.now(),
          displayedChildPath: displayedChildPath,
          path: getLogEntryPath(goalMap, targetGoalPath),
        )));
  }
  return goalDeltas;
}

/// Computes the GoalDeltas needed when dropping a set of goals onto a separator between goals.
List<GoalDelta> computeDropOnSeparatorEffects(
  Map<String, Goal> goalMap,
  Set<GoalPath> draggedGoalDetails,
  GoalPath prevGoalPath,
  GoalPath nextGoalPath, {
  bool isAdditive = false,
}) {
  GoalPath? newParentPath;
  double? newPriority = getGoalPriorityBetween(goalMap,
      pathBefore: prevGoalPath, pathAfter: nextGoalPath);

  if (prevGoalPath.length == nextGoalPath.length) {
    // dropped between siblings
    newParentPath = prevGoalPath.parentPath.trailingGoalPath;
  } else if (prevGoalPath.length == nextGoalPath.length - 1) {
    // dropped between parent and child
    newParentPath = prevGoalPath.trailingGoalPath;
  } else if (prevGoalPath.length > nextGoalPath.length) {
    // dropped after last child and before add goal entry
    newParentPath = nextGoalPath.parentPath.trailingGoalPath;
  }

  // Cycle check: If newParentPath is non-empty, check if any dragged goal is a supergoal of newParentPath or equal to newParentPath.
  if (newParentPath != null && newParentPath.isNotEmpty) {
    final superGoals = getTransitiveSuperGoals(goalMap, newParentPath.goalId);
    for (final path in draggedGoalDetails) {
      if (superGoals.containsKey(path.goalId) ||
          path.goalId == newParentPath.goalId) {
        // abort mission. one of these goals is a super goal of the new parent.
        return [];
      }
    }
  }

  // Duplicate / root check for additive drops:
  // In additive mode, root destinations cannot represent an additive edge (root has no edge representation),
  // and dropping onto an already-existing destination parent edge is rejected with zero effects.
  if (isAdditive) {
    if (newParentPath == null || newParentPath.isEmpty) {
      return [];
    }
    for (final details in draggedGoalDetails) {
      final droppedGoal = goalMap[details.goalId];
      if (droppedGoal == null || droppedGoal.hasParent(newParentPath.goalId)) {
        return [];
      }
    }
  }

  final List<GoalDelta> goalDeltas = [];

  // Check if we need to bump any sibling priorities to make room
  if (newPriority != null) {
    final conflictingBumps = getConflictingPriorityBumps(
      goalMap,
      newParentPath,
      nextGoalPath,
      newPriority,
    );

    if (conflictingBumps.isNotEmpty) {
      final priorityEntryPath = newParentPath != null
          ? getLogEntryPath(goalMap, newParentPath)
          : null;

      for (final entry in conflictingBumps.entries) {
        goalDeltas.add(GoalDelta(
            id: entry.key,
            logEntry: PriorityLogEntry(
              id: Cupid.random().encode(),
              creationTime: DateTime.now(),
              priority: entry.value,
              path: priorityEntryPath,
            )));
      }
    }
  }

  for (final details in draggedGoalDetails) {
    final droppedGoal = goalMap[details.goalId];
    if (droppedGoal == null) continue;

    final pathParentId = details.parentId;

    if (newParentPath != null && newParentPath.isNotEmpty) {
      if (!droppedGoal.hasParent(newParentPath.goalId)) {
        if (!isAdditive && pathParentId != null) {
          goalDeltas.add(GoalDelta(
              id: details.goalId,
              logEntry: RemoveParentLogEntry(
                id: Cupid.random().encode(),
                creationTime: DateTime.now(),
                parentId: pathParentId,
                path: getLogEntryPath(goalMap, details),
              )));
        }

        goalDeltas.add(GoalDelta(
            id: details.goalId,
            logEntry: AddParentLogEntry(
              id: Cupid.random().encode(),
              parentId: newParentPath.goalId,
              creationTime: DateTime.now(),
              path: getLogEntryPath(goalMap, newParentPath),
            )));
      }
    } else {
      if (!isAdditive && pathParentId != null) {
        goalDeltas.add(GoalDelta(
            id: details.goalId,
            logEntry: RemoveParentLogEntry(
              id: Cupid.random().encode(),
              creationTime: DateTime.now(),
              parentId: pathParentId,
              path: getLogEntryPath(goalMap, details),
            )));
      }
    }

    final priorityEntryPath = newParentPath != null
        ? getLogEntryPath(goalMap, newParentPath)
        : null;

    goalDeltas.add(GoalDelta(
        id: details.goalId,
        logEntry: PriorityLogEntry(
          id: Cupid.random().encode(),
          creationTime: DateTime.now(),
          priority: newPriority,
          path: priorityEntryPath,
        )));
  }

  return goalDeltas;
}

/// Computes the GoalDeltas needed when dropping a goal onto a goal or separator target.
List<GoalDelta> computeDropGoalEffects(
  Map<String, Goal> goalMap,
  GoalPath path, {
  Set<GoalPath>? selectedGoals,
  GoalPath? dropPath,
  GoalPath? prevDropPath,
  GoalPath? nextDropPath,
  bool isAdditive = false,
}) {
  final Set<GoalPath> goalsToUpdate =
      (selectedGoals != null && selectedGoals.contains(path))
          ? {...selectedGoals}
          : {path};

  if (!((dropPath != null) ^
      (prevDropPath != null && nextDropPath != null))) {
    print(
        'Exactly one of dropPath or prevDropPath and nextDropPath must be non-null');
    throw Exception(
        'Exactly one of dropPath or prevDropPath and nextDropPath must be non-null');
  }

  if (prevDropPath != null && nextDropPath != null) {
    return computeDropOnSeparatorEffects(
      goalMap,
      goalsToUpdate,
      prevDropPath,
      nextDropPath,
      isAdditive: isAdditive,
    );
  } else {
    return computeDropOnGoalEffects(
      goalMap,
      goalsToUpdate,
      dropPath!,
      isAdditive: isAdditive,
    );
  }
}

