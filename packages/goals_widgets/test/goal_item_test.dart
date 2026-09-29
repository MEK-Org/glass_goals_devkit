import 'dart:ui' show Size;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath;
import 'package:goals_core/sync.dart'
    show GoalDelta, MemoryLocalStore, MemoryPersistenceService, SyncClient;
import 'package:goals_ui_core/core.dart'
    show
        GoalActionsContext,
        GoalWidgetsContext,
        GoalsTheme,
        hasMouseProvider,
        selectedGoalsProvider,
        textFocusProvider;
import 'package:goals_widgets/src/goal_item.dart';

void main() {
  late SyncClient client;

  ThemeData selectionTheme() {
    return ThemeData(
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontWeight: FontWeight.normal),
      ),
      extensions: [
        GoalsTheme(
          uiUnit: 4,
          primaryColor: Colors.black,
          focusedFontStyle: const TextStyle(fontWeight: FontWeight.bold),
          activeGoalBg: Colors.white,
          activeGoalFg: Colors.black,
          doneGoalBg: Colors.white,
          doneGoalFg: Colors.black,
          archivedGoalBg: Colors.white,
          archivedGoalFg: Colors.black,
          pendingGoalBg: Colors.white,
          pendingGoalFg: Colors.black,
          toDoGoalBg: Colors.white,
          toDoGoalFg: Colors.black,
        ),
      ],
    );
  }

  setUp(() async {
    textFocusProvider.add(null);
    hasMouseProvider.add(true);
    selectedGoalsProvider.add([]);
    client = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: MemoryPersistenceService(),
    );
    await client.init();
    await client.modifyGoal(GoalDelta(id: 'g1', text: 'Original Goal Text'));
  });

  tearDown(() {
    textFocusProvider.add(null);
    client.dispose();
  });

  Widget createTestWidget({required GoalPath path}) {
    return MaterialApp(
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: GoalItemWidget(
              path: path,
              hasRenderableChildren: false,
              hoverActionsBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  group('GoalItemWidget edit focus restoration', () {
    testWidgets(
        'active edit-goal field re-requests focus after tab/window focus round trip while preserving draft and selection',
        (tester) async {
      final path = GoalPath(const ['g1']);

      await tester.pumpWidget(createTestWidget(path: path));
      await tester.pump();

      // 1. Enter edit mode by tapping the goal text.
      await tester.tap(find.text('Original Goal Text'));
      await tester.pump();
      await tester.pump(Duration.zero);
      await tester.pump();

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      final editableFinder = find.byType(EditableText);
      final editableState = tester.state<EditableTextState>(editableFinder);
      expect(editableState.widget.focusNode.hasFocus, isTrue);

      // 2. Enter draft text and set a specific selection range.
      await tester.enterText(textFieldFinder, 'Edited Goal Draft Text');
      await tester.pump();
      editableState.updateEditingValue(const TextEditingValue(
        text: 'Edited Goal Draft Text',
        selection: TextSelection(baseOffset: 7, extentOffset: 17),
      ));
      await tester.pump();

      expect(editableState.widget.focusNode.hasFocus, isTrue);

      // 3. Simulate browser tab/window losing focus (unfocus active node while logical text focus is still on this path).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      // In the reference AddNoteCard, _focusListener schedules focus re-request when focus is lost.
      // Resume / allow microtasks / scheduled frames to process.
      await tester.pump(Duration.zero);
      await tester.pump();

      // 4. Assert focus is restored and draft/selection are preserved.
      expect(
        editableState.widget.focusNode.hasFocus,
        isTrue,
        reason:
            'Active edit-goal field must re-request focus after tab/window focus round trip',
      );
      expect(
        editableState.textEditingValue.text,
        'Edited Goal Draft Text',
        reason: 'Draft text must be preserved across focus round trip',
      );
      expect(
        editableState.textEditingValue.selection,
        const TextSelection(baseOffset: 7, extentOffset: 17),
        reason: 'Selection must be preserved across focus round trip',
      );
    });

    testWidgets(
        'inactive goal item does not steal focus after window focus loss',
        (tester) async {
      final path = GoalPath(const ['g1']);

      await tester.pumpWidget(createTestWidget(path: path));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);

      // Simulate window blur / unfocus
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(Duration.zero);
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
    });
  });

  testWidgets(
      'selection becomes bold and deselection restores the normal weight',
      (tester) async {
    final path = GoalPath(const ['g1']);

    Future<void> pumpSelectionUpdate() async {
      // BehaviorSubject first replays its current value, then delivers the
      // newly-published selection on the next turn.
      await tester.pump();
      await tester.pump();
    }

    // This is the same value the viewer publishes when the user selects this
    // row. Set it before mounting so the widget's initial provider snapshot
    // represents the selected state.
    selectedGoalsProvider.add([path]);

    // The production theme supplies a regular bodyLarge style. Exercise that
    // order explicitly: the selected style must override its normal weight.
    await tester.pumpWidget(MaterialApp(
      theme: selectionTheme(),
      home: Scaffold(
        body: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: GoalItemWidget(
              path: path,
              hasRenderableChildren: false,
              hoverActionsBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ));
    await pumpSelectionUpdate();

    Text goalText() => tester.widget<Text>(find.text('Original Goal Text'));

    expect(
      goalText().style!.fontWeight,
      FontWeight.bold,
      reason: 'The selected goal must be visibly bold.',
    );

    selectedGoalsProvider.add([]);
    await pumpSelectionUpdate();

    expect(
      goalText().style!.fontWeight,
      FontWeight.normal,
      reason: 'Clearing selection must restore the ordinary goal appearance.',
    );

    selectedGoalsProvider.add([path]);
    await pumpSelectionUpdate();

    expect(
      goalText().style!.fontWeight,
      FontWeight.bold,
      reason: 'Selecting again must restore the visible selection state.',
    );
  });

  testWidgets('selected goal visual state', (tester) async {
    tester.view.physicalSize = const Size(640, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = GoalPath(const ['g1']);
    selectedGoalsProvider.add([path]);

    await tester.pumpWidget(MaterialApp(
      theme: selectionTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: GoalWidgetsContext(
            syncClient: client,
            child: GoalActionsContext.empty(
              child: GoalItemWidget(
                key: const ValueKey('selected-goal'),
                path: path,
                hasRenderableChildren: false,
                hoverActionsBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('selected-goal')),
      matchesGoldenFile('goldens/selected_goal_after.png'),
    );
  });
}
