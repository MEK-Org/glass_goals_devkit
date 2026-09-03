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
        FocusNode,
        GestureDetector,
        Icon,
        MouseRegion,
        Padding,
        Row,
        SizedBox,
        Text,
        TextEditingController,
        Widget,
        WidgetsBinding,
        StatefulWidget,
        State,
        Expanded;
import 'package:goals_core/model.dart';
import 'package:goals_ui_core/core.dart';

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
  bool _hasMouse = hasMouseProvider.value;
  final FocusNode _focusNode = FocusNode();
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    this._focusNode.addListener(this._focusListener);
    _subscriptions.add(hasMouseProvider.stream.listen((hasMouse) {
      if (!mounted || hasMouse == _hasMouse) {
        return;
      }
      setState(() {
        _hasMouse = hasMouse;
      });
    }));
    _subscriptions.add(textFocusProvider.stream.listen(_onTextFocusChanged));

    if (pathsMatch(textFocusProvider.value, this.widget.path)) {
      _startEditing();
    }
  }

  _focusListener() {
    if (!this._focusNode.hasFocus &&
        pathsMatch(textFocusProvider.value, this.widget.path)) {
      Future.delayed(Duration.zero, () => this._focusNode.requestFocus());
    }
  }

  @override
  void didUpdateWidget(AddSubgoalItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!pathsMatch(oldWidget.path, widget.path) &&
        pathsMatch(textFocusProvider.value, widget.path)) {
      _startEditing();
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _textController.selection = TextSelection(
          baseOffset: 0, extentOffset: _textController.text.length);
    });
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
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
      _focusNode.unfocus();
      if (_editing && mounted) {
        setState(() {
          _editing = false;
        });
      }
    }
  }

  _cancelEditing() {
    this._textController.text = '';
    textFocusProvider.add(null);
  }

  _addGoal() async {
    final newText = _textController.text;
    await GoalActionsContext.of(context).onAddGoal.call(
        widget.path.parentPath, newText,
        pathBefore: widget.prevSiblingPath, pathAfter: widget.nextSiblingPath);
    _textController.text = '';
    _textController.selection = TextSelection(baseOffset: 0, extentOffset: 0);
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
          child: Row(
            children: [
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
                        style: theme.textTheme.bodyLarge ??
                            theme.textTheme.bodyMedium,
                        maxLines: _hasMouse ? null : 1,
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
                      child: Text(ADD_GOAL_TEXT,
                          style: (theme.textTheme.bodyLarge ??
                                  theme.textTheme.bodyMedium)
                              ?.copyWith(color: Colors.black54)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
