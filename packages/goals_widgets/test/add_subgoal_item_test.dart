import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart' show GoalPath;
import 'package:goals_ui_core/core.dart'
    show GoalActionsContext, hasMouseProvider, textFocusProvider;
import 'package:goals_widgets/src/add_subgoal_item.dart';

class _TestHost extends StatefulWidget {
  final GoalPath path;
  const _TestHost({required this.path});

  @override
  State<_TestHost> createState() => _TestHostState();
}

class _TestHostState extends State<_TestHost> {
  int rebuildCount = 0;

  void triggerRebuild() {
    setState(() {
      rebuildCount++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: GoalActionsContext.empty(
          child: AddSubgoalItemWidget(
            path: widget.path,
          ),
        ),
      ),
    );
  }
}

/// Simulates entering a character into the currently focused text input.
/// The typed character replaces the current selection range, mirroring
/// platform IME / keyboard behavior.
void _typeCharacter(WidgetTester tester, String char) {
  final state = tester.state<EditableTextState>(find.byType(EditableText));
  final currentVal = state.textEditingValue;
  final start = currentVal.selection.start;
  final end = currentVal.selection.end;
  final newText = currentVal.text.replaceRange(start, end, char);
  final newOffset = start + char.length;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    ),
  );
}

void main() {
  setUp(() {
    textFocusProvider.add(null);
    hasMouseProvider.add(true);
  });

  tearDown(() {
    textFocusProvider.add(null);
  });

  group('AddSubgoalItemWidget', () {
    testWidgets(
        'first activation requests focus and sets initial selection via post-frame callback',
        (tester) async {
      final path = GoalPath(const ['root', 'childIndex:0']);

      await tester.pumpWidget(_TestHost(path: path));
      await tester.pump();

      // Initially inactive: not editing and no TextField.
      expect(find.byType(TextField), findsNothing);

      // Activate the widget by setting textFocusProvider.
      textFocusProvider.add(path);
      await tester.pump();
      await tester.pump();

      // Verify TextField is mounted and focused.
      final editableFinder = find.byType(EditableText);
      expect(editableFinder, findsOneWidget);

      final editableState = tester.state<EditableTextState>(editableFinder);
      expect(editableState.textEditingValue.text, '');
      expect(
        editableState.textEditingValue.selection,
        const TextSelection.collapsed(offset: 0),
      );
      expect(
        FocusScope.of(tester.element(editableFinder)).focusedChild,
        isNotNull,
      );
    });

    testWidgets(
        'same-logical-path rebuild preserves collapsed selection offset',
        (tester) async {
      final path = GoalPath(const ['root', 'childIndex:0']);

      await tester.pumpWidget(_TestHost(path: path));
      await tester.pump();

      // 1. Activate AddSubgoalItemWidget.
      textFocusProvider.add(path);
      await tester.pump();
      await tester.pump();

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      final editableFinder = find.byType(EditableText);
      expect(editableFinder, findsOneWidget);

      // 2. Enter a multi-character draft and leave the caret collapsed at its end.
      await tester.enterText(textFieldFinder, 'my draft');
      await tester.pump();

      final editableState = tester.state<EditableTextState>(editableFinder);
      expect(editableState.textEditingValue.text, 'my draft');
      expect(
        editableState.textEditingValue.selection,
        const TextSelection.collapsed(offset: 8),
      );

      // 3. Rebuild parent with the same logical add-goal path (modeling watched-state emission).
      tester.state<_TestHostState>(find.byType(_TestHost)).triggerRebuild();
      await tester.pump();
      await tester.pump(); // allow post-frame callbacks to run

      // 4. Assert the draft is unchanged and selection is still collapsed at the same offset.
      expect(
        editableState.textEditingValue.text,
        'my draft',
        reason: 'Draft text must be preserved across same-path rebuilds',
      );
      expect(
        editableState.textEditingValue.selection,
        const TextSelection.collapsed(offset: 8),
        reason:
            'Selection must remain collapsed at offset 8 instead of selecting [0, 8]',
      );
    });

    testWidgets(
        'typing next character after same-logical-path rebuild appends to draft instead of replacing it',
        (tester) async {
      final path = GoalPath(const ['root', 'childIndex:0']);

      await tester.pumpWidget(_TestHost(path: path));
      await tester.pump();

      // 1. Activate AddSubgoalItemWidget.
      textFocusProvider.add(path);
      await tester.pump();
      await tester.pump();

      final textFieldFinder = find.byType(TextField);
      await tester.enterText(textFieldFinder, 'my draft');
      await tester.pump();

      // 2. Rebuild parent with same logical path.
      tester.state<_TestHostState>(find.byType(_TestHost)).triggerRebuild();
      await tester.pump();
      await tester.pump();

      // 3. Type next character and assert it appends instead of overwriting.
      _typeCharacter(tester, '!');
      await tester.pump();

      final editableFinder = find.byType(EditableText);
      final editableState = tester.state<EditableTextState>(editableFinder);
      expect(
        editableState.textEditingValue.text,
        'my draft!',
        reason:
            'Next character must append to draft instead of replacing full selection',
      );
      expect(
        editableState.textEditingValue.selection,
        const TextSelection.collapsed(offset: 9),
      );
    });

    testWidgets(
        'active add-goal field re-requests focus after tab/window focus round trip while preserving draft and selection',
        (tester) async {
      final path = GoalPath(const ['root', 'childIndex:0']);

      await tester.pumpWidget(_TestHost(path: path));
      await tester.pump();

      // 1. Activate AddSubgoalItemWidget.
      textFocusProvider.add(path);
      await tester.pump();
      await tester.pump();

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      final editableFinder = find.byType(EditableText);
      final editableState = tester.state<EditableTextState>(editableFinder);

      // 2. Type draft text and set a specific selection range.
      await tester.enterText(textFieldFinder, 'my new goal draft');
      await tester.pump();
      editableState.updateEditingValue(const TextEditingValue(
        text: 'my new goal draft',
        selection: TextSelection(baseOffset: 3, extentOffset: 11),
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
            'Active add-goal field must re-request focus after tab/window focus round trip',
      );
      expect(
        editableState.textEditingValue.text,
        'my new goal draft',
        reason: 'Draft text must be preserved across focus round trip',
      );
      expect(
        editableState.textEditingValue.selection,
        const TextSelection(baseOffset: 3, extentOffset: 11),
        reason: 'Selection must be preserved across focus round trip',
      );
    });

    testWidgets(
        'inactive add-goal field does not steal focus after window focus loss',
        (tester) async {
      final path = GoalPath(const ['root', 'childIndex:0']);

      await tester.pumpWidget(_TestHost(path: path));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);

      // Simulate window blur / unfocus
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(Duration.zero);
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
    });
  });
}
