import 'dart:async' show StreamSubscription;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:goals_core/model.dart' show GoalPath, WorldContext;
import 'package:rxdart/rxdart.dart' show BehaviorSubject, CombineLatestStream;

import 'time_slice.dart';

final isOnlineProvider = BehaviorSubject<bool>.seeded(false);
StreamSubscription<List<ConnectivityResult>>? _isOnlineSubscription;

void initIsOnlineProvider() async {
  final connectivity = Connectivity();

  // Check initial connectivity
  final result = await connectivity.checkConnectivity();
  isOnlineProvider.add(!result.contains(ConnectivityResult.none));

  // Listen for connectivity changes
  _isOnlineSubscription?.cancel();
  _isOnlineSubscription = connectivity.onConnectivityChanged
      .listen((List<ConnectivityResult> results) {
    isOnlineProvider.add(!results.contains(ConnectivityResult.none));
  });
}

final selectedGoalsProvider = BehaviorSubject<List<GoalPath>>.seeded([]);

final expandedGoalsProvider = BehaviorSubject<List<GoalPath>>.seeded([]);

void togglePath(
    BehaviorSubject<List<GoalPath>> pathListSubject, GoalPath path) {
  final existingPathList = [...pathListSubject.value];
  if (pathListSubject.value.contains(path)) {
    existingPathList.removeWhere((p) => pathsMatch(p, path));
  } else {
    existingPathList.add(path);
  }
  pathListSubject.add(existingPathList);
}

void addPath(BehaviorSubject<List<GoalPath>> pathListSubject, GoalPath path) {
  if (pathListSubject.value.contains(path)) return;
  final existingPathList = [...pathListSubject.value];
  existingPathList.add(path);
  pathListSubject.add(existingPathList);
}

void removePath(
    BehaviorSubject<List<GoalPath>> pathListSubject, GoalPath path) {
  if (pathListSubject.value.contains(path)) return;
  final existingPathList = [...pathListSubject.value];
  existingPathList.removeWhere((p) => pathsMatch(p, path));
  pathListSubject.add(existingPathList);
}

final focusedGoalProvider = BehaviorSubject<GoalPath?>.seeded(null);

enum DragEventType {
  start,
  cancel,
  end,
  none,
}

final dragEventProvider =
    BehaviorSubject<DragEventType>.seeded(DragEventType.none);

final worldContextProvider =
    BehaviorSubject<WorldContext>.seeded(WorldContext.now());

final _manualTimeSlices = BehaviorSubject<
    List<({DateTime creationDateTime, TimeSlice slice})>>.seeded([]);

Future<void> createManualTimeSlice(TimeSlice slice) async {
  final previousTimeSlices = [..._manualTimeSlices.value];
  previousTimeSlices.add((creationDateTime: DateTime.now(), slice: slice));
  _manualTimeSlices.add(previousTimeSlices);
}

/// This provider will return a list of time slices that we should show
/// even if they don't have any active goals within them.
final manualTimeSliceProvider = BehaviorSubject<List<TimeSlice>>.seeded([]);
final manualTimeSliceProviderSubscription =
    CombineLatestStream<Object, List<TimeSlice>>(
  [worldContextProvider.stream, _manualTimeSlices],
  (values) {
    final [
      WorldContext ctx,
      List<({DateTime creationDateTime, TimeSlice slice})> manualTimeSlices
    ] = values as List<dynamic>;

    final now = ctx.time;

    final slices = <TimeSlice>[];
    for (final (:creationDateTime, :slice) in manualTimeSlices) {
      final sliceStartTime = slice.startTime(creationDateTime);
      final sliceEndTime = slice.endTime(creationDateTime);
      if ((sliceStartTime == null || now.isAfter(sliceStartTime)) &&
          (sliceEndTime == null || now.isBefore(sliceEndTime))) {
        slices.add(slice);
      }
    }
    return slices;
  },
).listen(manualTimeSliceProvider.add);

final debugProvider = BehaviorSubject<bool>.seeded(false);
final hasMouseProvider = BehaviorSubject<bool>.seeded(false);

final hoverEventStream = BehaviorSubject<List<String>?>.seeded(null);

final textFocusProvider = BehaviorSubject<GoalPath?>.seeded(null);

final findInPageProvider = BehaviorSubject<String?>.seeded(null);

bool pathsMatch(List<String>? a, List<String>? b) {
  if (a == null && b == null) return true;
  if (a?.length != b?.length) {
    return false;
  }
  for (int i = 0; i < a!.length; i++) {
    if (a[i] != b![i]) return false;
  }
  return true;
}

enum EditingEvent {
  accept,
  discard,
}
