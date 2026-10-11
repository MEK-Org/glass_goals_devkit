import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart'
    show GoalPath, WorldContext, getGoalStatus;
import 'package:goals_types/goals_types.dart' show GoalStatus, Op;
import 'package:goals_core/sync.dart'
    show
        GoalDelta,
        StatusLogEntry,
        MemoryLocalStore,
        MemoryPersistenceService,
        SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        GoalActionsContext,
        GoalWidgetsContext,
        SHORTCUTS,
        expandedGoalsProvider,
        hasMouseProvider,
        hoverEventStream,
        selectedGoalsProvider,
        textFocusProvider,
        worldContextProvider;
import 'package:goals_widgets/goals_widgets.dart' show FlattenedGoalTree;

class _Remote extends MemoryPersistenceService {
  Future<void> persist(List<Op> batch) => super.save([
        ...ops.where((old) => !batch.any((op) => op.id == old.id)),
        ...batch,
      ]);
  @override
  Future<void> save(Iterable<Op> values) async {
    await persist(values.toList());
  }
}

void main() {
  late SyncClient client;
  late _Remote persistenceService;
  late MemoryLocalStore localStore;
  final boundaryKey = GlobalKey();

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    worldContextProvider.add(WorldContext(time: DateTime(2026)));

    localStore = MemoryLocalStore();
    persistenceService = _Remote();
    client = SyncClient(
      localStore: localStore,
      persistenceService: persistenceService,
    );
    await client.init();
    await client.modifyGoals([
      GoalDelta(id: 'g1', text: 'First goal: review PR #195'),
      GoalDelta(id: 'g2', text: 'Second goal: implement first-row boundary fix'),
      GoalDelta(id: 'g3', text: 'Third goal: verify reload persistence'),
    ]);
    await client.sync();
  });

  tearDown(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hoverEventStream.add(null);
    client.dispose();
  });

  Future<void> capture(WidgetTester tester, String filename) async {
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../docs/images/issue195/$filename');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(byteData!.buffer.asUint8List());
    });
  }

  testWidgets('capture before and after hover-backspace archive on first row',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Shortcuts(
                shortcuts: SHORTCUTS,
                child: GoalWidgetsContext(
                  syncClient: client,
                  child: GoalActionsContext.empty(
                    child: Builder(
                      builder: (context) => GoalActionsContext.overrideWith(
                        context,
                        onArchive: (path) {
                          if (path != null) {
                            client.modifyGoal(GoalDelta(
                              id: path.goalId,
                              logEntry: StatusLogEntry(
                                id: 'archive-${path.goalId}',
                                creationTime: DateTime.now(),
                                status: GoalStatus.archived,
                              ),
                            ));
                          }
                        },
                        child: FlattenedGoalTree(
                          predicate: (worldContext, goalMap, path, goal) =>
                              getGoalStatus(worldContext, goal)?.status !=
                              GoalStatus.archived,
                          showAddGoal: true,
                          rootGoalPaths: [
                            GoalPath(const ['g1']),
                            GoalPath(const ['g2']),
                            GoalPath(const ['g3']),
                          ],
                          hoverActionsBuilder: (_) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1. Hover first row (g1)
    hoverEventStream.add(GoalPath(const ['g1']));
    await tester.pumpAndSettle();
    await capture(tester, 'before_archive_first_row_hovered.png');

    // 2. Press Backspace to archive first row
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    await capture(tester, 'after_archive_first_row_removed.png');
  });
}
