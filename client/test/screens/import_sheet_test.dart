import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// A Home stand-in that opens the sheet the way Home and the sources screen
/// do, so "Make your first mix" has a first route to pop back to.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('host'),
        body: Center(
          child: TextButton(
            key: const Key('open'),
            onPressed: () => showImportSheet(context),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  late FakeListeningApi listening;
  late FakeImportService service;
  late FakeArchivePicker picker;

  ProviderContainer container() {
    listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    service = FakeImportService();
    picker = FakeArchivePicker(extendedArchive);
    return onboardingContainer(listening: listening, importService: service, picker: picker);
  }

  Future<void> open(WidgetTester tester, ProviderContainer c) async {
    await pumpScreen(tester, c, const _Host());
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  Finder sheet() => find.byType(ImportSheet);

  testWidgets('idle: Choose a ZIP picks and inspects, then the inventory shows the file, the '
      'package, the counts, the zone, the files, and the private toggle off', (tester) async {
    final c = container();
    await open(tester, c);
    expect(find.text('Choose a ZIP'), findsOneWidget);
    expectInteractiveWidgetsKeyed(sheet());

    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    expect(picker.picks, 1);
    expect(find.text('my_spotify_data_extended.zip'), findsOneWidget);
    expect(find.text('38.4 MB · Extended streaming history'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('1,203'), findsOneWidget);
    expect(find.text('Days with plays'), findsOneWidget);
    expect(find.text('486'), findsOneWidget);
    expect(find.text('Years covered'), findsOneWidget);
    expect(find.text('2018 – 2026'), findsOneWidget);
    expect(find.text('Local days in Africa/Lagos'), findsOneWidget);
    expect(find.text('Skipped rows'), findsOneWidget);
    expect(find.text('12 podcasts · 3 local files'), findsOneWidget);
    expect(find.text('54,111'), findsNothing, reason: 'rows read is not a fact the record shows');
    expect(find.text('Streaming_History_Audio_2018-2020_0.json'), findsOneWidget);
    expect(find.text('24,110 rows'), findsOneWidget);
    expect(find.text('Streaming_History_Video_2024_0.json'), findsOneWidget);
    expect(find.text('ReadMeFirst_ExtendedStreamingHistory.pdf'), findsOneWidget);
    expect(find.text('ignored'), findsNWidgets(2));
    expect(find.text('Ignored · never read'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('import-private-sessions')));
    expect(toggle.value, isFalse);
    expect(
      find.text('5 plays hidden from followers stay out unless you choose otherwise.'),
      findsOneWidget,
    );
    expect(
      find.text('Only these plays leave this device. Your account details, payments, and IP '
          'addresses are never read.'),
      findsOneWidget,
    );
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Choose a different file'), findsOneWidget);
    expectInteractiveWidgetsKeyed(sheet());
  });

  testWidgets('the private toggle flips the provider; the account package has none', (tester) async {
    final c = container();
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('import-private-sessions')));
    await tester.pumpAndSettle();
    expect((c.read(listeningImportProvider) as ImportInventory).includePrivateSessions, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('import-private-sessions'))).value, isTrue);

    service.preview = accountPreview;
    picker.next = accountArchive;
    await tester.tap(find.byKey(const Key('import-pick-other')));
    await tester.pumpAndSettle();

    expect(picker.picks, 2);
    expect(find.text('my_spotify_data.zip'), findsOneWidget);
    expect(find.text('1.2 MB · Account data'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('226'), findsOneWidget);
    expect(find.text('Liked songs'), findsOneWidget);
    expect(find.text('214'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('37'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Skipped rows'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Days with plays'), findsNothing);
    expect(find.text('Years covered'), findsNothing);
    expect(find.byKey(const Key('import-private-sessions')), findsNothing);
    expect(find.textContaining('hidden from followers'), findsNothing);
    expect(find.textContaining('Local days in'), findsNothing);
    expect(find.text('YourLibrary.json'), findsOneWidget);
    expect(find.text('Identity.json'), findsOneWidget);
    expect(find.text('ignored'), findsOneWidget);
  });

  Future<void> inventoryFor(WidgetTester tester, ImportPreview preview) async {
    final c = container();
    service.preview = preview;
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
  }

  testWidgets('one private play reads in the singular; none replaces the hint and keeps the switch',
      (tester) async {
    await inventoryFor(tester, extendedPreviewWith(privatePlays: 1));
    expect(
      find.text('1 play hidden from followers stays out unless you choose otherwise.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('import-pick-other')));
    service.preview = extendedPreviewWith(privatePlays: 0);
    await tester.pumpAndSettle();
    expect(find.text('No private-session plays in this file.'), findsOneWidget);
    expect(find.textContaining('hidden from followers'), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('import-private-sessions'))).value, isFalse);
  });

  testWidgets('skipped rows omit zero parts, read None when nothing was skipped, and years '
      'collapse to one', (tester) async {
    await inventoryFor(tester, extendedPreviewWith(localFiles: 0));
    expect(find.text('12 podcasts'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-pick-other')));
    service.preview = extendedPreviewWith(podcasts: 0, localFiles: 1);
    await tester.pumpAndSettle();
    expect(find.text('1 local file'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-pick-other')));
    service.preview = extendedPreviewWith(
      podcasts: 0,
      localFiles: 0,
      ledgerFrom: '2026-01-04',
      ledgerTo: '2026-08-30',
    );
    await tester.pumpAndSettle();
    expect(find.text('None'), findsOneWidget);
    expect(find.text('2026'), findsOneWidget);
    expect(find.textContaining('podcast'), findsNothing);
  });

  testWidgets('inspecting shows the file name with a spinner and a Cancel that lands on cancelled',
      (tester) async {
    final c = container();
    service.holdInspect = true;
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('my_spotify_data_extended.zip'), findsOneWidget);
    expectInteractiveWidgetsKeyed(sheet());

    await tester.tap(find.byKey(const Key('import-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('Import cancelled.'), findsOneWidget);
    expect(find.byKey(const Key('import-pick')), findsOneWidget);
  });

  testWidgets('uploading shows real progress, announces the status as a live region, and can '
      'cancel', (tester) async {
    final c = container();
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();

    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('import-progress'))).value, 0);
    expect(find.text('Uploading … · 0%'), findsOneWidget);

    service.report(0.62);
    await tester.pump();

    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('import-progress'))).value, 0.62);
    expect(find.text('Uploading … · 62%'), findsOneWidget);
    final status = tester.widget<Semantics>(find.byKey(const Key('import-status')));
    expect(status.properties.liveRegion, isTrue);
    expect(find.byKey(const Key('import-private-sessions')), findsNothing);
    expectInteractiveWidgetsKeyed(sheet());

    await tester.tap(find.byKey(const Key('import-cancel')));
    await tester.pumpAndSettle();

    expect(service.cancels, 1);
    expect(find.text('Import cancelled.'), findsOneWidget);
  });

  testWidgets('done: counts, ledger range, the enrichment note, Make your first mix pops to Home, '
      'Import the account data too picks again', (tester) async {
    final c = container();
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    service.finish(extendedResult());
    await tester.pumpAndSettle();

    expect(find.text('Extended history imported'), findsOneWidget);
    expect(find.text('4,812 tracks · 1,903 days with plays'), findsOneWidget);
    expect(find.text('Ledger Mar 2018 → Aug 2026'), findsOneWidget);
    expect(find.text('9 rows skipped (podcasts, local files, no track)'), findsOneWidget);
    expect(
      find.text('The DJ starts with what it knows best. More detail arrives over the next hours '
          'as tracks are enriched.'),
      findsOneWidget,
    );
    expect(find.text('Make your first mix'), findsOneWidget);
    expect(find.text('Import the account data too'), findsOneWidget);
    expectInteractiveWidgetsKeyed(sheet());

    await tester.tap(find.byKey(const Key('import-other')));
    await tester.pumpAndSettle();
    expect(picker.picks, 2);
    expect(find.text('Upload'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    service.finish(extendedResult());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-make-mix')));
    await tester.pumpAndSettle();

    expect(sheet(), findsNothing);
    expect(find.byKey(const Key('host')), findsOneWidget);
    expect(c.read(listeningImportProvider), isA<ImportIdle>());
  });

  testWidgets('done for the account package counts liked songs, artists, and playlists',
      (tester) async {
    final c = container();
    service.preview = accountPreview;
    picker.next = accountArchive;
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    service.finish(accountResult());
    await tester.pumpAndSettle();

    expect(find.text('Account data imported'), findsOneWidget);
    expect(find.text('214 liked songs · 37 artists · 12 playlists'), findsOneWidget);
    expect(find.textContaining('Ledger'), findsNothing);
    expect(find.text('10 playlist entries are still unmatched.'), findsOneWidget);
    expect(find.text('Import the extended history too'), findsOneWidget);
  });

  testWidgets('partial: history published, playlists failed, the web\'s copy, Retry playlists '
      're-uploads the same file, Make a mix anyway', (tester) async {
    final c = container();
    service.preview = accountPreview;
    picker.next = accountArchive;
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    service.finish(accountResult(playlistError: const ListeningImportProtocolException()));
    await tester.pumpAndSettle();

    expect(find.text("Account data imported, playlists didn't land"), findsOneWidget);
    expect(
      find.text('Likes and followed artists are in. The playlist sync was interrupted.'),
      findsOneWidget,
    );
    expect(find.text('214 liked songs · 37 artists'), findsOneWidget);
    expect(
      find.text('Your liked songs and artists are safe on the server. Nothing is lost and nothing '
          'needs re-uploading; the playlists can follow later.'),
      findsOneWidget,
    );
    expect(find.text('Make a mix anyway'), findsOneWidget);
    expect(find.text('Retry playlists'), findsOneWidget);
    expect(find.text('Re-uploads the file; nothing is duplicated.'), findsOneWidget);
    expect(find.byKey(const Key('import-other')), findsNothing);
    expectInteractiveWidgetsKeyed(sheet());

    service.importedPath = null;
    await tester.tap(find.byKey(const Key('import-retry-playlists')));
    await tester.pump();
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    expect(service.importedPath, accountArchive.path);
    expect(picker.picks, 1);
    service.finish(accountResult());
    await tester.pumpAndSettle();
    expect(find.text('Account data imported'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-make-mix')));
    await tester.pumpAndSettle();
    expect(sheet(), findsNothing);
  });

  testWidgets('an unreadable file fails at once and says the report is being built, then shows '
      'it', (tester) async {
    final report = Completer<ExportDiagnostics>();
    listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    service = FakeImportService()..inspectError = brokenError;
    picker = FakeArchivePicker(extendedArchive);
    final c = onboardingContainer(
      listening: listening,
      importService: service,
      picker: picker,
      diagnoser: (_) => report.future,
    );
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't read this export"), findsOneWidget);
    expect(find.textContaining('Expected files'), findsOneWidget);
    expect(find.text('Building the report…'), findsOneWidget);
    expect(find.byKey(const Key('import-diagnostics')), findsNothing);
    expect(find.byKey(const Key('import-copy-report')), findsNothing);
    expect(find.byKey(const Key('import-cancel')), findsNothing);
    expect(find.byKey(const Key('import-try-another')), findsOneWidget);

    report.complete(brokenDiagnostics);
    await tester.pumpAndSettle();
    expect(find.text('Building the report…'), findsNothing);
    expect(find.byKey(const Key('import-diagnostics')), findsOneWidget);
    expect(find.byKey(const Key('import-copy-report')), findsOneWidget);
  });

  testWidgets('failed: the expected file names, the report in a monospace box, Copy report puts '
      'the report on the clipboard, Try another file picks again', (tester) async {
    final c = container();
    service.inspectError = brokenError;
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't read this export"), findsOneWidget);
    expect(find.textContaining("Streaming_History_Audio_2021-2023_1.json couldn't be read"), findsOneWidget);
    expect(
      find.text('Expected files: Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json.'),
      findsOneWidget,
    );
    final box = tester.widget<Text>(find.byKey(const Key('import-diagnostics')));
    expect(box.data, brokenDiagnostics.canonicalJsonString());
    expect(box.style?.fontFamily, 'monospace');
    expect(
      find.text('The report lists file names, sizes, and row counts only. No song, artist, or '
          'personal data.'),
      findsOneWidget,
    );
    expectInteractiveWidgetsKeyed(sheet());

    await tester.ensureVisible(find.byKey(const Key('import-copy-report')));
    await tester.tap(find.byKey(const Key('import-copy-report')));
    await tester.pumpAndSettle();
    expect(clipboard, [brokenDiagnostics.canonicalJsonString()]);
    expect(clipboard.single, isNot(contains('spotify_track_uri": "')));
    expect(find.text('Report copied'), findsOneWidget);

    service.inspectError = null;
    await tester.ensureVisible(find.byKey(const Key('import-try-another')));
    await tester.tap(find.byKey(const Key('import-try-another')));
    await tester.pumpAndSettle();
    expect(picker.picks, 2);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('a failure on the way to the server has no report and no expected-files line',
      (tester) async {
    final c = container();
    await open(tester, c);
    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-upload')));
    await tester.pump();
    service.fail(const ListeningImportProtocolException());
    await tester.pumpAndSettle();

    expect(find.text('Import failed'), findsOneWidget);
    expect(find.textContaining("didn't match"), findsOneWidget);
    expect(find.byKey(const Key('import-diagnostics')), findsNothing);
    expect(find.byKey(const Key('import-copy-report')), findsNothing);
    expect(find.textContaining('Expected files'), findsNothing);
    expect(find.byKey(const Key('import-try-another')), findsOneWidget);
  });
}
