import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_marquee.dart';

const _labels = ['One idea', 'Another idea', 'A third idea'];

Future<void> _pump(
  WidgetTester tester, {
  bool running = true,
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        disableAnimations: reduceMotion,
      ),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 390,
            child: IdeaMarquee(
              running: running,
              inset: 14,
              children: [
                for (final label in _labels)
                  SizedBox(height: 34, child: Text(label)),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

/// Where the readable pass of [label] sits (the second pass drawn), from the
/// row's leading edge.
double _left(WidgetTester tester, String label) =>
    tester.getTopLeft(find.text(label).at(1)).dx -
    tester.getTopLeft(find.byKey(IdeaMarquee.rowKey)).dx;

void main() {
  setUp(() => IdeaMarquee.animate = true);
  tearDown(() => IdeaMarquee.animate = false);

  testWidgets('the row drifts left on its own and loops', (tester) async {
    await _pump(tester);
    await tester.pump();
    await tester.pump();
    final start = _left(tester, _labels.first);
    expect(start, moreOrLessEquals(14, epsilon: 0.5));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_left(tester, _labels.first), lessThan(start - 10));
    // The same pills come round again: more than one pass is drawn.
    expect(find.text(_labels.first).evaluate().length, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held still while not running', (tester) async {
    await _pump(tester, running: false);
    await tester.pump();
    await tester.pump();
    final start = _left(tester, _labels.first);
    await tester.pump(const Duration(seconds: 2));
    expect(_left(tester, _labels.first), start);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion draws each pill once, still', (tester) async {
    await _pump(tester, reduceMotion: true);
    await tester.pumpAndSettle();
    for (final label in _labels) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('a pill in the drifting row still takes a tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IdeaMarquee(
            inset: 14,
            children: [
              for (final label in _labels)
                TextButton(onPressed: () => taps++, child: Text(label)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(_labels.first).at(1));
    await tester.pump();
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  group('the first pill changing mid-drift (launch glitch, 2026-11-24)', () {
    Widget row(List<(String, double)> pills) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              child: IdeaMarquee(
                inset: 14,
                children: [
                  for (final (label, width) in pills)
                    SizedBox(
                      key: ValueKey(label),
                      width: width,
                      height: 34,
                      child: Text(label),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    /// Where each drawn copy of [label] sits: the row repeats, so a pill may
    /// carry on in the next copy round.
    List<double> copies(WidgetTester tester, String label) => [
      for (final e in find.text(label).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx -
            tester.getTopLeft(find.byKey(IdeaMarquee.rowKey)).dx,
    ];

    Matcher near(double x, {double before = 0.5, double after = 0.5}) =>
        contains(
          predicate<double>((v) => v <= x + before && v >= x - after - 0.001),
        );

    Future<void> drift(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 700));
    }

    testWidgets('dropping it leaves the others where they are', (tester) async {
      await tester.pumpWidget(
        row([('skeleton', 60), ('One idea', 120), ('Another idea', 140)]),
      );
      await drift(tester);
      final one = _left(tester, 'One idea');
      final another = _left(tester, 'Another idea');

      await tester.pumpWidget(row([('One idea', 120), ('Another idea', 140)]));
      // The very frame it goes: nothing jumps.
      expect(copies(tester, 'One idea'), near(one));
      await tester.pump();
      await tester.pump();
      // Still drifting from there, never back by the dropped width.
      expect(copies(tester, 'Another idea'), near(another, after: 5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('swapping it for a wider one leaves the others in place', (
      tester,
    ) async {
      await tester.pumpWidget(
        row([('skeleton', 60), ('One idea', 120), ('Another idea', 140)]),
      );
      await drift(tester);
      final one = _left(tester, 'One idea');

      await tester.pumpWidget(
        row([('Routine', 110), ('One idea', 120), ('Another idea', 140)]),
      );
      await tester.pump();
      await tester.pump();
      expect(copies(tester, 'One idea'), near(one, after: 5));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
