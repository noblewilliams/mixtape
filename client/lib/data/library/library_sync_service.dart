import 'dart:async';
import 'dart:convert';

import '../api/api_client.dart';
import '../musickit/musickit_bridge.dart';

class LibraryAccessDenied implements Exception {}

/// Thrown when [LibrarySyncService.cancel] interrupts a run in progress.
class SyncCancelled implements Exception {}

class LibrarySyncProtocolException implements Exception {
  const LibrarySyncProtocolException();

  @override
  String toString() => 'LibrarySyncProtocolException';
}

class LibrarySyncSummary {
  const LibrarySyncSummary({
    required this.songs,
    required this.playlists,
    required this.entries,
    required this.resolvedEntries,
    required this.unresolvedEntries,
  });

  final int songs;
  final int playlists;
  final int entries;
  final int resolvedEntries;
  final int unresolvedEntries;
}

class LibrarySyncService {
  LibrarySyncService({
    required this.bridge,
    required this.api,
    this.chunkSize = 200,
  }) {
    assert(chunkSize > 0);
  }

  static const _songStageEnd = 0.6;
  static const _playlistStageEnd = 0.95;
  static const _playlistChunkSize = 50;
  static const _entryChunkSize = 200;

  final MusicKitBridge bridge;
  final ApiClient api;
  final int chunkSize;

  Future<LibrarySyncSummary>? _inFlight;
  bool _cancelRequested = false;
  bool _materializingPlaylists = false;

  /// Requests that the in-flight run stop at its next await boundary.
  /// Native playlist materialization is cancelled immediately because it can
  /// otherwise spend minutes paging MusicKit without returning to Dart.
  void cancel() {
    if (_inFlight == null) return;
    _cancelRequested = true;
    if (_materializingPlaylists) {
      unawaited(bridge.cancelPlaylistSnapshot().catchError((_) => false));
    }
  }

  /// Full library sync. Songs are uploaded first so playlist entries can link
  /// to known catalog tracks when the staged playlist snapshot is published.
  /// Concurrent callers join the same in-flight run; the joiner's progress
  /// callback is intentionally ignored.
  Future<LibrarySyncSummary> sync({
    void Function(double progress)? onProgress,
  }) => _inFlight ??= _run(onProgress).whenComplete(() {
    _inFlight = null;
    _cancelRequested = false;
    _materializingPlaylists = false;
  });

  void _checkCancelled() {
    if (_cancelRequested) throw SyncCancelled();
  }

  Future<LibrarySyncSummary> _run(
    void Function(double progress)? onProgress,
  ) async {
    final authorized = await bridge.requestAuthorization();
    _checkCancelled();
    if (!authorized) throw LibraryAccessDenied();

    final songs = await _syncSongs(onProgress);
    _checkCancelled();

    PlaylistSnapshotHeader? snapshot;
    Object? failure;
    StackTrace? failureStack;
    LibrarySyncSummary? result;
    try {
      _materializingPlaylists = true;
      try {
        snapshot = await bridge.beginPlaylistSnapshot();
      } catch (_) {
        if (_cancelRequested) throw SyncCancelled();
        rethrow;
      } finally {
        _materializingPlaylists = false;
      }
      _checkCancelled();
      result = await _syncPlaylistSnapshot(snapshot, songs, onProgress);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }

    if (snapshot != null) {
      try {
        await bridge.releasePlaylistSnapshot(snapshot.snapshotId);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    return result!;
  }

  Future<int> _syncSongs(void Function(double progress)? onProgress) async {
    var offset = 0;
    var total = 0;
    while (true) {
      _checkCancelled();
      final page = await bridge.fetchLibrarySongs(
        offset: offset,
        limit: chunkSize,
      );
      _checkCancelled();
      total = page.total;
      if (page.songs.isEmpty) break;
      await api.postJson('/ingest/library', {
        'songs': page.songs.map((song) => song.toJson()).toList(),
      });
      _checkCancelled();
      offset += page.songs.length;
      final ratio = total == 0 ? 1.0 : (offset / total).clamp(0.0, 1.0);
      onProgress?.call(_songStageEnd * ratio);
      if (offset >= total) break;
    }
    if (total == 0) onProgress?.call(_songStageEnd);
    return total;
  }

  Future<LibrarySyncSummary> _syncPlaylistSnapshot(
    PlaylistSnapshotHeader snapshot,
    int songs,
    void Function(double progress)? onProgress,
  ) async {
    final startResponse = await api.postJson('/ingest/playlists/syncs', {
      'storefront': snapshot.storefront,
      'expectedPlaylists': snapshot.totalPlaylists,
      'expectedEntries': snapshot.totalEntries,
    });
    _checkCancelled();
    final start = _decodeObject(startResponse.body);
    final syncId = start['syncId'];
    if (syncId is! String || syncId.isEmpty) {
      throw const LibrarySyncProtocolException();
    }

    final totalUnits = snapshot.totalPlaylists + snapshot.totalEntries;
    var completedUnits = 0;
    void reportPlaylistProgress() {
      final ratio = totalUnits == 0 ? 1.0 : completedUnits / totalUnits;
      onProgress?.call(
        _songStageEnd +
            ((_playlistStageEnd - _songStageEnd) * ratio.clamp(0.0, 1.0)),
      );
    }

    var playlistOffset = 0;
    var uploadedEntries = 0;
    while (playlistOffset < snapshot.totalPlaylists) {
      final page = await bridge.fetchPlaylistSnapshotPage(
        snapshotId: snapshot.snapshotId,
        offset: playlistOffset,
        limit: _playlistChunkSize,
      );
      _checkCancelled();
      if (page.total != snapshot.totalPlaylists || page.playlists.isEmpty) {
        throw const LibrarySyncProtocolException();
      }
      if (playlistOffset + page.playlists.length > snapshot.totalPlaylists) {
        throw const LibrarySyncProtocolException();
      }
      await api.putJson('/ingest/playlists/syncs/$syncId/playlists', {
        'playlists': [
          for (var index = 0; index < page.playlists.length; index++)
            {
              'ordinal': playlistOffset + index,
              ...page.playlists[index].toJson(),
            },
        ],
      });
      _checkCancelled();
      playlistOffset += page.playlists.length;
      completedUnits += page.playlists.length;
      reportPlaylistProgress();

      for (final playlist in page.playlists) {
        var entryOffset = 0;
        while (true) {
          final entryPage = await bridge.fetchPlaylistEntryPage(
            snapshotId: snapshot.snapshotId,
            playlistAppleId: playlist.appleLibraryId,
            offset: entryOffset,
            limit: _entryChunkSize,
          );
          _checkCancelled();
          if (entryPage.total != playlist.entryCount) {
            throw const LibrarySyncProtocolException();
          }
          if (entryPage.entries.isEmpty && entryOffset < playlist.entryCount) {
            throw const LibrarySyncProtocolException();
          }
          if (entryOffset + entryPage.entries.length > playlist.entryCount ||
              uploadedEntries + entryPage.entries.length >
                  snapshot.totalEntries) {
            throw const LibrarySyncProtocolException();
          }
          await api.putJson('/ingest/playlists/syncs/$syncId/entries', {
            'playlistAppleId': playlist.appleLibraryId,
            'entries': entryPage.entries
                .map((entry) => entry.toJson())
                .toList(),
          });
          _checkCancelled();
          if (entryPage.entries.isEmpty) break;
          entryOffset += entryPage.entries.length;
          uploadedEntries += entryPage.entries.length;
          completedUnits += entryPage.entries.length;
          reportPlaylistProgress();
          if (entryOffset == playlist.entryCount) break;
        }
      }
    }

    if (playlistOffset != snapshot.totalPlaylists ||
        uploadedEntries != snapshot.totalEntries) {
      throw const LibrarySyncProtocolException();
    }
    if (totalUnits == 0) reportPlaylistProgress();
    _checkCancelled();
    final completeResponse = await api.postJson(
      '/ingest/playlists/syncs/$syncId/complete',
      const <String, dynamic>{},
    );
    _checkCancelled();
    final complete = _decodeObject(completeResponse.body);
    final playlists = _nonnegativeResult(complete, 'playlists');
    final entries = _nonnegativeResult(complete, 'entries');
    final resolvedEntries = _nonnegativeResult(complete, 'resolvedEntries');
    final unresolvedEntries = _nonnegativeResult(complete, 'unresolvedEntries');
    if (playlists != snapshot.totalPlaylists ||
        entries != snapshot.totalEntries ||
        resolvedEntries + unresolvedEntries != entries) {
      throw const LibrarySyncProtocolException();
    }
    onProgress?.call(1.0);
    return LibrarySyncSummary(
      songs: songs,
      playlists: playlists,
      entries: entries,
      resolvedEntries: resolvedEntries,
      unresolvedEntries: unresolvedEntries,
    );
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const LibrarySyncProtocolException();
      }
      return decoded;
    } on LibrarySyncProtocolException {
      rethrow;
    } catch (_) {
      throw const LibrarySyncProtocolException();
    }
  }

  int _nonnegativeResult(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 0) {
      throw const LibrarySyncProtocolException();
    }
    return field;
  }
}
