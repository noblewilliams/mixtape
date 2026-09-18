import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/collection_review.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/collection_review_form.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';

Future<ParsedExport> parseSample(WidgetTester tester) async {
  final archive = openExportArchive(File('../fixtures/exportify/sample.csv'));
  final parsed = (await tester.runAsync(
    () => parseExport(archive, const ParseOptions(timeZone: 'UTC')),
  ))!;
  await archive.close();
  return parsed;
}

/// An Exportify parse of [names], one CSV each, so the grouped review has
/// more than one file to set at once.
ListeningExportSnapshot snapshotOf(List<String> names) =>
    ListeningExportSnapshot(
      package: ExportPackage.spotifyExportify,
      timeZone: 'UTC',
      country: null,
      tracks: [
        for (var i = 0; i < names.length; i++)
          SnapshotTrack(
            platformId: 'track$i',
            title: 'T$i',
            artist: 'A',
            album: null,
            durationMs: null,
          ),
      ],
      days: const [],
      library: const [],
      artists: const [],
      playlists: [
        for (var i = 0; i < names.length; i++)
          SnapshotPlaylist(
            ordinal: i,
            key: 'hash$i',
            name: names[i],
            description: null,
            lastModifiedAt: null,
            entries: [
              SnapshotEntry(
                position: 0,
                platformId: 'track$i',
                title: 'T$i',
                artist: 'A',
                album: null,
                addedAt: null,
              ),
            ],
          ),
      ],
      unresolved: const SnapshotUnresolved(rows: 0, plays: 0),
      ledgerFrom: null,
      ledgerTo: null,
    );

/// Pumps the form under the native theme, holding the selection so the widget
/// sees each change the way the import sheet feeds it back.
Future<CollectionSelection Function()> pumpForm(
  WidgetTester tester,
  ListeningExportSnapshot snapshot,
  CollectionSelection initial, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Size? surface,
  double sidePadding = 0,
  List<String> paths = const ['sample.csv'],
}) async {
  if (surface != null) {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  var selection = initial;
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: sidePadding),
            child: StatefulBuilder(
              builder: (context, setState) => CollectionReviewForm(
                snapshot: snapshot,
                paths: paths,
                selection: selection,
                onChanged: (value) => setState(() => selection = value),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return () => selection;
}

/// A collection already imported, so a file has something to attach to.
const attachCandidate = ImportedCollection(
  key: 'spotify:playlist:1',
  name: 'Late night',
  fingerprint: 'f1',
  fileHash: null,
);

CollectionSelection selectionFor(
  ListeningExportSnapshot snapshot, {
  List<String> ids = const [],
  List<ImportedCollection> playlists = const [],
}) => CollectionSelection.initial(
  snapshot,
  CollectionContext(ids: ids, fingerprint: 'current', playlists: playlists),
);

void main() {
  testWidgets(
    'review stays usable on a narrow screen with large text and requires explicit likes replacement',
    (tester) async {
      final parsed = await parseSample(tester);
      var selection = selectionFor(parsed.snapshot, ids: ['old']);
      selection = selection.change(
        files: [selection.files.single.change(role: 'liked')],
        mode: 'replace',
      );
      final current = await pumpForm(
        tester,
        parsed.snapshot,
        selection,
        textScale: 1.6,
        surface: const Size(320, 740),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Remove 1 songs'), findsOneWidget);
      expect(current().canUpload(parsed.snapshot), isFalse);
      // Above 150% text the toggles stack into rows, so the three-way choice
      // still fits 320 pt.
      expect(find.byType(SegmentedToggle<String>), findsNothing);
      expect(find.byKey(const ValueKey('collection-role-0')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('collection-confirm-removals')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('collection-confirm-removals')));
      await tester.pumpAndSettle();

      // Upload itself is the review now, so nothing else is left to tick.
      expect(
        current().change(confirmed: true).canUpload(parsed.snapshot),
        isTrue,
      );
      expect(
        current()
            .change(confirmed: true)
            .apply(parsed.snapshot)
            .snapshot
            .library
            .single
            .dateAdded,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the role choice is the house segmented toggle at normal text', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    final current = await pumpForm(
      tester,
      parsed.snapshot,
      selectionFor(parsed.snapshot, playlists: const [attachCandidate]),
    );

    expect(find.byType(SegmentedToggle<String>), findsOneWidget);
    expect(current().files.single.role, 'playlist');
    expect(find.text('Playlist'), findsOneWidget);
    expect(find.text('Liked Songs'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    // With something to attach to, the file names where it lands, as a flush
    // row in the same group.
    expect(find.byKey(const ValueKey('collection-target-0')), findsOneWidget);
    expect(find.text('Create new playlist'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('collection-file-0')),
        matching: find.byKey(const ValueKey('collection-target-0')),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Liked Songs'));
    await tester.pumpAndSettle();
    expect(current().files.single.role, 'liked');
    // Choosing Liked Songs brings the update choice and clears the target row.
    expect(find.byKey(const ValueKey('collection-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('collection-target-0')), findsNothing);

    expect(current().change(confirmed: true).canUpload(parsed.snapshot), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every file is its own group, under a caption of file and count', (
    tester,
  ) async {
    final snapshot = snapshotOf(['Dopamine', 'Late night']);
    await pumpForm(
      tester,
      snapshot,
      selectionFor(snapshot),
      paths: const [
        'spotify_playlists/dopamine.csv',
        'spotify_playlists/late_night.csv',
      ],
      surface: const Size(390, 1400),
      sidePadding: 20,
    );

    // The caption spreads: file name on the left, count on the right.
    expect(find.text('DOPAMINE.CSV'), findsOneWidget);
    expect(find.text('LATE_NIGHT.CSV'), findsOneWidget);
    expect(find.text('1 ENTRY'), findsNWidgets(2));
    final name = tester.getRect(find.text('DOPAMINE.CSV'));
    final count = tester.getRect(find.text('1 ENTRY').first);
    expect(name.left, lessThan(count.left));
    // The count is pushed to the far edge of its own entry, not tucked in
    // behind the name.
    expect(count.left - name.right, greaterThan(100));
    expect(
      count.right,
      greaterThan(tester.getRect(find.text('LATE_NIGHT.CSV')).right),
    );
    // Every entry is a bordered card, and nothing is left to choose about
    // where a playlist lands, so that row is not drawn at all.
    for (var i = 0; i < 2; i++) {
      expect(
        tester
            .widget<InsetGroup>(find.byKey(ValueKey('collection-file-$i')))
            .outlined,
        isTrue,
      );
      expect(find.byKey(ValueKey('collection-target-$i')), findsNothing);
    }
    // No track or artist name anywhere: file names, counts and the playlist
    // names the listener is naming themselves.
    expect(find.textContaining('T0'), findsNothing);
    expect(find.text('Use as'), findsNothing, reason: 'the toggle says it');

    // The bordered box itself, inside the group's own bottom margin.
    Rect surfaceOf(int i) => tester.getRect(
      find
          .descendant(
            of: find.byKey(ValueKey('collection-file-$i')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(
      surfaceOf(1).top - surfaceOf(0).bottom,
      moreOrLessEquals(InsetGroup.bottomMargin, epsilon: 0.5),
    );
    for (var i = 0; i < 2; i++) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('collection-file-$i')),
          matching: find.byKey(ValueKey('collection-role-$i')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('collection-file-$i')),
          matching: find.byKey(ValueKey('collection-name-$i')),
        ),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });


  testWidgets('with nothing to attach to, the file still creates a new '
      'playlist and shows no action row', (tester) async {
    final snapshot = snapshotOf(['Dopamine']);
    final current = await pumpForm(tester, snapshot, selectionFor(snapshot));

    expect(find.byKey(const ValueKey('collection-target-0')), findsNothing);
    expect(find.text('Create new playlist'), findsNothing);
    expect(current().files.single.target, isNull, reason: 'a new playlist');
    final applied = current().change(confirmed: true).apply(snapshot);
    expect(applied.snapshot.playlists.single.name, 'Dopamine');
    expect(applied.playlistReview.single['baseFingerprint'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Set all is a chip on the counts line, not a word', (
    tester,
  ) async {
    final snapshot = snapshotOf(['Dopamine', 'Late night']);
    await pumpForm(
      tester,
      snapshot,
      selectionFor(snapshot),
      surface: const Size(390, 1400),
      sidePadding: 20,
    );

    final chip = tester.widget<LabelChip>(
      find.byKey(CollectionReviewForm.setAllKey),
    );
    expect(chip.label, 'Set all…');
    expect(chip.hole, isFalse, reason: 'no reel hole on an action chip');
    final counts = tester.getRect(find.byKey(const Key('collection-summary')));
    final chipRect = tester.getRect(find.byKey(CollectionReviewForm.setAllKey));
    expect(chipRect.left, greaterThan(counts.right));
    expect(
      chipRect.center.dy,
      moreOrLessEquals(counts.center.dy, epsilon: 2),
      reason: 'on the same line as the counts',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Set all applies one choice to every file, and As detected puts '
      'the suggestions back', (tester) async {
    final snapshot = snapshotOf(['Dopamine', 'Late night', 'Rain']);
    final current = await pumpForm(
      tester,
      snapshot,
      selectionFor(snapshot),
      surface: const Size(390, 1800),
      sidePadding: 20,
      paths: const ['a.csv', 'b.csv', 'c.csv'],
    );

    Future<void> setAll(String label) async {
      await tester.ensureVisible(find.byKey(CollectionReviewForm.setAllKey));
      await tester.pump();
      await tester.tap(find.byKey(CollectionReviewForm.setAllKey));
      await tester.pumpAndSettle();
      expect(find.byKey(mixtapeMenuCancelKey), findsOneWidget);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await setAll('All as liked songs');
    expect(current().files.map((f) => f.role), everyElement('liked'));

    await setAll('Skip all');
    expect(current().files.map((f) => f.role), everyElement('skip'));

    await setAll('All as playlists');
    expect(current().files.map((f) => f.role), everyElement('playlist'));

    // A file renamed and set aside comes back to its own suggestion.
    await tester.enterText(
      find.byKey(const ValueKey('collection-name-1')),
      'Something else',
    );
    await tester.pumpAndSettle();
    await setAll('Skip all');
    expect(current().files[1].name, 'Something else');

    await setAll('As detected');
    expect(current().files.map((f) => f.role), everyElement('playlist'));
    expect(current().files.map((f) => f.name), [
      'Dopamine',
      'Late night',
      'Rain',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement target is chosen from a sheet of inset rows', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    final initial = selectionFor(
      parsed.snapshot,
      playlists: const [attachCandidate],
    );
    final current = await pumpForm(tester, parsed.snapshot, initial);

    await tester.ensureVisible(
      find.byKey(const ValueKey('collection-target-0')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('collection-target-0')));
    await tester.pumpAndSettle();

    expect(find.byType(InsetGroup), findsWidgets);
    await tester.tap(
      find.byKey(
        const ValueKey('collection-target-0-option-spotify:playlist:1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(current().files.single.target, 'spotify:playlist:1');
    expect(find.text('Replace: Late night'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark', (tester) async {
    final parsed = await parseSample(tester);
    await pumpForm(
      tester,
      parsed.snapshot,
      selectionFor(parsed.snapshot),
      brightness: Brightness.dark,
    );

    expect(find.byKey(CollectionReviewForm.setAllKey), findsOneWidget);
    expect(find.byKey(const ValueKey('collection-file-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the review stage fits the sheet at 390 pt without overflowing', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    var selection = selectionFor(
      parsed.snapshot,
      ids: ['old'],
      playlists: const [
        ImportedCollection(
          key: 'spotify:playlist:1',
          name: 'Songs for the long drive home, part two',
          fingerprint: 'f1',
          fileHash: null,
        ),
      ],
    );
    selection = selection.change(
      files: [selection.files.single.change(role: 'liked')],
      mode: 'replace',
    );
    // The import sheet's own 20 pt of side padding, on an iPhone 15 width.
    await pumpForm(
      tester,
      parsed.snapshot,
      selection,
      surface: const Size(390, 844),
      sidePadding: 20,
    );

    expect(tester.takeException(), isNull);
    // …and at the text scales just under the stacking threshold, where the
    // segments are widest but still side by side.
    for (final scale in const [1.2, 1.4]) {
      await pumpForm(
        tester,
        parsed.snapshot,
        selection,
        surface: const Size(390, 844),
        sidePadding: 20,
        textScale: scale,
      );
      expect(tester.takeException(), isNull, reason: 'at ${scale}x');
    }
    expect(find.textContaining('Remove 1 songs'), findsOneWidget);
    expect(
      tester.getSize(find.byType(CollectionReviewForm)).width,
      lessThanOrEqualTo(350),
    );
    expect(tester.takeException(), isNull);
  });
}
