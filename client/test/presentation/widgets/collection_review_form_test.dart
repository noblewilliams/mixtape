import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/collection_review.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';
import 'package:mixtape/presentation/widgets/collection_review_form.dart';

void main() {
  testWidgets(
    'review stays usable on a narrow screen with large text and requires explicit likes replacement',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final archive = openExportArchive(
        File('../fixtures/exportify/sample.csv'),
      );
      final parsed = (await tester.runAsync(
        () => parseExport(archive, const ParseOptions(timeZone: 'UTC')),
      ))!;
      await archive.close();
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (context, setState) => CollectionReviewForm(
                    snapshot: parsed.snapshot,
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
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Remove 1 songs'), findsOneWidget);
      expect(selection.canUpload(parsed.snapshot), isFalse);
      for (final checkbox
          in find.byType(CheckboxListTile).evaluate().toList()) {
        final finder = find.byWidget(checkbox.widget);
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }
      expect(selection.canUpload(parsed.snapshot), isTrue);
      expect(
        selection.apply(parsed.snapshot).snapshot.library.single.dateAdded,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
