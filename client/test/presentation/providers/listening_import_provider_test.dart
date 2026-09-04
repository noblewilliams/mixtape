import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_import_service.dart';
import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeListeningApi listening;
  late FakeImportService service;
  late FakeArchivePicker picker;
  late FakeOpenedArchiveSource opened;
  late List<String> diagnosed;

  ProviderContainer container({TestAuthNotifier? auth, String timeZone = 'Africa/Lagos'}) {
    listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    service = FakeImportService();
    picker = FakeArchivePicker(extendedArchive);
    opened = FakeOpenedArchiveSource();
    diagnosed = [];
    return onboardingContainer(
      listening: listening,
      importService: service,
      picker: picker,
      opened: opened,
      timeZone: timeZone,
      auth: auth,
      diagnoser: (path) async {
        diagnosed.add(path);
        return brokenDiagnostics;
      },
    );
  }

  ListeningImportNotifier notifier(ProviderContainer c) => c.read(listeningImportProvider.notifier);

  test('starts idle and a dismissed picker leaves it idle', () async {
    final c = container();
    picker.next = null;
    expect(c.read(listeningImportProvider), isA<ImportIdle>());

    await notifier(c).pick();

    expect(picker.picks, 1);
    expect(c.read(listeningImportProvider), isA<ImportIdle>());
    expect(service.inspected, isEmpty);
  });

  test('pick inspects the file and lands on the inventory with the device zone and the private '
      'toggle off', () async {
    final c = container();
    final states = <ImportFlowState>[];
    c.listen(listeningImportProvider, (_, next) => states.add(next), fireImmediately: false);

    await notifier(c).pick();

    expect(service.inspected, [extendedArchive.path]);
    expect(states.first, isA<ImportInspecting>());
    final state = c.read(listeningImportProvider) as ImportInventory;
    expect(state.archive, extendedArchive);
    expect(state.inventory, same(extendedInventory));
    expect(state.timeZone, 'Africa/Lagos');
    expect(state.includePrivateSessions, isFalse);
  });

  test('the private-sessions toggle applies to the extended package only', () async {
    final c = container();
    await notifier(c).inspect(extendedArchive);
    notifier(c).setIncludePrivateSessions(true);
    expect((c.read(listeningImportProvider) as ImportInventory).includePrivateSessions, isTrue);
    notifier(c).setIncludePrivateSessions(false);
    expect((c.read(listeningImportProvider) as ImportInventory).includePrivateSessions, isFalse);

    service.preview = accountPreview;
    await notifier(c).inspect(accountArchive);
    notifier(c).setIncludePrivateSessions(true);
    expect((c.read(listeningImportProvider) as ImportInventory).includePrivateSessions, isFalse);
  });

  test('upload drives the service with the zone and toggle, reports progress, lands on done, '
      'and refreshes onboarding', () async {
    final c = container();
    c.listen(onboardingProvider, (_, _) {}, fireImmediately: true);
    await _settle();
    final before = listening.getOnboardingCalls;
    await notifier(c).inspect(extendedArchive);
    notifier(c).setIncludePrivateSessions(true);

    final upload = notifier(c).upload();
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportUploading>());
    expect(service.importedPath, extendedArchive.path);
    expect(service.importedOptions!.timeZone, 'Africa/Lagos');
    expect(service.importedOptions!.includePrivateSessions, isTrue);

    service.report(0.62);
    expect((c.read(listeningImportProvider) as ImportUploading).progress, 0.62);

    service.finish(extendedResult());
    await upload;

    final done = c.read(listeningImportProvider) as ImportDone;
    expect(done.result.summary.tracks, 4812);
    expect(done.archive, extendedArchive);
    expect(listening.getOnboardingCalls, before + 1);
  });

  test('a playlist failure after publication is a partial result, and still refreshes', () async {
    final c = container();
    c.listen(onboardingProvider, (_, _) {}, fireImmediately: true);
    await _settle();
    final before = listening.getOnboardingCalls;
    service.preview = accountPreview;
    await notifier(c).inspect(accountArchive);

    final upload = notifier(c).upload();
    await _settle();
    service.finish(accountResult(playlistError: const ListeningImportProtocolException()));
    await upload;

    final partial = c.read(listeningImportProvider) as ImportPartial;
    expect(partial.result.playlistSummary, isNull);
    expect(partial.result.summary.libraryTracks, 214);
    expect(listening.getOnboardingCalls, before + 1);
  });

  test('Retry playlists re-runs the import on the partial archive with the same options, and '
      'refreshes when it lands', () async {
    final c = container();
    c.listen(onboardingProvider, (_, _) {}, fireImmediately: true);
    await _settle();
    service.preview = accountPreview;
    await notifier(c).inspect(accountArchive);
    final upload = notifier(c).upload();
    await _settle();
    service.finish(accountResult(playlistError: const ListeningImportProtocolException()));
    await upload;
    expect(c.read(listeningImportProvider), isA<ImportPartial>());
    final before = listening.getOnboardingCalls;
    service.importedPath = null;

    final retry = notifier(c).retryPlaylists();
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportUploading>());
    expect(service.importedPath, accountArchive.path);
    expect(service.importedOptions!.timeZone, 'Africa/Lagos');
    expect(service.importedOptions!.includePrivateSessions, isFalse);

    service.finish(accountResult());
    await retry;
    expect((c.read(listeningImportProvider) as ImportDone).result.playlistSummary, isNotNull);
    expect(listening.getOnboardingCalls, before + 1);
  });

  test('cancel during the upload lands on cancelled', () async {
    final c = container();
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();

    notifier(c).cancel();
    await upload;

    expect(service.cancels, 1);
    expect(c.read(listeningImportProvider), isA<ImportFlowCancelled>());
  });

  test('cancel during the inspect lands on cancelled and posts nothing', () async {
    final c = container();
    service.holdInspect = true;
    final inspect = notifier(c).inspect(extendedArchive);
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportInspecting>());

    notifier(c).cancel();
    await inspect;

    expect(c.read(listeningImportProvider), isA<ImportFlowCancelled>());
    expect(listening.funnelEvents, isEmpty);
  });

  test('an unreadable inventory fails with the content-free diagnostics for that file', () async {
    final c = container();
    service.inspectError = brokenError;

    await notifier(c).inspect(extendedArchive);

    final failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.archive, extendedArchive);
    expect(failed.message, contains('Streaming_History_Audio_2021-2023_1.json'));
    expect(failed.diagnostics, same(brokenDiagnostics));
    expect(diagnosed, [extendedArchive.path]);
  });

  test('an archive with none of the expected files, or no ZIP at all, fails with a message '
      'that names what was expected', () async {
    final c = container();
    service.inspectError = const UnreadableExportException(file: null, inventory: ExportInventory.empty);
    await notifier(c).inspect(extendedArchive);
    expect((c.read(listeningImportProvider) as ImportFailed).message, contains('Spotify export'));

    service.inspectError =
        const UnreadableExportException(file: null, inventory: ExportInventory.empty);
    await notifier(c).inspect(extendedArchive);
    final failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.message, contains('ZIP'));
    expect(failed.diagnostics, same(brokenDiagnostics));
  });

  test('a diagnoser failure still reports the failure, without a report', () async {
    final c = onboardingContainer(
      listening: FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify')),
      importService: FakeImportService()..inspectError = brokenError,
      diagnoser: (_) async => throw StateError('no report'),
    );
    await notifier(c).inspect(extendedArchive);
    final failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.diagnostics, isNull);
    expect(failed.unreadable, isTrue);
    expect(failed.diagnosing, isFalse);
    expect(failed.message, isNotEmpty);
  });

  ProviderContainer heldReportContainer(Completer<ExportDiagnostics> report) => onboardingContainer(
        listening: FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify')),
        importService: FakeImportService()..inspectError = brokenError,
        diagnoser: (_) => report.future,
      );

  test('an unreadable file fails at once, before the report is built, and the report attaches '
      'when it arrives', () async {
    final report = Completer<ExportDiagnostics>();
    final c = heldReportContainer(report);
    final inspect = notifier(c).inspect(extendedArchive);
    await _settle();

    var failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.unreadable, isTrue);
    expect(failed.diagnosing, isTrue);
    expect(failed.diagnostics, isNull);
    expect(failed.message, contains('Streaming_History_Audio_2021-2023_1.json'));

    report.complete(brokenDiagnostics);
    await inspect;
    failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.diagnosing, isFalse);
    expect(failed.diagnostics, same(brokenDiagnostics));
  });

  test('cancel while the report is being built lands on cancelled and drops the report', () async {
    final report = Completer<ExportDiagnostics>();
    final c = heldReportContainer(report);
    final inspect = notifier(c).inspect(extendedArchive);
    await _settle();
    expect((c.read(listeningImportProvider) as ImportFailed).diagnosing, isTrue);

    notifier(c).cancel();
    expect(c.read(listeningImportProvider), isA<ImportFlowCancelled>());

    report.complete(brokenDiagnostics);
    await inspect;
    expect(c.read(listeningImportProvider), isA<ImportFlowCancelled>());
  });

  test('a picker that throws fails with a message, no file, and no report', () async {
    final c = container();
    picker.error = StateError('no document picker');

    await notifier(c).pick();

    final failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.message, "Couldn't open the file picker. Try again.");
    expect(failed.archive, isNull);
    expect(failed.unreadable, isFalse);
    expect(failed.diagnostics, isNull);
    expect(service.inspected, isEmpty);
  });

  test('upload failures map to messages: offline, server, protocol, and a broken parse', () async {
    Future<ImportFailed> failWith(Object error) async {
      final c = container();
      await notifier(c).inspect(extendedArchive);
      final upload = notifier(c).upload();
      await _settle();
      service.fail(error);
      await upload;
      return c.read(listeningImportProvider) as ImportFailed;
    }

    expect((await failWith(NetworkException(Exception("offline")))).message, contains('connection'));
    expect(
      (await failWith(ApiException(409, '{"error":"sync_conflict"}'))).message,
      contains('still open'),
    );
    expect((await failWith(ApiException(500, 'boom'))).message, contains('our end'));
    expect(
      (await failWith(const ListeningImportProtocolException())).message,
      contains("didn't match"),
    );
    final parse = await failWith(
      const UnreadableExportException(file: 'YourLibrary.json', inventory: ExportInventory.empty),
    );
    expect(parse.message, contains('YourLibrary.json'));
    expect(parse.diagnostics, same(brokenDiagnostics));
  });

  test('a protocol failure on the upload still refreshes onboarding: the mismatch can come '
      'after the history was published', () async {
    final c = container();
    c.listen(onboardingProvider, (_, _) {}, fireImmediately: true);
    await _settle();
    final before = listening.getOnboardingCalls;
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();

    service.fail(const ListeningImportProtocolException());
    await upload;

    expect(c.read(listeningImportProvider), isA<ImportFailed>());
    expect(listening.getOnboardingCalls, before + 1);
  });

  test('a new upload inside the cancel window never joins the cancelled run: it waits for that '
      'run to settle, then proceeds with the new file and options', () async {
    final c = container();
    service.holdCancel = true;
    await notifier(c).inspect(extendedArchive);
    notifier(c).setIncludePrivateSessions(true);
    final first = notifier(c).upload();
    await _settle();

    notifier(c).reset();
    service.preview = accountPreview;
    await notifier(c).inspect(accountArchive);
    final second = notifier(c).upload();
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportUploading>());
    expect(service.importedPath, extendedArchive.path, reason: 'the fresh run waits for the old one');

    service.settleCancelled();
    await first;
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportUploading>());
    expect(service.importedPath, accountArchive.path);
    expect(service.importedOptions!.includePrivateSessions, isFalse);

    service.finish(accountResult());
    await second;
    expect((c.read(listeningImportProvider) as ImportDone).archive, accountArchive);
  });

  test('reset returns to idle and cancels whatever is running', () async {
    final c = container();
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();

    notifier(c).reset();
    expect(c.read(listeningImportProvider), isA<ImportIdle>());
    await upload;
    // The cancelled run must not overwrite the reset.
    expect(c.read(listeningImportProvider), isA<ImportIdle>());
    expect(service.cancels, 1);
  });

  test('a sign-out resets the flow and cancels the service; what the cancelled run reports '
      'after that is dropped: no cancelled state over the fresh idle, no onboarding refresh '
      'while signed out', () async {
    final auth = TestAuthNotifier(AuthStatus.signedIn);
    final c = container(auth: auth);
    c.listen(listeningImportProvider, (_, _) {});
    c.listen(onboardingProvider, (_, _) {}, fireImmediately: true);
    service.holdCancel = true;
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportUploading>());

    auth.set(AuthStatus.signedOut);
    await _settle();
    expect(c.read(listeningImportProvider), isA<ImportIdle>());
    expect(service.cancels, greaterThanOrEqualTo(1));
    final before = listening.getOnboardingCalls;

    service.settleCancelled();
    await upload;
    await _settle();

    expect(c.read(listeningImportProvider), isA<ImportIdle>());
    expect(listening.getOnboardingCalls, before);
  });

  // C5 privacy: a file handed to the app from Files or Mail was copied into
  // the app's own temporary directory. That copy is the listener's whole
  // export — the identity and payment files the parser refuses to read
  // included — so it goes the moment the run is over.
  test('the copy of a handed-over archive is deleted once the import lands', () async {
    final c = container();
    await notifier(c).inspect(handedOverArchive, handedOver: true);
    final upload = notifier(c).upload();
    await _settle();
    expect(opened.discarded, isEmpty, reason: 'the run is still reading it');

    service.finish(extendedResult());
    await upload;

    expect(c.read(listeningImportProvider), isA<ImportDone>());
    expect(opened.discarded, [handedOverArchive]);
  });

  test('a handed-over archive the listener cancelled, reset, or failed on is deleted too',
      () async {
    for (final land in [
      (ListeningImportNotifier n) => n.cancel(),
      (ListeningImportNotifier n) => n.reset(),
    ]) {
      final c = container();
      await notifier(c).inspect(handedOverArchive, handedOver: true);
      final upload = notifier(c).upload();
      await _settle();

      land(notifier(c));
      await upload;
      await _settle();

      expect(opened.discarded, [handedOverArchive]);
    }

    final c = container();
    service.inspectError = brokenError;
    await notifier(c).inspect(handedOverArchive, handedOver: true);
    await _settle();

    expect(c.read(listeningImportProvider), isA<ImportFailed>());
    expect(diagnosed, [handedOverArchive.path], reason: 'the report is built before the delete');
    expect(opened.discarded, [handedOverArchive]);
  });

  test('a file the listener picked here is never deleted: it is theirs, not our copy', () async {
    final c = container();
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();
    service.finish(extendedResult());
    await upload;

    expect(c.read(listeningImportProvider), isA<ImportDone>());
    expect(opened.discarded, isEmpty);
  });

  test('a partial keeps the copy only while a retry would have to read it again', () async {
    final c = container();
    await notifier(c).inspect(handedOverArchive, handedOver: true);
    final upload = notifier(c).upload();
    await _settle();
    service.finish(accountResult(playlistError: 'nope'));
    await upload;

    // "Retry playlists" re-runs from the preview, never from the file.
    expect(c.read(listeningImportProvider), isA<ImportPartial>());
    expect(opened.discarded, [handedOverArchive]);
  });

  test('a file the app could not copy at all fails by name, and never over a run in flight',
      () async {
    final c = container();
    await notifier(c).inspect(extendedArchive);
    final upload = notifier(c).upload();
    await _settle();

    notifier(c).handOverFailed('my_spotify_data.zip');
    expect(c.read(listeningImportProvider), isA<ImportUploading>(),
        reason: 'the run in flight is never thrown away');

    service.finish(extendedResult());
    await upload;
    notifier(c).handOverFailed('my_spotify_data.zip');

    final failed = c.read(listeningImportProvider) as ImportFailed;
    expect(failed.unreadable, isTrue);
    expect(failed.message, contains('my_spotify_data.zip'));
    expect(failed.archive, isNull);
    expect(failed.diagnosing, isFalse, reason: 'there is no file here to report on');
  });
}
