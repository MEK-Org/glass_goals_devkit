import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:goals_core/model.dart'
    show
        Goal,
        GoalPath,
        GoalPredicate,
        TraversalDecision,
        getPriorityComparator,
        TraversalOrder,
        traverseAll,
        traverseParallelLoad;
import 'package:goals_core/sync.dart';
import 'package:goals_core/util.dart' show CancellationToken;
import 'package:goals_ui_core/core.dart';
import 'package:rxdart/rxdart.dart';
import 'package:collection/collection.dart' show IterableExtension;

import 'add_subgoal_item.dart';
import 'goal_item.dart';
import 'goal_separator.dart';
import 'hover_actions_builder.dart';

typedef FlattenedGoalItem = ({
  GoalPath path,
  bool hasRenderableChildren,
  GoalPath? renderedPath,
  int depth,

  // the position of this goal in its parent's subgoal list
  int childIndex,
});

const _ACTION_THRESHOLD_RATIO = 0.2;

String getChildIndexPathPart(int i) {
  return 'childIndex:${i.toString()}';
}

int? parseChildIndexPathPart(String? part) {
  if (part == null) {
    return null;
  }
  if (part.startsWith('childIndex:')) {
    return int.tryParse(part.substring('childIndex:'.length));
  }
  return null;
}

class FlattenedGoalTree extends StatefulWidget {
  final List<GoalPath>? rootGoalPaths;
  final int? depthLimit;
  final bool showParentName;
  final HoverActionsBuilder hoverActionsBuilder;
  final GoalPath path;
  final bool showAddGoal;
  final GoalPredicate? predicate;
  final FileDropOnGoalCallback? onFileDropOnGoal;
  final FileDropBetweenGoalsCallback? onFileDropBetweenGoals;
  const FlattenedGoalTree({
    super.key,
    this.rootGoalPaths,
    this.depthLimit,
    this.showParentName = false,
    required this.hoverActionsBuilder,
    this.showAddGoal = true,
    this.path = const GoalPath([]),
    this.predicate,
    this.onFileDropOnGoal,
    this.onFileDropBetweenGoals,
  });

  @override
  State<FlattenedGoalTree> createState() => _FlattenedGoalTreeState();
}

class _FlattenedGoalTreeState extends State<FlattenedGoalTree>
    with SingleTickerProviderStateMixin {
  List<FlattenedGoalItem> _flattenedGoalItems = [];

  CancellationToken? _pendingFetch;

  int? _shiftHoverStartIndex;
  int? _shiftHoverEndIndex;

  final List<StreamSubscription> _subscriptions = [];
  bool _hasMouse = hasMouseProvider.value;

  /// Pins the goals this tree currently considers (visible + any traversed
  /// during fetch). Updated via `setIds` from `_updateFlattenedGoalItems`
  /// after the final visible set is computed.
  WatchedGoalSet? _watch;

  /// Synchronous snapshot of the watched goals. Reads the watch set's live
  /// value (rather than a copy taken off the throttled stream) so a mutation
  /// that was just awaited — and any child it adopted — is visible in the same
  /// turn, with no one-frame flash. The throttled stream subscription is kept
  /// only as a rebuild trigger. Before the watch has been populated (its
  /// `currentValue` starts empty), falls back to the sync client's resident
  /// set so the very first traversal has data to work with.
  Map<String, Goal> get _goalMap {
    final live = _watch?.currentValue;
    if (live == null || live.isEmpty) {
      return GoalWidgetsContext.of(context).syncClient.stateSubject.value;
    }
    return live;
  }

  int? _swipeIndex;
  late final AnimationController _swipeController =
      AnimationController.unbounded(
          vsync: this, duration: Duration(milliseconds: 200));
  double? _dragStartLoc;
  int dragOffset = 0;

  GoalPath? _swipedGoalPath;

  late final FocusNode _focusNode = FocusNode(
    onKeyEvent: (node, event) {
      if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
          event.logicalKey == LogicalKeyboardKey.shiftRight) {
        _updateShiftSelectionRange();
      }

      return KeyEventResult.ignored;
    },
  );

  _updateShiftSelectionRange() {
    if (!isShiftHeld()) {
      if ((_shiftHoverStartIndex != null || _shiftHoverEndIndex != null)) {
        setState(() {
          _shiftHoverStartIndex = null;
          _shiftHoverEndIndex = null;
        });
      }
      return;
    }

    if (textFocusProvider.value != null) {
      return;
    }

    final lastSelectedGoalPath = selectedGoalsProvider.value.lastOrNull;
    final hoveredPath = hoverEventStream.value;

    if (lastSelectedGoalPath != null && hoveredPath != null) {
      final lastSelectedGoalIndex = _flattenedGoalItems
          .indexWhere((item) => pathsMatch(item.path, lastSelectedGoalPath));
      final hoveredGoalIndex = _flattenedGoalItems
          .indexWhere((item) => pathsMatch(item.path, hoveredPath));
      if (lastSelectedGoalIndex != -1 &&
          hoveredGoalIndex != -1 &&
          lastSelectedGoalIndex != hoveredGoalIndex) {
        if (lastSelectedGoalIndex < hoveredGoalIndex &&
            (_shiftHoverStartIndex != lastSelectedGoalIndex ||
                _shiftHoverEndIndex != hoveredGoalIndex)) {
          setState(() {
            _shiftHoverStartIndex = lastSelectedGoalIndex;
            _shiftHoverEndIndex = hoveredGoalIndex;
          });
        } else if (lastSelectedGoalIndex > hoveredGoalIndex &&
            (_shiftHoverStartIndex != hoveredGoalIndex ||
                _shiftHoverEndIndex != lastSelectedGoalIndex)) {
          setState(() {
            _shiftHoverStartIndex = hoveredGoalIndex;
            _shiftHoverEndIndex = lastSelectedGoalIndex;
          });
        }
      }
    }
  }

  void _animateDragEnd() {
    double screenWidth = MediaQuery.sizeOf(context).width;

    if (this._swipeController.value.abs() <
        screenWidth * _ACTION_THRESHOLD_RATIO) {
      this._swipeController.animateTo(
            0,
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
      this._swipeController.addStatusListener(this._resetSwipeState);
    } else {
      if (this._swipeController.value > 0) {
        this._swipeController.animateTo(
              screenWidth,
              duration: Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
      } else {
        this._swipeController.animateTo(
              -screenWidth,
              duration: Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
      }
      this._swipeController.addStatusListener(this._doneSwipe);
    }
  }

  void _resetSwipeState(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      setState(() {
        this._swipeController.value = 0;
        this._swipeIndex = null;
      });
      this._swipeController.removeStatusListener(this._resetSwipeState);
    }
  }

  void _doneSwipe(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      this._swipedGoalPath = _flattenedGoalItems[this._swipeIndex!].path;
      GoalActionsContext.of(context).onDone(this._swipedGoalPath, null);
      hoverEventStream.add(null);
      this._swipeController.value = 0;
      this._swipeIndex = null;
      this._updateFlattenedGoalItems();
      this._swipeController.removeStatusListener(this._doneSwipe);
    }
  }

  @override
  void initState() {
    super.initState();
    _subscriptions.add(hasMouseProvider.stream.listen((hasMouse) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hasMouse = hasMouse;
      });
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sc = GoalWidgetsContext.of(context).syncClient;
      _watch = sc.watchGoals(const []);
      _subscriptions.add(_watch!.stream
          .throttleTime(Duration(milliseconds: 16), trailing: true)
          .listen((_) {
        // The stream is only a rebuild trigger now; render reads
        // `_watch.currentValue` synchronously via the `_goalMap` getter.
        if (!mounted) return;
        setState(() {});
        _updateFlattenedGoalItems();
      }));

      _updateFlattenedGoalItems();
      _fetchGoals();

      _subscriptions.add(expandedGoalsProvider.stream.skip(1).listen((_) {
        // Don't wait to rerender the list before fetching
        _updateFlattenedGoalItems();
        _fetchGoals();
      }));

      _subscriptions.add(worldContextProvider.stream.listen((_) {
        _updateFlattenedGoalItems();
      }));

      _subscriptions.add(textFocusProvider.stream.listen((_) {
        _updateFlattenedGoalItems();
      }));

      // when a new sync subject event gets emitted, we refetch goals
      _subscriptions.add(sc.syncSubject.stream
          .distinct()
          // only respond to changes after the first one
          .skip(1)
          .listen((_) {
        _fetchGoals();
      }));
    });
    _subscriptions.add(hoverEventStream.listen((_) {
      this._updateShiftSelectionRange();
    }));
  }

  void _updateFlattenedGoalItems() {
    if (!mounted) {
      return;
    }

    final syncClient = GoalWidgetsContext.of(context).syncClient;
    final worldContext = worldContextProvider.value;
    final expandedGoalPaths = expandedGoalsProvider.value;
    final textFocus = textFocusProvider.value;
    final goalMap = _goalMap;
    final priorityComparator = getPriorityComparator(goalMap);
    final List<FlattenedGoalItem> flattenedGoals = [];

    final rootGoalPaths = this.widget.rootGoalPaths ??
        syncClient.getRootGoalIds().map((id) => GoalPath([id])).toList();

    rootGoalPaths.sort(priorityComparator);

    var rootChildIndex = 0;

    // This is the case where the textfocus is at the 0th child of the
    // root path of the tree.
    if (textFocus != null &&
        textFocus.parentPath == this.widget.path &&
        parseChildIndexPathPart(textFocus.goalId) == 0) {
      flattenedGoals.add((
        path: textFocus,
        hasRenderableChildren: false,
        renderedPath: null,
        childIndex: rootChildIndex++,
        depth: 0,
      ));
    }

    traverseAll(
      goalMap,
      rootGoalPaths,
      order: TraversalOrder.depthFirst,
      onVisit: (path, {required bool isLeaf, required int childIndex}) {
        final fullGoalPath = GoalPath([
          ...this.widget.path,
          ...path,
        ]);

        // This is so that we hide the swiped goal between the time when the
        // swipe completes and the time when the goal is actually removed.
        if (fullGoalPath == _swipedGoalPath) {
          return TraversalDecision.dontRecurse;
        }

        final goal = goalMap[fullGoalPath.goalId];

        if (goal == null) {
          // If the goal is not found in the map, we assume it is missing and
          // will try to load it later.
          return TraversalDecision.dontRecurse;
        }

        final relationshipEntry =
            goal.superGoalRelationships[fullGoalPath.parentId];

        final relationshipEntryPath = relationshipEntry?.path;
        if ((relationshipEntryPath != null &&
            !fullGoalPath.trailingGoalPath
                .containsPath(relationshipEntryPath))) {
          return TraversalDecision.dontRecurse;
        }

        final parentId = fullGoalPath.parentId;
        final parentGoal = parentId != null ? goalMap[parentId] : null;

        // there's no way this is robust
        final parentRelationshipEntry = parentGoal
            ?.superGoalRelationships[fullGoalPath.parentPath.parentId];
        if ((relationshipEntryPath == null &&
            parentRelationshipEntry is AddParentLogEntry &&
            parentRelationshipEntry.isSlice)) {
          return TraversalDecision.dontRecurse;
        }

        if (this.widget.predicate != null &&
            !this
                .widget
                .predicate!
                .call(worldContext, goalMap, fullGoalPath, goal)) {
          return TraversalDecision.dontRecurse;
        }

        flattenedGoals.add((
          childIndex: childIndex,
          path: fullGoalPath,
          hasRenderableChildren: goal.subGoalIds.where((gId) {
            final childGoal = goalMap[gId];
            if (childGoal == null) {
              return false;
            }

            if (this.widget.predicate != null &&
                !this.widget.predicate!.call(worldContext, goalMap,
                    GoalPath([...fullGoalPath, gId]), childGoal)) {
              return false;
            }

            final subGoalRltnPath = goal.subGoalRelationships[gId]?.path;
            if (subGoalRltnPath != null &&
                !GoalPath([...fullGoalPath, gId])
                    .trailingGoalPath
                    .containsPath(subGoalRltnPath)) {
              return false;
            }

            final parentRelationshipEntry =
                goal.superGoalRelationships[fullGoalPath.parentId];
            if ((subGoalRltnPath == null &&
                parentRelationshipEntry is AddParentLogEntry &&
                parentRelationshipEntry.isSlice)) {
              return false;
            }
            return true;
          }).isNotEmpty,
          renderedPath: path.length == 1 && rootGoalPaths[childIndex].length > 1
              ? rootGoalPaths[childIndex]
              : relationshipEntry is AddParentLogEntry &&
                      relationshipEntry.displayedChildPath != null
                  ? GoalPath(relationshipEntry.displayedChildPath!)
                  : null,
          depth: path.length - 1,
        ));

        // This is the case where the textfocus is at the 0th child of this
        // goal.
        if (textFocus != null) {
          final childIndex = parseChildIndexPathPart(textFocus.goalId);
          if (fullGoalPath == textFocus.parentPath && childIndex == 0) {
            flattenedGoals.add((
              path: textFocus,
              hasRenderableChildren: false,
              renderedPath: null,
              depth: path.length,
              childIndex: 0,
            ));
          }
        }

        if (expandedGoalPaths.contains(fullGoalPath)) {
          return TraversalDecision.continueTraversal;
        }
        return TraversalDecision.dontRecurse;
      },
      onDepart: (GoalPath path,
          {required bool isLeaf, required int childIndex}) async {
        if (textFocus == null) {
          return;
        }
        final fullGoalPath = GoalPath([...this.widget.path, ...path]);
        final parsedChildIndex = parseChildIndexPathPart(textFocus.goalId);

        if (parsedChildIndex == null) {
          return;
        }
        var addTrailingAddGoalItem = false;

        // We're departing a parent goal and we want to add a final child.
        if (fullGoalPath == textFocus.parentPath && parsedChildIndex == -1) {
          addTrailingAddGoalItem = true;
        }

        // We're departing a child goal and we want to add an add goal sibling
        // after it.
        if (fullGoalPath.parentPath == textFocus.parentPath &&
            parsedChildIndex == childIndex + 1) {
          addTrailingAddGoalItem = true;
        }

        if (addTrailingAddGoalItem) {
          flattenedGoals.add((
            path: textFocus,
            hasRenderableChildren: false,
            renderedPath: null,
            depth: path.length,
            childIndex: 0,
          ));
        }
      },
      childTraversalComparator: priorityComparator,
    );

    // If the widget requested a showAddGoal, we add a final add goal item to the end of
    // the list, in the case that the last goal isn't already an add goal item.
    if (this.widget.showAddGoal &&
        parseChildIndexPathPart(flattenedGoals.lastOrNull?.path.goalId) ==
            null) {
      flattenedGoals.add((
        path: GoalPath([...this.widget.path, getChildIndexPathPart(-1)]),
        hasRenderableChildren: false,
        renderedPath: null,
        childIndex: rootChildIndex++,
        depth: 0,
      ));
    } else if (textFocus != null &&
        textFocus.parentPath == this.widget.path &&
        parseChildIndexPathPart(textFocusProvider.value?.goalId) == -1) {
      // This is the case where the widget's path has text focus at -1.
      flattenedGoals.add((
        path: textFocus,
        hasRenderableChildren: false,
        renderedPath: null,
        childIndex: rootChildIndex++,
        depth: 0,
      ));
    }
    if (mounted) {
      setState(() {
        this._flattenedGoalItems = flattenedGoals;
      });
    }
  }

  void _fetchGoals() async {
    if (!mounted) {
      return;
    }

    final prevPendingItemsUpdate = _pendingFetch;
    final newPendingItemsUpdate = CancellationToken();
    _pendingFetch = newPendingItemsUpdate;
    if (prevPendingItemsUpdate != null) {
      prevPendingItemsUpdate.isCancelled = true;
    }

    final syncClient = GoalWidgetsContext.of(context).syncClient;
    final worldContext = worldContextProvider.value;
    final expandedGoalPaths = expandedGoalsProvider.value;
    final goalMap = _goalMap;
    final watch = _watch;

    final rootGoalPaths = this.widget.rootGoalPaths ??
        syncClient.getRootGoalIds().map((id) => GoalPath([id])).toList();

    // Pre-load all goals in parallel before constructing the tree.
    // Each visited goal is pinned in the watch via `add`. After the
    // traversal completes we trim the watch to the actually-traversed set
    // — visible rows plus their not-yet-rendered subgoals (we visit them
    // to know whether the expansion arrow should appear).
    //
    // The load callback always goes through `loadGoal` rather than first
    // checking the captured `goalMap` snapshot — the snapshot is taken at
    // fetch start and won't reflect goals loaded mid-traversal, so a
    // stale-map check would force an extra cached `loadGoal` call without
    // actually saving any work.
    final traversedIds = <String>{};
    await traverseParallelLoad(
      rootGoalPaths,
      (goalId) async {
        traversedIds.add(goalId);
        watch?.add(goalId);
        return await syncClient.loadGoal(goalId);
      },
      onVisit: (path, {required isLeaf}) {
        final fullGoalPath = GoalPath([
          ...this.widget.path,
          ...path,
        ]);

        // Don't load goals that don't pass the predicate
        final goal = goalMap[fullGoalPath.goalId];
        if (goal != null &&
            this.widget.predicate != null &&
            !this
                .widget
                .predicate!
                .call(worldContext, goalMap, fullGoalPath, goal)) {
          return TraversalDecision.dontRecurse;
        }

        // Only recurse into expanded goals to avoid loading unnecessary data
        if (expandedGoalPaths.contains(fullGoalPath) ||
            expandedGoalPaths.contains(fullGoalPath.parentPath) ||
            rootGoalPaths.contains(path) ||
            rootGoalPaths.contains(path.parentPath)) {
          return TraversalDecision.continueTraversal;
        }
        return TraversalDecision.dontRecurse;
      },
      cancellationToken: newPendingItemsUpdate,
    );
    if (_pendingFetch == newPendingItemsUpdate) {
      _pendingFetch = null;
      // After a (non-cancelled) fetch completes, trim the watch to the
      // set of ids the traversal actually visited. Pins on goals that
      // are no longer reachable (e.g. children of a collapsed parent on
      // a later fetch) are released here.
      watch?.setIds(traversedIds);
    }
  }

  bool _rootGoalPathsMatch(
    List<GoalPath>? oldRootGoalPaths,
    List<GoalPath>? newRootGoalPaths,
  ) {
    if (oldRootGoalPaths == null && newRootGoalPaths == null) {
      return true;
    }
    if (oldRootGoalPaths == null || newRootGoalPaths == null) {
      return false;
    }
    if (oldRootGoalPaths.length != newRootGoalPaths.length) {
      return false;
    }
    for (int i = 0; i < oldRootGoalPaths.length; i++) {
      if (oldRootGoalPaths[i] != newRootGoalPaths[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(FlattenedGoalTree oldWidget) {
    super.didUpdateWidget(oldWidget);

    // clear the swiped goal path once we see the updated goalMap

    final flattenedGoalMapUpdateTrigger = [];

    if (!_rootGoalPathsMatch(
        this.widget.rootGoalPaths, oldWidget.rootGoalPaths)) {
      flattenedGoalMapUpdateTrigger.add("rootGoalPaths");
    }

    if (oldWidget.path != widget.path) {
      flattenedGoalMapUpdateTrigger.add("path");
    }

    if (flattenedGoalMapUpdateTrigger.isNotEmpty) {
      _updateFlattenedGoalItems();
      // A changed root set can introduce ids this tree doesn't yet watch
      // (e.g. a goal added at the root). Refetch so they're loaded and pinned
      // into the watch — `_updateFlattenedGoalItems` alone would leave them
      // absent from `currentValue` and they'd render as nothing.
      _fetchGoals();
    }

    if (pathsMatch(this.widget.path, hoverEventStream.value)) {
      this._focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _watch?.dispose();
    this._focusNode.dispose();
    super.dispose();
  }

  Widget _swipeWrap({required Widget child, required int itemIndex}) {
    final swipingPath = this._swipeIndex == null
        ? null
        : this._flattenedGoalItems[this._swipeIndex!].path;
    final thisPath = this._flattenedGoalItems[itemIndex].path;
    final shouldAnimate =
        swipingPath != null && thisPath.startsWith(swipingPath);
    return GestureDetector(
      key: ValueKey(itemIndex),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (DragStartDetails deets) {
        setState(() {
          this._swipeIndex = itemIndex;
          this._dragStartLoc = deets.globalPosition.dx;
        });
      },
      onHorizontalDragUpdate: (DragUpdateDetails deets) {
        this._swipeController.value =
            deets.globalPosition.dx - this._dragStartLoc!;
      },
      onHorizontalDragEnd: (DragEndDetails deets) {
        _animateDragEnd();
      },
      child: AnimatedBuilder(
        animation:
            shouldAnimate ? this._swipeController : AlwaysStoppedAnimation(0),
        builder: (context, child) {
          return shouldAnimate
              ? Transform.translate(
                  offset: Offset(this._swipeController.value, 0),
                  child: child,
                )
              : child ?? Container();
        },
        child: child,
      ),
    );
  }

  /// iterates backwards through the list of flattened goals to find the
  /// previous sibling of the goal at [itemIndex].
  _getPrevSiblingPath(int itemIndex) {
    final item = this._flattenedGoalItems[itemIndex];
    while (itemIndex > 0) {
      itemIndex--;
      final prevItem = this._flattenedGoalItems[itemIndex];
      if (prevItem.path.length == item.path.length) {
        return prevItem.path;
      }

      // If we see that one of the previous paths is shallower
      // than the item that we're looking for, we know that we've reached the
      // end of the possible siblings.
      if (prevItem.path.length < item.path.length) {
        break;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) =>
        (goalsTheme?.uiUnit ?? 4.0) * numUnits;

    final hasMouse = _hasMouse;

    final goalItems = <Widget>[];
    final onDropGoal = GoalActionsContext.of(context).onDropGoal;
    final onArchive = GoalActionsContext.of(context).onArchive;
    final goalMap = _goalMap;

    for (int i = 0; i < this._flattenedGoalItems.length; i++) {
      final prevGoal = i > 0 ? this._flattenedGoalItems[i - 1] : null;
      final flattenedGoal = this._flattenedGoalItems[i];
      final goalId = flattenedGoal.path.goalId;
      goalItems.add(GoalSeparator(
          isFirst: i == 0,
          prevGoalPath: prevGoal?.path ?? [...this.widget.path],
          nextGoalPath: flattenedGoal.path,
          path: this.widget.path,
          goalMap: goalMap,
          onFileDropBetweenGoals: widget.onFileDropBetweenGoals,
          pendingShiftSelect: _shiftHoverStartIndex != null &&
              _shiftHoverEndIndex != null &&
              i >= _shiftHoverStartIndex! &&
              i <= _shiftHoverEndIndex!,
          shiftSelectStartPath: _shiftHoverStartIndex != null
              ? this._flattenedGoalItems[_shiftHoverStartIndex!].path
              : null,
          shiftSelectEndPath: _shiftHoverEndIndex != null
              ? this._flattenedGoalItems[_shiftHoverEndIndex!].path
              : null,
          onDropGoal: (goalDragDetails, topDrop) {
            onDropGoal(
              goalDragDetails.path,
              prevDropPath: prevGoal?.path ?? GoalPath([...this.widget.path]),
              // this messy logic is for the case when a goal has been dropped
              // on the top of a separator between the end last child goal
              // and the next sibling of a parent goal.
              nextDropPath: prevGoal != null &&
                      topDrop &&
                      prevGoal.path.length > flattenedGoal.path.length
                  ? null
                  : flattenedGoal.path,
              isAdditive: isAltHeld(),
            );
          }));
      goalItems.add(parseChildIndexPathPart(goalId) == null
          ? _swipeWrap(
              child: GoalItemWidget(
                onFileDropOnGoal: widget.onFileDropOnGoal,
                onDropGoal: (details) {
                  onDropGoal(
                    details.path,
                    dropPath: flattenedGoal.path,
                    isAdditive: isAltHeld(),
                  );
                },
                onEnter: () {
                  // if this is the last child of this parent
                  // set the index to -1
                  final nextItemPath =
                      this._flattenedGoalItems.elementAtOrNull(i + 1)?.path;

                  GoalPath path;
                  int index;

                  if (nextItemPath == null ||
                      nextItemPath.length < flattenedGoal.path.length) {
                    // this is the last entry in the list or the last child of the parent
                    // use the special -1 index to represent the last
                    path = flattenedGoal.path.parentPath;
                    index = -1;
                  } else if (parseChildIndexPathPart(nextItemPath.goalId) !=
                      null) {
                    path = nextItemPath.parentPath;
                    index = parseChildIndexPathPart(nextItemPath.goalId)!;
                  } else if (nextItemPath.length == flattenedGoal.path.length) {
                    // this is the case where the new goal item
                    // will be placed between two siblings
                    path = flattenedGoal.path.parentPath;
                    index = flattenedGoal.childIndex + 1;
                  } else {
                    // this is the case where the new goal item will
                    // be placed
                    path = flattenedGoal.path;
                    index = 0;
                  }

                  final addGoalPath = GoalPath([
                    ...path,
                    getChildIndexPathPart(index),
                  ]);
                  textFocusProvider.add(addGoalPath);
                },
                padding: EdgeInsets.only(left: uiUnit(4) * flattenedGoal.depth),
                renderedPath: flattenedGoal.renderedPath,
                pendingShiftSelect: _shiftHoverStartIndex != null &&
                    _shiftHoverEndIndex != null &&
                    i >= _shiftHoverStartIndex! &&
                    i <= _shiftHoverEndIndex!,
                hoverActionsBuilder: this.widget.hoverActionsBuilder,
                hasRenderableChildren: flattenedGoal.hasRenderableChildren,
                showExpansionArrow:
                    flattenedGoal.hasRenderableChildren || widget.showAddGoal,
                dragHandle: !hasMouse
                    ? GoalItemDragHandle.bullet
                    : GoalItemDragHandle.item,
                path: flattenedGoal.path,
              ),
              itemIndex: i)
          : AddSubgoalItemWidget(
              path: flattenedGoal.path,
              prevSiblingPath: _getPrevSiblingPath(i),
              nextSiblingPath: this
                          ._flattenedGoalItems
                          .elementAtOrNull(i + 1)
                          ?.path
                          .length ==
                      flattenedGoal.path.length
                  ? this._flattenedGoalItems[i + 1].path
                  : null,
              padding: EdgeInsets.only(
                  left: uiUnit(4) *
                      (flattenedGoal.path.length -
                          (1 + this.widget.path.length))),
            ));
    }
    if (!this.widget.showAddGoal && this._flattenedGoalItems.isNotEmpty) {
      goalItems.add(
        GoalSeparator(
          goalMap: goalMap,
          isFirst: false,
          prevGoalPath: this._flattenedGoalItems.last.path,
          // TODO: this is a hack to make the last separator work
          nextGoalPath:
              GoalPath([...this.widget.path, getChildIndexPathPart(0)]),
          onFileDropBetweenGoals: widget.onFileDropBetweenGoals,
        ),
      );
    }
    final treeWidget = Actions(
        actions: {
          if (textFocusProvider.value == null)
            NextIntent: CallbackAction(
              onInvoke: (_) {
                final hoveredIndex = _flattenedGoalItems.indexWhere(
                    (item) => pathsMatch(item.path, hoverEventStream.value));
                if (hoveredIndex != -1 &&
                    hoveredIndex < _flattenedGoalItems.length - 1) {
                  hoverEventStream
                      .add(_flattenedGoalItems[hoveredIndex + 1].path);
                }
              },
            ),
          if (textFocusProvider.value == null)
            PreviousIntent: CallbackAction(
              onInvoke: (_) {
                final hoveredIndex = _flattenedGoalItems.indexWhere(
                    (item) => pathsMatch(item.path, hoverEventStream.value));
                if (hoveredIndex != -1 && hoveredIndex > 0) {
                  hoverEventStream
                      .add(_flattenedGoalItems[hoveredIndex - 1].path);
                }
              },
            ),
          if (parseChildIndexPathPart(textFocusProvider.value?.goalId) != null)
            IndentIntent: CallbackAction(
              onInvoke: (_) {
                final newGoalIndex = _flattenedGoalItems.indexWhere(
                    (item) => pathsMatch(item.path, textFocusProvider.value));

                if (newGoalIndex <= 0) return;

                // We're already at the max depth.
                if (_flattenedGoalItems[newGoalIndex - 1].path.length <
                    textFocusProvider.value!.length) {
                  return;
                }

                // We do this sublist here so that we don't indent more than one level.
                final parentPath = GoalPath(
                    _flattenedGoalItems[newGoalIndex - 1]
                        .path
                        .sublist(0, textFocusProvider.value!.length));

                GoalActionsContext.of(context)
                    .onExpanded(parentPath, expanded: true);
                final parentGoal = goalMap[parentPath.goalId];
                if (parentGoal != null) {
                  final newGoalPath =
                      GoalPath([...parentPath, getChildIndexPathPart(-1)]);
                  textFocusProvider.add(newGoalPath);
                }
              },
            ),
          if (parseChildIndexPathPart(textFocusProvider.value?.goalId) != null)
            OutdentIntent: CallbackAction(
              onInvoke: (_) {
                var newGoalIndex = _flattenedGoalItems.indexWhere(
                    (item) => pathsMatch(item.path, textFocusProvider.value));

                // special handling for the case when the goal is the last child of a parent
                if (newGoalIndex == _flattenedGoalItems.length - 1) {
                  textFocusProvider.add(GoalPath([
                    ...textFocusProvider.value!.parentPath.parentPath,
                    getChildIndexPathPart(-1)
                  ]));
                  return;
                }

                GoalPath? parentPath;
                var childIndex = 0;
                while (newGoalIndex > 0) {
                  newGoalIndex--;
                  final parentCandidate = _flattenedGoalItems[newGoalIndex];
                  if (textFocusProvider.value!.length -
                          parentCandidate.path.length ==
                      2) {
                    parentPath = _flattenedGoalItems[newGoalIndex].path;
                    GoalActionsContext.of(context)
                        .onExpanded(parentPath, expanded: true);
                    final parentGoal = goalMap[parentPath.goalId];
                    if (parentGoal != null) {
                      textFocusProvider.add(GoalPath(
                          [...parentPath, getChildIndexPathPart(childIndex)]));
                    }
                    return;
                  } else if (textFocusProvider.value!.length -
                          parentCandidate.path.length ==
                      1) {
                    childIndex++;
                  }
                }
                textFocusProvider.add(GoalPath([
                  ...this.widget.path,
                  getChildIndexPathPart(childIndex + 1)
                ]));
              },
            ),
          if (textFocusProvider.value == null)
            RemoveIntent: CallbackAction<RemoveIntent>(
              onInvoke: (_) {
                final index = _flattenedGoalItems.indexWhere(
                    (item) => pathsMatch(item.path, hoverEventStream.value));
                if (index == -1) return;
                if (index < _flattenedGoalItems.length - 1) {
                  hoverEventStream.add(_flattenedGoalItems[index - 1].path);
                } else {
                  hoverEventStream.add(null);
                }
                onArchive.call(_flattenedGoalItems[index].path);
              },
            ),
        },
        child: Focus(
          focusNode: this._focusNode,
          child: GoalActionsContext.overrideWith(context,
              onFocused: (this._shiftHoverEndIndex != null &&
                      this._shiftHoverEndIndex != null)
                  ? (goalId, {inPlace}) {
                      final newSelectedGoals = [...selectedGoalsProvider.value];
                      for (int i = this._shiftHoverStartIndex!;
                          i <= this._shiftHoverEndIndex!;
                          i++) {
                        final goalPath = _flattenedGoalItems[i].path;
                        if (parseChildIndexPathPart(goalPath.goalId) == null &&
                            !newSelectedGoals.contains(goalPath)) {
                          newSelectedGoals.add(goalPath);
                        }
                      }
                      selectedGoalsProvider.add(newSelectedGoals);
                    }
                  : null,
              child: Column(children: goalItems)),
        ));
    return treeWidget;
  }
}
