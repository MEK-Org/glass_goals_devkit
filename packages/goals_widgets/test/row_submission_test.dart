import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:goals_widgets/goals_widgets.dart';

class _Remote extends MemoryPersistenceService {
  bool hold = false;
  bool echo = false;
  final calls = <({List<Op> ops, Completer<void> gate})>[];
  Future<void> persist(List<Op> batch) => super.save([
    ...ops.where((old) => !batch.any((op) => op.id == old.id)),
    ...batch,
  ]);
  @override
  Future<void> save(Iterable<Op> values) async {
    final batch = values.toList();
    if (hold) {
      final gate = Completer<void>();
      calls.add((ops: batch, gate: gate));
      if (echo) await persist(batch);
      await gate.future;
    }
    if (!echo) await persist(batch);
  }

  void release() {
    hold = false;
    for (final call in calls) {
      if (!call.gate.isCompleted) call.gate.complete();
    }
  }
}

final _add = find.descendant(
  of: find.byType(AddSubgoalItemWidget),
  matching: find.byType(TextField),
);
final _inline = find.descendant(
  of: find.byType(GoalItemWidget),
  matching: find.byType(TextField),
);
const _outside = ValueKey('outside');

class _Harness {
  _Harness(this.tester, {this.tree = false, this.add = false, int slot = -1})
    : path = ValueNotifier(
        GoalPath(add ? ['root', 'childIndex:$slot'] : ['g1']),
      );
  final WidgetTester tester;
  final bool tree;
  final bool add;
  final ValueNotifier<GoalPath> path;
  final remote = _Remote();
  late final client = SyncClient(
    localStore: MemoryLocalStore(),
    persistenceService: remote,
  );
  final outsideFocus = FocusNode();
  Completer<void>? callbackGate;
  final submitted = <String>[];
  int advanced = 0;
  Future<void> start() async {
    await client.init();
    await client.modifyGoals([
      GoalDelta(id: 'g1', text: 'Old goal'),
      GoalDelta(id: 'g2', text: 'Other goal'),
    ]);
    await client.sync();
    hasMouseProvider.add(true);
    textFocusProvider.add(null);
    selectedGoalsProvider.add([]);
    expandedGoalsProvider.add([]);
    hoverEventStream.add(null);
    worldContextProvider.add(WorldContext(time: DateTime(2026)));
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: GoalWidgetsContext(
          syncClient: client,
          child: GoalActionsContext.empty(
            child: Builder(
              builder: (context) => GoalActionsContext.overrideWith(
                context,
                onAddGoal:
                    (
                      GoalPath? parent,
                      String text, {
                      TimeSlice? slice,
                      GoalPath? pathBefore,
                      GoalPath? pathAfter,
                    }) async {
                      submitted.add(text);
                      final id = 'created-${submitted.length}';
                      await callbackGate?.future;
                      await client.modifyGoal(GoalDelta(id: id, text: text));
                    },
                child: Scaffold(
                  body: Shortcuts(
                    shortcuts: {
                      LogicalKeySet(LogicalKeyboardKey.enter): AcceptIntent(),
                      LogicalKeySet(LogicalKeyboardKey.escape): CancelIntent(),
                    },
                    child: Column(
                      children: [
                        if (tree)
                          Expanded(
                            child: SingleChildScrollView(
                              child: StreamBuilder<Map<String, Goal>>(
                                stream: client.stateSubject,
                                initialData: client.stateSubject.value,
                                builder: (_, snapshot) => FlattenedGoalTree(
                                  path: const GoalPath(['ui:tree']),
                                  rootGoalPaths: snapshot.data!.keys
                                      .where(
                                        (id) => id != 'g2' && id != 'unrelated',
                                      )
                                      .map((id) => GoalPath([id]))
                                      .toList(),
                                  hoverActionsBuilder: (_) => const SizedBox(),
                                ),
                              ),
                            ),
                          )
                        else
                          ValueListenableBuilder<GoalPath>(
                            valueListenable: path,
                            builder: (_, p, __) => add
                                ? AddSubgoalItemWidget(
                                    key: const ValueKey('row'),
                                    path: p,
                                  )
                                : GoalItemWidget(
                                    key: const ValueKey('row'),
                                    path: p,
                                    hasRenderableChildren: false,
                                    hoverActionsBuilder: (_) =>
                                        const SizedBox(),
                                    onEnter: () {
                                      advanced++;
                                    },
                                  ),
                          ),
                        TextButton(key: _outside, focusNode: outsideFocus, onPressed: outsideFocus.requestFocus, child: const Text('Other control')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      if (callbackGate != null && !callbackGate!.isCompleted)
        callbackGate!.complete();
      remote.release();
      await tester.pumpAndSettle();
      textFocusProvider.add(null);
      hoverEventStream.add(null);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 32));
      client.dispose();
      outsideFocus.dispose();
      path.dispose();
      tester.view.reset();
    });
  }

  Future<void> edit({bool adding = false, String text = 'New goal'}) async {
    final field = adding ? _add : _inline;
    if (field.evaluate().isEmpty) {
      await tester.tap(
        adding ? find.text('[Add goal]').last : find.text('Old goal'),
      );
      await tester.pumpAndSettle();
    }
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> submit({bool outside = false}) async {
    if (outside) {
      await tester.tap(find.byKey(_outside), kind: PointerDeviceKind.mouse);
    } else {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }
    await tester.pump();
  }

  Future<void> finish() async {
    remote.release();
    await tester.pumpAndSettle();
  }

  String get inlineText => _inline.evaluate().isNotEmpty
      ? tester.widget<TextField>(_inline).controller!.text
      : tester
            .widget<Text>(
              find
                  .descendant(
                    of: find.byType(GoalItemWidget),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is Text &&
                          [
                            'Old goal',
                            'New goal',
                            'Second goal',
                            'Other goal',
                          ].contains(w.data),
                    ),
                  )
                  .first,
            )
            .data!;
  Future<void> reload(String id, String text) async {
    await client.sync();
    await tester.pump(const Duration(milliseconds: 1));
    await remote.settled;
    final fresh = SyncClient(
      localStore: MemoryLocalStore(),
      persistenceService: remote,
    );
    await fresh.init();
    expect((await fresh.loadGoal(id))!.text, text);
    await tester.pumpAndSettle();
    fresh.dispose();
  }
}

void main() {
  for (final mode in ['immediate', 'held', 'early echo', 'unrelated']) {
    testWidgets('tree add consumes submitted draft: $mode', (tester) async {
      final h = _Harness(tester, tree: true);
      await h.start();
      await h.edit(adding: true);
      h.remote.hold = ['held', 'early echo'].contains(mode);
      h.remote.echo = mode == 'early echo';
      if (mode == 'unrelated')
        await h.client.modifyGoal(
          GoalDelta(id: 'unrelated', text: 'Elsewhere'),
        );
      else
        await h.submit();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (mode == 'unrelated')
          expect(tester.widget<TextField>(_add).controller!.text, 'New goal');
        else if (find
            .text('New goal', findRichText: true)
            .evaluate()
            .isNotEmpty) {
          expect(tester.widget<TextField>(_add).controller!.text, '');
        }
      }
      await h.finish();
      if (mode != 'unrelated') {
        expect(h.submitted, ['New goal']);
        await h.reload('created-1', 'New goal');
      }
    });
  }
  for (final slot in [-1, 0]) {
    testWidgets('add slot $slot hands off only after callback', (tester) async {
      final h = _Harness(tester, add: true, slot: slot);
      await h.start();
      await h.edit(adding: true);
      final original = h.path.value;
      h.remote.hold = true;
      await h.submit();
      expect(textFocusProvider.value, original);
      expect(tester.widget<TextField>(_add).controller!.text, '');
      await h.finish();
      expect(
        textFocusProvider.value,
        GoalPath(['root', 'childIndex:${slot == -1 ? -1 : 1}']),
      );
      await h.reload('created-1', 'New goal');
    });
    testWidgets('add slot $slot preserves newer draft selection', (
      tester,
    ) async {
      final h = _Harness(tester, add: true, slot: slot);
      await h.start();
      await h.edit(adding: true);
      h.remote.hold = true;
      await h.submit();
      await h.edit(adding: true, text: 'Second goal');
      final controller = tester.widget<TextField>(_add).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );
      await h.finish();
      expect(controller.text, 'Second goal');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      expect(textFocusProvider.value, h.path.value);
    });
  }
  testWidgets('add repeated Enter and click-away submit captured draft once', (
    tester,
  ) async {
    final h = _Harness(tester, add: true);
    await h.start();
    await h.edit(adding: true);
    h.remote.hold = true;
    await h.submit();
    await h.submit();
    await h.submit(outside: true);
    expect(h.submitted, ['New goal']);
    await h.finish();
    expect(h.outsideFocus.hasPrimaryFocus, isTrue);
  });
  for (final newestFirst in [false, true]) {
    testWidgets('overlapping add completion newestFirst=$newestFirst', (
      tester,
    ) async {
      final h = _Harness(tester, add: true);
      await h.start();
      await h.edit(adding: true);
      h.remote.hold = true;
      await h.submit();
      await h.edit(adding: true, text: 'Second goal');
      await h.submit();
      expect(h.remote.calls, hasLength(2));
      await h.edit(adding: true, text: 'Third draft');
      h.remote.calls[newestFirst ? 1 : 0].gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_add).controller!.text, 'Third draft');
      await h.finish();
      expect(tester.widget<TextField>(_add).controller!.text, 'Third draft');
      await h.reload('created-1', 'New goal');
      await h.reload('created-2', 'Second goal');
    });
  }
  for (final change in ['focus', 'path', 'cancel', 'dispose']) {
    testWidgets('add completion respects $change', (tester) async {
      final h = _Harness(tester, add: true, slot: 0);
      await h.start();
      await h.edit(adding: true);
      h.remote.hold = true;
      await h.submit();
      if (change == 'focus') {
        textFocusProvider.add(const GoalPath(['elsewhere', 'childIndex:4']));
        h.outsideFocus.requestFocus();
      }
      if (change == 'path') {
        h.path.value = const GoalPath(['other', 'childIndex:0']);
        textFocusProvider.add(h.path.value);
      }
      if (change == 'cancel')
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      if (change == 'dispose') await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final focus = textFocusProvider.value;
      await h.finish();
      expect(textFocusProvider.value, focus);
      expect(tester.takeException(), isNull);
      if (change == 'focus') expect(h.outsideFocus.hasPrimaryFocus, isTrue);
    });
  }
  for (final newer in [false, true]) {
    testWidgets(
      'failed add callback restores only its own draft newer=$newer',
      (tester) async {
        final h = _Harness(tester, add: true);
        await h.start();
        await h.edit(adding: true);
        h.callbackGate = Completer<void>();
        final callback = tester.widget<TextField>(_add).onEditingComplete!;
        final pending = Function.apply(callback, []) as Future<void>;
        final failure = expectLater(pending, throwsStateError);
        if (newer) await h.edit(adding: true, text: 'Second goal');
        h.callbackGate!.completeError(
          StateError('controlled callback failure'),
        );
        await failure;
        await tester.pump();
        expect(
          tester.widget<TextField>(_add).controller!.text,
          newer ? 'Second goal' : 'New goal',
        );
        h.callbackGate = null;
        await h.submit();
        await h.finish();
        await h.reload('created-2', newer ? 'Second goal' : 'New goal');
      },
    );
  }
  for (final outside in [false, true]) {
    for (final mode in ['immediate', 'held', 'early echo', 'failed save']) {
      testWidgets(
        'inline ${outside ? 'click-away' : 'Enter'} await handoff: $mode',
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
        (tester) async {
          final h = _Harness(tester);
          await h.start();
          await h.edit();
          h.remote.hold = mode != 'immediate';
          h.remote.echo = mode == 'early echo';
          await h.submit(outside: outside);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 1));
            expect(h.inlineText, 'New goal');
          }
          if (mode != 'immediate') {
            expect(_inline, findsOneWidget);
            expect(h.advanced, 0);
          }
          if (mode == 'failed save')
            h.remote.calls.single.gate.completeError(
              StateError('controlled transport failure'),
            );
          await h.finish();
          expect(_inline, findsNothing);
          expect(h.inlineText, 'New goal');
          expect(h.advanced, outside ? 0 : 1);
          if (outside) expect(h.outsideFocus.hasPrimaryFocus, isTrue);
          await h.reload('g1', 'New goal');
        },
      );
    }
  }
  for (final outside in [false, true]) {
    testWidgets(
      'unchanged inline ${outside ? 'click-away' : 'Enter'} is a no-op',
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
      (tester) async {
        final h = _Harness(tester);
        await h.start();
        final modification = h.client.modifyGoal(GoalDelta(id: 'g2', text: 'Temporary'));
        await tester.pumpAndSettle();
        await modification;
        final undoing = h.client.undo();
        await tester.pumpAndSettle();
        await undoing;
        await tester.pumpAndSettle();
        final undo = [...h.client.undoStack];
        final redo = [...h.client.redoStack];
        expect(undo, isNotEmpty);
        expect(redo, isNotEmpty);
        await tester.tap(find.text('Old goal'));
        await tester.pumpAndSettle();
        h.remote.hold = true;
        await h.submit(outside: outside);
        await tester.pumpAndSettle();
        expect(h.remote.calls, isEmpty);
        expect(h.client.undoStack, undo);
        expect(h.client.redoStack, redo);
        expect(_inline, findsNothing);
        expect(h.inlineText, 'Old goal');
        expect(textFocusProvider.value, isNull);
        expect(h.advanced, outside ? 0 : 1);
        if (outside) expect(h.outsideFocus.hasPrimaryFocus, isTrue);
        await h.finish();
        final redoing = h.client.redo();
        await tester.pumpAndSettle();
        await redoing;
        expect(h.client.stateSubject.value['g2']!.text, 'Temporary');
      },
    );
  }
  for (final newestFirst in [false, true]) {
    testWidgets('inline revert to live text awaits older edit newestFirst=$newestFirst', (tester) async {
      final h = _Harness(tester);
      await h.start();
      await h.edit();
      h.remote.hold = true;
      await h.submit();
      expect(h.client.stateSubject.value['g1']!.text, 'Old goal');
      await h.edit(text: 'Old goal');
      await h.submit();
      expect(h.remote.calls, hasLength(2));
      expect(_inline, findsOneWidget);
      expect(h.inlineText, 'Old goal');
      expect(h.advanced, 0);
      h.remote.calls[newestFirst ? 1 : 0].gate.complete();
      await tester.pumpAndSettle();
      expect(h.inlineText, 'Old goal');
      await h.finish();
      expect(h.inlineText, 'Old goal');
      expect(h.advanced, 1);
      await h.reload('g1', 'Old goal');
    });
    testWidgets('inline overlap newestFirst=$newestFirst', (tester) async {
      final h = _Harness(tester);
      await h.start();
      await h.edit();
      h.remote.hold = true;
      await h.submit();
      await h.edit(text: 'Second goal');
      await h.submit();
      expect(h.remote.calls, hasLength(2));
      h.remote.calls[newestFirst ? 1 : 0].gate.complete();
      await tester.pumpAndSettle();
      expect(h.inlineText, 'Second goal');
      await h.finish();
      expect(h.inlineText, 'Second goal');
      expect(h.advanced, 1);
      await h.reload('g1', 'Second goal');
    });
  }
  for (final change in [
    'draft',
    'focus',
    'path',
    'cancel',
    'dispose',
    'repeat',
  ]) {
    testWidgets('inline pending respects $change', (tester) async {
      final h = _Harness(tester);
      await h.start();
      await h.edit();
      h.remote.hold = true;
      await h.submit();
      if (change == 'draft') await h.edit(text: 'Second goal');
      if (change == 'focus') {
        textFocusProvider.add(const GoalPath(['other']));
        h.outsideFocus.requestFocus();
      }
      if (change == 'path') {
        h.path.value = const GoalPath(['g2']);
        await tester.pumpAndSettle();
        expect(find.text('Other goal'), findsOneWidget);
        await tester.tap(find.text('Other goal'));
        await tester.pumpAndSettle();
        await h.edit(text: 'Second goal');
      }
      if (change == 'cancel') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await h.edit(text: 'Second goal');
      }
      if (change == 'dispose') await tester.pumpWidget(const SizedBox());
      if (change == 'repeat') {
        await h.submit();
        await h.submit(outside: true);
        expect(h.remote.calls, hasLength(1));
      }
      await tester.pump();
      await h.finish();
      expect(tester.takeException(), isNull);
      if (['draft', 'path', 'cancel'].contains(change)) {
        expect(_inline, findsOneWidget);
        expect(h.inlineText, 'Second goal');
      }
      if (['focus', 'repeat'].contains(change))
        expect(h.outsideFocus.hasPrimaryFocus, isTrue);
      expect(h.advanced, 0);
    });
  }
}
