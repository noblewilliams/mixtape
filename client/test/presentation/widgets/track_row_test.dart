import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/reason_band.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/track_row.dart';

QueueTrack _track({
  int position = 0,
  String trackId = 't1',
  String? appleId = 'apple-1',
  String? spotifyId,
  String? reason,
  String title = 'Low Tide, Late',
  String artist = 'Harbour Lights',
  bool newToYou = false,
}) => QueueTrack(
  position: position,
  trackId: trackId,
  appleId: appleId,
  spotifyId: spotifyId,
  title: title,
  artist: artist,
  reason: reason,
  durationMs: 180000,
  newToYou: newToYou,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double width = 390,
  TextScaler textScaler = TextScaler.noScaling,
  bool scrollable = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? MixtapeTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: scrollable
                  ? SingleChildScrollView(child: child)
                  : SizedBox(height: 300, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a row shows its 1-based number, title and artist', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackRow(number: 3, track: _track(), expanded: false, onTap: () {}),
    );

    expect(find.text('3'), findsOneWidget);
    expect(find.text('Low Tide, Late'), findsOneWidget);
    expect(find.text('Harbour Lights'), findsOneWidget);
    // The number column is the board's fixed 22 pt gutter.
    expect(
      tester.getSize(find.byKey(TrackRow.numberKey)).width,
      TrackRow.numberWidth,
    );
  });

  testWidgets('the first row draws no hairline; a later one draws it inset 82', (
    tester,
  ) async {
    await _pump(
      tester,
      Column(
        children: [
          TrackRow(
            number: 1,
            track: _track(trackId: 'a'),
            expanded: false,
            isFirst: true,
          ),
          TrackRow(number: 2, track: _track(trackId: 'b'), expanded: false),
        ],
      ),
    );

    final hairlines = find.byKey(TrackRow.hairlineKey);
    expect(hairlines, findsOneWidget);
    final row = tester.getTopLeft(find.byKey(TrackRow.rowKey('b')));
    expect(tester.getTopLeft(hairlines).dx - row.dx, TrackRow.hairlineInset);
  });

  testWidgets('tapping toggles the reason band', (tester) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MixtapeMetrics.screenSidePadding,
              ),
              child: TrackRow(
                number: 1,
                track: _track(reason: 'Quiet opener, matches "tired"'),
                expanded: expanded,
                onTap: () => setState(() => expanded = !expanded),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ReasonBand), findsNothing);
    await tester.tap(find.byKey(TrackRow.rowKey('t1')));
    await tester.pumpAndSettle();
    expect(find.byType(ReasonBand), findsOneWidget);
    expect(find.text('Quiet opener, matches "tired"'), findsOneWidget);

    await tester.tap(find.byKey(TrackRow.rowKey('t1')));
    await tester.pumpAndSettle();
    expect(find.byType(ReasonBand), findsNothing);
  });

  testWidgets('a reasonless row reveals the DJ-has-nothing line', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackRow(number: 1, track: _track(), expanded: true, onTap: () {}),
    );

    expect(find.text(TrackRow.noReasonText), findsOneWidget);
  });

  testWidgets('a track with no Apple Music match carries the skipped em-line', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackRow(
        number: 1,
        track: _track(appleId: null),
        expanded: false,
        onTap: () {},
      ),
    );

    expect(find.text(TrackRow.unavailableText), findsOneWidget);
  });

  testWidgets('an available track carries no em-line', (tester) async {
    await _pump(
      tester,
      TrackRow(number: 1, track: _track(), expanded: false, onTap: () {}),
    );

    expect(find.text(TrackRow.unavailableText), findsNothing);
  });

  testWidgets('the Spotify variant trades the grip for Open in Spotify', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      TrackRow(
        number: 1,
        track: _track(appleId: null, spotifyId: 'sp1'),
        expanded: false,
        onOpenInSpotify: () => opened++,
      ),
    );

    expect(find.byKey(TrackRow.gripKey('t1')), findsNothing);
    final button = find.byKey(TrackRow.spotifyKey('t1'));
    expect(button, findsOneWidget);
    // Over the 44 pt floor.
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44.0));
    await tester.tap(button);
    expect(opened, 1);
  });

  testWidgets('Open in Spotify is a button VoiceOver can activate', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      TrackRow(
        number: 1,
        track: _track(appleId: null, spotifyId: 'sp1'),
        expanded: false,
        onOpenInSpotify: () {},
      ),
    );

    final data = tester
        .getSemantics(find.bySemanticsLabel('Open in Spotify: Low Tide, Late'))
        .getSemanticsData();
    expect(
      data.hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'a node with no tap action cannot be activated by VoiceOver',
    );
    expect(data.flagsCollection.isButton, isTrue);

    handle.dispose();
  });

  testWidgets("the grip is the board's 36 x 44 target", (tester) async {
    await _pump(
      tester,
      ReorderableListView(
        buildDefaultDragHandles: false,
        onReorder: (_, __) {},
        children: [
          TrackRow(
            key: const ValueKey('row-t1'),
            number: 1,
            track: _track(),
            expanded: false,
            dragIndex: 0,
          ),
        ],
      ),
      scrollable: false,
    );

    final grip = find.byKey(TrackRow.gripKey('t1'));
    expect(grip, findsOneWidget);
    expect(
      tester.getSize(grip),
      const Size(TrackRow.gripWidth, TrackRow.gripHeight),
    );
  });

  testWidgets('VoiceOver gets Move up and Move down actions', (tester) async {
    final handle = tester.ensureSemantics();
    var up = 0;
    var down = 0;
    await _pump(
      tester,
      TrackRow(
        number: 2,
        track: _track(),
        expanded: false,
        onTap: () {},
        onMoveUp: () => up++,
        onMoveDown: () => down++,
      ),
    );

    final node = tester.getSemantics(find.byKey(TrackRow.rowKey('t1')));
    final labels = node
        .getSemanticsData()
        .customSemanticsActionIds!
        .map((id) => CustomSemanticsAction.getAction(id)!.label)
        .toList();
    expect(labels, containsAll(<String>['Move up', 'Move down']));

    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(TrackRow.moveUpAction),
    );
    await tester.pump();
    expect(up, 1);
    expect(down, 0);
    handle.dispose();
  });

  testWidgets('a row with no move callbacks offers no move actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      TrackRow(number: 1, track: _track(), expanded: false, onTap: () {}),
    );

    final data = tester
        .getSemantics(find.byKey(TrackRow.rowKey('t1')))
        .getSemanticsData();
    expect(data.customSemanticsActionIds ?? const <int>[], isEmpty);
    handle.dispose();
  });

  testWidgets(
    'a lifted row paints the raised background and drops its hairline',
    (tester) async {
      await _pump(
        tester,
        TrackRow(number: 2, track: _track(), expanded: false, lifted: true),
      );

      expect(find.byKey(TrackRow.hairlineKey), findsNothing);
      final lift = tester.widget<DecoratedBox>(find.byKey(TrackRow.liftKey));
      final decoration = lift.decoration as BoxDecoration;
      expect(decoration.color, TrackRow.liftColorFor(Brightness.light));
      expect(
        decoration.borderRadius,
        BorderRadius.circular(TrackRow.liftRadius),
      );
      expect(decoration.boxShadow, isNotEmpty);
    },
  );

  testWidgets('dark mode keeps the row legible and lifts on its own colour', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackRow(number: 1, track: _track(), expanded: true, lifted: true),
      theme: MixtapeTheme.dark(),
    );

    expect(find.text('Low Tide, Late'), findsOneWidget);
    final lift = tester.widget<DecoratedBox>(find.byKey(TrackRow.liftKey));
    expect(
      (lift.decoration as BoxDecoration).color,
      TrackRow.liftColorFor(Brightness.dark),
    );
  });

  testWidgets(
    'at 200% text the title wraps while art and grip keep their size',
    (tester) async {
      await _pump(
        tester,
        ReorderableListView(
          buildDefaultDragHandles: false,
          onReorder: (_, __) {},
          children: [
            TrackRow(
              key: const ValueKey('row-t1'),
              number: 1,
              track: _track(
                title: 'A very long song title that has to wrap at 200 percent',
              ),
              expanded: false,
              dragIndex: 0,
            ),
          ],
        ),
        width: 320,
        textScaler: const TextScaler.linear(2),
        scrollable: false,
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(TrackRow.artKey)),
        const Size(TrackRow.artSize, TrackRow.artSize),
      );
      expect(
        tester.getSize(find.byKey(TrackRow.gripKey('t1'))),
        const Size(TrackRow.gripWidth, TrackRow.gripHeight),
      );
      final title = tester.widget<Text>(
        find.text('A very long song title that has to wrap at 200 percent'),
      );
      expect(title.maxLines, isNull);
    },
  );

  group('new to you mark', () {
    testWidgets('a new track ends the artist line with the plum status word', (
      tester,
    ) async {
      await _pump(
        tester,
        TrackRow(number: 2, track: _track(newToYou: true), expanded: false),
      );

      final word = tester.widget<StatusWord>(find.byType(StatusWord));
      expect(word.label, 'New to you');
      expect(word.kind, StatusKind.accent);
      expect(word.icon, isFalse);
      final style = tester.widget<Text>(find.text('New to you')).style!;
      expect(style.fontSize, 12.5);
      expect(style.fontWeight, FontWeight.w600);
      expect(style.color, MixtapeTokens.light.plum);
      expect(find.text(' · '), findsOneWidget);
      expect(find.text('Harbour Lights'), findsOneWidget);
      // On the artist's line, after it.
      final artist = tester.getRect(find.text('Harbour Lights'));
      final mark = tester.getRect(find.text('New to you'));
      expect(mark.left, greaterThan(artist.right));
      expect((mark.center.dy - artist.center.dy).abs(), lessThan(4));
    });

    testWidgets('an owned track carries no mark', (tester) async {
      await _pump(tester, TrackRow(number: 1, track: _track(), expanded: false));

      expect(find.byType(StatusWord), findsNothing);
      expect(find.text('New to you'), findsNothing);
      expect(find.text(' · '), findsNothing);
    });

    testWidgets('a long artist ellipsises first and the mark is never cut', (
      tester,
    ) async {
      await _pump(
        tester,
        TrackRow(
          number: 4,
          track: _track(
            artist: 'Ilse Varga and the Night Shift Choir Orchestra',
            newToYou: true,
          ),
          expanded: false,
          onOpenInSpotify: () {},
        ),
        // The test font draws every glyph a full em wide, so this is far
        // tighter than a real 320 pt phone.
        width: 340,
      );

      expect(tester.takeException(), isNull);
      final artist = tester.renderObject<RenderParagraph>(
        find.text('Ilse Varga and the Night Shift Choir Orchestra'),
      );
      expect(artist.didExceedMaxLines, isTrue);
      final mark = tester.renderObject<RenderParagraph>(find.text('New to you'));
      expect(mark.didExceedMaxLines, isFalse);
      expect(
        mark.size.width,
        moreOrLessEquals(mark.getMaxIntrinsicWidth(double.infinity), epsilon: 0.5),
      );
      // The Spotify control keeps its full target beside it.
      expect(
        tester.getSize(find.byKey(TrackRow.spotifyKey('t1'))),
        const Size(MixtapeMetrics.minTarget, MixtapeMetrics.minTarget),
      );
      expect(
        tester.getRect(find.text('New to you')).right,
        lessThanOrEqualTo(tester.getRect(find.byKey(TrackRow.spotifyKey('t1'))).left),
      );
    });

    testWidgets('an unavailable new track keeps the skipped line', (tester) async {
      await _pump(
        tester,
        TrackRow(
          number: 1,
          track: _track(appleId: null, newToYou: true),
          expanded: false,
        ),
      );

      expect(find.text('New to you'), findsOneWidget);
      expect(find.text(TrackRow.unavailableText), findsOneWidget);
    });

    testWidgets('just under the wrap scale the mark stays on the artist line', (
      tester,
    ) async {
      await _pump(
        tester,
        TrackRow(number: 2, track: _track(newToYou: true), expanded: false),
        width: 420,
        textScaler: const TextScaler.linear(1.49),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(' · '), findsOneWidget);
      final artist = tester.getRect(find.text('Harbour Lights'));
      final dot = tester.getRect(find.text(' · '));
      final mark = tester.getRect(find.text('New to you'));
      expect(dot.left, greaterThanOrEqualTo(artist.right));
      expect(mark.left, greaterThanOrEqualTo(dot.right));
      expect((mark.center.dy - artist.center.dy).abs(), lessThan(6));
      expect(
        tester.renderObject<RenderParagraph>(find.text('New to you')).didExceedMaxLines,
        isFalse,
      );
    });

    testWidgets('at 150% text the mark takes its own line, without the dot', (
      tester,
    ) async {
      await _pump(
        tester,
        TrackRow(
          number: 2,
          track: _track(
            artist: 'Ilse Varga and the Night Shift Choir Orchestra',
            newToYou: true,
          ),
          expanded: false,
        ),
        width: 320,
        textScaler: const TextScaler.linear(1.5),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(' · '), findsNothing);
      final artist = tester.getRect(
        find.text('Ilse Varga and the Night Shift Choir Orchestra'),
      );
      final mark = tester.getRect(find.text('New to you'));
      expect(mark.top, greaterThanOrEqualTo(artist.bottom));
      expect(mark.left, moreOrLessEquals(artist.left, epsilon: 0.5));
      expect(
        tester.renderObject<RenderParagraph>(find.text('New to you')).didExceedMaxLines,
        isFalse,
      );
    });

    testWidgets('VoiceOver reads one row ending in new to you, no extra stop', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        TrackRow(
          number: 2,
          track: _track(newToYou: true),
          expanded: false,
          onTap: () {},
        ),
      );

      final row = tester.getSemantics(find.text('Low Tide, Late')).getSemanticsData();
      expect(row.label, contains('Harbour Lights'));
      expect(row.label.toLowerCase(), endsWith('new to you'));
      expect(row.label, isNot(contains('·')));
      expect(
        tester.getSemantics(find.text('New to you')),
        same(tester.getSemantics(find.text('Low Tide, Late'))),
      );
      handle.dispose();
    });
  });
}
