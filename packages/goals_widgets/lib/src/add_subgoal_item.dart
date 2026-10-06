import 'dart:async' show StreamSubscription;

import 'package:flutter/material.dart' show Colors, Icons, TextField, Theme;
import 'package:flutter/painting.dart' show EdgeInsets, EdgeInsetsGeometry;
import 'package:flutter/services.dart' show SystemMouseCursors, TextSelection;
import 'package:flutter/widgets.dart'
    show
        Actions,
        BuildContext,
        CallbackAction,
        Center,
        Column,
        CrossAxisAlignment,
        FocusNode,
        FocusManager,
        FocusScopeNode,
        GestureDetector,
        Icon,
        MouseRegion,
        Padding,
        Row,
        KeyedSubtree,
        SizedBox,
        Text,
        TextEditingController,
        Widget,
        WidgetsBinding,
        ValueKey,
        StatefulWidget,
        State,
        Expanded;
import 'package:goals_core/model.dart';
import 'package:goals_ui_core/core.dart';

import 'flattened_goal_tree.dart' show getChildIndexPathPart, parseChildIndexPathPart;

class AddSubgoalItemWidget extends StatefulWidget {
  final GoalPath path;
  final EdgeInsetsGeometry padding;
  final GoalPath? prevSiblingPath;
  final GoalPath? nextSiblingPath;
  const AddSubgoalItemWidget({
    super.key,
    required this.path,
    this.padding = const EdgeInsets.all(0),
    this.prevSiblingPath,
    this.nextSiblingPath,
  });

  @override
  State<AddSubgoalItemWidget> createState() => _AddSubgoalItemWidgetState();
}

class _AddSubgoalItemWidgetState extends State<AddSubgoalItemWidget> {
  late TextEditingController _textController = TextEditingController(text: '');
  bool _editing = false;
  int _draftRevision = 0;
  int _focusRevision = 0;
  int _pendingSubmissions = 0;
  final Map<String, _PendingGoal> _pendingGoals = {};
  PendingGoalRegistry? _pendingGoalRegistry;
  bool _hasMouse = hasMouseProvider.value;
  final FocusNode _focusNode = FocusNode();
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    this._focusNode.addListener(this._focusListener);
    _subscriptions.add(
      hasMouseProvider.stream.listen((hasMouse) {
        if (!mounted || hasMouse == _hasMouse) {
          return;
        }
        setState(() {
          _hasMouse = hasMouse;
        });
      }),
    );
    _subscriptions.add(textFocusProvider.stream.listen(_onTextFocusChanged));

    if (pathsMatch(textFocusProvider.value, this.widget.path)) {
      _startEditing();
    }
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
  void didUpdateWidget(AddSubgoalItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!pathsMatch(oldWidget.path, widget.path)) {
      _clearPendingGoals();
      _draftRevision++;
      _focusRevision++;
      _textController.clear();
      _editing = false;
      if (pathsMatch(textFocusProvider.value, widget.path)) _startEditing();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pendingGoalRegistry =
        GoalWidgetsContext.maybeOf(context)?.pendingGoalRegistry;
  }

  Iterable<_PendingGoal> get _visiblePendingGoals {
    final registry = _pendingGoalRegistry;
    if (registry == null) return _pendingGoals.values;
    final rendered = _pendingGoals.keys
        .where(registry.isRendered)
        .toList(growable: false);
    if (rendered.isEmpty) return _pendingGoals.values;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        for (final id in rendered) {
          _pendingGoals.remove(id);
        }
      });
      for (final id in rendered) {
        registry.forget(id);
      }
    });
    return _pendingGoals.entries
        .where((entry) => !registry.isRendered(entry.key))
        .map((entry) => entry.value);
  }

  void _clearPendingGoals() {
    final registry = _pendingGoalRegistry;
    for (final id in _pendingGoals.keys) {
      registry?.forget(id);
    }
    _pendingGoals.clear();
  }

  void _removePendingGoal(String id) {
    final removed = _pendingGoals.remove(id);
    _pendingGoalRegistry?.forget(id);
    if (removed != null && mounted) setState(() {});
  }

  void _retirePendingGoalAfterTreePass(String id) {
    final registry = _pendingGoalRegistry;
    if (registry == null) {
      _removePendingGoal(id);
      return;
    }
    registry.beginRetirement(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pendingGoals.containsKey(id)) return;
      if (registry.isRetirementReady(id)) {
        _removePendingGoal(id);
      } else {
        _retirePendingGoalAfterTreePass(id);
      }
    });
  }

  /// Switches the row into editing mode and focuses the text field *after*
  /// it has been inserted into the tree. Requesting focus in the same turn we
  /// flip `_editing` to true (which is what we used to do) requests focus on a
  /// node that isn't attached to a `TextField` yet — on web the platform
  /// text-input connection isn't established in time, so the first typed
  /// character is dropped. Deferring the focus request to the post-frame
  /// callback guarantees the field is mounted and its input connection is
  /// open before any keystroke arrives.
  void _startEditing() {
    if (_editing) {
      if (!_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
      return;
    }
    if (mounted) {
      setState(() => _editing = true);
    } else {
      _editing = true;
    }
    final path = widget.path;
    final revision = _draftRevision;
    final focusRevision = _focusRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !pathsMatch(widget.path, path) ||
          !pathsMatch(textFocusProvider.value, path) ||
          revision != _draftRevision ||
          focusRevision != _focusRevision)
        return;
      _focusNode.requestFocus();
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    });
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _clearPendingGoals();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextFocusChanged(GoalPath? newValue) {
    if (pathsMatch(widget.path, newValue)) {
      if (!_editing || !_focusNode.hasFocus) {
        _startEditing();
      }
    } else {
      _focusRevision++;
      if (_editing && mounted) {
        setState(() {
          _editing = false;
        });
      }
    }
  }

  _cancelEditing() {
    _draftRevision++;
    this._textController.text = '';
    textFocusProvider.add(null);
  }

  Future<void> _addGoal() async {
    // A repeated Enter/click-away must not submit the consumed buffer again.
    if (_pendingSubmissions > 0 && _textController.text.isEmpty) return;
    final path = widget.path;
    final draft = _textController.value;
    final revision = ++_draftRevision;
    final focusRevision = _focusRevision;
    final submission = GoalActionsContext.of(context).onAddGoal(
      path.parentPath,
      draft.text,
      pathBefore: widget.prevSiblingPath,
      pathAfter: widget.nextSiblingPath,
    );
    _pendingSubmissions++;
    // A stream echo may insert the new goal before the callback completes.
    // This reusable row now owns the NEXT draft, not the submitted one.
    _textController.clear();
    if (_pendingGoalRegistry != null) {
      _pendingGoalRegistry!.register(submission.goalId);
      setState(() {
        _pendingGoals[submission.goalId] =
            _PendingGoal(id: submission.goalId, text: draft.text);
      });
    }
    try {
      await submission.completion;
      // Wait for a post-success tree pass. A rendered row hands off without a
      // blank frame; a slice that cannot render the goal retires its row once
      // that pass proves the absence.
      _retirePendingGoalAfterTreePass(submission.goalId);
      if (!mounted ||
          !pathsMatch(widget.path, path) ||
          _draftRevision != revision ||
          _focusRevision != focusRevision ||
          !_editing ||
          !pathsMatch(textFocusProvider.value, path))
        return;
      // Focus/selection handoff still waits for the mutation contract. Only
      // the submitting row can tell whether the user has started another draft.
      final index = parseChildIndexPathPart(path.goalId);
      if (index != null && index != -1) {
        textFocusProvider.add(
          GoalPath([...path.parentPath, getChildIndexPathPart(index + 1)]),
        );
      }
    } catch (_) {
      _removePendingGoal(submission.goalId);
      if (mounted &&
          pathsMatch(widget.path, path) &&
          _draftRevision == revision &&
          _textController.text.isEmpty) {
        _textController.value = draft;
      }
      rethrow;
    } finally {
      _pendingSubmissions--;
    }
  }

  @override
  Widget build(BuildContext context) {
    final goalsTheme = Theme.of(context).extension<GoalsTheme>();
    final theme = Theme.of(context);
    return Actions(
      actions: {
        CancelIntent: CallbackAction<CancelIntent>(
          onInvoke: (_) {
            this._cancelEditing();
          },
        ),
        AcceptIntent: CallbackAction<AcceptIntent>(
          onInvoke: (_) {
            this._addGoal();
          },
        ),
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: this.widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final pending in _visiblePendingGoals)
                KeyedSubtree(
                  key: ValueKey('pending-goal-${pending.id}'),
                  child: Row(
                    children: [
                      SizedBox(
                        width: (goalsTheme?.uiUnit ?? 4) * 10,
                        height:
                            (goalsTheme?.uiUnit ?? 4) * (_hasMouse ? 8 : 12),
                        child: const Center(child: Icon(Icons.circle, size: 8)),
                      ),
                      Expanded(
                        child: Text(
                          pending.text,
                          style: theme.textTheme.bodyLarge ??
                              theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              Row(children: [
              GestureDetector(
                onTap: () {
                  textFocusProvider.add(widget.path);
                },
                child: SizedBox(
                  width: (goalsTheme?.uiUnit ?? 4) * 10,
                  height: (goalsTheme?.uiUnit ?? 4) * (_hasMouse ? 8 : 12),
                  child: const Center(child: Icon(Icons.add, size: 18)),
                ),
              ),
              _editing
                  ? Expanded(
                      child: TextField(
                        autocorrect: false,
                        controller: _textController,
                        decoration: null,
                        style:
                            theme.textTheme.bodyLarge ??
                            theme.textTheme.bodyMedium,
                        maxLines: _hasMouse ? null : 1,
                        onChanged: (_) => _draftRevision++,
                        onEditingComplete: _addGoal,
                        onTapOutside: (_) {
                          if (_textController.text.isNotEmpty) {
                            _addGoal();
                          }
                          textFocusProvider.add(null);
                        },
                        focusNode: _focusNode,
                      ),
                    )
                  : GestureDetector(
                      onTap: () {
                        textFocusProvider.add(widget.path);
                      },
                      child: Text(
                        ADD_GOAL_TEXT,
                        style:
                            (theme.textTheme.bodyLarge ??
                                    theme.textTheme.bodyMedium)
                                ?.copyWith(color: Colors.black54),
                      ),
                    ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingGoal {
  final String id;
  final String text;

  const _PendingGoal({required this.id, required this.text});
}
