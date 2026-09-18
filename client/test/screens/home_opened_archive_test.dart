// C5: a Spotify export ZIP tapped in Files or Mail and handed to Mixtape.
// Home is the only route pusher, so the import flow opens from here — for a
// cold start (the archive was waiting when Home mounted) and for a file
// opened while the app is already running.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/new_mix_inspiration_provider.dart';
import 'package:mixtape/presentation/providers/opened_archive_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// Home under the native theme, on a surface tall enough that the whole
/// waiting card clears the bottom panel (task 3.3 turns the card into the
/// board's two flush rows; here it only moved into the open space). The width
/// is the test default, so the sheets these tests open keep the room they
/// were written against.
Future<void> pumpHome(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MixtapeTheme.light(), home: const HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'an archive handed to the app opens the flow on that file, without the picker',
    (tester) async {
      final opened = FakeOpenedArchiveSource(pending: extendedArchive);
      final picker = FakeArchivePicker();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: picker,
        importService: service,
      );
      await pumpHome(tester, container);

      expect(find.byType(ImportSheet), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('import-file-name'))).data,
        extendedArchive.name,
      );
      expect(service.inspected, [extendedArchive.path]);
      expect(
        picker.picks,
        0,
        reason: 'the listener already chose the file in Files',
      );
      expect(
        container.read(openedArchiveProvider),
        isNull,
        reason: 'consumed exactly once',
      );
    },
  );

  testWidgets(
    'an archive opened mid-upload shows the run where it got to, and the run\'s own '
    'result offers the waiting file rather than replacing itself with it',
    (tester) async {
      final opened = FakeOpenedArchiveSource();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: FakeArchivePicker(extendedArchive),
        importService: service,
      );
      await pumpHome(tester, container);
      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-upload')));
      await tester.pump();
      service.report(0.4);
      await tester.pump();
      final cancelsBefore = service.cancels;

      opened.hand(accountArchive);
      await tester.pumpAndSettle();

      // The re-entry rule: the run is never reset, and only one sheet is up.
      expect(find.byType(ImportSheet), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('import-progress')),
            )
            .value,
        0.4,
      );
      expect(service.cancels, cancelsBefore);
      expect(service.importedPath, extendedArchive.path);
      expect(
        container.read(openedArchiveProvider),
        handed(accountArchive),
        reason: 'still waiting',
      );

      service.finish(extendedResult());
      await tester.pumpAndSettle();

      // The result this listener has not read yet stays on screen; the file
      // that arrived during it is offered, not started.
      expect(find.byKey(const Key('import-done-title')), findsOneWidget);
      expect(service.inspected, [extendedArchive.path]);
      expect(
        tester.widget<Text>(find.byKey(const Key('import-waiting-file'))).data,
        'Another file is waiting: ${accountArchive.name}',
      );

      await tester.tap(find.byKey(const Key('import-waiting-start')));
      await tester.pumpAndSettle();

      expect(service.inspected, [extendedArchive.path, accountArchive.path]);
      expect(container.read(openedArchiveProvider), isNull);
      expect(find.byType(ImportSheet), findsOneWidget);
    },
  );

  testWidgets(
    'a sheet the listener put away mid-upload comes back locked for a handed file, '
    'and is theirs again — result and all — the moment the run lands',
    (tester) async {
      final opened = FakeOpenedArchiveSource();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: FakeArchivePicker(extendedArchive),
        importService: service,
      );
      await pumpHome(tester, container);
      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-upload')));
      await tester.pump();
      service.report(0.4);
      await tester.pumpAndSettle();

      // Put away: the upload keeps going without it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsNothing);

      opened.hand(accountArchive);
      await tester.pumpAndSettle();

      // Back over the upload, and locked while it runs: dismissing it would
      // hide a run the listener cannot see anywhere else.
      expect(find.byKey(const Key('import-progress')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsOneWidget);

      service.finish(extendedResult());
      await tester.pumpAndSettle();

      // The first run's result is shown, the waiting file is offered, and the
      // sheet is no longer holding anyone.
      expect(find.byKey(const Key('import-done-title')), findsOneWidget);
      expect(find.byKey(const Key('import-waiting-start')), findsOneWidget);
      expect(
        find.byType(ImportSheet),
        findsOneWidget,
        reason: 'never two sheets',
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byType(ImportSheet), findsNothing);
      expect(container.read(openedArchiveProvider), handed(accountArchive));
    },
  );

  testWidgets(
    'a sheet the listener dismissed with a file still waiting does not come back on an '
    'unrelated rebuild',
    (tester) async {
      final opened = FakeOpenedArchiveSource();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: FakeArchivePicker(extendedArchive),
        importService: service,
      );
      await pumpHome(tester, container);
      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-upload')));
      await tester.pump();
      service.finish(extendedResult());
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsNothing);

      // A file arrives while the flow sits on that result: the sheet comes up
      // once with the offer, and the listener puts it away again.
      opened.hand(accountArchive);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('import-waiting-start')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsNothing);

      // Anything else that rebuilds Home — the composer's attachment, here,
      // now that the mix list lives in the Mixes tab.
      container.invalidate(newMixInspirationProvider);
      await tester.pumpAndSettle();

      expect(
        find.byType(ImportSheet),
        findsNothing,
        reason: 'they put it away',
      );
      expect(
        container.read(openedArchiveProvider),
        handed(accountArchive),
        reason: 'still waiting',
      );
      expect(service.inspected, [extendedArchive.path]);
    },
  );

  testWidgets(
    'a handed file never stacks a second sheet over the one the sources screen opened, '
    'and is dealt with when the listener comes back',
    (tester) async {
      final opened = FakeOpenedArchiveSource();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: FakeArchivePicker(),
        importService: service,
      );
      await pumpHome(tester, container);
      // The Library tab owns this entry now (task 2.2); what this case is
      // about is the one sheet, wherever it was opened from.
      Navigator.of(tester.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const MusicSourcesScreen()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MusicSourcesScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('sources-import')));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsOneWidget);

      opened.hand(accountArchive);
      await tester.pumpAndSettle();

      expect(
        find.byType(ImportSheet),
        findsOneWidget,
        reason: 'one sheet, wherever it came from',
      );

      // Put the sources screen's sheet away, go back, and the file that was
      // waiting all along opens the flow — once.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MusicSourcesScreen.backKey));
      await tester.pumpAndSettle();

      expect(find.byType(ImportSheet), findsOneWidget);
      expect(service.inspected, [accountArchive.path]);
      expect(container.read(openedArchiveProvider), isNull);
    },
  );

  testWidgets(
    'a file that waited for a run gets its look when the run ends, even with the sheet '
    'put away',
    (tester) async {
      final opened = FakeOpenedArchiveSource();
      final service = FakeImportService();
      final container = onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
        opened: opened,
        picker: FakeArchivePicker(extendedArchive),
        importService: service,
      );
      await pumpHome(tester, container);
      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-upload')));
      await tester.pump();
      opened.hand(accountArchive);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsNothing);

      service.finish(extendedResult());
      await tester.pumpAndSettle();

      // The run it waited for has landed, and the result it landed on is where
      // the waiting file is offered.
      expect(find.byKey(const Key('import-done-title')), findsOneWidget);
      expect(find.byKey(const Key('import-waiting-start')), findsOneWidget);
      expect(container.read(openedArchiveProvider), handed(accountArchive));
    },
  );
}
