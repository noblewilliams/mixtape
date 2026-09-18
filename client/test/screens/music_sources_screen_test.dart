import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/library_sync_sheet.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// The restyled screen reads the approved tokens off the ambient theme, so it
/// is pumped under MixtapeTheme rather than the harness's bare MaterialApp.
Future<void> _pumpSources(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Size? size,
  double textScale = 1,
}) async {
  // Only the layout cases resize: the import sheet this screen pushes is
  // another task's file and overflows below its own minimum width.
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const MusicSourcesScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every action the screen declares carries a Key (house rule); the
/// foundation controls are not Material buttons, so they are named here.
void _expectKeyedActions(List<Key> keys) {
  for (final key in keys) {
    expect(find.byKey(key), findsOneWidget, reason: '$key is missing');
  }
}

void main() {
  testWidgets('Apple listeners can add Spotify through the Exportify guide', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'apple',
        hasLibrary: true,
        sources: [musicSource(source: 'apple_live')],
      ),
    );
    await _pumpSources(tester, onboardingContainer(listening: listening));
    await tester.tap(find.byKey(const Key('sources-add-spotify')));
    await tester.pumpAndSettle();
    expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    expect(find.byKey(const Key('open-exportify')), findsOneWidget);
    expect(find.text('Choose files'), findsOneWidget);
    expect(listening.onboarding.chosenService, 'apple');
  });

  final now = DateTime.now();
  final importedAt = DateTime(now.year, 9, 4, 10);

  testWidgets(
    'lists every source with its name, import date, ledger range, and the actions '
    'its kind allows',
    (tester) async {
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
      await _pumpSources(tester, onboardingContainer(listening: listening));

      expect(find.text('Your music'), findsOneWidget);
      expect(find.text('Spotify · extended history'), findsOneWidget);
      expect(find.text('Imported 4 Sep · Mar 2018 → Aug 2026'), findsOneWidget);
      expect(find.text('1 of 2 in'), findsOneWidget);
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.text('Imported 4 Sep'), findsOneWidget);
      expect(find.text('Apple Music · export'), findsOneWidget);
      expect(find.text('Nothing imported yet'), findsOneWidget);

      expect(
        find.byKey(const Key('import-again-spotify_export')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('remove-spotify_export')), findsOneWidget);
      expect(find.byKey(const Key('import-again-apple_live')), findsNothing);
      expect(find.byKey(const Key('remove-apple_live')), findsNothing);
      expect(find.byKey(const Key('import-again-apple_export')), findsNothing);
      expect(find.byKey(const Key('remove-apple_export')), findsOneWidget);
      expect(find.byKey(const Key('browse-playlists')), findsOneWidget);
      _expectKeyedActions(const [
        Key('import-again-spotify_export'),
        Key('remove-spotify_export'),
        Key('remove-apple_export'),
        Key('browse-playlists'),
        MusicSourcesScreen.backKey,
        MusicSourcesScreen.syncKey,
      ]);
    },
  );

  testWidgets('native library without a snapshot date stays connected', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'apple',
        hasLibrary: true,
        sources: [musicSource(source: 'apple_live')],
      ),
    );
    await _pumpSources(tester, onboardingContainer(listening: listening));
    expect(find.text('Apple Music'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byType(StatusWord), findsOneWidget);
    expect(find.text('Nothing connected yet.'), findsNothing);
    expect(find.text('Nothing imported yet'), findsNothing);
  });

  testWidgets('both packages in reads as one row named for both', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(
            packages: ['spotify_account', 'spotify_extended'],
            lastImportedAt: importedAt,
          ),
        ],
      ),
    );
    await _pumpSources(tester, onboardingContainer(listening: listening));

    expect(find.text('Spotify · both packages'), findsOneWidget);
    expect(find.text('Both in'), findsOneWidget);
  });

  testWidgets('nothing connected: an empty state that can start an import', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'spotify'),
    );
    final picker = FakeArchivePicker();
    await _pumpSources(tester, onboardingContainer(listening: listening, picker: picker));

    expect(find.text('Nothing connected yet.'), findsOneWidget);
    _expectKeyedActions(const [
      Key('sources-add-spotify'),
      Key('sources-import'),
    ]);

    await tester.tap(find.byKey(const Key('sources-import')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
  });

  testWidgets('Import again opens the import sheet and picks', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(
            packages: ['spotify_account'],
            lastImportedAt: importedAt,
          ),
        ],
      ),
    );
    final picker = FakeArchivePicker(extendedArchive);
    await _pumpSources(tester, onboardingContainer(listening: listening, picker: picker));

    await tester.tap(find.byKey(const Key('import-again-spotify_export')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets(
    'Import again while an upload is in flight shows where it got to and cancels '
    'nothing',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          sources: [
            musicSource(
              packages: ['spotify_account'],
              lastImportedAt: importedAt,
            ),
          ],
        ),
      );
      final picker = FakeArchivePicker(extendedArchive);
      final service = FakeImportService();
      await _pumpSources(tester, onboardingContainer(
          listening: listening,
          picker: picker,
          importService: service,
        ));
      await tester.tap(find.byKey(const Key('import-again-spotify_export')));
      await tester.pumpAndSettle();
      // The import sheet is another task's restyle in flight; scroll its
      // action into view rather than assuming where it sits.
      await tester.ensureVisible(find.byKey(const Key('import-upload')));
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
      final route =
          ModalRoute.of(tester.element(find.byType(ImportSheet)))!
              as ModalBottomSheetRoute<void>;
      expect(route.isDismissible, isFalse);
    },
  );

  testWidgets(
    'Remove confirms with the copy that says what goes and what stays, then deletes '
    'and refreshes',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          sources: [
            musicSource(
              packages: ['spotify_account'],
              lastImportedAt: importedAt,
            ),
          ],
        ),
      );
      listening.onDeleteSource = (source) async {
        listening.onboarding = onboardingState(chosenService: 'spotify');
        return const DeleteSourceResult(
          deletedDays: 0,
          deletedTracks: 226,
          unlibraried: 214,
        );
      };
      await _pumpSources(tester, onboardingContainer(listening: listening));
      final before = listening.getOnboardingCalls;

      await tester.tap(find.byKey(const Key('remove-spotify_export')));
      await tester.pumpAndSettle();

      expect(find.text('Remove Spotify · account data?'), findsOneWidget);
      expect(
        find.text(
          'Deletes your listening history, liked songs, artists, and playlists from Mixtape. '
          'The DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
        ),
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
    },
  );

  testWidgets('the Apple export row has its own removal copy', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'apple',
        hasLibrary: true,
        sources: [
          musicSource(source: 'apple_export', lastImportedAt: importedAt),
        ],
      ),
    );
    await _pumpSources(tester, onboardingContainer(listening: listening));

    await tester.tap(find.byKey(const Key('remove-apple_export')));
    await tester.pumpAndSettle();

    expect(find.text('Remove Apple Music · export?'), findsOneWidget);
    expect(
      find.textContaining('Your synced Apple Music library stays'),
      findsOneWidget,
    );
  });

  testWidgets('a failed removal keeps the row and says so', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(
            packages: ['spotify_extended'],
            lastImportedAt: importedAt,
          ),
        ],
      ),
    );
    listening.onDeleteSource = (_) async => throw StateError('boom');
    await _pumpSources(tester, onboardingContainer(listening: listening));

    await tester.tap(find.byKey(const Key('remove-spotify_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Spotify · extended history'), findsOneWidget);
    expect(find.text("couldn't remove — try again"), findsOneWidget);
  });

  testWidgets('the Sync cluster opens the shared sync sheet', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'apple',
        hasLibrary: true,
        sources: [musicSource(source: 'apple_live')],
      ),
    );
    await _pumpSources(tester, onboardingContainer(listening: listening));

    await tester.tap(find.byKey(MusicSourcesScreen.syncKey));
    await tester.pumpAndSettle();

    expect(find.byType(LibrarySyncSheet), findsOneWidget);
    expect(find.byKey(LibrarySyncSheet.startKey), findsOneWidget);
  });

  testWidgets('holds at 200% text on a 320 pt phone, in dark', (tester) async {
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
          musicSource(source: 'apple_live'),
        ],
      ),
    );
    await _pumpSources(
      tester,
      onboardingContainer(listening: listening),
      brightness: Brightness.dark,
      size: const Size(320, 844),
      textScale: 2,
    );

    expect(find.byType(FlushRow), findsNWidgets(2));
    expect(find.byKey(const Key('remove-spotify_export')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
