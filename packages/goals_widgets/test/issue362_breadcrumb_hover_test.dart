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
        Breadcrumb,
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

  Widget wrapWithContext(
    Widget child, {
    void Function(GoalPath)? onFocused,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: Builder(
              builder: (context) => GoalActionsContext.overrideWith(
                context,
                onFocused: onFocused == null
                    ? null
                    : (path, {bool? inPlace}) => onFocused(path),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> createMouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  Future<TestGesture> hoverFinder(WidgetTester tester, Finder finder) async {
    final gesture = await createMouse(tester);
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets(
      'PathBreadcrumb middle omission shows clickable vertical popover on … and navigates on tap',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 280,
        child: PathBreadcrumb(
          contextPath: GoalPath(['ctx']),
          renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Root'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf Goal'), findsOneWidget);
    expect(find.text('Part One'), findsNothing);
    expect(find.text('Part Two'), findsNothing);

    final gesture = await hoverFinder(tester, find.text('…'));

    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('Part One'), findsOneWidget);
    expect(find.text('Part Two'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('Part One'), matching: find.byType(Breadcrumb)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('Part Two'), matching: find.byType(Breadcrumb)),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Part Two')).dy,
      greaterThan(tester.getTopLeft(find.text('Part One')).dy),
    );

    // Moving the mouse from … into the popover keeps it open past the grace timer.
    await gesture.moveTo(tester.getCenter(find.text('Part Two')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Part One'), findsOneWidget);
    expect(find.text('Part Two'), findsOneWidget);

    await tester.tap(find.text('Part Two'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['ctx', 'g0', 'g1', 'g2'])]);
    expect(find.text('Part One'), findsNothing);
    expect(find.text('Part Two'), findsNothing);
  });

  testWidgets(
      'PathBreadcrumb start omission shows clickable omitted leading crumbs vertically and closes on pointer exit',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 280,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
          omissionStrategy: PathOmissionStrategy.start,
          maxWidth: 280,
        ),
      ),
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf Goal'), findsOneWidget);
    expect(find.text('Root'), findsNothing);

    final gesture = await hoverFinder(tester, find.text('…'));

    expect(find.text('Root'), findsOneWidget);
    expect(find.text('Part One'), findsOneWidget);
    expect(find.text('Part Two'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Part One')).dy,
      greaterThan(tester.getTopLeft(find.text('Root')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Part Two')).dy,
      greaterThan(tester.getTopLeft(find.text('Part One')).dy),
    );

    // Leaving both … and the popover closes it after the grace timer.
    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Root'), findsNothing);
    expect(find.text('Part One'), findsNothing);

    // Re-hover … and click Root inside the popover.
    await gesture.moveTo(tester.getCenter(find.text('…')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.text('Root')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Root'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['g0'])]);
  });

  testWidgets(
      'PathBreadcrumb 2-crumb narrow fallback shows clickable omitted first crumb on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 160,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['long_ancestor', 'short_leaf']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf'), findsOneWidget);
    expect(find.text('Very Long Ancestor Title'), findsNothing);

    final gesture = await hoverFinder(tester, find.text('…'));

    expect(find.text('Very Long Ancestor Title'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.text('Very Long Ancestor Title')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Very Long Ancestor Title'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['long_ancestor'])]);
  });

  testWidgets(
      'PathBreadcrumb >2-crumb ultra-narrow fallback shows clickable leading omitted crumbs vertically on …',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    await tester.pumpWidget(wrapWithContext(
      const SizedBox(
        width: 160,
        child: PathBreadcrumb(
          renderedPath: GoalPath(['long_ancestor', 'mid', 'short_leaf']),
          omissionStrategy: PathOmissionStrategy.middle,
          maxWidth: null,
        ),
      ),
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Leaf'), findsOneWidget);
    expect(find.text('Very Long Ancestor Title'), findsNothing);
    expect(find.text('Mid'), findsNothing);

    final gesture = await hoverFinder(tester, find.text('…'));

    expect(find.text('Very Long Ancestor Title'), findsOneWidget);
    expect(find.text('Mid'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Mid')).dy,
      greaterThan(tester.getTopLeft(find.text('Very Long Ancestor Title')).dy),
    );

    await gesture.moveTo(tester.getCenter(find.text('Mid')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Mid'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['long_ancestor', 'mid'])]);
  });

  testWidgets(
      'PathBreadcrumb popover shows full goal names and allows navigation even when abbreviationStrategy abbreviates crumbs',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await client.modifyGoal(GoalDelta(
      id: 'abbr_mid',
      text: 'Section 4 - Commerce Power Details',
    ));

    final focused = <GoalPath>[];

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
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('…'), findsOneWidget);
    expect(find.text('Section 4 - Commerce Power Details'), findsNothing);

    final gesture = await hoverFinder(tester, find.text('…'));

    expect(find.text('Section 4 - Commerce Power Details'), findsOneWidget);
    await gesture.moveTo(
      tester.getCenter(find.text('Section 4 - Commerce Power Details')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Section 4 - Commerce Power Details'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['g0', 'abbr_mid'])]);
  });

  testWidgets(
      'PathBreadcrumb popover respects allowTappingCrumbs: false and closes when omittedIndices becomes empty',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final focused = <GoalPath>[];

    Widget buildAtWidth(double width) => wrapWithContext(
          SizedBox(
            width: width,
            child: const PathBreadcrumb(
              renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
              omissionStrategy: PathOmissionStrategy.middle,
              allowTappingCrumbs: false,
              maxWidth: null,
            ),
          ),
          onFocused: focused.add,
        );

    await tester.pumpWidget(buildAtWidth(280));
    await tester.pumpAndSettle();

    final gesture = await hoverFinder(tester, find.text('…'));
    expect(find.text('Part One'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.text('Part One')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Part One'));
    await tester.pumpAndSettle();
    expect(focused, isEmpty);

    // Widen so no crumbs are omitted: popover closes cleanly.
    await tester.pumpWidget(buildAtWidth(600));
    await tester.pumpAndSettle();
    expect(find.text('…'), findsNothing);
    expect(find.text('Part One'), findsOneWidget);
    expect(find.text('Part Two'), findsOneWidget);
  });

  testWidgets(
      'GoalItemWidget hover toolbar does not reflow PathBreadcrumb or shift … position, and popover + toolbar clicks work',
      (tester) async {
    tester.view.physicalSize = const Size(900, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var toolbarButtonTaps = 0;
    final focused = <GoalPath>[];

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
      onFocused: focused.add,
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
    final gesture = await hoverFinder(tester, find.text('…'));

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
    expect(find.text('Hidden Section'), findsOneWidget);
    expect(find.text('Very Long Suffix'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Very Long Suffix')).dy,
      greaterThan(tester.getTopLeft(find.text('Hidden Section')).dy),
    );

    // Tapping the overlaid hover toolbar button must still succeed.
    await tester.tap(find.text('Act'));
    await tester.pump();
    expect(toolbarButtonTaps, 1);

    // Re-hover … and click an omitted crumb in the popover.
    await gesture.moveTo(tester.getCenter(find.text('…')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.text('Hidden Section')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Hidden Section'));
    await tester.pumpAndSettle();

    expect(focused, [const GoalPath(['short_leaf', 'g0', 'mid', 'hidden'])]);
  });
}
