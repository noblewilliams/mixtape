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

  group('compact (the Home panel row, album picks board H1)', () {
    Future<List<int>> pumpCompact(
      WidgetTester tester, {
      double textScale = 1,
    }) async {
      final taps = <int>[];
      var current = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: Center(
                  child: StatefulBuilder(
                    builder: (context, setState) =>
                        SegmentedToggle<int>.compact(
                          semanticLabel: 'What to make',
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
      await tester.pumpAndSettle();
      return taps;
    }

    testWidgets('drawn 26 pt tall with 11.5 pt labels', (tester) async {
      await pumpCompact(tester);
      final track = _rectOf(tester, SegmentedToggle.trackKey);
      expect(track.height, moreOrLessEquals(26, epsilon: 0.5));
      expect(SegmentedToggle.compactTrackHeight, 26);
      final label = tester.widget<Text>(find.text('Spotify'));
      expect(label.style!.fontSize, 11.5);
      // The thumb sits inside the drawn track, not the hit area.
      final thumb = _rectOf(tester, SegmentedToggle.thumbKey);
      expect(thumb.top, greaterThanOrEqualTo(track.top));
      expect(thumb.bottom, lessThanOrEqualTo(track.bottom));
    });

    testWidgets('each segment answers taps over a 44 pt tall area', (
      tester,
    ) async {
      final taps = await pumpCompact(tester);
      for (final key in const [Key('seg-apple'), Key('seg-spotify')]) {
        expect(
          _rectOf(tester, key).height,
          greaterThanOrEqualTo(MixtapeMetrics.minTarget),
        );
      }
      final track = _rectOf(tester, SegmentedToggle.trackKey);
      final spotify = _rectOf(tester, const Key('seg-spotify'));
      // Above the drawn track, still inside the invisible hit area.
      await tester.tapAt(Offset(spotify.center.dx, track.top - 6));
      await tester.pumpAndSettle();
      expect(taps, [1]);
    });

    testWidgets('at 1.5x text it draws 28 to 32 pt, still 44 pt to touch', (
      tester,
    ) async {
      await pumpCompact(tester, textScale: 1.5);
      final track = _rectOf(tester, SegmentedToggle.trackKey);
      expect(track.height, greaterThanOrEqualTo(28));
      expect(track.height, lessThanOrEqualTo(32));
      // The board's large-text frame: a 28 pt segment in a 32 pt track.
      expect(
        _rectOf(tester, SegmentedToggle.thumbKey).height,
        greaterThanOrEqualTo(28 - SegmentedToggle.compactInset * 2),
      );
      expect(
        _rectOf(tester, const Key('seg-apple')).height,
        greaterThanOrEqualTo(MixtapeMetrics.minTarget),
      );
    });

    testWidgets('past 1.5x the drawn height stops growing', (tester) async {
      await pumpCompact(tester, textScale: 3);
      expect(
        _rectOf(tester, SegmentedToggle.trackKey).height,
        lessThanOrEqualTo(32),
      );
    });

    testWidgets('the control is a named group of selectable segments', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCompact(tester);
      expect(find.bySemanticsLabel('What to make'), findsOneWidget);
      final apple = tester
          .getSemantics(find.byKey(const Key('seg-apple')))
          .getSemanticsData();
      expect(apple.flagsCollection.isSelected, isTrue);
      expect(apple.label, 'Apple Music');
      handle.dispose();
    });
  });
}
