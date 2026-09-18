import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/opened_archive_provider.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// House rule on the native controls: every one carries a Key and a 44 pt
/// target. Replaces `expectInteractiveWidgetsKeyed`, which audits the Material
/// controls these screens no longer build. Covers the foundation controls, the
/// inset rows, the adaptive switches, the segmented controls and the inline
/// privacy link.
void expectNativeControls(WidgetTester tester, Finder root) {
  final controls = find.descendant(
    of: root,
    matching: find.byWidgetPredicate(
      (w) =>
          w is TapeButton ||
          w is LabelChip ||
          w is TextAction ||
          w is InsetRow ||
          w is Switch ||
          w is CupertinoSlidingSegmentedControl ||
          (w is InkWell && w.key == const Key('link-spotify-privacy')),
    ),
  );
  expect(controls, findsWidgets);
  for (final element in controls.evaluate()) {
    expect(
      element.widget.key,
      isNotNull,
      reason: '${element.widget.runtimeType} without a Key',
    );
    expect(
      tester.getSize(find.byWidget(element.widget)).height,
      greaterThanOrEqualTo(44),
      reason: '${element.widget.key} under 44 pt',
    );
  }
}

/// A Home stand-in that opens the sheet the way Home and the sources screen
/// do, so "Make your first mix" has a first route to pop back to.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('host'),
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              key: const Key('open'),
              onPressed: () => showImportSheet(context),
              child: const Text('open'),
            ),
            // How Home opens it over a run in flight, when a file handed to
            // the app arrives mid-upload.
            TextButton(
              key: const Key('open-locked'),
              onPressed: () => showImportSheet(context, dismissible: false),
              child: const Text('open locked'),
            ),
          ],
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

  /// `pumpScreen` builds a bare `MaterialApp`; every foundation control reads
  /// `MixtapeTokens` off the ambient theme, so the host carries one.
  Future<void> pumpHost(
    WidgetTester tester,
    ProviderContainer c, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    Size? surface,
  }) async {
    if (surface != null) {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? MixtapeTheme.dark()
              : MixtapeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const _Host(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester,
    ProviderContainer c, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    Size? surface,
  }) async {
    await pumpHost(
      tester,
      c,
      brightness: brightness,
      textScale: textScale,
      surface: surface,
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  Finder sheet() => find.byType(ImportSheet);

  /// The sheet scrolls inside itself, so a control can sit below the fold —
  /// bring it into view the way a finger would before tapping it.
  Future<void> tapInSheet(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  testWidgets('idle: Choose files picks and inspects, then the inventory shows the file, the '
      'package, the counts, the zone, the files, and the private toggle off', (tester) async {
    final c = container();
    await open(tester, c);
    expect(find.text('Choose files'), findsOneWidget);
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();

    expect(picker.picks, 1);
    expect(find.text('my_spotify_data_extended.zip'), findsOneWidget);
    expect(find.text('38.4 MB'), findsOneWidget);
    expect(
      tester
          .widget<StatusWord>(find.byKey(const Key('import-file-package')))
          .label,
      'Extended streaming history',
    );
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
    final toggle = tester.widget<Switch>(
      find.byKey(const Key('import-private-sessions')),
    );
    expect(toggle.value, isFalse);
    expect(
      find.text('5 plays hidden from followers stay out unless you choose otherwise.'),
      findsOneWidget,
    );
    expect(
      find.text('Only reviewed music leaves this device. Your account details, payments, and IP '
          'addresses are never read.'),
      findsOneWidget,
    );
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Choose a different file'), findsOneWidget);
    expectNativeControls(tester, sheet());
  });

  testWidgets('the private toggle flips the provider; the account package has none', (tester) async {
    final c = container();
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();

    await tapInSheet(tester, const Key('import-private-sessions'));
    await tester.pumpAndSettle();
    expect((c.read(listeningImportProvider) as ImportInventory).includePrivateSessions, isTrue);
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('import-private-sessions')))
          .value,
      isTrue,
    );

    service.preview = accountPreview;
    picker.next = accountArchive;
    await tapInSheet(tester, const Key('import-pick-other'));
    await tester.pumpAndSettle();

    expect(picker.picks, 2);
    expect(find.text('my_spotify_data.zip'), findsOneWidget);
    expect(find.text('1.2 MB'), findsOneWidget);
    expect(
      tester
          .widget<StatusWord>(find.byKey(const Key('import-file-package')))
          .label,
      'Account data',
    );
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
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
  }

  testWidgets('one private play reads in the singular; none replaces the hint and keeps the switch',
      (tester) async {
    await inventoryFor(tester, extendedPreviewWith(privatePlays: 1));
    expect(
      find.text('1 play hidden from followers stays out unless you choose otherwise.'),
      findsOneWidget,
    );

    await tapInSheet(tester, const Key('import-pick-other'));
    service.preview = extendedPreviewWith(privatePlays: 0);
    await tester.pumpAndSettle();
    expect(find.text('No private-session plays in this file.'), findsOneWidget);
    expect(find.textContaining('hidden from followers'), findsNothing);
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('import-private-sessions')))
          .value,
      isFalse,
    );
  });

  testWidgets('skipped rows omit zero parts, read None when nothing was skipped, and years '
      'collapse to one', (tester) async {
    await inventoryFor(tester, extendedPreviewWith(localFiles: 0));
    expect(find.text('12 podcasts'), findsOneWidget);

    await tapInSheet(tester, const Key('import-pick-other'));
    service.preview = extendedPreviewWith(podcasts: 0, localFiles: 1);
    await tester.pumpAndSettle();
    expect(find.text('1 local file'), findsOneWidget);

    await tapInSheet(tester, const Key('import-pick-other'));
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
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('my_spotify_data_extended.zip'), findsOneWidget);
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Import cancelled.'), findsOneWidget);
    expect(find.byKey(const Key('import-pick')), findsOneWidget);
  });

  testWidgets('uploading shows real progress, announces the status as a live region, and can '
      'cancel', (tester) async {
    final c = container();
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
    await tester.pump();

    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('import-progress')),
          )
          .value,
      0,
    );
    expect(find.text('Uploading … · 0%'), findsOneWidget);

    service.report(0.62);
    await tester.pump();

    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('import-progress')),
          )
          .value,
      0.62,
    );
    expect(find.text('Uploading … · 62%'), findsOneWidget);
    final status = tester.widget<Semantics>(find.byKey(const Key('import-status')));
    expect(status.properties.liveRegion, isTrue);
    expect(find.byKey(const Key('import-private-sessions')), findsNothing);
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-cancel'));
    await tester.pumpAndSettle();

    expect(service.cancels, 1);
    expect(find.text('Import cancelled.'), findsOneWidget);
  });

  testWidgets('done: counts, ledger range, the enrichment note, Make your first mix pops to Home, '
      'Import the account data too picks again', (tester) async {
    final c = container();
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
    await tester.pump();
    service.finish(extendedResult());
    await tester.pumpAndSettle();

    expect(find.text('Extended history imported'), findsOneWidget);
    expect(find.text('4,812 tracks · 1,903 days with plays'), findsOneWidget);
    expect(find.text('Ledger'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('import-ledger'))).data,
      'Mar 2018 → Aug 2026',
    );
    expect(find.text('9 rows skipped (podcasts, local files, no track)'), findsOneWidget);
    expect(
      find.text('The DJ starts with what it knows best. More detail arrives over the next hours '
          'as tracks are enriched.'),
      findsOneWidget,
    );
    expect(find.text('Make your first mix'), findsOneWidget);
    expect(find.text('Import the account data too'), findsOneWidget);
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-other'));
    await tester.pumpAndSettle();
    expect(picker.picks, 2);
    expect(find.text('Upload'), findsOneWidget);

    await tapInSheet(tester, const Key('import-upload'));
    await tester.pump();
    service.finish(extendedResult());
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-make-mix'));
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
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
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
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
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
    expectNativeControls(tester, sheet());

    service.importedPath = null;
    await tapInSheet(tester, const Key('import-retry-playlists'));
    await tester.pump();
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    expect(service.importedPath, accountArchive.path);
    expect(picker.picks, 1);
    service.finish(accountResult());
    await tester.pumpAndSettle();
    expect(find.text('Account data imported'), findsOneWidget);

    await tapInSheet(tester, const Key('import-make-mix'));
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
    await tapInSheet(tester, const Key('import-pick'));
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
    await tapInSheet(tester, const Key('import-pick'));
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
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-copy-report'));
    await tester.pumpAndSettle();
    expect(clipboard, [brokenDiagnostics.canonicalJsonString()]);
    expect(clipboard.single, isNot(contains('spotify_track_uri": "')));
    expect(find.text('Report copied'), findsOneWidget);

    service.inspectError = null;
    await tapInSheet(tester, const Key('import-try-another'));
    await tester.pumpAndSettle();
    expect(picker.picks, 2);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('a failure on the way to the server has no report and no expected-files line',
      (tester) async {
    final c = container();
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
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

  testWidgets('the sheet says it is showing while it is up, wherever it was opened from',
      (tester) async {
    final c = container();
    await pumpHost(tester, c);
    expect(importSheetShowing, isFalse);

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(importSheetShowing, isTrue);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(importSheetShowing, isFalse);
  });

  testWidgets('a sheet opened over a run in flight is locked, and is dismissible again the '
      'moment the run lands — with the result still on it', (tester) async {
    final c = container();
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
    await tester.pump();
    // The listener puts the sheet away mid-upload, and a file handed to the
    // app brings it back over the run still going.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(sheet(), findsNothing);
    await tester.tap(find.byKey(const Key('open-locked')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-progress')), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(sheet(), findsOneWidget, reason: 'an upload cannot be dismissed out from under');
    expect(importSheetShowing, isTrue);

    service.finish(extendedResult());
    await tester.pumpAndSettle();

    // The result is on the sheet, and the sheet is a dismissible one now.
    expect(find.byKey(const Key('import-done-title')), findsOneWidget);
    expect(importSheetShowing, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(sheet(), findsNothing);
    expect(importSheetShowing, isFalse);
  });

  testWidgets('a result offers the file handed over while the run was going, and Import it '
      'starts that file without the picker', (tester) async {
    final opened = FakeOpenedArchiveSource(pending: handedOverArchive);
    listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    service = FakeImportService();
    picker = FakeArchivePicker(extendedArchive);
    final c = onboardingContainer(
      listening: listening,
      importService: service,
      picker: picker,
      opened: opened,
    );
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    await tapInSheet(tester, const Key('import-upload'));
    await tester.pump();
    service.finish(extendedResult());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('import-done-title')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('import-waiting-file'))).data,
      'Another file is waiting: ${handedOverArchive.name}',
    );
    expectNativeControls(tester, sheet());

    await tapInSheet(tester, const Key('import-waiting-start'));
    await tester.pumpAndSettle();

    expect(service.inspected, [extendedArchive.path, handedOverArchive.path]);
    expect(picker.picks, 1, reason: 'only the first file went through the picker');
    expect(c.read(openedArchiveProvider), isNull, reason: 'taken exactly once');
    expect(find.byKey(const Key('import-waiting-file')), findsNothing);
  });

  testWidgets('a failed run offers the waiting file too, and an unreadable hand-over is named',
      (tester) async {
    final opened = FakeOpenedArchiveSource();
    listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    service = FakeImportService()..inspectError = NetworkException('offline');
    picker = FakeArchivePicker(extendedArchive);
    final c = onboardingContainer(
      listening: listening,
      importService: service,
      picker: picker,
      opened: opened,
    );
    await open(tester, c);
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-failed-title')), findsOneWidget);

    // The file could not even be copied out of its security scope: there is
    // nothing to parse, only a name.
    c.read(openedArchiveProvider);
    opened.handUnreadable('my_spotify_data.zip');
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('import-waiting-file'))).data,
      'Another file is waiting: my_spotify_data.zip',
    );

    await tapInSheet(tester, const Key('import-waiting-start'));
    await tester.pumpAndSettle();

    expect(service.inspected, [extendedArchive.path], reason: 'there is no file to read');
    expect(find.text("Couldn't read this export"), findsOneWidget);
    expect(find.textContaining('my_spotify_data.zip'), findsOneWidget);
  });

  testWidgets('the inventory renders in dark and scrolls inside the sheet at '
      '200% text on a 320 pt screen', (tester) async {
    final c = container();
    await open(
      tester,
      c,
      brightness: Brightness.dark,
      textScale: 2,
      surface: const Size(320, 700),
    );
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();

    expect(find.text('my_spotify_data_extended.zip'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The sheet itself never grows past its share of the screen; the content
    // scrolls inside it.
    expect(
      tester.getSize(sheet()).height,
      lessThanOrEqualTo(700 * ImportSheet.maxHeightFactor + 1),
    );
    expect(
      find.descendant(of: sheet(), matching: find.byType(Scrollable)),
      findsWidgets,
    );
    await tester.ensureVisible(find.byKey(const Key('import-upload')));
    await tester.pump();
    expectNativeControls(tester, sheet());
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a 390 pt sheet without overflowing and lifts its content '
      'clear of the keyboard', (tester) async {
    final c = container();
    await open(tester, c, surface: const Size(390, 844));
    await tapInSheet(tester, const Key('import-pick'));
    await tester.pumpAndSettle();

    expect(find.text('my_spotify_data_extended.zip'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(sheet()).width, lessThanOrEqualTo(390));
    expectNativeControls(tester, sheet());

    // The keyboard's inset becomes padding under the content, so a field at
    // the bottom of the review scrolls above it rather than behind it.
    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(of: sheet(), matching: find.byType(SingleChildScrollView)),
    );
    final before = (scroll.padding! as EdgeInsets).bottom;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final lifted = tester.widget<SingleChildScrollView>(
      find.descendant(of: sheet(), matching: find.byType(SingleChildScrollView)),
    );
    expect((lifted.padding! as EdgeInsets).bottom, before + 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the sheet wears the shared chrome only: one handle, and no dead band '
    'between its content and the bottom of the screen',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      // A phone with a home indicator: the chrome clears it, the sheet does
      // not clear it a second time (smoke round four, note 1).
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);

      final c = container();
      await open(tester, c);

      // One handle in the tree: the shared chrome's.
      expect(find.byKey(MixtapeSheet.handleKey), findsOneWidget);

      final surface = tester.getRect(find.byKey(MixtapeSheet.surfaceKey));
      expect(surface.bottom, moreOrLessEquals(900, epsilon: 0.5));

      // The idle step hugs its content: what is under "Choose files" is the
      // sheet's own bottom padding and the home indicator, nothing else.
      final content = tester.getRect(find.byKey(const Key('import-pick')));
      expect(
        surface.bottom - content.bottom,
        lessThanOrEqualTo(34 + ImportSheet.contentBottomPadding + 1),
      );
    },
  );
}
