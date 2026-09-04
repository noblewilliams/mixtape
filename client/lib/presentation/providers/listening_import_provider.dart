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
    required this.inventory,
    required this.timeZone,
    required this.includePrivateSessions,
  });

  final PickedArchive archive;
  final ExportInventory inventory;

  /// The zone local days are computed in (shown as "Local days in …").
  final String timeZone;
  final bool includePrivateSessions;

  ImportInventory withPrivateSessions(bool include) => ImportInventory(
        archive: archive,
        inventory: inventory,
        timeZone: timeZone,
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
  const ImportPartial(this.archive, this.result);
  final PickedArchive archive;
  final ListeningImportResult result;
}

class ImportFailed extends ImportFlowState {
  const ImportFailed({required this.archive, required this.message, required this.diagnostics});
  final PickedArchive archive;
  final String message;

  /// Present when the file itself could not be read; null for a failure on
  /// the way to the server (nothing about the file to report) or when the
  /// report could not be built.
  final ExportDiagnostics? diagnostics;
}

class ImportFlowCancelled extends ImportFlowState {
  const ImportFlowCancelled();
}

class ListeningImportNotifier extends Notifier<ImportFlowState> {
  late ListeningImportService _service;

  /// Bumped by every inspect, upload, and reset so a run that finishes after
  /// the listener moved on cannot write over the newer state.
  int _generation = 0;

  @override
  ImportFlowState build() {
    ref.watch(authProvider); // user-scoped: reset to idle on every auth transition
    final service = ref.watch(listeningImportServiceProvider);
    ref.onDispose(service.cancel);
    _service = service;
    return const ImportIdle();
  }

  /// Opens the document picker; a dismissed picker changes nothing.
  Future<void> pick() async {
    final archive = await ref.read(archivePickerProvider).pick();
    if (archive == null || !ref.mounted) return;
    await inspect(archive);
  }

  /// Lists the archive for the inventory. A file that cannot yield a
  /// snapshot fails here with its diagnostics, before anything is uploaded.
  Future<void> inspect(PickedArchive archive) async {
    if (state is ImportUploading) return;
    final generation = ++_generation;
    state = ImportInspecting(archive);
    try {
      final inventory = await _service.inspect(archive.path);
      if (!_current(generation)) return;
      if (!inventory.isReadable) {
        await _failUnreadable(generation, archive, inventory.package, inventory.unreadableFile);
        return;
      }
      final timeZone = await ref.read(deviceTimeZoneProvider)();
      if (!_current(generation)) return;
      state = ImportInventory(
        archive: archive,
        inventory: inventory,
        timeZone: timeZone,
        includePrivateSessions: false,
      );
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
    final generation = ++_generation;
    final archive = current.archive;
    state = ImportUploading(archive, 0);
    try {
      final result = await _service.import(
        archive.path,
        ImportOptions(
          timeZone: current.timeZone,
          includePrivateSessions: current.includePrivateSessions,
        ),
        onProgress: (progress) {
          if (_current(generation)) state = ImportUploading(archive, progress);
        },
      );
      if (!_current(generation)) return;
      state = result.playlistError == null
          ? ImportDone(archive, result)
          : ImportPartial(archive, result);
      await _refreshOnboarding();
    } on ImportCancelled {
      if (!_current(generation)) return;
      state = const ImportFlowCancelled();
      // A cancel after `complete` has still published the history.
      await _refreshOnboarding();
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
  }

  /// Stops the inspect or upload in flight; the flow lands on cancelled.
  void cancel() => _service.cancel();

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

  Future<void> _fail(
    int generation,
    PickedArchive archive,
    String message, {
    bool diagnose = false,
  }) async {
    ExportDiagnostics? diagnostics;
    if (diagnose) {
      try {
        diagnostics = await ref.read(exportDiagnoserProvider)(archive.path);
      } catch (_) {
        diagnostics = null;
      }
    }
    if (!_current(generation)) return;
    state = ImportFailed(archive: archive, message: message, diagnostics: diagnostics);
  }

  Future<void> _refreshOnboarding() async {
    if (!ref.mounted) return;
    await ref.read(onboardingProvider.notifier).refresh();
  }
}

final listeningImportProvider =
    NotifierProvider<ListeningImportNotifier, ImportFlowState>(ListeningImportNotifier.new);
