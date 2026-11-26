// #404: every goal breadcrumb, visible or listed under `…`, offers the app's
// hover through GoalWidgetsContext.breadcrumbHoverBuilder. The hover can
// open the crumb's goal as a tap does, and while it shows it holds open the
// `…` list it was opened from. Without a builder a crumb is just its label.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath, WorldContext;
import 'package:goals_core/sync.dart'
    show GoalDelta, MemoryLocalStore, MemoryPersistenceService, SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        BreadcrumbHoverBuilder,
        BreadcrumbHoverRequest,
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
    show Breadcrumb, PathBreadcrumb, PathOmissionStrategy;

void main() {
  late SyncClient client;

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    worldContextProvider.add(WorldContext(time: DateTime(2026, 11, 22)));

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
    ]) {
      await client.modifyGoal(GoalDelta(id: id, text: text));
    }
  });

  tearDown(() {
    hoverEventStream.add(null);
    textFocusProvider.add(null);
    client.dispose();
  });

  Widget host(
    Widget child, {
    BreadcrumbHoverBuilder? hoverBuilder,
    void Function(GoalPath)? onFocused,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            breadcrumbHoverBuilder: hoverBuilder,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onFocused: onFocused == null
                      ? null
                      : (path, {bool? inPlace}) => onFocused(path),
                  child: Align(alignment: Alignment.topLeft, child: child),
                ),
              ),
            ),
          ),
        ),
      );

  /// Records each crumb's latest request and marks its wrapped label.
  BreadcrumbHoverBuilder recordingBuilder(
          Map<GoalPath, BreadcrumbHoverRequest> requests) =>
      (context, request) {
        requests[request.path] = request;
        return KeyedSubtree(
          key: ValueKey(('hover', request.path)),
          child: request.child,
        );
      };

  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(790, 290));
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  void narrowView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // Narrow enough that the middle crumbs fold into `…`.
  const middlePath = SizedBox(
    width: 280,
    child: PathBreadcrumb(
      contextPath: GoalPath(['ctx']),
      renderedPath: GoalPath(['g0', 'g1', 'g2', 'g3']),
      omissionStrategy: PathOmissionStrategy.middle,
      maxWidth: null,
    ),
  );

  testWidgets(
      'a Breadcrumb hands its path and label to the hover builder, and the '
      'hover opens its goal as a tap does', (tester) async {
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    final focused = <GoalPath>[];
    var tapped = 0;
    const path = GoalPath(['ctx', 'g1']);

    await tester.pumpWidget(host(
      Breadcrumb(path: path, onTap: () => tapped++),
      hoverBuilder: recordingBuilder(requests),
      onFocused: focused.add,
    ));
    await tester.pumpAndSettle();

    expect(requests.keys, [path]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(('hover', path))),
        matching: find.text('Part One'),
      ),
      findsOneWidget,
    );

    requests[path]!.onOpenGoal();
    expect(focused, [path]);
    expect(tapped, 1);

    // Tapping the crumb itself still navigates.
    await tester.tap(find.text('Part One'));
    await tester.pump();
    expect(focused, [path, path]);
    expect(tapped, 2);
  });

  testWidgets(
      'without a hover builder a Breadcrumb renders and navigates as before, '
      'at the same size it has inside a hover', (tester) async {
    narrowView(tester);
    final focused = <GoalPath>[];
    await tester.pumpWidget(host(middlePath, onFocused: focused.add));
    await tester.pumpAndSettle();
    final plainSize = tester.getSize(find.byType(PathBreadcrumb));
    final plainDots = tester.getTopLeft(find.text('…'));
    await tester.tap(find.text('Root'));
    await tester.pump();
    expect(focused, [
      const GoalPath(['ctx', 'g0'])
    ]);

    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    await tester.pumpWidget(host(middlePath,
        hoverBuilder: recordingBuilder(requests), onFocused: focused.add));
    await tester.pumpAndSettle();
    expect(requests, isNotEmpty);
    expect(tester.getSize(find.byType(PathBreadcrumb)), plainSize);
    expect(tester.getTopLeft(find.text('…')), plainDots);
  });

  testWidgets(
      'visible crumbs and the crumbs listed under … each offer the hover for '
      'their own goal', (tester) async {
    narrowView(tester);
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    await tester
        .pumpWidget(host(middlePath, hoverBuilder: recordingBuilder(requests)));
    await tester.pumpAndSettle();

    expect(requests.keys.toSet(), {
      const GoalPath(['ctx', 'g0']),
      const GoalPath(['ctx', 'g0', 'g1', 'g2', 'g3']),
    });

    final gesture = await mouse(tester);
    await gesture.moveTo(tester.getCenter(find.text('…')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.text('Part One'), findsOneWidget);
    expect(requests.keys.toSet(), {
      const GoalPath(['ctx', 'g0']),
      const GoalPath(['ctx', 'g0', 'g1']),
      const GoalPath(['ctx', 'g0', 'g1', 'g2']),
      const GoalPath(['ctx', 'g0', 'g1', 'g2', 'g3']),
    });
    // Each omitted crumb reports to the … list it is listed in.
    expect(requests[const GoalPath(['ctx', 'g0', 'g1'])]!.onShowingChanged,
        isNotNull);
    expect(requests[const GoalPath(['ctx', 'g0'])]!.onShowingChanged, isNull);
  });

  testWidgets(
      'an omitted crumb\'s showing hover holds the … list open after the '
      'pointer leaves it, and the list closes once the hover goes',
      (tester) async {
    narrowView(tester);
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    final focused = <GoalPath>[];
    await tester.pumpWidget(host(middlePath,
        hoverBuilder: recordingBuilder(requests), onFocused: focused.add));
    await tester.pumpAndSettle();

    final gesture = await mouse(tester);
    await gesture.moveTo(tester.getCenter(find.text('…')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.text('Part Two')));
    await tester.pump();

    const partTwo = GoalPath(['ctx', 'g0', 'g1', 'g2']);
    const partOne = GoalPath(['ctx', 'g0', 'g1']);
    // The crumb's hover shows; its card is drawn outside the list, so the
    // pointer moving onto it leaves the list.
    requests[partTwo]!.onShowingChanged!(true);
    await gesture.moveTo(const Offset(790, 290));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Part Two'), findsOneWidget,
        reason: 'the … list stays while the crumb\'s hover shows');

    // Moving to another omitted crumb's hover: the new one shows before the
    // old one goes, and the list stays.
    requests[partOne]!.onShowingChanged!(true);
    requests[partTwo]!.onShowingChanged!(false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Part One'), findsOneWidget);

    requests[partOne]!.onShowingChanged!(false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Part One'), findsNothing,
        reason: 'with no hover showing and no pointer, the … list closes');
  });

  testWidgets(
      'opening an omitted crumb\'s goal from its hover navigates and closes '
      'the … list', (tester) async {
    narrowView(tester);
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    final focused = <GoalPath>[];
    await tester.pumpWidget(host(middlePath,
        hoverBuilder: recordingBuilder(requests), onFocused: focused.add));
    await tester.pumpAndSettle();

    final gesture = await mouse(tester);
    await gesture.moveTo(tester.getCenter(find.text('…')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    const partOne = GoalPath(['ctx', 'g0', 'g1']);
    requests[partOne]!.onShowingChanged!(true);
    requests[partOne]!.onOpenGoal();
    requests[partOne]!.onShowingChanged!(false);
    await tester.pumpAndSettle();
    expect(focused, [partOne]);
    expect(find.text('Part One'), findsNothing);
  });
}
