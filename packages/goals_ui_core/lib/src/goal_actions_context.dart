import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Widget;
import 'package:goals_core/model.dart';

import 'pdf_variant.dart';
import 'time_slice.dart';

class GoalDragDetails {
  final GoalPath path;

  const GoalDragDetails({
    required this.path,
  });
}

typedef AddGoalCallback = Function(GoalPath? parentPath, String text,
    {TimeSlice? slice, GoalPath? pathBefore, GoalPath? pathAfter});

class GoalActionsContext extends InheritedWidget {
  final Function(List<String> goalId) onSelected;
  final Function(GoalPath, {bool? inPlace}) onFocused;
  final Function(GoalPath goalId, {bool? expanded}) onExpanded;
  final AddGoalCallback onAddGoal;
  final Function(GoalPath?) onUnarchive;
  final Function(GoalPath?) onArchive;
  final Function(GoalPath?, DateTime?) onDone;
  final Function(GoalPath?, DateTime?) onSnooze;
  final Function(String) onMakeAnchor;
  final Function(String) onClearAnchor;
  final Function(String) onAddSummary;
  final Function(String) onClearSummary;
  final Function(String) onAddDocumentContent;
  final Function(String) onClearDocumentContent;
  final Function(GoalPath?) onClearStatus;
  final Function(
    GoalPath, {
    GoalPath? dropPath,
    GoalPath? prevDropPath,
    GoalPath? nextDropPath,
    bool isAdditive,
  }) onDropGoal;
  final Function(GoalPath?, {DateTime startTime, DateTime? endTime}) onActive;
  final Function(String? goalId, PdfVariant variant, [String? format])? onPrint;

  const GoalActionsContext({
    required Widget child,
    required this.onSelected,
    required this.onFocused,
    required this.onExpanded,
    required this.onAddGoal,
    required this.onUnarchive,
    required this.onArchive,
    required this.onDone,
    required this.onSnooze,
    required this.onActive,
    required this.onDropGoal,
    required this.onMakeAnchor,
    required this.onClearAnchor,
    required this.onAddSummary,
    required this.onClearSummary,
    required this.onAddDocumentContent,
    required this.onClearDocumentContent,
    required this.onClearStatus,
    this.onPrint,
  }) : super(child: child);

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) {
    return true;
  }

  static GoalActionsContext of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GoalActionsContext>()!;
  }

  factory GoalActionsContext.empty({required Widget child}) {
    return GoalActionsContext(
      child: child,
      onSelected: (List<String> goalId) {},
      onFocused: (GoalPath path, {bool? inPlace}) {},
      onExpanded: (GoalPath path, {bool? expanded}) {},
      onAddGoal: (GoalPath? parentPath, String text,
          {TimeSlice? slice, GoalPath? pathBefore, GoalPath? pathAfter}) {},
      onUnarchive: (GoalPath? goalId) {},
      onArchive: (GoalPath? goalId) {},
      onDone: (GoalPath? goalId, DateTime? dateTime) {},
      onSnooze: (GoalPath? goalId, DateTime? dateTime) {},
      onActive: (GoalPath? goalId, {DateTime? startTime, DateTime? endTime}) {},
      onDropGoal: (GoalPath path,
          {GoalPath? dropPath,
          GoalPath? prevDropPath,
          GoalPath? nextDropPath,
          bool isAdditive = false}) {},
      onMakeAnchor: (String goalId) {},
      onClearAnchor: (String goalId) {},
      onAddSummary: (String goalId) {},
      onClearSummary: (String goalId) {},
      onAddDocumentContent: (String goalId) {},
      onClearDocumentContent: (String goalId) {},
      onClearStatus: (GoalPath? goalId) {},
    );
  }

  // I don't LOVE this but it should work for now.
  // This feels like it should be represented with Intents and Actions.
  static GoalActionsContext overrideWith(
    BuildContext context, {
    required Widget child,
    Function(GoalPath, {bool? inPlace})? onFocused,
    AddGoalCallback? onAddGoal,
    Function(GoalPath?)? onUnarchive,
    Function(GoalPath?)? onArchive,
    Function(GoalPath?, DateTime?)? onDone,
    Function(GoalPath?, DateTime?)? onSnooze,
    Function(GoalPath?, {DateTime startTime, DateTime? endTime})? onActive,
    Function(
      GoalPath, {
      GoalPath? dropPath,
      GoalPath? prevDropPath,
      GoalPath? nextDropPath,
      bool isAdditive,
    })? onDropGoal,
    Function(String? goalId, PdfVariant variant, [String? format])? onPrint,
    Function(String goalId)? onClearAnchor,
    Function(String goalId)? onMakeAnchor,
    Function(String goalId)? onAddSummary,
    Function(String goalId)? onClearSummary,
    Function(String goalId)? onAddDocumentContent,
    Function(String goalId)? onClearDocumentContent,
    Function(GoalPath? goalId)? onClearStatus,
  }) {
    return GoalActionsContext(
      child: child,
      onSelected: GoalActionsContext.of(context).onSelected,
      onFocused: onFocused ?? GoalActionsContext.of(context).onFocused,
      onExpanded: GoalActionsContext.of(context).onExpanded,
      onAddGoal: onAddGoal ?? GoalActionsContext.of(context).onAddGoal,
      onUnarchive: onUnarchive ?? GoalActionsContext.of(context).onUnarchive,
      onArchive: onArchive ?? GoalActionsContext.of(context).onArchive,
      onDone: onDone ?? GoalActionsContext.of(context).onDone,
      onSnooze: onSnooze ?? GoalActionsContext.of(context).onSnooze,
      onActive: onActive ?? GoalActionsContext.of(context).onActive,
      onDropGoal: onDropGoal ?? GoalActionsContext.of(context).onDropGoal,
      onPrint: onPrint ?? GoalActionsContext.of(context).onPrint,
      onClearAnchor:
          onClearAnchor ?? GoalActionsContext.of(context).onClearAnchor,
      onMakeAnchor: onMakeAnchor ?? GoalActionsContext.of(context).onMakeAnchor,
      onAddSummary: onAddSummary ?? GoalActionsContext.of(context).onAddSummary,
      onClearSummary:
          onClearSummary ?? GoalActionsContext.of(context).onClearSummary,
      onAddDocumentContent: onAddDocumentContent ??
          GoalActionsContext.of(context).onAddDocumentContent,
      onClearDocumentContent: onClearDocumentContent ??
          GoalActionsContext.of(context).onClearDocumentContent,
      onClearStatus:
          onClearStatus ?? GoalActionsContext.of(context).onClearStatus,
    );
  }
}
