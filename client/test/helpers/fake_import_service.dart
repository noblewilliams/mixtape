import 'dart:async';

import 'package:mixtape/data/files/archive_picker.dart';
import 'package:mixtape/data/files/opened_archive_channel.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';

import 'fake_listening_api.dart';

/// Stands in for the import service in provider and widget tests: [inspect]
/// throws [inspectError] at once, answers with [preview] on the next turn
/// of the event loop, or holds until [cancel] when [holdInspect] is set;
/// [import] hands the test a run it drives by hand with [report], [finish],
/// and [fail]. No isolate, no network.
class FakeImportService extends ListeningImportService {
  FakeImportService({FakeListeningApi? api})
      : super(
          api: api ?? FakeListeningApi(),
          parser: (_, _) => throw UnimplementedError('parser'),
        );

  ImportPreview preview = extendedPreview;
  Object? inspectError;
  bool holdInspect = false;
  Completer<ImportPreview>? _inspect;

  final List<String> inspected = [];
  final List<String> inspectedZones = [];
  String? importedPath;
  ImportOptions? importedOptions;
  ImportPreview? importedPreview;
  Completer<ListeningImportResult>? _run;
  void Function(double progress)? _onProgress;
  int cancels = 0;

  /// When set, [cancel] flags the run but leaves it pending until
  /// [settleCancelled]: the window in which a fresh [import] must not join
  /// the cancelled run, and in which a rebuilt provider must not let the
  /// cancelled run's error land on its fresh state.
  bool holdCancel = false;
  Completer<ListeningImportResult>? _cancelled;

  bool get running => _run != null && !_run!.isCompleted;

  @override
  Future<ImportPreview> inspect(String path, {required String timeZone}) {
    inspected.add(path);
    inspectedZones.add(timeZone);
    final error = inspectError;
    if (error != null) return Future.error(error);
    if (holdInspect) {
      _inspect = Completer<ImportPreview>();
      return _inspect!.future;
    }
    // The real parse runs in an isolate and never answers on the calling
    // turn, so the preview is read when the event loop comes back: a widget
    // test may set [preview] after the tap that starts the inspect.
    return Future(() => preview);
  }

  @override
  Future<ListeningImportResult> import(
    String path,
    ImportOptions options, {
    ImportPreview? preview,
    void Function(double progress)? onProgress,
  }) {
    final held = _cancelled;
    if (held == null || held.isCompleted) return _start(path, options, preview, onProgress);
    // The service's contract: a call inside the cancel window waits for the
    // cancelled run to settle and then starts fresh, never joining it.
    return held.future
        .then<void>((_) {}, onError: (Object _) {})
        .then((_) => _start(path, options, preview, onProgress));
  }

  Future<ListeningImportResult> _start(
    String path,
    ImportOptions options,
    ImportPreview? preview,
    void Function(double progress)? onProgress,
  ) {
    importedPath = path;
    importedOptions = options;
    importedPreview = preview;
    _onProgress = onProgress;
    _run = Completer<ListeningImportResult>();
    return _run!.future;
  }

  /// Settles the run a held [cancel] flagged, with [ImportCancelled].
  void settleCancelled() {
    final run = _cancelled;
    _cancelled = null;
    if (run != null && !run.isCompleted) run.completeError(ImportCancelled());
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
    if (run == null || run.isCompleted) return;
    if (holdCancel) {
      _cancelled = run;
    } else {
      run.completeError(ImportCancelled());
    }
  }
}

/// Stands in for the native open-archive channel (C5). [pending] is what a
/// cold start finds; [hand] is a file opened while the app runs, which —
/// exactly like the method-channel source — becomes the pending archive when
/// nobody is listening (no listener signed in yet).
class FakeOpenedArchiveSource implements OpenedArchiveSource {
  FakeOpenedArchiveSource({this.pending});

  PickedArchive? pending;
  int takes = 0;
  final StreamController<PickedArchive> _opened = StreamController<PickedArchive>.broadcast();

  @override
  Stream<PickedArchive> get opened => _opened.stream;

  @override
  Future<PickedArchive?> takePending() async {
    takes++;
    final held = pending;
    pending = null;
    return held;
  }

  void hand(PickedArchive archive) {
    if (_opened.hasListener) {
      _opened.add(archive);
    } else {
      pending = archive;
    }
  }
}

/// Hands the screen a fixed pick (or a dismissed picker when null), or
/// throws [error] the way the platform picker can.
class FakeArchivePicker implements ArchivePicker {
  FakeArchivePicker([this.next]);

  PickedArchive? next;
  Object? error;
  int picks = 0;

  @override
  Future<PickedArchive?> pick() async {
    picks++;
    final failure = error;
    if (failure != null) throw failure;
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

/// What the real service throws for [brokenInventory].
const brokenError = UnreadableExportException(
  file: 'Streaming_History_Audio_2021-2023_1.json',
  inventory: brokenInventory,
);

/// A parse of the extended package with the round numbers the inventory
/// screen shows: 1,203 tracks, 486 days with plays across 2018 – 2026, twelve
/// podcast rows and three local files skipped, five private plays kept out.
final extendedPreview = extendedPreviewWith();

ImportPreview extendedPreviewWith({
  int tracks = 1203,
  int days = 486,
  String? ledgerFrom = '2018-03-02',
  String? ledgerTo = '2026-08-30',
  int podcasts = 12,
  int localFiles = 3,
  int privatePlays = 5,
  String timeZone = 'Africa/Lagos',
}) =>
    ImportPreview(
      inventory: extendedInventory,
      snapshot: ListeningExportSnapshot(
        package: ExportPackage.spotifyExtended,
        timeZone: timeZone,
        country: 'NG',
        tracks: _tracks(tracks),
        days: [
          for (var i = 0; i < days; i++)
            SnapshotDay(
              platformId: 'track${(i % 500).toString().padLeft(18, '0')}',
              day: '2020-01-${(1 + i ~/ 500).toString().padLeft(2, '0')}',
              plays: 1,
              skips: 0,
              completes: 1,
              msPlayed: 30000,
              hoursMask: 1,
            ),
        ],
        library: const [],
        artists: const [],
        playlists: const [],
        unresolved: SnapshotUnresolved(rows: localFiles, plays: 0),
        ledgerFrom: ledgerFrom,
        ledgerTo: ledgerTo,
      ),
      stats: ExportStats(
        podcastOrAudiobook: podcasts,
        localFile: localFiles,
        privateSession: privatePlays + 2,
        badTimestamp: 1,
        privatePlays: privatePlays,
      ),
      options: ImportOptions(timeZone: timeZone),
    );

/// A parse of the account package: 226 tracks named across 214 liked songs,
/// 37 followed artists, and 12 playlists; nothing skipped.
final accountPreview = ImportPreview(
  inventory: accountInventory,
  snapshot: ListeningExportSnapshot(
    package: ExportPackage.spotifyAccount,
    timeZone: 'Africa/Lagos',
    country: null,
    tracks: _tracks(226),
    days: const [],
    library: [
      for (var i = 0; i < 214; i++)
        SnapshotLibraryRow(platformId: 'track${i.toString().padLeft(18, '0')}'),
    ],
    artists: [
      for (var i = 0; i < 37; i++)
        SnapshotArtist(name: 'Artist ${i.toString().padLeft(2, '0')}', spotifyId: null),
    ],
    playlists: [
      for (var i = 0; i < 12; i++)
        SnapshotPlaylist(
          ordinal: i,
          key: 'k' * 62 + i.toString().padLeft(2, '0'),
          name: 'P$i',
          description: null,
          lastModifiedAt: null,
          entries: const [],
        ),
    ],
    unresolved: const SnapshotUnresolved(rows: 0, plays: 0),
    ledgerFrom: null,
    ledgerTo: null,
  ),
  stats: ExportStats.zero,
  options: const ImportOptions(timeZone: 'Africa/Lagos'),
);

List<SnapshotTrack> _tracks(int count) => [
      for (var i = 0; i < count; i++)
        SnapshotTrack(
          platformId: 'track${i.toString().padLeft(18, '0')}',
          title: 'T$i',
          artist: 'A',
          album: null,
          durationMs: null,
        ),
    ];

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
