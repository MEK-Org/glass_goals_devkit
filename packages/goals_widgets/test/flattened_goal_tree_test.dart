import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:goals_widgets/goals_widgets.dart' show FlattenedGoalTree;

/// Stands in for `GoalDetail`: a goal's subtree rendered with
/// `path: <the goal>` next to an editor (the goal's document) that can hold
/// keyboard focus. [rebuild] re-renders the tree the way a periodic
/// `worldContextProvider` tick or a `watch.stream` update does.
class _DetailHarness extends StatefulWidget {
  final SyncClient client;
  final FocusNode editorFocusNode;
  const _DetailHarness({
    super.key,
    required this.client,
    required this.editorFocusNode,
  });

  @override
  State<_DetailHarness> createState() => _DetailHarnessState();
}

class _DetailHarnessState extends State<_DetailHarness> {
  int _tick = 0;

  void rebuild() => setState(() => _tick++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: widget.client,
          child: GoalActionsContext.empty(
            child: Column(
              children: [
                Text('tick $_tick'),
                TextField(
                  key: const ValueKey('editor'),
                  focusNode: widget.editorFocusNode,
                ),
                FlattenedGoalTree(
                  path: const GoalPath(['parent']),
                  rootGoalPaths: [
                    const GoalPath(['child'])
                  ],
                  showAddGoal: false,
                  hoverActionsBuilder: (_) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  late SyncClient client;
  late FocusNode editorFocusNode;
  final harnessKey = GlobalKey<_DetailHarnessState>();

  setUp(() async {
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hasMouseProvider.add(true);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    worldContextProvider.add(WorldContext(time: DateTime(2026)));

    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();
    await client.modifyGoals([
      GoalDelta(id: 'parent', text: 'Parent'),
      GoalDelta(
        id: 'child',
        text: 'Child',
        logEntry: AddParentLogEntry(
          id: 'child-edge',
          parentId: 'parent',
          creationTime: DateTime(2026),
        ),
      ),
    ]);
    editorFocusNode = FocusNode(debugLabel: 'editor');
  });

  tearDown(() {
    textFocusProvider.add(null);
    hoverEventStream.add(null);
    dragEventProvider.add(DragEventType.none);
    editorFocusNode.dispose();
    client.dispose();
  });

  Future<void> pumpHarness(WidgetTester tester) async {
    await tester.pumpWidget(_DetailHarness(
      key: harnessKey,
      client: client,
      editorFocusNode: editorFocusNode,
    ));
    await tester.pumpAndSettle();
  }

  // The goal was hovered in a list before it was opened, so the hover value
  // still matches the detail tree's `path`.
  void hoverOpenedGoal() => hoverEventStream.add(const GoalPath(['parent']));

  testWidgets(
      'rebuilding while an editor owns textFocusProvider does not steal '
      'focus from the editor', (tester) async {
    await pumpHarness(tester);

    hoverOpenedGoal();
    textFocusProvider.add(const GoalPath(['parent']));
    editorFocusNode.requestFocus();
    await tester.pump();
    expect(editorFocusNode.hasFocus, isTrue);

    harnessKey.currentState!.rebuild();
    await tester.pump();

    expect(editorFocusNode.hasFocus, isTrue,
        reason: 'FlattenedGoalTree.didUpdateWidget must not pull focus off '
            'the editor that owns textFocusProvider');
  });

  testWidgets('rebuilding during a drag does not steal focus', (tester) async {
    await pumpHarness(tester);

    hoverOpenedGoal();
    dragEventProvider.add(DragEventType.start);
    editorFocusNode.requestFocus();
    await tester.pump();
    expect(editorFocusNode.hasFocus, isTrue);

    harnessKey.currentState!.rebuild();
    await tester.pump();

    expect(editorFocusNode.hasFocus, isTrue);
  });

  testWidgets(
      'rebuilding with the opened goal hovered and no text focus still '
      'focuses the tree for keyboard navigation', (tester) async {
    await pumpHarness(tester);

    hoverOpenedGoal();
    editorFocusNode.requestFocus();
    await tester.pump();
    expect(editorFocusNode.hasFocus, isTrue);

    harnessKey.currentState!.rebuild();
    await tester.pump();

    expect(editorFocusNode.hasFocus, isFalse,
        reason: 'existing hover-to-focus behaviour is kept when nothing '
            'owns text focus');
  });
}
