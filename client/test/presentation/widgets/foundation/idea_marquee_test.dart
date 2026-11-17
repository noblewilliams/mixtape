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
}
