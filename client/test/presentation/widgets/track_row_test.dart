import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/reason_band.dart';
import 'package:mixtape/presentation/widgets/track_row.dart';

QueueTrack _track({
  int position = 0,
  String trackId = 't1',
  String? appleId = 'apple-1',
  String? spotifyId,
  String? reason,
  String title = 'Low Tide, Late',
  String artist = 'Harbour Lights',
}) => QueueTrack(
  position: position,
  trackId: trackId,
  appleId: appleId,
  spotifyId: spotifyId,
  title: title,
  artist: artist,
  reason: reason,
  durationMs: 180000,
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
}
