import 'dart:async' show StreamSubscription;

import 'package:flutter/material.dart';
import 'package:goals_core/model.dart'
    show Goal, GoalPath, WorldContext, getGoalStatus;
import 'package:goals_core/sync.dart';
import 'package:goals_core/util.dart'
    show
        DateTimeExtension,
        isWithinCalendarMonth,
        isWithinCalendarWeek,
        isWithinCalendarYear,
        isWithinDay,
        isWithinQuarter;
import 'package:goals_ui_core/core.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:rxdart/rxdart.dart' show ThrottleExtensions;

String getActiveDateString(DateTime now, StatusLogEntry status) {
  if (isWithinDay(now, status)) {
    return 'Today';
  } else if (isWithinCalendarWeek(now, status)) {
    return 'This Week';
  } else if (isWithinCalendarMonth(now, status)) {
    return 'This Month';
  } else if (isWithinQuarter(now, status)) {
    return 'This Quarter';
  } else if (isWithinCalendarYear(now, status)) {
    return 'This Year';
  } else if (status.endTime != null) {
    return 'Until ${DateFormat.yMd().format(status.endTime!)}';
  } else {
    return 'Ongoing';
  }
}

String getSnoozedDateString(DateTime now, StatusLogEntry status) {
  if (status.endTime?.isBefore(now.startOfDay.subtract(const Duration(seconds: 1))) ==
      true) {
    return DateFormat.yMd().format(status.endTime!);
  } else if (status.endTime?.isBefore(now.endOfDay.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Later Today';
  } else if (status.endTime?.isBefore(now.add(const Duration(days: 1)).endOfDay) ==
      true) {
    return 'Tomorrow';
  } else if (status.endTime?.isBefore(now.endOfWeek.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Later This Week';
  } else if (status.endTime?.isBefore(now.add(const Duration(days: 7)).endOfWeek.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Next Week';
  } else if (status.endTime?.isBefore(now.endOfMonth.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Later This Month';
  } else if (status.endTime?.isBefore(now.endOfMonth
          .add(const Duration(days: 1))
          .endOfMonth
          .subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Next Month';
  } else if (status.endTime
          ?.isBefore(now.endOfQuarter.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Later This Quarter';
  } else if (status.endTime
          ?.isBefore(now.endOfQuarter.add(const Duration(days: 1)).endOfQuarter.subtract(const Duration(seconds: 1))) ==
      true) {
    return 'Next Quarter';
  } else if (status.endTime?.isBefore(now.endOfYear.subtract(const Duration(seconds: 1))) == true) {
    return 'Later This Year';
  } else if (status.endTime != null) {
    return DateFormat.yMd().format(status.endTime!);
  } else {
    // Snoozing forever doesn't really make sense, but we'll render it as forever
    return 'Forever';
  }
}

String getGoalStatusStringSince(WorldContext context, StatusLogEntry status) {
  switch (status.status) {
    case GoalStatus.active:
      return "Active since ${status.startTime != null ? DateFormat.yMd().format(status.startTime!) : 'the beginning of time'}";
    case GoalStatus.done:
      return 'Done since ${status.startTime != null ? DateFormat.yMd().format(status.startTime!) : 'the beginning of time'}}';
    case GoalStatus.archived:
      return 'Archived';
    case GoalStatus.pending:
      return "Snoozed since ${status.startTime != null ? DateFormat.yMd().format(status.startTime!) : 'the beginning of time'}";
    case null:
      return 'To Do';
  }
}

String getVerboseGoalStatusString(WorldContext context, StatusLogEntry status) {
  switch (status.status) {
    case GoalStatus.active:
      return "${status.endTime != null ? 'Until ${DateFormat.yMd().format(status.endTime!)}' : 'Ongoing'}";
    case GoalStatus.done:
      return 'Done${status.endTime != null ? ' until ${getSnoozedDateString(context.time, status)}' : ''}';
    case GoalStatus.archived:
      return 'Archived';
    case GoalStatus.pending:
      return "Until ${DateFormat.yMd().format(status.endTime!)}";
    case null:
      return 'To Do';
  }
}

String getGoalStatusString(WorldContext context, StatusLogEntry status) {
  switch (status.status) {
    case GoalStatus.active:
      return getActiveDateString(context.time, status);
    case GoalStatus.done:
      return 'Done';
    case GoalStatus.archived:
      return 'Archived';
    case GoalStatus.pending:
      return getSnoozedDateString(context.time, status);
    case null:
      return 'To Do';
  }
}

Color getGoalStatusBackgroundColor(
    GoalsTheme? goalsTheme, StatusLogEntry status) {
  switch (status.status) {
    case GoalStatus.active:
      return goalsTheme?.activeGoalBg ?? Colors.green.shade100;
    case GoalStatus.done:
      return goalsTheme?.doneGoalBg ?? Colors.blue.shade100;
    case GoalStatus.archived:
      return goalsTheme?.archivedGoalBg ?? Colors.grey.shade300;
    case GoalStatus.pending:
      return goalsTheme?.pendingGoalBg ?? Colors.yellow.shade100;
    case null:
      return goalsTheme?.toDoGoalBg ?? Colors.purple.shade100;
  }
}

Color getGoalStatusTextColor(GoalsTheme? goalsTheme, StatusLogEntry status) {
  switch (status.status) {
    case GoalStatus.active:
      return goalsTheme?.activeGoalFg ?? Colors.green.shade900;
    case GoalStatus.done:
      return goalsTheme?.doneGoalFg ?? Colors.blue.shade900;
    case GoalStatus.archived:
      return goalsTheme?.archivedGoalFg ?? Colors.grey.shade700;
    case GoalStatus.pending:
      return goalsTheme?.pendingGoalFg ?? Colors.brown.shade900;
    case null:
      return goalsTheme?.toDoGoalFg ?? Colors.purple.shade900;
  }
}

/// Status Chip is a "dumb" Widget that just accepts a StatusLogEntry and displays it.
class StatusChip extends StatefulWidget {
  final StatusLogEntry? entry;
  final String goalId;
  final bool showArchiveButton;
  final bool until;
  final bool since;
  const StatusChip({
    super.key,
    required this.entry,
    required this.goalId,
    required this.showArchiveButton,
    this.until = false,
    this.since = false,
  });

  @override
  State<StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<StatusChip> {
  late WorldContext _worldContext = worldContextProvider.value;
  late bool _isDebugMode = debugProvider.value;
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _subscriptions.add(worldContextProvider.stream.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        _worldContext = value;
      });
    }));
    _subscriptions.add(debugProvider.stream.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDebugMode = value;
      });
    }));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goalsTheme = theme.extension<GoalsTheme>();
    double uiUnit([double numUnits = 1]) =>
        (goalsTheme?.uiUnit ?? 4.0) * numUnits;
    final chipTextStyle = theme.textTheme.bodyMedium ??
        theme.textTheme.bodySmall ??
        const TextStyle();

    final worldContext = _worldContext;
    final isDebugMode = _isDebugMode;

    if (widget.entry == null) {
      return Container();
    }

    return Container(
      decoration: BoxDecoration(
        color: getGoalStatusBackgroundColor(goalsTheme, widget.entry!),
        borderRadius: BorderRadius.circular(1),
      ),
      padding: EdgeInsets.only(
        top: uiUnit() / 2,
        bottom: uiUnit() / 2,
        left: uiUnit(),
        right: uiUnit() / 2,
      ),
      child: Row(
        children: [
          isDebugMode
              ? Tooltip(
                  message:
                      '${widget.entry!.startTime != null ? DateFormat.yMd().format(widget.entry!.startTime!) : 'The Big Bang'} - ${widget.entry!.endTime != null ? DateFormat.yMd().format(widget.entry!.endTime!) : 'The Heat Death of the Universe'}',
                  child: Text(
                    widget.until
                        ? getVerboseGoalStatusString(
                            worldContext, widget.entry!)
                        : widget.since
                            ? getGoalStatusStringSince(
                                worldContext, widget.entry!)
                            : getGoalStatusString(worldContext, widget.entry!),
                    style: chipTextStyle.copyWith(
                        color:
                            getGoalStatusTextColor(goalsTheme, widget.entry!)),
                  ),
                )
              : Text(
                  widget.until
                      ? getVerboseGoalStatusString(worldContext, widget.entry!)
                      : widget.since
                          ? getGoalStatusStringSince(
                              worldContext, widget.entry!)
                          : getGoalStatusString(worldContext, widget.entry!),
                  style: chipTextStyle.copyWith(
                      color: getGoalStatusTextColor(goalsTheme, widget.entry!)),
                ),
          SizedBox(width: uiUnit() / 2),
          if (widget.entry!.status != null && widget.showArchiveButton)
            SizedBox(
              width: 18.0,
              height: 18.0,
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close, size: 16.0),
                onPressed: () {
                  GoalWidgetsContext.of(context).syncClient.modifyGoal(GoalDelta(
                      id: widget.goalId,
                      logEntry: ArchiveStatusLogEntry(
                          creationTime: DateTime.now(), id: widget.entry!.id)));
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Current Status Chip is a "smart" Widget that accepts a goal and
/// looks up the current status of that goal according to the World context.
class CurrentStatusChip extends StatefulWidget {
  final Goal goal;
  final EdgeInsetsGeometry padding;
  final GoalPath path;
  final SyncClient? syncClient;

  const CurrentStatusChip({
    super.key,
    required this.goal,
    this.padding = const EdgeInsets.all(0),
    required this.path,
    this.syncClient,
  });

  @override
  State<CurrentStatusChip> createState() => _CurrentStatusChipState();
}

class _CurrentStatusChipState extends State<CurrentStatusChip> {
  late WorldContext _worldContext = worldContextProvider.value;
  final List<StreamSubscription> _subscriptions = [];

  /// Pins the goals along `widget.path` so [getGoalStatus] can resolve
  /// status-log entries that reference instance/slice ancestors. The chip
  /// owns its watch rather than reading a tree-wide goalMap — that keeps the
  /// pin set minimal (exactly the path) and the rebuilds reactive to changes
  /// in any path goal.
  WatchedGoalSet? _watch;
  SyncClient? _syncClient;

  /// Reads the live [stateSubject] rather than tracking the throttled stream's
  /// value in a field. The watch still pins the path and drives rebuilds; this
  /// getter avoids the lag window where [getGoalStatus] would read a stale
  /// path-bounded map.
  Map<String, Goal> get _goalMap => _syncClient!.stateSubject.value;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(worldContextProvider.stream.listen((value) {
      if (!mounted) return;
      setState(() {
        _worldContext = value;
      });
    }));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watch != null) return;
    final syncClient =
        widget.syncClient ?? GoalWidgetsContext.maybeOf(context)?.syncClient;
    if (syncClient == null) {
      throw StateError(
          'CurrentStatusChip requires either `syncClient` or GoalWidgetsContext in ancestry');
    }
    _syncClient = syncClient;
    _watch = syncClient.watchGoals(widget.path);
    _subscriptions.add(_watch!.stream
        .throttleTime(const Duration(milliseconds: 16), trailing: true)
        .listen((_) {
      if (!mounted) return;
      setState(() {});
    }));
  }

  @override
  void didUpdateWidget(CurrentStatusChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_pathEquals(oldWidget.path, widget.path)) {
      _watch?.setIds(widget.path);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _watch?.dispose();
    super.dispose();
  }

  static bool _pathEquals(GoalPath a, GoalPath b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final goalStatus = getGoalStatus(_worldContext, widget.goal,
        path: widget.path, goalMap: _goalMap);

    if (goalStatus == null) {
      return Container();
    }

    return Padding(
      padding: widget.padding,
      child: StatusChip(
          entry: goalStatus,
          until: true,
          goalId: widget.goal.id,
          showArchiveButton: true),
    );
  }
}
