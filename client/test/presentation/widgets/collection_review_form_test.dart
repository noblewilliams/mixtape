import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/collection_review.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/collection_review_form.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';

Future<ParsedExport> parseSample(WidgetTester tester) async {
  final archive = openExportArchive(File('../fixtures/exportify/sample.csv'));
  final parsed = (await tester.runAsync(
    () => parseExport(archive, const ParseOptions(timeZone: 'UTC')),
  ))!;
  await archive.close();
  return parsed;
}

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
                paths: const ['sample.csv'],
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

void main() {
  testWidgets(
    'review stays usable on a narrow screen with large text and requires explicit likes replacement',
    (tester) async {
      final parsed = await parseSample(tester);
      var selection = CollectionSelection.initial(
        parsed.snapshot,
        const CollectionContext(
          ids: ['old'],
          fingerprint: 'current',
          playlists: [],
        ),
      );
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
      // Above 150% text the segmented controls stack into inset rows, so the
      // three-way choice still fits 320 pt.
      expect(
        find.byType(CupertinoSlidingSegmentedControl<String>),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('collection-role-0')), findsOneWidget);

      for (final key in const [
        Key('collection-confirm-removals'),
        Key('collection-confirmed'),
      ]) {
        await tester.ensureVisible(find.byKey(key));
        await tester.pump();
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
      }
      expect(current().canUpload(parsed.snapshot), isTrue);
      expect(
        current().apply(parsed.snapshot).snapshot.library.single.dateAdded,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the role choice is a sliding segmented control at normal text', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    final initial = CollectionSelection.initial(
      parsed.snapshot,
      const CollectionContext(
        ids: [],
        fingerprint: 'current',
        playlists: [],
      ),
    );
    final current = await pumpForm(tester, parsed.snapshot, initial);

    expect(
      find.byType(CupertinoSlidingSegmentedControl<String>),
      findsOneWidget,
    );
    expect(current().files.single.role, 'playlist');
    expect(find.text('Playlist'), findsOneWidget);
    expect(find.text('Liked Songs'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    // A playlist file names where it lands, as an inset row with a chevron.
    expect(find.byKey(const ValueKey('collection-target-0')), findsOneWidget);
    expect(find.text('Create new playlist'), findsOneWidget);

    await tester.tap(find.text('Liked Songs'));
    await tester.pumpAndSettle();
    expect(current().files.single.role, 'liked');
    // Choosing Liked Songs brings the update choice and clears the target row.
    expect(find.byKey(const ValueKey('collection-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('collection-target-0')), findsNothing);
    expect(current().confirmed, isFalse, reason: 'a role change re-opens the review');

    await tester.tap(find.byKey(const Key('collection-confirmed')));
    await tester.pumpAndSettle();
    expect(current().confirmed, isTrue);
    expect(current().canUpload(parsed.snapshot), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement target is chosen from a sheet of inset rows', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    final initial = CollectionSelection.initial(
      parsed.snapshot,
      const CollectionContext(
        ids: [],
        fingerprint: 'current',
        playlists: [
          ImportedCollection(
            key: 'spotify:playlist:1',
            name: 'Late night',
            fingerprint: 'f1',
            fileHash: null,
          ),
        ],
      ),
    );
    final current = await pumpForm(tester, parsed.snapshot, initial);

    await tester.ensureVisible(find.byKey(const ValueKey('collection-target-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('collection-target-0')));
    await tester.pumpAndSettle();

    expect(find.byType(InsetGroup), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey('collection-target-0-option-spotify:playlist:1')),
    );
    await tester.pumpAndSettle();

    expect(current().files.single.target, 'spotify:playlist:1');
    expect(find.text('Replace: Late night'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark', (tester) async {
    final parsed = await parseSample(tester);
    final initial = CollectionSelection.initial(
      parsed.snapshot,
      const CollectionContext(
        ids: [],
        fingerprint: 'current',
        playlists: [],
      ),
    );
    await pumpForm(
      tester,
      parsed.snapshot,
      initial,
      brightness: Brightness.dark,
    );

    expect(find.text('Review your music'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the review stage fits the sheet at 390 pt without overflowing', (
    tester,
  ) async {
    final parsed = await parseSample(tester);
    var selection = CollectionSelection.initial(
      parsed.snapshot,
      const CollectionContext(
        ids: ['old'],
        fingerprint: 'current',
        playlists: [
          ImportedCollection(
            key: 'spotify:playlist:1',
            name: 'Songs for the long drive home, part two',
            fingerprint: 'f1',
            fileHash: null,
          ),
        ],
      ),
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
    expect(find.text('Review your music'), findsOneWidget);
    expect(find.textContaining('Remove 1 songs'), findsOneWidget);
    expect(
      tester.getSize(find.byType(CollectionReviewForm)).width,
      lessThanOrEqualTo(350),
    );
    expect(tester.takeException(), isNull);
  });
}
