import 'collection_review.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../data/listening/listening_api.dart';
import '../data/listening/listening_models.dart';
import 'import_isolate.dart';
import 'snapshot.dart';
import 'spotify_parser.dart';

/// Parses an export archive at a path (default: [parseExportInIsolate]).
typedef ExportParser =
    Future<ParsedExport> Function(String path, ParseOptions options);

class ImportOptions {
  const ImportOptions({
    required this.timeZone,
    this.includePrivateSessions = false,
  });

  /// IANA zone the run records; days and hours are local to it.
  final String timeZone;
  final bool includePrivateSessions;

  bool sameAs(ImportOptions other) =>
      timeZone == other.timeZone &&
      includePrivateSessions == other.includePrivateSessions;
}

/// What [ListeningImportService.inspect] hands the inventory screen: the full
/// parse of the archive under [options] (the device zone, private sessions
/// excluded), so the screen can show tracks, days with plays, the ledger
/// years, and the row drops before anything is uploaded. Handed back to
/// [ListeningImportService.import], it is uploaded as is unless the options
/// changed. Holds the whole snapshot: drop it with the screen.
class ImportPreview {
  const ImportPreview({
    this.selection,
    required this.inventory,
    required this.snapshot,
    required this.stats,
    required this.options,
  });

  final CollectionSelection? selection;
  ImportPreview withSelection(CollectionSelection value) => ImportPreview(
    inventory: inventory,
    snapshot: snapshot,
    stats: stats,
    options: options,
    selection: value,
  );
  final ExportInventory inventory;
  final ListeningExportSnapshot snapshot;
  final ExportStats stats;

  /// The options the parse ran with.
  final ImportOptions options;

  ExportPackage get package => snapshot.package;
  String get timeZone => snapshot.timeZone;
  int get tracks => snapshot.tracks.length;
  int get daysWithPlays => snapshot.days.length;
  int get skippedPodcasts => stats.podcastOrAudiobook;
  int get skippedLocalFiles => stats.localFile;

  /// Private-session plays the default parse kept out (see
  /// [ExportStats.privatePlays]).
  int get privatePlays => stats.privatePlays;
}

class ListeningImportResult {
  const ListeningImportResult({
    required this.inventory,
    required this.summary,
    required this.playlistSummary,
    required this.playlistError,
  });

  final ExportInventory inventory;
  final ListeningImportSummary summary;

  /// Present for an account package only (the playlist sync that follows
  /// the import); an extended package carries no playlists, and a partial
  /// result (see [playlistError]) carries none either.
  final PlaylistSyncSummary? playlistSummary;

  /// Set when the listening import was published but the playlist sync
  /// that followed failed: the history is on the server, the playlists are
  /// not, and the caller decides how to say so. Null on full success and
  /// for an extended package.
  final Object? playlistError;
}

/// The server accepted or reported a count that does not match the snapshot.
class ListeningImportProtocolException implements Exception {
  const ListeningImportProtocolException();

  @override
  String toString() => 'ListeningImportProtocolException';
}

/// Drives a Spotify export from a file on the device to the server: parse
/// off the main isolate, then the listening import protocol, then (account
/// package only) the playlist sync, with the funnel events the spec names.
/// Modelled on `LibrarySyncService`: [cancel] is honoured at every await,
/// progress reports staged bounds, and concurrent [import] calls join the
/// run in flight.
///
/// The listening import is published at `complete`; a playlist-sync failure
/// after that resolves as a partial [ListeningImportResult] rather than
/// throwing, so the caller never mistakes a landed history for a lost one.
/// Only a cancel still throws from the playlist phase.
///
/// Only the snapshot leaves the device, never the file. Nothing here logs a
/// track, artist, album, or playlist name.
///
/// The server keeps one open playlist run per user, so a caller must not run
/// this and `LibrarySyncService.sync` at the same time.
class ListeningImportService {
  ListeningImportService({required this.api, ExportParser? parser})
    : _parser = parser ?? parseExportInIsolate;

  static const int trackChunkSize = 500;
  static const int dayChunkSize = 2000;
  static const int libraryChunkSize = 500;
  static const int artistChunkSize = 500;
  static const int playlistChunkSize = 50;
  static const int entryChunkSize = 200;

  static const double _parseStageEnd = 0.4;
  static const double _uploadStageEnd = 0.95;
  static const double _playlistStageEnd = 0.99;

  final ListeningApi api;
  final ExportParser _parser;

  _ImportRun? _inFlight;
  CancelToken? _inspectToken;

  /// Requests that the in-flight run stop at its next await boundary; a
  /// parse in progress is cancelled through its token so the worker isolate
  /// stops too. The run then fails with [ImportCancelled]. An [inspect] in
  /// flight is cancelled the same way: it parses the whole archive, so a
  /// large history would otherwise keep the worker busy after the listener
  /// left the sheet.
  void cancel() {
    _inspectToken?.cancel();
    final job = _inFlight;
    if (job == null) return;
    job.cancelRequested = true;
    job.parseToken?.cancel();
  }

  /// Parses the archive for the inventory screen, with private sessions
  /// excluded and days local to [timeZone], and records that the listener
  /// got this far (`file_inspected`, fire-and-forget: a funnel failure never
  /// reaches the caller). One parse serves both the preview and, unless the
  /// listener flips the private-sessions switch, the upload. An unreadable
  /// archive throws [UnreadableExportException]; [cancel] aborts with
  /// [ImportCancelled] and posts nothing.
  Future<ImportPreview> inspect(
    String path, {
    required String timeZone,
    ParseProgress? onProgress,
  }) async {
    final token = CancelToken();
    _inspectToken = token;
    final options = ImportOptions(timeZone: timeZone);
    try {
      final parsed = await _parser(
        path,
        ParseOptions(
          timeZone: timeZone,
          includePrivateSessions: false,
          cancelToken: token,
          onProgress: onProgress,
        ),
      );
      _funnel(FunnelEventType.fileInspected);
      final context =
          parsed.snapshot.package == ExportPackage.spotifyExportify ||
              parsed.snapshot.package == ExportPackage.spotifyAccount
          ? await api.getCollectionReview()
          : null;
      final selection =
          context != null &&
              (parsed.snapshot.package == ExportPackage.spotifyExportify ||
                  context.hasQuickImport)
          ? CollectionSelection.initial(parsed.snapshot, context)
          : null;
      token.throwIfCancelled();
      return ImportPreview(
        selection: selection,
        inventory: parsed.inventory,
        snapshot: parsed.snapshot,
        stats: parsed.stats,
        options: options,
      );
    } finally {
      if (identical(_inspectToken, token)) _inspectToken = null;
    }
  }

  /// Parses and uploads the archive at [path]. A [preview] from [inspect] is
  /// uploaded as it is when [options] match the ones it was parsed with;
  /// otherwise (or without one) the archive is parsed again. Concurrent
  /// callers join the same in-flight run; a joiner's path, options, preview,
  /// and progress callback are intentionally ignored. Progress: parse 0–0.4
  /// (reported as 0.4 at once when the preview is reused), uploads
  /// 0.4–0.95, playlist sync to 0.99, 1.0 on completion.
  ///
  /// A call that arrives after [cancel] but before the cancelled run has
  /// settled never joins it: it waits for that settlement (the cancelled
  /// run's error belongs to its own callers) and then starts fresh with its
  /// own path and options. Either way the run starts on a microtask so
  /// [_inFlight] is set before its first step: [cancel] is honoured from the
  /// moment this returns.
  Future<ListeningImportResult> import(
    String path,
    ImportOptions options, {
    ImportPreview? preview,
    void Function(double progress)? onProgress,
  }) {
    final current = _inFlight;
    if (current != null && !current.cancelRequested) return current.future;
    final settled =
        current?.future.then<void>((_) {}, onError: (Object _) {}) ??
        Future<void>.value();
    final job = _ImportRun();
    job.future = settled
        .then((_) => _run(job, path, options, preview, onProgress))
        .whenComplete(() {
          if (identical(_inFlight, job)) _inFlight = null;
        });
    _inFlight = job;
    return job.future;
  }

  Future<ListeningImportResult> _run(
    _ImportRun job,
    String path,
    ImportOptions options,
    ImportPreview? preview,
    void Function(double progress)? onProgress,
  ) async {
    final ParsedExport parsed;
    if (preview != null && preview.options.sameAs(options)) {
      parsed = ParsedExport(
        inventory: preview.inventory,
        snapshot: preview.snapshot,
        stats: preview.stats,
      );
    } else {
      parsed = await _parse(job, path, options, onProgress);
    }
    job.checkCancelled();
    onProgress?.call(_parseStageEnd);

    final reviewed = preview?.selection?.apply(parsed.snapshot);
    final snapshot = reviewed?.snapshot ?? parsed.snapshot;
    if (snapshot.package == ExportPackage.spotifyExportify &&
        reviewed == null) {
      throw const FormatException('Review the files before importing.');
    }
    final canonical = snapshot.toCanonicalJson();
    final tracks = _withOrdinals(canonical['tracks']);
    final days = _withOrdinals(canonical['days']);
    final library = _withOrdinals(canonical['library']);
    final artists = _withOrdinals(canonical['artists']);

    final run = await api.beginImport(
      BeginListeningImport(
        libraryReview: reviewed?.libraryReview,
        source: ListeningExportSnapshot.source,
        package: snapshot.package.wire,
        timeZone: snapshot.timeZone,
        country: snapshot.country,
        expectedTracks: tracks.length,
        expectedDays: days.length,
        expectedLibraryTracks: library.length,
        expectedArtists: artists.length,
        unresolvedRows: snapshot.unresolved.rows,
        unresolvedPlays: snapshot.unresolved.plays,
      ),
    );
    job.checkCancelled();

    final totalRows =
        tracks.length + days.length + library.length + artists.length;
    var uploadedRows = 0;
    void reportUpload() {
      final ratio = totalRows == 0
          ? 1.0
          : (uploadedRows / totalRows).clamp(0.0, 1.0);
      onProgress?.call(
        _parseStageEnd + (_uploadStageEnd - _parseStageEnd) * ratio,
      );
    }

    Future<void> upload(
      List<Map<String, Object?>> rows,
      int chunkSize,
      Future<int> Function(String importId, List<Map<String, Object?>> rows)
      put,
    ) async {
      for (var offset = 0; offset < rows.length; offset += chunkSize) {
        job.checkCancelled();
        final chunk = rows.sublist(
          offset,
          math.min(offset + chunkSize, rows.length),
        );
        final accepted = await put(run.importId, chunk);
        job.checkCancelled();
        if (accepted != chunk.length) {
          throw const ListeningImportProtocolException();
        }
        uploadedRows += chunk.length;
        reportUpload();
      }
    }

    // Only the chunk types the package carries have rows: the parser leaves
    // the others empty, and begin() expected them as zero.
    await upload(tracks, trackChunkSize, api.putTracks);
    await upload(days, dayChunkSize, api.putDays);
    await upload(library, libraryChunkSize, api.putLibrary);
    await upload(artists, artistChunkSize, api.putArtists);
    if (totalRows == 0) reportUpload();

    job.checkCancelled();
    final summary = await api.completeImport(run.importId);
    // The history is committed server-side from here, so the funnel step
    // goes up now: the onboarding read derives importCompletedAt from it
    // and must learn the history landed even if the playlists don't.
    _funnel(FunnelEventType.importCompleted);
    job.checkCancelled();
    if (summary.tracks != tracks.length ||
        summary.days != days.length ||
        summary.libraryTracks != library.length ||
        summary.artists != artists.length) {
      throw const ListeningImportProtocolException();
    }

    // Playlists belong to the account package; the listening run has
    // completed by now, so at most one staged run is open at a time. A
    // failure here is reported on the result as a partial success, never
    // as a throw; only a cancel still throws.
    PlaylistSyncSummary? playlistSummary;
    Object? playlistError;
    if (snapshot.package == ExportPackage.spotifyAccount ||
        snapshot.package == ExportPackage.spotifyExportify) {
      try {
        playlistSummary = await _syncPlaylists(
          job,
          snapshot.playlists,
          onProgress,
          reviewed?.playlistReview,
        );
      } on ImportCancelled {
        rethrow;
      } catch (error) {
        playlistError = error;
      }
    }

    onProgress?.call(1.0);
    return ListeningImportResult(
      inventory: parsed.inventory,
      summary: summary,
      playlistSummary: playlistSummary,
      playlistError: playlistError,
    );
  }

  Future<ParsedExport> _parse(
    _ImportRun job,
    String path,
    ImportOptions options,
    void Function(double progress)? onProgress,
  ) async {
    final token = CancelToken();
    job.parseToken = token;
    if (job.cancelRequested) token.cancel();
    try {
      return await _parser(
        path,
        ParseOptions(
          timeZone: options.timeZone,
          includePrivateSessions: options.includePrivateSessions,
          cancelToken: token,
          onProgress: (stage, file, completed, total) {
            if (stage != ParseStage.parsing || total <= 0) return;
            onProgress?.call(
              _parseStageEnd * (completed / total).clamp(0.0, 1.0),
            );
          },
        ),
      );
    } finally {
      job.parseToken = null;
    }
  }

  Future<PlaylistSyncSummary> _syncPlaylists(
    _ImportRun job,
    List<SnapshotPlaylist> unordered,
    void Function(double progress)? onProgress,
    List<Map<String, Object?>>? review,
  ) async {
    final playlists = List.of(unordered)
      ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final totalEntries = playlists.fold<int>(
      0,
      (sum, p) => sum + p.entries.length,
    );

    final sync = await api.beginPlaylistSync(
      review: review,
      expectedPlaylists: playlists.length,
      expectedEntries: totalEntries,
    );
    job.checkCancelled();

    final totalUnits = playlists.length + totalEntries;
    var completedUnits = 0;
    void reportPlaylists() {
      final ratio = totalUnits == 0
          ? 1.0
          : (completedUnits / totalUnits).clamp(0.0, 1.0);
      onProgress?.call(
        _uploadStageEnd + (_playlistStageEnd - _uploadStageEnd) * ratio,
      );
    }

    for (
      var offset = 0;
      offset < playlists.length;
      offset += playlistChunkSize
    ) {
      job.checkCancelled();
      final chunk = playlists.sublist(
        offset,
        math.min(offset + playlistChunkSize, playlists.length),
      );
      final accepted = await api.putPlaylists(
        sync.syncId,
        chunk.map(_playlistSnapshot).toList(),
      );
      job.checkCancelled();
      if (accepted != chunk.length) {
        throw const ListeningImportProtocolException();
      }
      completedUnits += chunk.length;
      reportPlaylists();

      for (final playlist in chunk) {
        final entries = List.of(playlist.entries)
          ..sort((a, b) => a.position.compareTo(b.position));
        for (
          var entryOffset = 0;
          entryOffset < entries.length;
          entryOffset += entryChunkSize
        ) {
          job.checkCancelled();
          final page = entries.sublist(
            entryOffset,
            math.min(entryOffset + entryChunkSize, entries.length),
          );
          final accepted = await api.putPlaylistEntries(
            sync.syncId,
            playlist.key,
            page.map((entry) => _entrySnapshot(playlist, entry)).toList(),
          );
          job.checkCancelled();
          if (accepted != page.length) {
            throw const ListeningImportProtocolException();
          }
          completedUnits += page.length;
          reportPlaylists();
        }
      }
    }
    if (totalUnits == 0) reportPlaylists();

    job.checkCancelled();
    final summary = await api.completePlaylistSync(sync.syncId);
    job.checkCancelled();
    if (summary.playlists != playlists.length ||
        summary.entries != totalEntries ||
        summary.resolvedEntries + summary.unresolvedEntries !=
            summary.entries) {
      throw const ListeningImportProtocolException();
    }
    return summary;
  }

  void _funnel(FunnelEventType type) {
    unawaited(api.postFunnelEvent(type).catchError((Object _) {}));
  }

  /// The canonical rows of one snapshot list, each carrying its index as
  /// `ordinal` (the protocol's duplicate-chunk key).
  static List<Map<String, Object?>> _withOrdinals(Object? canonicalRows) {
    final rows = (canonicalRows as List<Object?>).cast<Map<String, Object?>>();
    return [
      for (var index = 0; index < rows.length; index++)
        {'ordinal': index, ...rows[index]},
    ];
  }

  static Map<String, Object?> _playlistSnapshot(SnapshotPlaylist playlist) => {
    'ordinal': playlist.ordinal,
    'appleLibraryId': playlist.key,
    'appleCatalogId': null,
    'name': playlist.name,
    'description': playlist.description,
    'curatorName': null,
    'artworkUrlTemplate': null,
    'artworkWidth': null,
    'artworkHeight': null,
    'artworkBgColor': null,
    'kind': 'user',
    'canEdit': false,
    'appleDateAdded': null,
    'appleLastModifiedAt': playlist.lastModifiedAt,
    'sourceFingerprint': playlistFingerprint(playlist.entries),
    'entryCount': playlist.entries.length,
  };

  static Map<String, Object?> _entrySnapshot(
    SnapshotPlaylist playlist,
    SnapshotEntry entry,
  ) => {
    'position': entry.position,
    'appleLibraryEntryId': '${playlist.key}:${entry.position}',
    'appleLibraryTrackId': null,
    'appleCatalogId': null,
    'spotifyId': entry.platformId,
    'isrcSnapshot': null,
    'titleSnapshot': entry.title,
    'artistSnapshot': entry.artist,
    'albumSnapshot': entry.album,
    'durationMsSnapshot': null,
    'artworkUrlTemplateSnapshot': null,
    'artworkWidthSnapshot': null,
    'artworkHeightSnapshot': null,
    'artworkBgColorSnapshot': null,
  };
}

/// One [ListeningImportService.import] run: its cancel flag and parse token
/// live here rather than on the service so a cancelled run that is still
/// settling cannot leak either into the fresh run that follows it.
class _ImportRun {
  bool cancelRequested = false;
  CancelToken? parseToken;
  late final Future<ListeningImportResult> future;

  void checkCancelled() {
    if (cancelRequested) throw ImportCancelled();
  }
}

/// Lowercase hex SHA-256 of the entries in position order, one line per
/// entry: `position \t platformId (empty when null) \t title \t artist`,
/// lines joined with `\n`. The same value the web import service computes,
/// so a playlist re-imported from either surface is recognised as unchanged.
String playlistFingerprint(List<SnapshotEntry> entries) {
  final ordered = List.of(entries)
    ..sort((a, b) => a.position.compareTo(b.position));
  final text = ordered
      .map(
        (e) => '${e.position}\t${e.platformId ?? ''}\t${e.title}\t${e.artist}',
      )
      .join('\n');
  return sha256.convert(utf8.encode(text)).toString();
}
