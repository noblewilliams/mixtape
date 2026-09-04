import 'dart:async';

import 'package:mixtape/data/files/archive_picker.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';

import 'fake_listening_api.dart';

/// Stands in for the import service in provider and widget tests: [inspect]
/// answers from [inventory] (or throws [inspectError]; or holds until
/// [cancel] when [holdInspect] is set), and [import] hands the test a run it
/// drives by hand with [report], [finish], and [fail]. No isolate, no
/// network.
class FakeImportService extends ListeningImportService {
  FakeImportService({FakeListeningApi? api})
      : super(
          api: api ?? FakeListeningApi(),
          parser: (_, _) => throw UnimplementedError('parser'),
          inspector: (_, {cancelToken}) => throw UnimplementedError('inspector'),
        );

  ExportInventory inventory = extendedInventory;
  Object? inspectError;
  bool holdInspect = false;
  Completer<ExportInventory>? _inspect;

  final List<String> inspected = [];
  String? importedPath;
  ImportOptions? importedOptions;
  Completer<ListeningImportResult>? _run;
  void Function(double progress)? _onProgress;
  int cancels = 0;

  bool get running => _run != null && !_run!.isCompleted;

  @override
  Future<ExportInventory> inspect(String path) {
    inspected.add(path);
    final error = inspectError;
    if (error != null) return Future.error(error);
    if (!holdInspect) return Future.value(inventory);
    _inspect = Completer<ExportInventory>();
    return _inspect!.future;
  }

  @override
  Future<ListeningImportResult> import(
    String path,
    ImportOptions options, {
    void Function(double progress)? onProgress,
  }) {
    importedPath = path;
    importedOptions = options;
    _onProgress = onProgress;
    _run = Completer<ListeningImportResult>();
    return _run!.future;
  }

  void report(double progress) => _onProgress?.call(progress);

  void finish(ListeningImportResult result) => _run!.complete(result);

  void fail(Object error) => _run!.completeError(error);

  @override
  void cancel() {
    cancels++;
    final inspect = _inspect;
    if (inspect != null && !inspect.isCompleted) inspect.completeError(ImportCancelled());
    final run = _run;
    if (run != null && !run.isCompleted) run.completeError(ImportCancelled());
  }
}

/// Hands the screen a fixed pick (or a dismissed picker when null).
class FakeArchivePicker implements ArchivePicker {
  FakeArchivePicker([this.next]);

  PickedArchive? next;
  int picks = 0;

  @override
  Future<PickedArchive?> pick() async {
    picks++;
    return next;
  }
}

const extendedArchive = PickedArchive(
  path: '/tmp/my_spotify_data_extended.zip',
  name: 'my_spotify_data_extended.zip',
  bytes: 40265318,
);

const accountArchive = PickedArchive(
  path: '/tmp/my_spotify_data.zip',
  name: 'my_spotify_data.zip',
  bytes: 1_300_000,
);

const extendedInventory = ExportInventory(
  package: ExportPackage.spotifyExtended,
  read: [
    InventoryReadFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2018-2020_0.json',
      rows: 24110,
    ),
    InventoryReadFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2021-2023_1.json',
      rows: 30001,
    ),
  ],
  ignored: [
    InventoryIgnoredFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Video_2024_0.json',
      bytes: 51200,
    ),
    InventoryIgnoredFile(
      path: 'Spotify Extended Streaming History/ReadMeFirst_ExtendedStreamingHistory.pdf',
      bytes: 204800,
    ),
  ],
);

const accountInventory = ExportInventory(
  package: ExportPackage.spotifyAccount,
  read: [
    InventoryReadFile(path: 'Spotify Account Data/YourLibrary.json', rows: 214),
    InventoryReadFile(path: 'Spotify Account Data/Playlist1.json', rows: 12),
  ],
  ignored: [
    InventoryIgnoredFile(path: 'Spotify Account Data/Identity.json', bytes: 2068),
  ],
);

/// An extended package whose second history file failed to decode.
const brokenInventory = ExportInventory(
  package: ExportPackage.spotifyExtended,
  read: [
    InventoryReadFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2018-2020_0.json',
      rows: 24110,
    ),
    InventoryReadFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2021-2023_1.json',
      rows: null,
    ),
  ],
  ignored: [],
);

const brokenDiagnostics = ExportDiagnostics(
  source: 'spotify_export',
  files: [
    DiagnosticsFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2018-2020_0.json',
      bytes: 12478361,
      rows: 24110,
      headers: ['ts', 'ms_played', 'spotify_track_uri'],
    ),
    DiagnosticsFile(
      path: 'Spotify Extended Streaming History/Streaming_History_Audio_2021-2023_1.json',
      bytes: 12688000,
      rows: null,
      headers: null,
    ),
  ],
  parserVersion: 'client-spotify-1',
);

ListeningImportSummary importSummary({
  int tracks = 4812,
  int days = 1903,
  int libraryTracks = 0,
  int artists = 0,
  int unresolvedRows = 9,
  int unresolvedPlays = 3,
  String? ledgerFrom = '2018-03-02',
  String? ledgerTo = '2026-08-30',
}) =>
    ListeningImportSummary(
      tracks: tracks,
      days: days,
      libraryTracks: libraryTracks,
      artists: artists,
      unresolvedRows: unresolvedRows,
      unresolvedPlays: unresolvedPlays,
      ledgerFrom: ledgerFrom,
      ledgerTo: ledgerTo,
      likedRemoved: 0,
      likedRemovalSkipped: false,
    );

ListeningImportResult extendedResult() => ListeningImportResult(
      inventory: extendedInventory,
      summary: importSummary(),
      playlistSummary: null,
      playlistError: null,
    );

ListeningImportResult accountResult({Object? playlistError}) => ListeningImportResult(
      inventory: accountInventory,
      summary: importSummary(
        tracks: 226,
        days: 0,
        libraryTracks: 214,
        artists: 37,
        unresolvedRows: 0,
        unresolvedPlays: 0,
        ledgerFrom: null,
        ledgerTo: null,
      ),
      playlistSummary: playlistError == null
          ? const PlaylistSyncSummary(
              playlists: 12,
              entries: 640,
              resolvedEntries: 630,
              unresolvedEntries: 10,
            )
          : null,
      playlistError: playlistError,
    );
