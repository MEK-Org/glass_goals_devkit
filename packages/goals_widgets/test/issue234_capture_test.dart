import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart' show loadAppFonts;
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:goals_widgets/src/goal_breadcrumb.dart';

void main() {
  testWidgets('capture issue 234 final layout', (tester) async {
    await loadAppFonts();
    tester.view.physicalSize = const Size(900, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();
    for (final (id, text) in [
      ('ancestor', 'Oldest ancestor'),
      ('older', 'Older parent'),
      ('parent', 'Parent before direct'),
      ('direct', 'Direct parent with a deliberately long title'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }

    final path = GoalPath(['ancestor', 'older', 'parent', 'direct']);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Narrow panel (280px)'),
                  SizedBox(
                    width: 280,
                    child: PathBreadcrumb(renderedPath: path, onRemove: () {}),
                  ),
                  const SizedBox(height: 36),
                  const Text('Wide panel (560px)'),
                  SizedBox(
                    width: 560,
                    child: PathBreadcrumb(renderedPath: path, onRemove: () {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/issue234-after.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    client.dispose();
  });
}
