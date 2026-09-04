// C5: a Spotify export ZIP tapped in Files or Mail and handed to Mixtape.
// Home is the only route pusher, so the import flow opens from here — for a
// cold start (the archive was waiting when Home mounted) and for a file
// opened while the app is already running.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/opened_archive_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

void main() {
  testWidgets('an archive handed to the app opens the flow on that file, without the picker',
      (tester) async {
    final opened = FakeOpenedArchiveSource(pending: extendedArchive);
    final picker = FakeArchivePicker();
    final service = FakeImportService();
    final container = onboardingContainer(
      listening: FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify')),
      opened: opened,
      picker: picker,
      importService: service,
    );
    await pumpScreen(tester, container, const HomeScreen());

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('import-file-name'))).data,
        extendedArchive.name);
    expect(service.inspected, [extendedArchive.path]);
    expect(picker.picks, 0, reason: 'the listener already chose the file in Files');
    expect(container.read(openedArchiveProvider), isNull, reason: 'consumed exactly once');
  });

  testWidgets('an archive opened mid-upload shows the run where it got to and waits for it',
      (tester) async {
    final opened = FakeOpenedArchiveSource();
    final service = FakeImportService();
    final container = onboardingContainer(
      listening: FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify')),
      opened: opened,
      picker: FakeArchivePicker(extendedArchive),
      importService: service,
    );
    await pumpScreen(tester, container, const HomeScreen());
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
    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('import-progress'))).value,
        0.4);
    expect(service.cancels, cancelsBefore);
    expect(service.importedPath, extendedArchive.path);
    expect(container.read(openedArchiveProvider), accountArchive, reason: 'still waiting');

    service.finish(extendedResult());
    await tester.pumpAndSettle();

    expect(service.inspected, [extendedArchive.path, accountArchive.path]);
    expect(container.read(listeningImportProvider), isA<ImportInventory>());
    expect(find.byType(ImportSheet), findsOneWidget);
    expect(container.read(openedArchiveProvider), isNull);
  });
}
