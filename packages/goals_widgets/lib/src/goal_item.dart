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
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, SystemMouseCursors, TextSelection;
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
        FocusManager,
        FocusScopeNode,
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
  int _editRevision = 0;
  int _focusRevision = 0;
  final Set<int> _pendingEdits = {};
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
    this._focusNode.addListener(this._focusListener);
    subscriptions.add(
      textFocusProvider.stream.listen((path) {
        if (!pathsMatch(path, widget.path)) _focusRevision++;
      }),
    );

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

  _focusListener() {
    if (!this._focusNode.hasFocus &&
        pathsMatch(textFocusProvider.value, this.widget.path)) {
      final revision = _focusRevision;
      Future.delayed(Duration.zero, () {
        if (mounted &&
            revision == _focusRevision &&
            pathsMatch(textFocusProvider.value, widget.path) &&
            FocusManager.instance.primaryFocus is FocusScopeNode) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    for (final subscription in this.subscriptions) {
      subscription.cancel();
    }
    _watch?.dispose();
    _focusNode.dispose();
    _textController.dispose();

    super.dispose();
  }

  _cancelEditing() {
    _editRevision++;
    hoverEventStream.add(null);
    if (pathsMatch(textFocusProvider.value, widget.path)) {
      textFocusProvider.add(null);
    }
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
      _editRevision++;
      _focusRevision++;
      _editing = false;
      _textController.clear();
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

  Future<void> _updateGoal({bool advance = false}) async {
    if (!_editing || _pendingEdits.contains(_editRevision)) return;
    final path = widget.path;
    final revision = _editRevision;
    final focusRevision = _focusRevision;
    final onEnter = widget.onEnter;
    // An unchanged draft is a focus handoff, not a new undoable mutation.
    // An older pending edit can still replace the live value, so submitting a
    // reversion to that value must remain an awaited mutation in that case.
    final shouldSave =
        _pendingEdits.isNotEmpty || _textController.text != goal?.text;
    _pendingEdits.add(revision);
    try {
      // Preserve the editor until the async contract guarantees the updated
      // model. build reads the live state, even inside the watch throttle window.
      if (shouldSave) {
        await GoalWidgetsContext.of(context).syncClient.modifyGoal(
          GoalDelta(id: path.goalId, text: _textController.text),
        );
      }
      if (!mounted ||
          !_pathEquals(widget.path, path) ||
          !_editing ||
          _editRevision != revision)
        return;
      final ownsFocus =
          _focusRevision == focusRevision &&
          pathsMatch(textFocusProvider.value, path);
      final advanceFocus = ownsFocus && _focusNode.hasFocus;
      setState(() => _editing = false);
      if (ownsFocus) {
        textFocusProvider.add(null);
        if (advance && advanceFocus) onEnter?.call();
      }
    } finally {
      _pendingEdits.remove(revision);
    }
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
      feedback: _GoalDragFeedback(
        count: isSelected ? selectedGoals.length : 1,
      ),
      child: child,
    );
  }

  _startEditing() {
    if (goal == null || _editing) {
      return;
    }
    _editRevision++;
    this._textController.text = goal!.text;
    this._textController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _textController.text.length,
    );
    textFocusProvider.add(this.widget.path);
    this._focusNode.unfocus();
    setState(() {
      _editing = true;
      final revision = _editRevision;
      Future.delayed(Duration.zero, () {
        if (mounted &&
            _editing &&
            revision == _editRevision &&
            pathsMatch(textFocusProvider.value, widget.path)) {
          _focusNode.requestFocus();
        }
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
                                  onChanged: (_) => _editRevision++,
                                  onEditingComplete: _updateGoal,
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
                                                      ? mainTextStyle.merge(
                                                          focusedFontStyle)
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
              _updateGoal(advance: true);
            },
          ),
        if (this._editing)
          AcceptMultiLineTextIntent: CallbackAction<AcceptMultiLineTextIntent>(
            onInvoke: (_) {
              _updateGoal(advance: true);
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

class _GoalDragFeedback extends StatefulWidget {
  final int count;
  const _GoalDragFeedback({required this.count});

  @override
  State<_GoalDragFeedback> createState() => _GoalDragFeedbackState();
}

class _GoalDragFeedbackState extends State<_GoalDragFeedback> {
  bool _isAdditive = false;

  @override
  void initState() {
    super.initState();
    _isAdditive = isAltHeld();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    final additive = isAltHeld();
    if (_isAdditive != additive) {
      setState(() {
        _isAdditive = additive;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: dragEventProvider.stream,
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data == DragEventType.cancel) {
          return Container();
        }
        final label = _isAdditive ? '+${widget.count}' : '${widget.count}';
        return Container(
          decoration: const BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 20,
                decoration: TextDecoration.none,
                color: Colors.white,
              ),
            ),
          ),
        );
      },
    );
  }
}
