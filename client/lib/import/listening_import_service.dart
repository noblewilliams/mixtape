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
typedef ExportParser = Future<ParsedExport> Function(String path, ParseOptions options);

/// Lists an export archive at a path (default: [inspectExportInIsolate]).
typedef ExportInspector = Future<ExportInventory> Function(String path);

class ImportOptions {
  const ImportOptions({required this.timeZone, this.includePrivateSessions = false});

  /// IANA zone the run records; days and hours are local to it.
  final String timeZone;
  final bool includePrivateSessions;
}

class ListeningImportResult {
  const ListeningImportResult({
    required this.inventory,
    required this.summary,
    required this.playlistSummary,
  });

  final ExportInventory inventory;
  final ListeningImportSummary summary;

  /// Present for an account package only (the playlist sync that follows
  /// the import); an extended package carries no playlists.
  final PlaylistSyncSummary? playlistSummary;
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
/// Only the snapshot leaves the device, never the file. Nothing here logs a
/// track, artist, album, or playlist name.
///
/// The server keeps one open playlist run per user, so a caller must not run
/// this and `LibrarySyncService.sync` at the same time.
class ListeningImportService {
  ListeningImportService({
    required this.api,
    ExportParser? parser,
    ExportInspector? inspector,
  })  : _parser = parser ?? parseExportInIsolate,
        _inspector = inspector ?? inspectExportInIsolate;

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
  final ExportInspector _inspector;

  Future<ListeningImportResult>? _inFlight;
  bool _cancelRequested = false;
  CancelToken? _parseToken;

  /// Requests that the in-flight run stop at its next await boundary; a
  /// parse in progress is cancelled through its token so the worker isolate
  /// stops too. The run then fails with [ImportCancelled].
  void cancel() {
    if (_inFlight == null) return;
    _cancelRequested = true;
    _parseToken?.cancel();
  }

  /// Lists the archive for the inventory screen and records that the
  /// listener got this far (`file_inspected`, fire-and-forget: a funnel
  /// failure never reaches the caller).
  Future<ExportInventory> inspect(String path) async {
    final inventory = await _inspector(path);
    _funnel(FunnelEventType.fileInspected);
    return inventory;
  }

  /// Parses and uploads the archive at [path]. Concurrent callers join the
  /// same in-flight run; a joiner's path, options, and progress callback are
  /// intentionally ignored. Progress: parse 0–0.4, uploads 0.4–0.95,
  /// playlist sync to 0.99, 1.0 on completion.
  ///
  /// The run starts on a microtask so [_inFlight] is set before its first
  /// step: [cancel] is honoured from the moment this returns.
  Future<ListeningImportResult> import(
    String path,
    ImportOptions options, {
    void Function(double progress)? onProgress,
  }) =>
      _inFlight ??= Future.microtask(() => _run(path, options, onProgress)).whenComplete(() {
        _inFlight = null;
        _cancelRequested = false;
        _parseToken = null;
      });

  void _checkCancelled() {
    if (_cancelRequested) throw ImportCancelled();
  }

  Future<ListeningImportResult> _run(
    String path,
    ImportOptions options,
    void Function(double progress)? onProgress,
  ) async {
    final parsed = await _parse(path, options, onProgress);
    _checkCancelled();
    onProgress?.call(_parseStageEnd);

    final snapshot = parsed.snapshot;
    final canonical = snapshot.toCanonicalJson();
    final tracks = _withOrdinals(canonical['tracks']);
    final days = _withOrdinals(canonical['days']);
    final library = _withOrdinals(canonical['library']);
    final artists = _withOrdinals(canonical['artists']);

    final run = await api.beginImport(
      BeginListeningImport(
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
    _checkCancelled();

    final totalRows = tracks.length + days.length + library.length + artists.length;
    var uploadedRows = 0;
    void reportUpload() {
      final ratio = totalRows == 0 ? 1.0 : (uploadedRows / totalRows).clamp(0.0, 1.0);
      onProgress?.call(_parseStageEnd + (_uploadStageEnd - _parseStageEnd) * ratio);
    }

    Future<void> upload(
      List<Map<String, Object?>> rows,
      int chunkSize,
      Future<int> Function(String importId, List<Map<String, Object?>> rows) put,
    ) async {
      for (var offset = 0; offset < rows.length; offset += chunkSize) {
        _checkCancelled();
        final chunk = rows.sublist(offset, math.min(offset + chunkSize, rows.length));
        final accepted = await put(run.importId, chunk);
        _checkCancelled();
        if (accepted != chunk.length) throw const ListeningImportProtocolException();
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

    _checkCancelled();
    final summary = await api.completeImport(run.importId);
    _checkCancelled();
    if (summary.tracks != tracks.length ||
        summary.days != days.length ||
        summary.libraryTracks != library.length ||
        summary.artists != artists.length) {
      throw const ListeningImportProtocolException();
    }

    PlaylistSyncSummary? playlistSummary;
    if (snapshot.package == ExportPackage.spotifyAccount) {
      playlistSummary = await _syncPlaylists(snapshot.playlists, onProgress);
    }

    onProgress?.call(1.0);
    _funnel(FunnelEventType.importCompleted);
    return ListeningImportResult(
      inventory: parsed.inventory,
      summary: summary,
      playlistSummary: playlistSummary,
    );
  }

  Future<ParsedExport> _parse(
    String path,
    ImportOptions options,
    void Function(double progress)? onProgress,
  ) async {
    final token = CancelToken();
    _parseToken = token;
    if (_cancelRequested) token.cancel();
    try {
      return await _parser(
        path,
        ParseOptions(
          timeZone: options.timeZone,
          includePrivateSessions: options.includePrivateSessions,
          cancelToken: token,
          onProgress: (stage, file, completed, total) {
            if (stage != ParseStage.parsing || total <= 0) return;
            onProgress?.call(_parseStageEnd * (completed / total).clamp(0.0, 1.0));
          },
        ),
      );
    } finally {
      _parseToken = null;
    }
  }

  Future<PlaylistSyncSummary> _syncPlaylists(
    List<SnapshotPlaylist> unordered,
    void Function(double progress)? onProgress,
  ) async {
    final playlists = List.of(unordered)..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final totalEntries = playlists.fold<int>(0, (sum, p) => sum + p.entries.length);

    final sync = await api.beginPlaylistSync(
      expectedPlaylists: playlists.length,
      expectedEntries: totalEntries,
    );
    _checkCancelled();

    final totalUnits = playlists.length + totalEntries;
    var completedUnits = 0;
    void reportPlaylists() {
      final ratio = totalUnits == 0 ? 1.0 : (completedUnits / totalUnits).clamp(0.0, 1.0);
      onProgress?.call(_uploadStageEnd + (_playlistStageEnd - _uploadStageEnd) * ratio);
    }

    for (var offset = 0; offset < playlists.length; offset += playlistChunkSize) {
      _checkCancelled();
      final chunk = playlists.sublist(offset, math.min(offset + playlistChunkSize, playlists.length));
      final accepted = await api.putPlaylists(sync.syncId, chunk.map(_playlistSnapshot).toList());
      _checkCancelled();
      if (accepted != chunk.length) throw const ListeningImportProtocolException();
      completedUnits += chunk.length;
      reportPlaylists();

      for (final playlist in chunk) {
        final entries = List.of(playlist.entries)..sort((a, b) => a.position.compareTo(b.position));
        // An empty playlist still sends one empty page, as the Apple sync does.
        var entryOffset = 0;
        while (true) {
          _checkCancelled();
          final page = entries.sublist(entryOffset, math.min(entryOffset + entryChunkSize, entries.length));
          final accepted = await api.putPlaylistEntries(
            sync.syncId,
            playlist.key,
            page.map((entry) => _entrySnapshot(playlist, entry)).toList(),
          );
          _checkCancelled();
          if (accepted != page.length) throw const ListeningImportProtocolException();
          if (page.isEmpty) break;
          entryOffset += page.length;
          completedUnits += page.length;
          reportPlaylists();
          if (entryOffset == entries.length) break;
        }
      }
    }
    if (totalUnits == 0) reportPlaylists();

    _checkCancelled();
    final summary = await api.completePlaylistSync(sync.syncId);
    _checkCancelled();
    if (summary.playlists != playlists.length ||
        summary.entries != totalEntries ||
        summary.resolvedEntries + summary.unresolvedEntries != summary.entries) {
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
      for (var index = 0; index < rows.length; index++) {'ordinal': index, ...rows[index]},
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

  static Map<String, Object?> _entrySnapshot(SnapshotPlaylist playlist, SnapshotEntry entry) => {
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

/// Lowercase hex SHA-256 of the entries in position order, one line per
/// entry: `position \t platformId (empty when null) \t title \t artist`,
/// lines joined with `\n`. The same value the web import service computes,
/// so a playlist re-imported from either surface is recognised as unchanged.
String playlistFingerprint(List<SnapshotEntry> entries) {
  final ordered = List.of(entries)..sort((a, b) => a.position.compareTo(b.position));
  final text = ordered
      .map((e) => '${e.position}\t${e.platformId ?? ''}\t${e.title}\t${e.artist}')
      .join('\n');
  return sha256.convert(utf8.encode(text)).toString();
}
