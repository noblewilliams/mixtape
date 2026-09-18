// The house segmented control (founder, smoke round five, note 3): one pill
// track with a sliding thumb, used by "Add your music" and the Mixes tab in
// place of `CupertinoSlidingSegmentedControl`.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';

const _options = [
  SegmentedOption(value: 0, label: 'Apple Music', key: Key('seg-apple')),
  SegmentedOption(value: 1, label: 'Spotify', key: Key('seg-spotify')),
];

/// The toggle inside a wide, loose parent, so "hugs its content" is a claim
/// about the control and not about the room it was given. The host owns the
/// value the way both real callers do.
Future<List<int>> _pump(
  WidgetTester tester, {
  int value = 0,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
  bool settle = true,
}) async {
  final taps = <int>[];
  var current = value;
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: StatefulBuilder(
                builder: (context, setState) => SegmentedToggle<int>(
                  options: _options,
                  value: current,
                  onChanged: (next) {
                    taps.add(next);
                    setState(() => current = next);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return taps;
}

Rect _rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

void main() {
  testWidgets("tapping a segment reports that segment's value", (tester) async {
    final taps = await _pump(tester);

    await tester.tap(find.byKey(const Key('seg-spotify')));
    await tester.pumpAndSettle();
    expect(taps, [1]);

    await tester.tap(find.byKey(const Key('seg-apple')));
    await tester.pumpAndSettle();
    expect(taps, [1, 0]);
  });

  testWidgets('the thumb covers the selected segment', (tester) async {
    await _pump(tester);

    final first = _rectOf(tester, const Key('seg-apple'));
    var thumb = _rectOf(tester, SegmentedToggle.thumbKey);
    expect(thumb.left, moreOrLessEquals(first.left, epsilon: 0.5));
    expect(thumb.right, moreOrLessEquals(first.right, epsilon: 0.5));
    expect(thumb.top, moreOrLessEquals(first.top, epsilon: 0.5));
    expect(thumb.bottom, moreOrLessEquals(first.bottom, epsilon: 0.5));

    await tester.tap(find.byKey(const Key('seg-spotify')));
    await tester.pumpAndSettle();
    final second = _rectOf(tester, const Key('seg-spotify'));
    thumb = _rectOf(tester, SegmentedToggle.thumbKey);
    expect(thumb.left, moreOrLessEquals(second.left, epsilon: 0.5));
    expect(thumb.right, moreOrLessEquals(second.right, epsilon: 0.5));
  });

  testWidgets('the thumb slides rather than jumping', (tester) async {
    await _pump(tester);
    final start = _rectOf(tester, SegmentedToggle.thumbKey).left;

    await tester.tap(find.byKey(const Key('seg-spotify')));
    // One frame in, the thumb has left but not arrived: the slide is an
    // animation, not a jump.
    await tester.pump();
    await tester.pump(SegmentedToggle.thumbDuration ~/ 4);
    final midway = _rectOf(tester, SegmentedToggle.thumbKey).left;
    expect(midway, greaterThan(start));

    await tester.pumpAndSettle();
    final end = _rectOf(tester, SegmentedToggle.thumbKey).left;
    expect(midway, lessThan(end));
  });

  testWidgets('reduced motion moves the thumb in one frame', (tester) async {
    await _pump(tester, reduceMotion: true);
    final start = _rectOf(tester, SegmentedToggle.thumbKey).left;

    await tester.tap(find.byKey(const Key('seg-spotify')));
    await tester.pump();
    final moved = _rectOf(tester, SegmentedToggle.thumbKey).left;
    final second = _rectOf(tester, const Key('seg-spotify'));
    expect(moved, greaterThan(start));
    expect(moved, moreOrLessEquals(second.left, epsilon: 0.5));
  });

  testWidgets('every segment is a button VoiceOver can select and activate', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    SemanticsData data(Key key) =>
        tester.getSemantics(find.byKey(key)).getSemanticsData();

    expect(data(const Key('seg-apple')).flagsCollection.isSelected, isTrue);
    expect(data(const Key('seg-spotify')).flagsCollection.isSelected, isFalse);
    for (final key in const [Key('seg-apple'), Key('seg-spotify')]) {
      expect(data(key).flagsCollection.isButton, isTrue);
      expect(
        data(key).hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a node with no tap action cannot be activated by VoiceOver',
      );
    }
    expect(
      find.bySemanticsLabel('Spotify'),
      findsOneWidget,
      reason: 'the label a screen reader hears is the option text',
    );
    handle.dispose();
  });

  testWidgets('the control hugs its segments instead of stretching', (
    tester,
  ) async {
    await _pump(tester);

    final track = tester.getRect(find.byKey(SegmentedToggle.trackKey));
    final segments = [
      for (final key in const [Key('seg-apple'), Key('seg-spotify')])
        _rectOf(tester, key),
    ];
    final sum = segments.fold<double>(0, (total, rect) => total + rect.width);

    expect(
      track.width,
      moreOrLessEquals(sum + SegmentedToggle.chrome * 2, epsilon: 0.5),
    );
    expect(
      track.width,
      lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio),
      reason: 'a hugging control never fills the screen',
    );
    expect(
      track.height,
      moreOrLessEquals(SegmentedToggle.trackHeight, epsilon: 0.5),
    );
  });
}
