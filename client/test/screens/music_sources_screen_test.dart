import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

void main() {
  final now = DateTime.now();
  final importedAt = DateTime(now.year, 9, 4, 10);

  testWidgets('lists every source with its name, import date, ledger range, and the actions '
      'its kind allows', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(
            packages: ['spotify_extended'],
            lastImportedAt: importedAt,
            ledgerFrom: '2018-03-02',
            ledgerTo: '2026-08-30',
          ),
          musicSource(source: 'apple_live', lastImportedAt: importedAt),
          musicSource(source: 'apple_export'),
        ],
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const MusicSourcesScreen());

    expect(find.text('Your music'), findsOneWidget);
    expect(find.text('Spotify · extended history'), findsOneWidget);
    expect(find.text('Imported 4 Sep · Mar 2018 → Aug 2026'), findsOneWidget);
    expect(find.text('1 of 2 in'), findsOneWidget);
    expect(find.text('Apple Music'), findsOneWidget);
    expect(find.text('Imported 4 Sep'), findsOneWidget);
    expect(find.text('Apple Music · export'), findsOneWidget);
    expect(find.text('Nothing imported yet'), findsOneWidget);

    expect(find.byKey(const Key('import-again-spotify_export')), findsOneWidget);
    expect(find.byKey(const Key('remove-spotify_export')), findsOneWidget);
    expect(find.byKey(const Key('import-again-apple_live')), findsNothing);
    expect(find.byKey(const Key('remove-apple_live')), findsNothing);
    expect(find.byKey(const Key('import-again-apple_export')), findsNothing);
    expect(find.byKey(const Key('remove-apple_export')), findsOneWidget);
    expectInteractiveWidgetsKeyed(find.byType(MusicSourcesScreen));
  });

  testWidgets('both packages in reads as one row named for both', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(packages: ['spotify_account', 'spotify_extended'], lastImportedAt: importedAt),
        ],
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const MusicSourcesScreen());

    expect(find.text('Spotify · both packages'), findsOneWidget);
    expect(find.text('Both in'), findsOneWidget);
  });

  testWidgets('nothing connected: an empty state that can start an import', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    final picker = FakeArchivePicker();
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, picker: picker),
      const MusicSourcesScreen(),
    );

    expect(find.text('Nothing connected yet.'), findsOneWidget);
    expectInteractiveWidgetsKeyed(find.byType(MusicSourcesScreen));

    await tester.tap(find.byKey(const Key('sources-import')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
  });

  testWidgets('Import again opens the import sheet and picks', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [musicSource(packages: ['spotify_account'], lastImportedAt: importedAt)],
      ),
    );
    final picker = FakeArchivePicker(extendedArchive);
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, picker: picker),
      const MusicSourcesScreen(),
    );

    await tester.tap(find.byKey(const Key('import-again-spotify_export')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('Import again while an upload is in flight shows where it got to and cancels '
      'nothing', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [musicSource(packages: ['spotify_account'], lastImportedAt: importedAt)],
      ),
    );
    final picker = FakeArchivePicker(extendedArchive);
    final service = FakeImportService();
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, picker: picker, importService: service),
      const MusicSourcesScreen(),
    );
    await tester.tap(find.byKey(const Key('import-again-spotify_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    Navigator.of(tester.element(find.byType(ImportSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ImportSheet), findsNothing);
    // reset() before the first pick counted one cancel; re-entry adds none.
    final cancelsBefore = service.cancels;

    await tester.tap(find.byKey(const Key('import-again-spotify_export')));
    await tester.pumpAndSettle();

    expect(service.cancels, cancelsBefore);
    expect(service.running, isTrue);
    expect(picker.picks, 1);
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(ImportSheet)))! as ModalBottomSheetRoute<void>;
    expect(route.isDismissible, isFalse);
  });

  testWidgets('Remove confirms with the copy that says what goes and what stays, then deletes '
      'and refreshes', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [musicSource(packages: ['spotify_account'], lastImportedAt: importedAt)],
      ),
    );
    listening.onDeleteSource = (source) async {
      listening.onboarding = onboardingState(chosenService: 'spotify');
      return const DeleteSourceResult(deletedDays: 0, deletedTracks: 226, unlibraried: 214);
    };
    await pumpScreen(tester, onboardingContainer(listening: listening), const MusicSourcesScreen());
    final before = listening.getOnboardingCalls;

    await tester.tap(find.byKey(const Key('remove-spotify_export')));
    await tester.pumpAndSettle();

    expect(find.text('Remove Spotify · account data?'), findsOneWidget);
    expect(
      find.text('Deletes your listening history, liked songs, artists, and playlists from Mixtape. '
          'The DJ forgets nothing you told it in the interview, and the songs you pasted stay.'),
      findsOneWidget,
    );
    expectInteractiveWidgetsKeyed(find.byType(AlertDialog));

    await tester.tap(find.byKey(const Key('remove-keep')));
    await tester.pumpAndSettle();
    expect(listening.deletedSources, isEmpty);
    expect(find.text('Spotify · account data'), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-spotify_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-confirm')));
    await tester.pumpAndSettle();

    expect(listening.deletedSources, ['spotify_export']);
    expect(listening.getOnboardingCalls, before + 1);
    expect(find.text('Spotify · account data'), findsNothing);
    expect(find.text('Nothing connected yet.'), findsOneWidget);
  });

  testWidgets('the Apple export row has its own removal copy', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'apple',
        hasLibrary: true,
        sources: [musicSource(source: 'apple_export', lastImportedAt: importedAt)],
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const MusicSourcesScreen());

    await tester.tap(find.byKey(const Key('remove-apple_export')));
    await tester.pumpAndSettle();

    expect(find.text('Remove Apple Music · export?'), findsOneWidget);
    expect(find.textContaining('Your synced Apple Music library stays'), findsOneWidget);
  });

  testWidgets('a failed removal keeps the row and says so', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [musicSource(packages: ['spotify_extended'], lastImportedAt: importedAt)],
      ),
    );
    listening.onDeleteSource = (_) async => throw StateError('boom');
    await pumpScreen(tester, onboardingContainer(listening: listening), const MusicSourcesScreen());

    await tester.tap(find.byKey(const Key('remove-spotify_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Spotify · extended history'), findsOneWidget);
    expect(find.text("couldn't remove — try again"), findsOneWidget);
  });
}
