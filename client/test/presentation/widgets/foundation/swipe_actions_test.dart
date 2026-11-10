// WhatsApp-style trailing swipe actions (founder, 2026-11-09): a swipe opens
// the row and waits; a full swipe fires the last action.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/foundation/swipe_actions.dart';

const _rowWidth = 360.0;

class _Log {
  final taps = <String>[];
  final actions = <String>[];
}

Widget _row(
  _Log log,
  String id, {
  FutureOr<void> Function()? onArchive,
  bool enabled = true,
}) => SwipeActions(
  key: ValueKey('swipe-$id'),
  enabled: enabled,
  actions: [
    SwipeAction(
      key: ValueKey('more-$id'),
      label: 'More',
      icon: Icons.more_horiz,
      color: Colors.grey,
      onPressed: () => log.actions.add('more-$id'),
    ),
    SwipeAction(
      key: ValueKey('archive-$id'),
      label: 'Archive',
      icon: Icons.archive_outlined,
      color: Colors.purple,
      commits: true,
      onPressed: onArchive ?? () => log.actions.add('archive-$id'),
    ),
  ],
  child: Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: () => log.taps.add(id),
      child: SizedBox(height: 72, child: Center(child: Text('Row $id'))),
    ),
  ),
);

Future<void> _pump(WidgetTester tester, List<Widget> rows) async {
  tester.view.physicalSize = const Size(_rowWidth, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SwipeActionsGroup(
          child: ListView(children: [...rows, const SizedBox(height: 1200)]),
        ),
      ),
    ),
  );
}

double _offsetOf(WidgetTester tester, String id) =>
    tester.getTopLeft(find.text('Row $id')).dx -
    tester.getTopLeft(find.byKey(ValueKey('swipe-$id'))).dx;

double _restingOffset(WidgetTester tester, String id) =>
    (_rowWidth - tester.getSize(find.text('Row $id')).width) / 2;

void main() {
  testWidgets('a swipe past halfway opens the row and it stays open', (
    tester,
  ) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);
    final rest = _restingOffset(tester, 'a');

    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    const open = SwipeActions.actionWidth * 2;
    expect(_offsetOf(tester, 'a'), closeTo(rest - open, 0.5));
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(log.actions, isEmpty);
  });

  testWidgets('a short swipe springs back shut', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);
    final rest = _restingOffset(tester, 'a');

    await tester.drag(find.text('Row a'), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('tapping an open row closes it rather than opening it', (
    tester,
  ) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);
    final rest = _restingOffset(tester, 'a');
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Row a'));
    await tester.pumpAndSettle();
    expect(log.taps, isEmpty);
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));

    await tester.tap(find.text('Row a'));
    expect(log.taps, ['a']);
  });

  testWidgets('More runs and the row closes behind it', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);
    final rest = _restingOffset(tester, 'a');
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('more-a')));
    await tester.pumpAndSettle();
    expect(log.actions, ['more-a']);
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
  });

  testWidgets('tapping Archive slides the row across while it runs, and back '
      'if the row is still there afterwards', (tester) async {
    final log = _Log();
    final gate = Completer<void>();
    await _pump(tester, [_row(log, 'a', onArchive: () => gate.future)]);
    final rest = _restingOffset(tester, 'a');
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('archive-a')));
    await tester.pumpAndSettle();
    expect(_offsetOf(tester, 'a'), closeTo(rest - _rowWidth, 0.5));
    // The strip is all Archive now.
    expect(
      tester.getSize(find.byKey(const ValueKey('archive-a'))).width,
      closeTo(_rowWidth, 0.5),
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
  });

  testWidgets('a full swipe fires the last action on its own', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);

    await tester.drag(find.text('Row a'), const Offset(-340, 0));
    await tester.pumpAndSettle();
    expect(log.actions, ['archive-a']);
  });

  testWidgets('a swipe that stops short of the full-swipe line only opens', (
    tester,
  ) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);

    // Past open, short of 62% of the row.
    await tester.drag(find.text('Row a'), const Offset(-190, 0));
    await tester.pumpAndSettle();
    expect(log.actions, isEmpty);
    expect(find.text('Archive'), findsOneWidget);
  });

  testWidgets('opening a second row closes the first', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a'), _row(log, 'b')]);
    final rest = _restingOffset(tester, 'a');

    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    // Row b's content is guarded while a is open; the swipe still reaches it.
    await tester.drag(
      find.text('Row b'),
      const Offset(-120, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
    expect(
      _offsetOf(tester, 'b'),
      closeTo(_restingOffset(tester, 'b') - SwipeActions.actionWidth * 2, 0.5),
    );
  });

  testWidgets('with one row open, tapping another closes it and opens '
      'nothing', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a'), _row(log, 'b')]);
    final rest = _restingOffset(tester, 'a');
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // The open row guards the others, so the tap lands on the guard.
    await tester.tap(find.text('Row b'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(log.taps, isEmpty);
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
  });

  testWidgets('scrolling the list closes an open row', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a'), _row(log, 'b')]);
    final rest = _restingOffset(tester, 'a');
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    await tester.drag(
      find.text('Row b'),
      const Offset(0, -40),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
  });

  testWidgets('a disabled row does not swipe', (tester) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a', enabled: false)]);
    final rest = _restingOffset(tester, 'a');

    await tester.drag(find.text('Row a'), const Offset(-340, 0));
    await tester.pumpAndSettle();
    expect(_offsetOf(tester, 'a'), closeTo(rest, 0.5));
    expect(log.actions, isEmpty);
  });

  testWidgets('an open row that leaves the list closes cleanly for the rest', (
    tester,
  ) async {
    final log = _Log();
    await _pump(tester, [_row(log, 'a'), _row(log, 'b')]);
    await tester.drag(find.text('Row b'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // b goes while it is the open row; a must not be told during the frame.
    await _pump(tester, [_row(log, 'a')]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Row a'));
    expect(log.taps, ['a']);
  });

  testWidgets('the bleed past the row edge is part of the last panel', (
    tester,
  ) async {
    final log = _Log();
    tester.view.physicalSize = const Size(_rowWidth, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeActionsGroup(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                SwipeActions(
                  key: const ValueKey('swipe-a'),
                  bleed: 20,
                  actions: [
                    SwipeAction(
                      label: 'Archive',
                      icon: Icons.archive_outlined,
                      color: Colors.purple,
                      onPressed: () => log.actions.add('archive-a'),
                    ),
                  ],
                  child: const SizedBox(
                    height: 72,
                    child: Center(child: Text('Row a')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.text('Row a'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // Inside the screen's side padding, over the panel's colour.
    final row = tester.getRect(find.byKey(const ValueKey('swipe-a')));
    await tester.tapAt(Offset(row.right + 10, row.center.dy));
    await tester.pumpAndSettle();
    expect(log.actions, ['archive-a']);
  });

  testWidgets('each action is a screen-reader custom action', (tester) async {
    final handle = tester.ensureSemantics();
    final log = _Log();
    await _pump(tester, [_row(log, 'a')]);

    final node = tester.getSemantics(find.text('Row a'));
    final data = node.getSemanticsData();
    for (final label in ['More', 'Archive']) {
      final id = CustomSemanticsAction.getIdentifier(
        CustomSemanticsAction(label: label),
      );
      expect(data.customSemanticsActionIds, contains(id), reason: label);
    }
    handle.dispose();
  });
}
