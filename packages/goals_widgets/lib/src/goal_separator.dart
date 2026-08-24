import 'dart:async';

import 'package:flutter_dropzone/flutter_dropzone.dart'
    show DropzoneViewController;
import 'package:flutter/material.dart' show Colors, Theme;
import 'package:flutter/widgets.dart';
import 'package:goals_core/model.dart';
import 'package:goals_ui_core/core.dart';

import 'file_drop_detector.dart';
import 'flattened_goal_tree.dart' show parseChildIndexPathPart;

typedef FileDropBetweenGoalsCallback = Future<void> Function({
  required BuildContext context,
  required DropzoneViewController dropzoneController,
  required dynamic dropEvent,
  required GoalPath prevGoalPath,
  required GoalPath nextGoalPath,
  required Map<String, Goal> goalMap,
});

class GoalSeparator extends StatefulWidget {
  final Map<String, Goal> goalMap;
  final List<String> prevGoalPath;
  final List<String> nextGoalPath;
  final bool isFirst;
  final Function(GoalDragDetails, bool)? onDropGoal;
  final List<String> path;
  final bool pendingShiftSelect;
  final GoalPath? shiftSelectStartPath;
  final GoalPath? shiftSelectEndPath;
  final FileDropBetweenGoalsCallback? onFileDropBetweenGoals;
  const GoalSeparator({
    super.key,
    required this.goalMap,
    required this.prevGoalPath,
    required this.nextGoalPath,
    this.onDropGoal,
    required this.isFirst,
    this.path = const [],
    this.pendingShiftSelect = false,
    this.shiftSelectStartPath,
    this.shiftSelectEndPath,
    this.onFileDropBetweenGoals,
  });

  @override
  State<GoalSeparator> createState() => _GoalSeparatorState();
}

class _GoalSeparatorState extends State<GoalSeparator> {
  bool _dragHovered = false;
  bool _topHovered = false;

  bool _adjacentHover = false;

  final List<StreamSubscription> _subscriptions = [];

  @override
  initState() {
    super.initState();

    _subscriptions.add(hoverEventStream.listen((newHoveredPath) {
      if (pathsMatch(newHoveredPath, this.widget.nextGoalPath) ||
          pathsMatch(newHoveredPath, this.widget.prevGoalPath)) {
        setState(() {
          this._adjacentHover = true;
        });
      } else {
        if (this._adjacentHover) {
          setState(() {
            this._adjacentHover = false;
          });
        }
      }
    }));
  }

  @override
  dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }

    super.dispose();
  }

  Widget _wrapWithFileDrop({
    required Widget child,
    required bool isTop,
  }) {
    final onFileDropBetweenGoals = widget.onFileDropBetweenGoals;
    if (onFileDropBetweenGoals == null) {
      return child;
    }

    return FileDropDetector(
      onFileDrop: (controller, event) async {
        await onFileDropBetweenGoals(
          context: context,
          dropzoneController: controller,
          dropEvent: event,
          prevGoalPath: GoalPath(widget.prevGoalPath),
          nextGoalPath: GoalPath(widget.nextGoalPath),
          goalMap: widget.goalMap,
        );
        setState(() {
          _dragHovered = false;
          _topHovered = false;
        });
      },
      onFileHover: () {
        if (!_dragHovered) {
          setState(() {
            _dragHovered = true;
            _topHovered = isTop;
          });
        }
      },
      onFileLeave: () {
        if (_dragHovered) {
          setState(() {
            _dragHovered = false;
            _topHovered = false;
          });
        }
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) => (goalsTheme?.uiUnit ?? 4.0) * numUnits;
    final darkElementColor = goalsTheme?.primaryColor ?? theme.colorScheme.onSurface;
    final emphasizedLightBackground = theme.hoverColor;

    return Padding(
      padding: EdgeInsets.only(
          left: this._dragHovered
              ? uiUnit(4) *
                  ((_topHovered &&
                                  widget.prevGoalPath.length >
                                      widget.nextGoalPath.length
                              ? widget.prevGoalPath
                              : widget.nextGoalPath)
                          .length -
                      (this.widget.path.length))
              : 0),
      child: Stack(
        children: [
          SizedBox(
            height: uiUnit(2),
            child: Center(
              child: Container(
                color: (this.widget.shiftSelectStartPath == null &&
                            (this._adjacentHover || this._dragHovered)) ||
                        (pathsMatch(this.widget.shiftSelectStartPath,
                                this.widget.nextGoalPath) ||
                            pathsMatch(this.widget.shiftSelectEndPath,
                                this.widget.prevGoalPath))
                    ? darkElementColor
                    : Colors.transparent,
                height: 2,
              ),
            ),
          ),
          if (!this.widget.isFirst)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: uiUnit(),
              child: _wrapWithFileDrop(
                isTop: true,
                child: DragTarget<GoalDragDetails>(
                  onAcceptWithDetails: (details) {
                    if (dragEventProvider.value == DragEventType.start) {
                      this.widget.onDropGoal?.call(details.data, true);
                    }
                    setState(() {
                      _dragHovered = false;
                      _topHovered = false;
                    });
                  },
                  onMove: (details) {
                    if (!_dragHovered) {
                      setState(() {
                        _dragHovered = true;
                        _topHovered = true;
                      });
                    }

                    if (hoverEventStream.value != null) {
                      hoverEventStream.add(null);
                    }
                  },
                  onLeave: (data) {
                    if (_dragHovered) {
                      setState(() {
                        _dragHovered = false;
                        _topHovered = true;
                      });
                    }
                  },
                  builder: (_, __, ___) => MouseRegion(
                      onHover: (event) {
                        if (!pathsMatch(hoverEventStream.value,
                                this.widget.prevGoalPath) &&
                            this.widget.prevGoalPath.isNotEmpty &&
                            parseChildIndexPathPart(
                                    this.widget.prevGoalPath.last) ==
                                null) {
                          hoverEventStream.add(this.widget.prevGoalPath);
                        }
                      },
                      child: Container(
                        color: pathsMatch(hoverEventStream.value,
                                    this.widget.prevGoalPath) ||
                                this.widget.pendingShiftSelect ||
                                pathsMatch(this.widget.shiftSelectStartPath,
                                    this.widget.prevGoalPath)
                            ? emphasizedLightBackground
                            : Colors.transparent,
                      )),
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: uiUnit(),
            child: _wrapWithFileDrop(
              isTop: false,
              child: DragTarget<GoalDragDetails>(
                  onAcceptWithDetails: (details) {
                    if (dragEventProvider.value == DragEventType.start) {
                      this.widget.onDropGoal?.call(details.data, false);
                    }
                    setState(() {
                      _dragHovered = false;
                      _topHovered = false;
                    });
                  },
                  onMove: (details) {
                    if (!_dragHovered) {
                      setState(() {
                        _dragHovered = true;
                        _topHovered = false;
                      });
                    }

                    if (hoverEventStream.value != null) {
                      hoverEventStream.add(null);
                    }
                  },
                  onLeave: (data) {
                    if (_dragHovered) {
                      setState(() {
                        _dragHovered = false;
                        _topHovered = false;
                      });
                    }
                  },
                  builder: (_, __, ___) => MouseRegion(
                        onHover: (event) {
                          if (!pathsMatch(hoverEventStream.value,
                                  this.widget.nextGoalPath) &&
                              this.widget.nextGoalPath.isNotEmpty &&
                              parseChildIndexPathPart(
                                      this.widget.nextGoalPath.last) ==
                                  null) {
                            hoverEventStream.add(this.widget.nextGoalPath);
                          }
                        },
                        child: Container(
                          color: pathsMatch(hoverEventStream.value,
                                      this.widget.nextGoalPath) ||
                                  this.widget.pendingShiftSelect ||
                                  pathsMatch(this.widget.shiftSelectStartPath,
                                      this.widget.prevGoalPath)
                              ? emphasizedLightBackground
                              : Colors.transparent,
                        ),
                      )),
            ),
          ),
        ],
      ),
    );
  }
}
