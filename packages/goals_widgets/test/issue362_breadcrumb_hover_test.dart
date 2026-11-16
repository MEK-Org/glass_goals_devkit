import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath, WorldContext;
import 'package:goals_core/sync.dart'
    show
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
        GoalItemWidget,
        PathBreadcrumb,
        PathOmissionStrategy;

void main() {
  late SyncClient client;

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    worldContextProvider.add(WorldContext(time: DateTime(2026, 11, 16)));

    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();

    for (final (id, text) in [
      ('g0', 'Root'),
      ('g1', 'Part One'),
      ('g2', 'Part Two'),
      ('g3', 'Leaf Goal'),
      ('mid', 'Mid'),
      ('hidden', 'Hidden Section'),
      ('long_suffix', 'Very Long Suffix'),
      ('long_ancestor', 'Very Long Ancestor Title'),
      ('short_leaf', 'Leaf'),
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }
  });

  tearDown(() {
    hoverEventStream.add(null);
    textFocusProvider.add(null);
    client.dispose();
  });

  Widget wrapWithContext(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> hoverFinder(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'PathBreadcrumb middle omission shows collapsed sections in hover tooltip on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 280,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Root'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf Goal'), findsOneWidget);
    expect(find.text('Part One'), findsNothing);
    expect(find.text('Part Two'), findsNothing);
    expect(find.text('Part One > Part Two'), findsNothing);

    await hoverFinder(tester, find.text('…'));

    expect(
      find.ancestor(of: find.text('…'), matching: find.byType(Tooltip)),
      findsOneWidget,
    );
    expect(find.text('Part One > Part Two'), findsOneWidget);
  });

  testWidgets(
      'PathBreadcrumb start omission shows omitted leading sections in hover tooltip on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 280,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
          omissionStrategy: PathOmissionStrategy.start,
          maxWidth: 280,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf Goal'), findsOneWidget);
    expect(find.text('Root'), findsNothing);
    expect(find.text('Root > Part One > Part Two'), findsNothing);

    await hoverFinder(tester, find.text('…'));

    expect(find.text('Root > Part One > Part Two'), findsOneWidget);
  });

  testWidgets(
      'PathBreadcrumb 2-crumb narrow fallback shows omitted first crumb in hover tooltip on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 160,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['long_ancestor', 'short_leaf']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf'), findsOneWidget);
    expect(find.text('Very Long Ancestor Title'), findsNothing);

    await hoverFinder(tester, find.text('…'));

    expect(find.text('Very Long Ancestor Title'), findsOneWidget);
  });

  testWidgets(
      'PathBreadcrumb >2-crumb ultra-narrow fallback shows all leading omitted crumbs in hover tooltip on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 160,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['long_ancestor', 'mid', 'short_leaf']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf'), findsOneWidget);
    expect(find.text('Very Long Ancestor Title > Mid'), findsNothing);

    await hoverFinder(tester, find.text('…'));

    expect(find.text('Very Long Ancestor Title > Mid'), findsOneWidget);
  });

  testWidgets(
      'PathBreadcrumb tooltip shows full goal names even when abbreviationStrategy abbreviates crumbs',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await client.modifyGoal(GoalDelta(
      id: 'abbr_mid',
      text: 'Section 4 - Commerce Power Details',
    ));

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 240,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['g0', 'abbr_mid', 'g3']),
          omissionStrategy: PathOmissionStrategy.middle,
          abbreviationStrategy: CrumbAbbreviationStrategy.show_last,
          maxWidth: null,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Section 4 - Commerce Power Details'), findsNothing);

    await hoverFinder(tester, find.text('…'));

    expect(find.text('Section 4 - Commerce Power Details'), findsOneWidget);
  });

  testWidgets(
      'GoalItemWidget hover toolbar does not reflow PathBreadcrumb or shift … position, and tooltip + toolbar clicks work',
      (tester) async {
    tester.view.physicalSize = const Size(900, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var toolbarButtonTaps = 0;

    await tester.pumpWidget(wrapWithContext(
      SizedBox(
        width: 450,
        child: GoalItemWidget(
          path: const GoalPath(['short_leaf']),
          renderedPath: const GoalPath(
            ['g0', 'mid', 'hidden', 'long_suffix', 'short_leaf'],
          ),
          hasRenderableChildren: false,
          showExpansionArrow: false,
          hoverActionsBuilder: (_) => SizedBox(
            key: const ValueKey('wide-hover-toolbar'),
            width: 120,
            height: 28,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => toolbarButtonTaps++,
              child: const Text('Act'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Root'), findsOneWidget);
    expect(find.text('Mid'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf'), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-hover-toolbar')), findsNothing);

    final breadcrumbSizeBefore = tester.getSize(find.byType(PathBreadcrumb));
    final ellipsisPosBefore = tester.getTopLeft(find.text('…'));

    // Hover over the … marker inside GoalItemWidget.
    await hoverFinder(tester, find.text('…'));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('wide-hover-toolbar')), findsOneWidget);
    expect(find.text('Mid'), findsOneWidget);
    expect(
      tester.getSize(find.byType(PathBreadcrumb)),
      equals(breadcrumbSizeBefore),
      reason: 'Hovering GoalItemWidget must not shrink PathBreadcrumb.',
    );
    expect(
      tester.getTopLeft(find.text('…')),
      equals(ellipsisPosBefore),
      reason: 'Hovering GoalItemWidget must not shift the … marker.',
    );
    expect(find.text('Hidden Section > Very Long Suffix'), findsOneWidget);

    // Tapping the overlaid hover toolbar button must still succeed.
    await tester.tap(find.text('Act'));
    await tester.pump();
    expect(toolbarButtonTaps, 1);
  });
}
