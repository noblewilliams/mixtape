// The import flow's state machine: pick a ZIP, inspect it, show the
// inventory, upload, and land on done / partial / failed / cancelled. Same
// auth-transition rules as library_sync_provider.dart: user-scoped, the
// service's in-flight work is cancelled when the listener signs out.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/files/archive_picker.dart';
import '../../data/listening/listening_models.dart';
import '../../import/diagnostics.dart';
import '../../import/listening_import_service.dart';
import '../../import/snapshot.dart';
import '../../import/spotify_parser.dart';
import 'auth_provider.dart';
import 'device_providers.dart';
import 'onboarding_provider.dart';

final listeningImportServiceProvider = Provider<ListeningImportService>(
  (ref) => ListeningImportService(api: ref.watch(listeningApiProvider)),
);

/// Builds the content-free report for a failed file (names, sizes, counts).
typedef ExportDiagnoser = Future<ExportDiagnostics> Function(String path);

final exportDiagnoserProvider = Provider<ExportDiagnoser>((ref) => diagnoseExportFile);

/// The file names an export must carry, as the failure copy lists them.
const String expectedExportFiles = 'Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json';

sealed class ImportFlowState {
  const ImportFlowState();

  /// A pick being read, an inventory awaiting its Upload, or an upload
  /// underway: re-entry from Home or the sources screen shows it where it
  /// got to rather than starting over (which would cancel it).
  bool get inProgress => switch (this) {
        ImportInspecting() || ImportInventory() || ImportUploading() => true,
        ImportIdle() || ImportDone() || ImportPartial() || ImportFailed() || ImportFlowCancelled() => false,
      };
}

class ImportIdle extends ImportFlowState {
  const ImportIdle();
}

class ImportInspecting extends ImportFlowState {
  const ImportInspecting(this.archive);
  final PickedArchive archive;
}

class ImportInventory extends ImportFlowState {
  const ImportInventory({
    required this.archive,
    required this.preview,
    required this.includePrivateSessions,
  });

  final PickedArchive archive;

  /// The full parse under the default options: every fact the inventory
  /// shows, and the snapshot the upload sends unless the switch is flipped.
  final ImportPreview preview;
  final bool includePrivateSessions;

  ExportInventory get inventory => preview.inventory;

  /// The zone local days are computed in (shown as "Local days in …").
  String get timeZone => preview.timeZone;

  ImportOptions get options =>
      ImportOptions(timeZone: timeZone, includePrivateSessions: includePrivateSessions);

  ImportInventory withPrivateSessions(bool include) => ImportInventory(
        archive: archive,
        preview: preview,
        includePrivateSessions: include,
      );
}

class ImportUploading extends ImportFlowState {
  const ImportUploading(this.archive, this.progress);
  final PickedArchive archive;

  /// 0–1: parse, then the chunk uploads, then (account package) playlists.
  final double progress;
}

class ImportDone extends ImportFlowState {
  const ImportDone(this.archive, this.result);
  final PickedArchive archive;
  final ListeningImportResult result;
}

/// The history was published but the playlist sync after it failed.
class ImportPartial extends ImportFlowState {
  const ImportPartial(this.archive, this.result, this.options, this.preview);
  final PickedArchive archive;
  final ListeningImportResult result;

  /// What the run was started with, so "Retry playlists" repeats it exactly
  /// (and, with the [preview], without parsing the file again).
  final ImportOptions options;
  final ImportPreview? preview;
}

class ImportFailed extends ImportFlowState {
  const ImportFailed({
    required this.archive,
    required this.message,
    required this.diagnostics,
    this.unreadable = false,
    this.diagnosing = false,
  });

  /// Null when the failure came before a file was picked.
  final PickedArchive? archive;
  final String message;

  /// The file itself could not be read (as opposed to a failure on the way
  /// to the server): the sheet names the expected files and shows the
  /// report once there is one.
  final bool unreadable;

  /// The content-free report for an unreadable file is still being built
  /// off the main isolate; it cannot be cancelled, so the failure shows at
  /// once and the report attaches when it arrives.
  final bool diagnosing;

  /// Present when the file itself could not be read; null for a failure on
  /// the way to the server (nothing about the file to report), while the
  /// report is being built ([diagnosing]), or when it could not be built.
  final ExportDiagnostics? diagnostics;
}

class ImportFlowCancelled extends ImportFlowState {
  const ImportFlowCancelled();
}

class ListeningImportNotifier extends Notifier<ImportFlowState> {
  late ListeningImportService _service;

  /// Bumped by every inspect, upload, reset, and rebuild so a run that
  /// finishes after the listener moved on cannot write over the newer state.
  int _generation = 0;

  @override
  ImportFlowState build() {
    // First: the rebuild cancels the run in flight (through onDispose below),
    // and that run's cancelled state must not land on the fresh idle, nor
    // its refresh reach the server for a listener who has signed out.
    _generation++;
    ref.watch(authProvider); // user-scoped: reset to idle on every auth transition
    final service = ref.watch(listeningImportServiceProvider);
    ref.onDispose(service.cancel);
    _service = service;
    return const ImportIdle();
  }

  /// Opens the document picker; a dismissed picker changes nothing, and a
  /// picker that cannot open fails the flow with nothing to report.
  Future<void> pick() async {
    final PickedArchive? archive;
    try {
      archive = await ref.read(archivePickerProvider).pick();
    } catch (error) {
      if (kDebugMode) debugPrint('import pick failed: ${error.runtimeType}');
      if (!ref.mounted || state is ImportUploading) return;
      _generation++;
      state = const ImportFailed(
        archive: null,
        message: "Couldn't open the file picker. Try again.",
        diagnostics: null,
      );
      return;
    }
    if (archive == null || !ref.mounted) return;
    await inspect(archive);
  }

  /// Parses the archive for the inventory, with days local to the device
  /// zone. A file that cannot yield a snapshot fails here with its
  /// diagnostics, before anything is uploaded.
  Future<void> inspect(PickedArchive archive) async {
    if (state is ImportUploading) return;
    final generation = ++_generation;
    state = ImportInspecting(archive);
    try {
      final timeZone = await ref.read(deviceTimeZoneProvider)();
      if (!_current(generation)) return;
      final preview = await _service.inspect(archive.path, timeZone: timeZone);
      if (!_current(generation)) return;
      state = ImportInventory(archive: archive, preview: preview, includePrivateSessions: false);
    } on ImportCancelled {
      if (_current(generation)) state = const ImportFlowCancelled();
    } on UnreadableExportException catch (error) {
      await _failUnreadable(generation, archive, error.inventory.package, error.file);
    } catch (error) {
      if (kDebugMode) debugPrint('import inspect failed: ${error.runtimeType}');
      await _fail(generation, archive, "Couldn't read this file. Try another file.", diagnose: true);
    }
  }

  /// Private sessions are a choice for the extended package only; the
  /// account package carries no plays.
  void setIncludePrivateSessions(bool include) {
    final current = state;
    if (current is! ImportInventory) return;
    if (current.inventory.package != ExportPackage.spotifyExtended) return;
    state = current.withPrivateSessions(include);
  }

  Future<void> upload() async {
    final current = state;
    if (current is! ImportInventory) return;
    await _upload(current.archive, current.options, current.preview);
  }

  /// Partial state: imports the same file again with the same options. The
  /// import is idempotent on the server, so the re-run duplicates nothing;
  /// what it adds is a fresh playlist sync after the history.
  Future<void> retryPlaylists() async {
    final current = state;
    if (current is! ImportPartial) return;
    await _upload(current.archive, current.options, current.preview);
  }

  Future<void> _upload(PickedArchive archive, ImportOptions options, ImportPreview? preview) async {
    final generation = ++_generation;
    state = ImportUploading(archive, 0);
    try {
      final result = await _service.import(
        archive.path,
        options,
        preview: preview,
        onProgress: (progress) {
          if (_current(generation)) state = ImportUploading(archive, progress);
        },
      );
      if (!_current(generation)) return;
      state = result.playlistError == null
          ? ImportDone(archive, result)
          : ImportPartial(archive, result, options, preview);
    } on ImportCancelled {
      if (!_current(generation)) return;
      state = const ImportFlowCancelled();
    } on UnreadableExportException catch (error) {
      await _failUnreadable(generation, archive, error.inventory.package, error.file);
    } on NetworkException {
      await _fail(generation, archive, "Couldn't reach mixtape. Check your connection and try again.");
    } on ApiException catch (error) {
      final message = switch (ListeningApiErrorCode.of(error)) {
        ListeningApiErrorCode.syncConflict =>
          'Another import is still open. Wait a moment and try again.',
        _ => 'Something went wrong on our end. Try again.',
      };
      await _fail(generation, archive, message);
    } on ListeningImportProtocolException {
      await _fail(generation, archive, "The server's counts didn't match this export. Try again.");
    } catch (error) {
      if (kDebugMode) debugPrint('import failed: ${error.runtimeType}');
      await _fail(generation, archive, 'Import failed. Try again.');
    }
    // Every terminal state refreshes: a cancel or a count mismatch after
    // `complete` has still published the history, and Home and the sources
    // screen show what the server holds.
    if (_current(generation)) await _refreshOnboarding();
  }

  /// Stops the inspect or upload in flight; the flow lands on cancelled. A
  /// report still being built for an unreadable file cannot be stopped, so
  /// the flow moves on without it and the report is dropped when it lands.
  void cancel() {
    final current = state;
    if (current is ImportFailed && current.diagnosing) {
      _generation++;
      state = const ImportFlowCancelled();
      return;
    }
    _service.cancel();
  }

  /// Back to idle, dropping (and cancelling) whatever was in flight.
  void reset() {
    _generation++;
    _service.cancel();
    state = const ImportIdle();
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  Future<void> _failUnreadable(
    int generation,
    PickedArchive archive,
    ExportPackage? package,
    String? file,
  ) {
    final message = file != null
        ? "$file couldn't be read, so nothing was uploaded."
        : package == null
            ? "This doesn't look like a Spotify export: none of the expected files are in the ZIP."
            : "This file isn't a ZIP archive Mixtape can open.";
    return _fail(generation, archive, message, diagnose: true);
  }

  /// Lands on failed at once. For an unreadable file ([diagnose]) the
  /// content-free report is then built off the main isolate, which cannot
  /// be cancelled: it attaches when it arrives unless the listener has
  /// moved on (cancel, reset, a new pick) by then.
  Future<void> _fail(
    int generation,
    PickedArchive archive,
    String message, {
    bool diagnose = false,
  }) async {
    if (!_current(generation)) return;
    state = ImportFailed(
      archive: archive,
      message: message,
      diagnostics: null,
      unreadable: diagnose,
      diagnosing: diagnose,
    );
    if (!diagnose) return;
    ExportDiagnostics? diagnostics;
    try {
      diagnostics = await ref.read(exportDiagnoserProvider)(archive.path);
    } catch (_) {
      diagnostics = null;
    }
    if (!_current(generation)) return;
    state = ImportFailed(archive: archive, message: message, diagnostics: diagnostics, unreadable: true);
  }

  Future<void> _refreshOnboarding() async {
    if (!ref.mounted) return;
    await ref.read(onboardingProvider.notifier).refresh();
  }
}

final listeningImportProvider =
    NotifierProvider<ListeningImportNotifier, ImportFlowState>(ListeningImportNotifier.new);
