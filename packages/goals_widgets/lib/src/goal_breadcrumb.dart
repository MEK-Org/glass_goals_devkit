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
        TextOverflow,
        TextPainter,
        TextSpan,
        TextStyle,
        VoidCallback;
import 'package:flutter/services.dart' show SystemMouseCursors;
import 'package:flutter/widgets.dart'
    show
        BoxConstraints,
        BuildContext,
        ConstrainedBox,
        DefaultTextStyle,
        Directionality,
        GestureDetector,
        Icon,
        LayoutBuilder,
        MainAxisSize,
        MediaQuery,
        MouseRegion,
        Padding,
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
  final double? maxWidth;
  const Breadcrumb({
    super.key,
    this.style,
    required this.path,
    this.allowTapping = true,
    this.abbreviateGoalName = false,
    this.maxWidth,
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
  Goal? get _goal => GoalWidgetsContext.of(context)
      .syncClient
      .stateSubject
      .value[widget.path.goalId];

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

    final Widget child;
    if (crumbText == null) {
      child = FadeShimmer(
        width: 50,
        height: widget.style?.fontSize ?? 14,
        baseColor: emphasizedLightBackground,
        highlightColor: Color.lerp(lightBackground, Colors.white, 0.5)!,
      );
    } else {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          child: Text(
            crumbText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
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

    if (widget.maxWidth == null) return child;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth!),
      child: child,
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
  static const _maxBreadcrumbWidth = 560.0;
  static const _rightEdgePadding = 8.0;
  static const _chevronWidth = 24.0;
  static const _omissionWidth = 20.0;
  static const _removeButtonWidth = 18.0;

  bool _hovered = false;
  WatchedGoalSet? _watch;
  StreamSubscription? _watchSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watch != null) return;
    final syncClient = GoalWidgetsContext.of(context).syncClient;
    _watch = syncClient.watchGoals(widget.renderedPath);
    _watchSub = _watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(PathBreadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.renderedPath != widget.renderedPath) {
      _watch?.setIds(widget.renderedPath);
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _watch?.dispose();
    super.dispose();
  }

  List<double> _naturalCrumbWidths(BuildContext context) {
    final goalMap =
        GoalWidgetsContext.of(context).syncClient.stateSubject.value;
    final defaultStyle = DefaultTextStyle.of(context).style;
    final crumbStyle = defaultStyle.merge((widget.style ?? const TextStyle())
        .copyWith(decoration: TextDecoration.underline));
    return List.generate(widget.renderedPath.length, (index) {
      final shouldAbbreviate = switch (widget.abbreviationStrategy) {
        CrumbAbbreviationStrategy.none => false,
        CrumbAbbreviationStrategy.show_last =>
          index != widget.renderedPath.length - 1,
        CrumbAbbreviationStrategy.all => true,
      };
      final text = shouldAbbreviate
          ? _doAbbreviation(goalMap[widget.renderedPath[index]]?.text)
          : goalMap[widget.renderedPath[index]]?.text;
      if (text == null) return 50.0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: crumbStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      return painter.width;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) =>
        (goalsTheme?.uiUnit ?? 4.0) * numUnits;
    final palePinkColor = Colors.pink.shade50;
    final deepRedColor = Colors.red.shade900;
    final visibleRemoveColor = theme.iconTheme.color ?? Colors.black54;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxBreadcrumbWidth),
      child: Padding(
        padding: const EdgeInsets.only(right: _rightEdgePadding),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : _maxBreadcrumbWidth;
              final removeWidth = widget.onRemove == null
                  ? 0.0
                  : uiUnit(2) + _removeButtonWidth;
              final pathLength = widget.renderedPath.length;
              final availableCrumbWidth =
                  (availableWidth - removeWidth).clamp(0.0, availableWidth);
              final naturalWidths = _naturalCrumbWidths(context);
              final allCrumbsWidth = naturalWidths.fold<double>(
                    0.0,
                    (sum, width) => sum + width,
                  ) +
                  (pathLength - 1) * _chevronWidth;
              var firstVisible = 0;
              if (pathLength > 1 && allCrumbsWidth > availableCrumbWidth) {
                firstVisible = pathLength - 1;
                var visibleWidth =
                    _omissionWidth + _chevronWidth + naturalWidths.last;
                for (var index = pathLength - 2; index >= 0; index--) {
                  final candidateWidth =
                      visibleWidth + _chevronWidth + naturalWidths[index];
                  if (candidateWidth > availableCrumbWidth) break;
                  firstVisible = index;
                  visibleWidth = candidateWidth;
                }
              }
              final targetVisible = pathLength - firstVisible;
              final hasOmission = firstVisible > 0;
              final separatorCount =
                  (targetVisible - 1) + (hasOmission ? 1 : 0);
              final displayedCrumbWidth = (availableCrumbWidth -
                      (separatorCount * _chevronWidth) -
                      (hasOmission ? _omissionWidth : 0.0))
                  .clamp(0.0, availableCrumbWidth);
              final widgets = <Widget>[];

              if (hasOmission) {
                widgets.add(const SizedBox(
                  width: _omissionWidth,
                  child: Text('…', maxLines: 1),
                ));
                widgets.add(const Icon(Icons.chevron_right));
              }

              for (var i = firstVisible; i < pathLength; i++) {
                final shouldAbbreviate = switch (widget.abbreviationStrategy) {
                  CrumbAbbreviationStrategy.none => false,
                  CrumbAbbreviationStrategy.show_last => i != pathLength - 1,
                  CrumbAbbreviationStrategy.all => true,
                };
                final isNearestVisibleCrumb = i == pathLength - 1;
                final earlierVisibleWidths = naturalWidths
                    .sublist(firstVisible, i)
                    .fold<double>(0.0, (sum, width) => sum + width);
                final crumbWidth = isNearestVisibleCrumb
                    ? (displayedCrumbWidth - earlierVisibleWidths)
                        .clamp(0.0, displayedCrumbWidth)
                    : naturalWidths[i];
                widgets.add(Breadcrumb(
                  style: widget.style,
                  maxWidth: crumbWidth,
                  path: GoalPath([
                    ...widget.contextPath,
                    ...widget.renderedPath.sublist(0, i + 1)
                  ]),
                  allowTapping: widget.allowTappingCrumbs,
                  abbreviateGoalName: shouldAbbreviate,
                ));
                if (i != pathLength - 1) {
                  widgets.add(const Icon(Icons.chevron_right));
                }
              }

              if (widget.onRemove != null) {
                widgets.add(SizedBox(width: uiUnit(2)));
                widgets.add(Ink(
                  decoration: ShapeDecoration(
                    color: _hovered ? palePinkColor : Colors.transparent,
                    shape: CircleBorder(),
                  ),
                  child: SizedBox(
                    width: _removeButtonWidth,
                    height: _removeButtonWidth,
                    child: IconButton(
                      color: _hovered ? deepRedColor : visibleRemoveColor,
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close, size: 16.0),
                      onPressed: widget.onRemove,
                    ),
                  ),
                ));
              }

              return Row(mainAxisSize: MainAxisSize.min, children: widgets);
            },
          ),
        ),
      ),
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
    final visited = <String>{};

    while (curGoal != null && visited.add(curGoal.id)) {
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
