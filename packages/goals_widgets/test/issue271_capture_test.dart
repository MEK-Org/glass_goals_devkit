import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart' show loadAppFonts;
import 'package:goals_core/model.dart' show GoalPath, WorldContext;
import 'package:goals_core/sync.dart'
    show
        AddParentLogEntry,
        GoalDelta,
        MemoryLocalStore,
        MemoryPersistenceService,
        SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        DragEventType,
        GoalActionsContext,
        GoalWidgetsContext,
        dragEventProvider,
        expandedGoalsProvider,
        hasMouseProvider,
        hoverEventStream,
        selectedGoalsProvider,
        textFocusProvider,
        worldContextProvider;
import 'package:goals_widgets/goals_widgets.dart'
    show
        CrumbAbbreviationStrategy,
        CurrentStatusChip,
        FlattenedGoalTree,
        PathBreadcrumb,
        PathOmissionStrategy;

void main() {
  late SyncClient client;
  final beforeKey = GlobalKey();
  final afterKey = GlobalKey();

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([const GoalPath(['folder'])]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    worldContextProvider.add(WorldContext(time: DateTime(2026, 11, 3)));

    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();

    for (final (id, text) in [
      ('folder', 'Constitutional Law Outline'),
      ('root', 'Constitutional Law'),
      ('part', 'Commerce Clause'),
      ('sub', 'Market Participant'),
      ('leaf', 'South-Central Timber Development v. Wunnicke'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }

    final time = DateTime(2026, 11, 3);
    await client.modifyGoal(GoalDelta(
      id: 'leaf',
      logEntry: AddParentLogEntry(
        id: 'leaf-folder',
        parentId: 'folder',
        creationTime: time,
        displayedChildPath: ['root', 'part', 'sub', 'leaf'],
      ),
    ));
  });

  tearDown(() {
    client.dispose();
  });

  Future<void> capture(GlobalKey key, String filename) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../../docs/images/issue271/$filename');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(byteData!.buffer.asUint8List());
  }

  Widget buildBeforeTreeBox(double width) {
    final leafGoal = client.stateSubject.value['leaf']!;
    final folderGoal = client.stateSubject.value['folder']!;
    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 7),
                const SizedBox(width: 8),
                const Text(
                  'Constitutional Law Outline',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
                CurrentStatusChip(
                  goal: folderGoal,
                  path: const GoalPath(['folder']),
                  padding: const EdgeInsets.only(left: 8),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 4, bottom: 4, right: 4),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 7),
                const SizedBox(width: 8),
                Flexible(
                  child: PathBreadcrumb(
                    renderedPath:
                        const GoalPath(['root', 'part', 'sub', 'leaf']),
                    contextPath: const GoalPath(['folder', 'leaf']),
                    maxWidth: 560.0,
                    omissionStrategy: PathOmissionStrategy.start,
                    abbreviationStrategy: CrumbAbbreviationStrategy.show_last,
                  ),
                ),
                CurrentStatusChip(
                  goal: leafGoal,
                  path: const GoalPath(['folder', 'leaf']),
                  padding: const EdgeInsets.only(left: 8),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  testWidgets('capture before and after issue 271 breadcrumb layouts',
      (tester) async {
    await loadAppFonts();
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appTheme = ThemeData(fontFamily: 'Roboto');

    // 1. Capture BEFORE layout (hard 560px cap and start omission)
    await tester.pumpWidget(MaterialApp(
      theme: appTheme,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: RepaintBoundary(
            key: beforeKey,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: GoalWidgetsContext(
                syncClient: client,
                child: GoalActionsContext.empty(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'BEFORE: Displayed path in FlattenedGoalTree (Wide 1000px row — capped at 560px with start omission)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      buildBeforeTreeBox(1000),
                      const SizedBox(height: 24),
                      const Text(
                        'BEFORE: Displayed path in FlattenedGoalTree (Constrained 520px row — start omission hides root)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      buildBeforeTreeBox(520),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await capture(beforeKey, 'before.png');
    });

    // 2. Capture AFTER layout (production FlattenedGoalTree with uncapped full width and middle omission)
    await tester.pumpWidget(MaterialApp(
      theme: appTheme,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: RepaintBoundary(
            key: afterKey,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: GoalWidgetsContext(
                syncClient: client,
                child: GoalActionsContext.empty(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'AFTER: Displayed path in FlattenedGoalTree (Wide 1000px row — expands across full available width)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 1000,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: FlattenedGoalTree(
                          rootGoalPaths: [const GoalPath(['folder'])],
                          showAddGoal: false,
                          hoverActionsBuilder: (_) => const SizedBox.shrink(),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'AFTER: Displayed path in FlattenedGoalTree (Constrained 520px row — middle omission preserves root and leaf)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 520,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: FlattenedGoalTree(
                          rootGoalPaths: [const GoalPath(['folder'])],
                          showAddGoal: false,
                          hoverActionsBuilder: (_) => const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await capture(afterKey, 'after.png');
    });
  });
}
