import 'dart:async';

import 'package:flutter_dropzone/flutter_dropzone.dart'
    show DropzoneViewController;
import 'package:flutter/material.dart'
    show Colors, IconButton, Icons, TextField, Theme;
import 'dart:ui' show FontWeight;
import 'package:flutter/painting.dart'
    show
        Border,
        BorderRadius,
        BoxDecoration,
        BoxShape,
        EdgeInsets,
        EdgeInsetsGeometry,
        TextDecoration,
        TextOverflow,
        TextStyle;
import 'package:flutter/rendering.dart'
    show HitTestBehavior, MainAxisAlignment, MainAxisSize;
import 'package:flutter/services.dart' show SystemMouseCursors, TextSelection;
import 'package:flutter/widgets.dart'
    show
        Actions,
        BuildContext,
        CallbackAction,
        Center,
        Container,
        DragTarget,
        Draggable,
        Flexible,
        Focus,
        FocusNode,
        GestureDetector,
        Icon,
        IntrinsicWidth,
        MediaQuery,
        MouseRegion,
        Padding,
        Row,
        SizedBox,
        State,
        StatefulWidget,
        StreamBuilder,
        Text,
        TextEditingController,
        Widget,
        pointerDragAnchorStrategy;
import 'package:goals_core/model.dart'
    show Goal, GoalInstance, GoalPath, getPathParentEntry;
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:fade_shimmer/fade_shimmer.dart' show FadeShimmer, FadeTheme;
import 'package:rxdart/rxdart.dart' show ThrottleExtensions;

import 'file_drop_detector.dart';
import 'goal_breadcrumb.dart';
import 'hover_actions_builder.dart';
import 'status_chip.dart';

typedef FileDropOnGoalCallback = Future<void> Function({
  required BuildContext context,
  required DropzoneViewController dropzoneController,
  required dynamic dropEvent,
  required GoalPath targetGoalPath,
  required Map<String, Goal> goalMap,
});

enum GoalItemDragHandle {
  none,
  bullet,
  item,
}

class GoalItemWidget extends StatefulWidget {
  final HoverActionsBuilder hoverActionsBuilder;
  final bool hasRenderableChildren;
  final bool showExpansionArrow;
  final GoalItemDragHandle dragHandle;
  final Function(GoalDragDetails goalId)? onDropGoal;
  final Function()? onEnter;

  // TODO: figure out if there's a way to combine path and renderedPath

  /// This is the overall path of this item including the context.
  final GoalPath path;

  /// This is the part of the path that will actually be rendered by this widget.
  /// If unspecified, we'll just render the last part of the path.
  final GoalPath? renderedPath;
  final EdgeInsetsGeometry padding;
  final bool pendingShiftSelect;
  final FileDropOnGoalCallback? onFileDropOnGoal;

  const GoalItemWidget({
    super.key,
    required this.hoverActionsBuilder,
    required this.hasRenderableChildren,
    this.showExpansionArrow = true,
    this.dragHandle = GoalItemDragHandle.none,
    this.onDropGoal,
    required this.path,
    this.padding = const EdgeInsets.all(0),
    this.pendingShiftSelect = false,
    this.renderedPath,
    this.onEnter,
    this.onFileDropOnGoal,
  });

  @override
  State<GoalItemWidget> createState() => _GoalItemWidgetState();
}

class _GoalItemWidgetState extends State<GoalItemWidget> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // TODO: maybe this should be a state machine?
  bool _editing = false;
  bool _hovering = false;
  bool _dragging = false;
  List<GoalPath> _expandedGoals = expandedGoalsProvider.value;
  List<GoalPath> _selectedGoals = selectedGoalsProvider.value;
  bool _hasMouse = hasMouseProvider.value;

  List<StreamSubscription> subscriptions = [];

  /// Pins the goals along [widget.path] so this leaf can resolve its own
  /// goal, walk parent relationships (`getPathParentEntry`), and supply a
  /// path-bounded `goalMap` to file-drop handlers — without depending on a
  /// tree-wide context map.
  WatchedGoalSet? _watch;

  /// Reads the live state directly rather than tracking the throttled stream's
  /// emissions in a field. The watch is still essential — it pins these goals
  /// against eviction and triggers rebuilds when they change — but the value
  /// at build time comes from [stateSubject] so there's no window where this
  /// widget renders a shimmer for a goal that is actually resident.
  Map<String, Goal> get _goalMap =>
      GoalWidgetsContext.of(context).syncClient.stateSubject.value;

  Goal? get goal => _goalMap[widget.path.goalId];

  @override
  void initState() {
    super.initState();

    subscriptions.add(hoverEventStream.listen((hoveredPath) {
      if (!pathsMatch(hoveredPath, widget.path) && _hovering) {
        setState(() {
          _hovering = false;
        });
      } else if (pathsMatch(hoveredPath, widget.path) && !_hovering) {
        setState(() {
          _hovering = true;
        });
      }

      if (pathsMatch(hoveredPath, this.widget.path) &&
          textFocusProvider.value == null &&
          dragEventProvider.value != DragEventType.start) {
        this._focusNode.requestFocus();
      }
    }));
    subscriptions.add(expandedGoalsProvider.stream.listen((expandedGoals) {
      if (!mounted) {
        return;
      }
      setState(() {
        _expandedGoals = expandedGoals;
      });
    }));
    subscriptions.add(selectedGoalsProvider.stream.listen((selectedGoals) {
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedGoals = selectedGoals;
      });
    }));
    subscriptions.add(hasMouseProvider.stream.listen((hasMouse) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hasMouse = hasMouse;
      });
    }));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watch != null) return;
    final syncClient = GoalWidgetsContext.of(context).syncClient;
    _watch = syncClient.watchGoals(widget.path);
    subscriptions.add(_watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (!mounted) return;
      setState(() {});
    }));
  }

  @override
  void dispose() {
    for (final subscription in this.subscriptions) {
      subscription.cancel();
    }
    _watch?.dispose();

    super.dispose();
  }

  _cancelEditing() {
    hoverEventStream.add(null);
    textFocusProvider.add(null);
    if (goal != null) {
      _textController.text = goal!.text;
    }
    setState(() {
      this._editing = false;
    });
  }

  @override
  didUpdateWidget(GoalItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pendingShiftSelect != widget.pendingShiftSelect) {
      setState(() {});
    }
    if (!_pathEquals(oldWidget.path, widget.path)) {
      _watch?.setIds(widget.path);
    }
  }

  static bool _pathEquals(GoalPath a, GoalPath b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  _updateGoal() {
    if (_textController.text != goal?.text) {
      GoalWidgetsContext.of(context).syncClient.modifyGoal(
          GoalDelta(id: widget.path.goalId, text: _textController.text));
    }

    textFocusProvider.add(null);
    setState(() {
      _editing = false;
    });
  }

  Widget _dragWrapWidget({
    required Widget child,
    required bool isSelected,
    required List<List<String>> selectedGoals,
  }) {
    return Draggable<GoalDragDetails>(
      data: GoalDragDetails(path: this.widget.path),
      hitTestBehavior: HitTestBehavior.opaque,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        this._focusNode.requestFocus();
        if (dragEventProvider.value == DragEventType.start) {
          dragEventProvider.add(DragEventType.cancel);
        }
        dragEventProvider.add(DragEventType.start);
        setState(() {
          this._dragging = true;
        });
      },
      onDragCompleted: () {
        if (dragEventProvider.value == DragEventType.start) {
          dragEventProvider.add(DragEventType.end);
        }
        setState(() {
          this._dragging = false;
        });
      },
      onDraggableCanceled: (_, __) {
        if (dragEventProvider.value == DragEventType.start) {
          dragEventProvider.add(DragEventType.cancel);
        }
        setState(() {
          this._dragging = false;
        });
      },
      feedback: StreamBuilder(
          stream: dragEventProvider.stream,
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data == DragEventType.cancel) {
              return Container();
            }
            return Container(
              decoration: const BoxDecoration(
                  color: Colors.red, shape: BoxShape.circle),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text((isSelected ? selectedGoals.length : 1).toString(),
                    style: const TextStyle(
                        fontSize: 20,
                        decoration: TextDecoration.none,
                        color: Colors.white)),
              ),
            );
          }),
      child: child,
    );
  }

  _startEditing() {
    if (goal == null || _editing) {
      return;
    }
    this._textController.text = goal!.text;
    this._textController.selection =
        TextSelection(baseOffset: 0, extentOffset: _textController.text.length);
    textFocusProvider.add(this.widget.path);
    this._focusNode.unfocus();
    setState(() {
      _editing = true;
      Future.delayed(Duration.zero, () {
        this._focusNode.requestFocus();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) =>
        (goalsTheme?.uiUnit ?? 4.0) * numUnits;
    final darkElementColor =
        goalsTheme?.primaryColor ?? theme.colorScheme.onSurface;
    final emphasizedLightBackground = theme.hoverColor;
    final mainTextStyle = theme.textTheme.bodyLarge ?? const TextStyle();
    final focusedFontStyle = goalsTheme?.focusedFontStyle ??
        const TextStyle(fontWeight: FontWeight.bold);

    final expandedGoals = _expandedGoals;
    final isExpanded = expandedGoals.contains(widget.path);
    final selectedGoals = _selectedGoals;
    final hasMouse = _hasMouse;

    final isSelected = selectedGoals.contains(widget.path);
    final isNarrow = MediaQuery.of(context).size.width < 600;
    final onExpanded = GoalActionsContext.of(context).onExpanded;
    final onFocused = GoalActionsContext.of(context).onFocused;
    final onSelected = GoalActionsContext.of(context).onSelected;
    final pathParentEntry = getPathParentEntry(_goalMap, widget.path);
    final isInstanceSpecific = pathParentEntry?.path != null;
    final isGoalInstance = goal is GoalInstance;
    final bullet = SizedBox(
      width: uiUnit(10),
      height: uiUnit(hasMouse ? 8 : 12),
      child: Center(
          child: Container(
        width: uiUnit(1.5),
        height: uiUnit(1.5),
        decoration: BoxDecoration(
          color: isGoalInstance ? null : darkElementColor,
          borderRadius:
              isInstanceSpecific ? null : BorderRadius.circular(uiUnit()),
          border: isGoalInstance
              ? Border.all(color: darkElementColor, width: 1.25)
              : null,
        ),
      )),
    );
    final content = MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (event) {
        if (!_hovering) {
          hoverEventStream.add(this.widget.path);
          setState(() {
            _hovering = true;
          });
        }
      },
      child: GestureDetector(
        onTap: _editing
            ? null
            : () {
                onSelected.call(widget.path);
                onFocused.call(widget.path);
              },
        onTertiaryTapUp: _editing
            ? null
            : (details) {
                onFocused.call(widget.path, inPlace: true);
              },
        child: Container(
          decoration: BoxDecoration(
            color: _hovering || widget.pendingShiftSelect
                ? emphasizedLightBackground
                : Colors.transparent,
          ),
          child: Padding(
            padding: widget.padding,
            child: Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    widget.dragHandle == GoalItemDragHandle.bullet &&
                            !this._editing
                        ? _dragWrapWidget(
                            child: bullet,
                            isSelected: isSelected,
                            selectedGoals: selectedGoals,
                          )
                        : bullet,
                    goal == null
                        ? FadeShimmer(
                            width: uiUnit(30),
                            height: uiUnit(10),
                            fadeTheme: FadeTheme.light,
                          )
                        : _editing
                            ? IntrinsicWidth(
                                child: TextField(
                                  autocorrect: false,
                                  controller: _textController,
                                  decoration: null,

                                  // NOTE: this is a workaround so that the text field doesn't
                                  // auto-highlight when switching between windows.
                                  maxLines: hasMouse ? null : 1,
                                  style: mainTextStyle,
                                  onEditingComplete: this._updateGoal,
                                  onTapOutside: (_) {
                                    _updateGoal();
                                  },
                                  focusNode: _focusNode,
                                ),
                              )
                            : (this.widget.renderedPath?.length ?? 1) > 1
                                ? PathBreadcrumb(
                                    renderedPath: this.widget.renderedPath!,
                                    style: mainTextStyle,
                                    contextPath: this.widget.path,
                                    abbreviationStrategy:
                                        CrumbAbbreviationStrategy.show_last,
                                  )
                                : Flexible(
                                    child: Focus(
                                      focusNode: _focusNode,
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.text,
                                        child: GestureDetector(
                                          onTap:
                                              hasMouse ? _startEditing : null,
                                          onLongPress:
                                              !hasMouse ? _startEditing : null,
                                          child: Text(
                                              goal?.text.length == 0
                                                  ? " "
                                                  : goal?.text ?? " ",
                                              style: (isSelected
                                                      ? focusedFontStyle
                                                          .merge(mainTextStyle)
                                                      : mainTextStyle)
                                                  .copyWith(
                                                decoration:
                                                    TextDecoration.underline,
                                                overflow: TextOverflow.ellipsis,
                                              )),
                                        ),
                                      ),
                                    ),
                                  ),
                    // chip-like container widget around text status widget:
                    if (goal != null)
                      CurrentStatusChip(
                        goal: goal!,
                        padding: EdgeInsets.only(left: uiUnit(2)),
                        path: widget.path,
                      ),
                    if (this.widget.showExpansionArrow &&
                        widget.hasRenderableChildren)
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => onExpanded(widget.path),
                            icon: Icon(
                                size: 24,
                                isExpanded
                                    ? Icons.arrow_drop_down
                                    : Icons.arrow_right)),
                      ),
                  ]),
                ),
                if (!isNarrow && !_editing && _hovering)
                  Padding(
                    padding: const EdgeInsets.only(right: 16.0),
                    child: widget.hoverActionsBuilder(this.widget.path),
                  )
              ],
            ),
          ),
        ),
      ),
    );

    final actionsWidget = Actions(
      actions: {
        if (this._editing)
          CancelIntent: CallbackAction<CancelIntent>(
            onInvoke: (_) {
              this._cancelEditing();
            },
          ),
        if (this._dragging)
          CancelIntent: CallbackAction<CancelIntent>(
            onInvoke: (_) {
              dragEventProvider.add(DragEventType.cancel);
              setState(() {
                this._dragging = false;
              });
            },
          ),
        if (this._editing)
          AcceptIntent: CallbackAction<AcceptIntent>(
            onInvoke: (_) {
              this._updateGoal();
              this.widget.onEnter?.call();
            },
          ),
        if (this._editing)
          AcceptMultiLineTextIntent: CallbackAction<AcceptMultiLineTextIntent>(
            onInvoke: (_) {
              this._updateGoal();
              this.widget.onEnter?.call();
            },
          ),
        if (!this._editing)
          ActivateIntent:
              CallbackAction<ActivateIntent>(onInvoke: (ActivateIntent intent) {
            onExpanded.call(GoalPath(widget.path));
          }),
        if (!this._editing)
          AcceptIntent: CallbackAction<AcceptIntent>(
            onInvoke: (_) {
              onSelected.call(widget.path);
              onFocused.call(GoalPath(widget.path));
            },
          ),
      },
      child: DragTarget<GoalDragDetails>(
        onAcceptWithDetails: (details) {
          if (dragEventProvider.value == DragEventType.start) {
            this.widget.onDropGoal?.call(details.data);
          }
        },
        onMove: (details) {
          if (!_hovering) {
            hoverEventStream.add(this.widget.path);
            setState(() {
              _hovering = true;
            });
          }
        },
        builder: (context, _, __) =>
            widget.dragHandle == GoalItemDragHandle.item && !this._editing
                ? _dragWrapWidget(
                    isSelected: isSelected,
                    selectedGoals: selectedGoals,
                    child: content,
                  )
                : content,
      ),
    );

    // Wrap with file drop detector if handler is available
    final onFileDropOnGoal = widget.onFileDropOnGoal;
    if (onFileDropOnGoal != null) {
      return FileDropDetector(
        onFileDrop: (controller, event) async {
          await onFileDropOnGoal(
            context: context,
            dropzoneController: controller,
            dropEvent: event,
            targetGoalPath: widget.path,
            goalMap: _goalMap,
          );
        },
        onFileHover: () {
          hoverEventStream.add(widget.path);
        },
        onFileLeave: () {
          if (_hovering) {
            hoverEventStream.add(null);
          }
        },
        child: actionsWidget,
      );
    }

    return actionsWidget;
  }
}
