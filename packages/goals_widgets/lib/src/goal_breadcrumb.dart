import 'dart:async' show StreamSubscription;
import 'dart:ui' show Color;

import 'package:fade_shimmer/fade_shimmer.dart' show FadeShimmer;
import 'package:flutter/material.dart'
    show Colors, IconButton, Icons, Ink, Theme;
import 'package:flutter/painting.dart'
    show
        CircleBorder,
        EdgeInsets,
        ShapeDecoration,
        TextDecoration,
        TextStyle,
        VoidCallback;
import 'package:flutter/services.dart' show SystemMouseCursors;
import 'package:flutter/widgets.dart'
    show
        BuildContext,
        GestureDetector,
        Icon,
        MainAxisSize,
        MouseRegion,
        Row,
        SizedBox,
        State,
        StatefulWidget,
        Text,
        Widget;
import 'package:goals_core/model.dart' show Goal, GoalPath, isAnchor;
import 'package:goals_core/sync.dart' show SyncClient, WatchedGoalSet;
import 'package:goals_ui_core/core.dart'
    show GoalActionsContext, GoalWidgetsContext, GoalsTheme;
import 'package:rxdart/rxdart.dart' show ThrottleExtensions;

enum CrumbAbbreviationStrategy {
  /// Don't abbreviate any parts of the path.
  none,

  /// Abbreviate everything but the last part of the path.
  show_last,

  /// Abbreviate all parts of the path.
  all,
}

String? _doAbbreviation(String? goalName) {
  if (goalName == null) {
    return null;
  }
  final parts = goalName.split(' - ');
  if (parts.length < 2) {
    return goalName;
  }
  return _abbreviateLocatorName(parts[0]);
}

const ABBREVIATIONS = {
  "article": "Art.",
  "section": "§",
  "clause": "Cl.",
  "chapter": "Ch.",
  "paragraph": "¶",
  "part": "Pt.",
};

String _abbreviateLocatorName(String partyName) {
  var result = '';
  for (var word in partyName.split(' ')) {
    final abbr = ABBREVIATIONS[word.toLowerCase()];
    if (abbr != null) {
      result += abbr;
    } else {
      result += word;
    }
    result += ' ';
  }
  return result.trim();
}

class Breadcrumb extends StatefulWidget {
  final TextStyle? style;
  final GoalPath path;
  final bool allowTapping;
  final bool abbreviateGoalName;
  const Breadcrumb({
    super.key,
    this.style,
    required this.path,
    this.allowTapping = true,
    this.abbreviateGoalName = false,
  });

  @override
  State<Breadcrumb> createState() => _BreadcrumbState();
}

class _BreadcrumbState extends State<Breadcrumb> {
  /// Pins just this crumb's goal id. Rebuilds when that goal loads or its
  /// text changes — the crumb only reads the goal's `text`, so the watch is
  /// a single-element set.
  WatchedGoalSet? _watch;
  StreamSubscription? _watchSub;

  /// Reads from the live [stateSubject] rather than tracking the throttled
  /// stream's value in a field. The watch still pins the goal and triggers
  /// rebuilds; this getter eliminates the window where the field lags fresh
  /// state and we'd otherwise render a shimmer for a resident goal.
  Goal? get _goal =>
      GoalWidgetsContext.of(context).syncClient.stateSubject.value[widget.path.goalId];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watch != null) return;
    final syncClient = GoalWidgetsContext.of(context).syncClient;
    _watch = syncClient.watchGoals([widget.path.goalId]);
    _watchSub = _watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(Breadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path.goalId != widget.path.goalId) {
      _watch?.setIds([widget.path.goalId]);
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _watch?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emphasizedLightBackground = theme.hoverColor;
    final lightBackground = theme.scaffoldBackgroundColor;

    var crumbText =
        widget.abbreviateGoalName ? _doAbbreviation(_goal?.text) : _goal?.text;

    if (crumbText == null) {
      return FadeShimmer(
        width: 50,
        height: widget.style?.fontSize ?? 14,
        baseColor: emphasizedLightBackground,
        highlightColor: Color.lerp(lightBackground, Colors.white, 0.5)!,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        child: Text(
          crumbText,
          style: widget.style != null
              ? widget.style!.copyWith(decoration: TextDecoration.underline)
              : TextStyle(decoration: TextDecoration.underline),
        ),
        onTap: widget.allowTapping
            ? () {
                GoalActionsContext.of(context).onFocused(widget.path);
              }
            : null,
      ),
    );
  }
}

class PathBreadcrumb extends StatefulWidget {
  final GoalPath renderedPath;
  final GoalPath contextPath;
  final TextStyle? style;
  final VoidCallback? onRemove;
  final bool allowTappingCrumbs;
  final CrumbAbbreviationStrategy abbreviationStrategy;
  const PathBreadcrumb({
    super.key,
    required this.renderedPath,
    this.style,
    this.contextPath = const GoalPath([]),
    this.onRemove,
    this.allowTappingCrumbs = true,
    this.abbreviationStrategy = CrumbAbbreviationStrategy.none,
  });

  @override
  State<PathBreadcrumb> createState() => _PathBreadcrumbState();
}

class _PathBreadcrumbState extends State<PathBreadcrumb> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) =>
        (goalsTheme?.uiUnit ?? 4.0) * numUnits;
    final palePinkColor = Colors.pink.shade50;
    final deepRedColor = Colors.red.shade900;

    final widgets = <Widget>[];

    for (final (i, _) in this.widget.renderedPath.indexed) {
      final shouldAbbreviate = switch (this.widget.abbreviationStrategy) {
        CrumbAbbreviationStrategy.none => false,
        CrumbAbbreviationStrategy.show_last =>
          i != this.widget.renderedPath.length - 1,
        CrumbAbbreviationStrategy.all => true,
      };
      widgets.add(Breadcrumb(
        style: this.widget.style,
        path: GoalPath([
          ...this.widget.contextPath,
          ...this.widget.renderedPath.sublist(0, i + 1)
        ]),
        allowTapping: this.widget.allowTappingCrumbs,
        abbreviateGoalName: shouldAbbreviate,
      ));
      widgets.add(const Icon(Icons.chevron_right));
    }
    if (widgets.isNotEmpty) widgets.removeLast();

    if (this.widget.onRemove != null) {
      widgets.add(SizedBox(width: uiUnit(2)));
      widgets.add(Ink(
        decoration: ShapeDecoration(
          color: this._hovered ? palePinkColor : Colors.transparent,
          shape: CircleBorder(),
        ),
        child: SizedBox(
          width: 18.0,
          height: 18.0,
          child: IconButton(
            color: this._hovered ? deepRedColor : Colors.transparent,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close, size: 16.0),
            onPressed: this.widget.onRemove,
          ),
        ),
      ));
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(mainAxisSize: MainAxisSize.min, children: widgets),
    );
  }
}

class ParentBreadcrumb extends StatefulWidget {
  final GoalPath path;
  final VoidCallback? onRemove;
  const ParentBreadcrumb({
    super.key,
    required this.path,
    this.onRemove,
  });

  @override
  State<ParentBreadcrumb> createState() => _ParentBreadcrumbState();
}

class _ParentBreadcrumbState extends State<ParentBreadcrumb> {
  /// Pins the chain `[widget.path.goalId, parent, grandparent, ...]` up to
  /// the first anchor. The watched set grows as each parent loads, since we
  /// can't know the chain length without reading the goals.
  WatchedGoalSet? _watch;
  StreamSubscription? _watchSub;
  SyncClient? _syncClient;

  /// Reads the live [stateSubject] rather than tracking the throttled stream
  /// in a field. The watch still pins the chain and drives rebuilds; this
  /// getter avoids the lag window between an emission landing and the next
  /// build that would otherwise render a stale chain.
  Map<String, Goal> get _goalMap =>
      GoalWidgetsContext.of(context).syncClient.stateSubject.value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watch != null) return;
    _syncClient = GoalWidgetsContext.of(context).syncClient;
    _watch = _syncClient!.watchGoals(_computeChainIds(_goalMap));
    _watchSub = _watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (!mounted) return;
      setState(() {});
      // Each emission may expose a new parent — re-walk the chain using the
      // fresh live state and extend the watched set if needed.
      _watch?.setIds(_computeChainIds(_goalMap));
    });
  }

  @override
  void didUpdateWidget(ParentBreadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path.goalId != widget.path.goalId) {
      _watch?.setIds(_computeChainIds(_goalMap));
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _watch?.dispose();
    super.dispose();
  }

  /// Walks up `superGoalIds.firstOrNull` from [widget.path.goalId] using the
  /// loaded entries in [goalMap]. Stops at the first anchor, the first
  /// missing ancestor, or a cycle. Includes the start id so [Breadcrumb]
  /// can render the leaf even before any parent has loaded.
  Set<String> _computeChainIds(Map<String, Goal> goalMap) {
    final ids = <String>{widget.path.goalId};
    Goal? curGoal = goalMap[widget.path.goalId];
    while (curGoal != null) {
      if (isAnchor(curGoal) != null) break;
      final parentId = curGoal.superGoalIds.firstOrNull;
      if (parentId == null || ids.contains(parentId)) break;
      ids.add(parentId);
      curGoal = goalMap[parentId];
    }
    return ids;
  }

  @override
  Widget build(BuildContext context) {
    Goal? curGoal = _goalMap[widget.path.goalId];
    GoalPath parentPath = widget.path.parentPath;
    final renderedPath = <String>[];

    while (curGoal != null) {
      renderedPath.add(curGoal.id);

      if (isAnchor(curGoal) != null) {
        break;
      }
      curGoal = _goalMap[curGoal.superGoalIds.firstOrNull];
    }

    return PathBreadcrumb(
      renderedPath: GoalPath(renderedPath.reversed.toList()),
      contextPath: parentPath,
      onRemove: widget.onRemove,
      abbreviationStrategy: CrumbAbbreviationStrategy.show_last,
    );
  }
}
