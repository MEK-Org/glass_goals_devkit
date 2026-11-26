// glass_goals#410: a goal row's name offers the app's goal hover through
// GoalWidgetsContext.goalNameHoverBuilder, as breadcrumbs do through
// breadcrumbHoverBuilder (#404). The hover wraps the name only, can open the
// row's goal as tapping the row does, and leaves clicking the name to edit
// its title alone. Without a builder a row renders as before.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath;
import 'package:goals_core/sync.dart'
    show GoalDelta, MemoryLocalStore, MemoryPersistenceService, SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        BreadcrumbHoverBuilder,
        BreadcrumbHoverRequest,
        GoalActionsContext,
        GoalWidgetsContext,
        hasMouseProvider,
        hoverEventStream,
        selectedGoalsProvider,
        textFocusProvider;
import 'package:goals_widgets/src/goal_item.dart';

void main() {
  late SyncClient client;

  setUp(() async {
    textFocusProvider.add(null);
    hasMouseProvider.add(true);
    selectedGoalsProvider.add([]);
    hoverEventStream.add(null);
    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();
    for (final (id, text) in [
      ('g0', 'Parent Goal'),
      ('g1', 'Row Goal'),
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
    GoalPath path, {
    GoalPath? renderedPath,
    BreadcrumbHoverBuilder? nameHoverBuilder,
    BreadcrumbHoverBuilder? breadcrumbHoverBuilder,
    void Function(GoalPath)? onFocused,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: GoalWidgetsContext(
            syncClient: client,
            goalNameHoverBuilder: nameHoverBuilder,
            breadcrumbHoverBuilder: breadcrumbHoverBuilder,
            child: GoalActionsContext.empty(
              child: Builder(
                builder: (context) => GoalActionsContext.overrideWith(
                  context,
                  onFocused: onFocused == null
                      ? null
                      : (path, {bool? inPlace}) => onFocused(path),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 700,
                      child: GoalItemWidget(
                        path: path,
                        renderedPath: renderedPath,
                        hasRenderableChildren: false,
                        hoverActionsBuilder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Records each row's latest request and marks its wrapped name.
  BreadcrumbHoverBuilder recordingBuilder(
          Map<GoalPath, BreadcrumbHoverRequest> requests) =>
      (context, request) {
        requests[request.path] = request;
        return KeyedSubtree(
          key: ValueKey(('name-hover', request.path)),
          child: request.child,
        );
      };

  const rowPath = GoalPath(['ctx', 'g1']);

  testWidgets(
      'a row hands its path and name to the name hover builder, and the hover '
      'opens the row\'s goal as tapping the row does', (tester) async {
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    final focused = <GoalPath>[];
    await tester.pumpWidget(host(rowPath,
        nameHoverBuilder: recordingBuilder(requests), onFocused: focused.add));
    await tester.pumpAndSettle();

    expect(requests.keys, [rowPath]);
    final wrapped = find.byKey(const ValueKey(('name-hover', rowPath)));
    expect(
      find.descendant(of: wrapped, matching: find.text('Row Goal')),
      findsOneWidget,
    );
    // The name alone: the hover is as wide as the title, not the row.
    expect(tester.getSize(wrapped).width,
        tester.getSize(find.text('Row Goal')).width);

    requests[rowPath]!.onOpenGoal();
    expect(focused, [rowPath]);
    // A crumb's open has a popover to close; a row has none to report to.
    expect(requests[rowPath]!.onShowingChanged, isNull);
  });

  testWidgets(
      'clicking the wrapped name still edits the title, and the editing field '
      'is not wrapped', (tester) async {
    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    await tester.pumpWidget(
        host(rowPath, nameHoverBuilder: recordingBuilder(requests)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Row Goal'));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey(('name-hover', rowPath))), findsNothing);
  });

  testWidgets(
      'without a name hover builder a row renders as before, with its name at '
      'the same place and size it has inside a hover', (tester) async {
    await tester.pumpWidget(host(rowPath));
    await tester.pumpAndSettle();
    final plainRect = tester.getRect(find.text('Row Goal'));

    final requests = <GoalPath, BreadcrumbHoverRequest>{};
    await tester.pumpWidget(
        host(rowPath, nameHoverBuilder: recordingBuilder(requests)));
    await tester.pumpAndSettle();
    expect(requests, isNotEmpty);
    expect(tester.getRect(find.text('Row Goal')), plainRect);
  });

  testWidgets(
      'a row drawn as a path of crumbs leaves its names to the breadcrumb '
      'hover', (tester) async {
    final names = <GoalPath, BreadcrumbHoverRequest>{};
    final crumbs = <GoalPath, BreadcrumbHoverRequest>{};
    await tester.pumpWidget(host(
      const GoalPath(['ctx', 'g0', 'g1']),
      renderedPath: const GoalPath(['g0', 'g1']),
      nameHoverBuilder: recordingBuilder(names),
      breadcrumbHoverBuilder: (context, request) {
        crumbs[request.path] = request;
        return request.child;
      },
    ));
    await tester.pumpAndSettle();

    expect(names, isEmpty);
    expect(crumbs, isNotEmpty);
  });
}
