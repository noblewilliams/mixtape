import 'dart:async';

import 'package:flutter/services.dart';

class LibrarySong {
  const LibrarySong({
    required this.appleId,
    required this.title,
    required this.artist,
    required this.playCount,
    this.album,
    this.genre,
    this.releaseYear,
    this.explicit,
    this.lastPlayedAt,
    this.dateAdded,
  });

  final String appleId;
  final String title;
  final String artist;
  final int playCount;
  final String? album;
  final String? genre;
  final int? releaseYear;
  final bool? explicit;
  final int? lastPlayedAt; // epoch ms
  final int? dateAdded; // epoch ms

  factory LibrarySong.fromMap(Map<dynamic, dynamic> m) => LibrarySong(
        appleId: m['appleId'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        playCount: m['playCount'] as int,
        album: m['album'] as String?,
        genre: m['genre'] as String?,
        releaseYear: m['releaseYear'] as int?,
        explicit: m['explicit'] as bool?,
        lastPlayedAt: m['lastPlayedAt'] as int?,
        dateAdded: m['dateAdded'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'appleId': appleId,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'releaseYear': releaseYear,
        'explicit': explicit,
        'playCount': playCount,
        'lastPlayedAt': lastPlayedAt,
        'dateAdded': dateAdded,
      };
}

class LibraryPage {
  const LibraryPage({required this.songs, required this.total});
  final List<LibrarySong> songs;
  final int total;
}

class PlaylistSnapshotHeader {
  const PlaylistSnapshotHeader({
    required this.snapshotId,
    required this.storefront,
    required this.totalPlaylists,
    required this.totalEntries,
  });

  final String snapshotId;
  final String storefront;
  final int totalPlaylists;
  final int totalEntries;

  factory PlaylistSnapshotHeader.fromMap(Map<dynamic, dynamic> map) {
    final snapshotId = _requiredString(map, 'snapshotId');
    final storefront = _requiredString(map, 'storefront');
    final totalPlaylists = _nonnegativeInt(map, 'totalPlaylists');
    final totalEntries = _nonnegativeInt(map, 'totalEntries');
    if (!RegExp(r'^[a-z]{2}$').hasMatch(storefront)) {
      throw MusicKitException('malformed playlist snapshot header');
    }
    return PlaylistSnapshotHeader(
      snapshotId: snapshotId,
      storefront: storefront,
      totalPlaylists: totalPlaylists,
      totalEntries: totalEntries,
    );
  }
}

class PlaylistSnapshotPlaylist {
  const PlaylistSnapshotPlaylist({
    required this.appleLibraryId,
    required this.name,
    required this.kind,
    required this.canEdit,
    required this.sourceFingerprint,
    required this.entryCount,
    this.appleCatalogId,
    this.description,
    this.curatorName,
    this.artworkUrlTemplate,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
    this.appleDateAdded,
    this.appleLastModifiedAt,
  });

  static const _kinds = {
    'user',
    'editorial',
    'external',
    'personal_mix',
    'replay',
    'user_shared',
    'unknown',
  };

  final String appleLibraryId;
  final String? appleCatalogId;
  final String name;
  final String? description;
  final String? curatorName;
  final String? artworkUrlTemplate;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  final String kind;
  final bool canEdit;
  final int? appleDateAdded;
  final int? appleLastModifiedAt;
  final String sourceFingerprint;
  final int entryCount;

  factory PlaylistSnapshotPlaylist.fromMap(Map<dynamic, dynamic> map) {
    final kind = _requiredString(map, 'kind');
    final fingerprint = _requiredString(map, 'sourceFingerprint');
    if (!_kinds.contains(kind) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw MusicKitException('malformed playlist snapshot payload');
    }
    return PlaylistSnapshotPlaylist(
      appleLibraryId: _requiredString(map, 'appleLibraryId'),
      appleCatalogId: _nullableString(map, 'appleCatalogId'),
      name: _requiredString(map, 'name'),
      description: _nullableString(map, 'description', allowEmpty: true),
      curatorName: _nullableString(map, 'curatorName', allowEmpty: true),
      artworkUrlTemplate: _nullableString(map, 'artworkUrlTemplate'),
      artworkWidth: _positiveNullableInt(map, 'artworkWidth'),
      artworkHeight: _positiveNullableInt(map, 'artworkHeight'),
      artworkBgColor: _artworkColor(map, 'artworkBgColor'),
      kind: kind,
      canEdit: _requiredBool(map, 'canEdit'),
      appleDateAdded: _nullableInt(map, 'appleDateAdded'),
      appleLastModifiedAt: _nullableInt(map, 'appleLastModifiedAt'),
      sourceFingerprint: fingerprint,
      entryCount: _nonnegativeInt(map, 'entryCount'),
    );
  }

  Map<String, dynamic> toJson() => {
    'appleLibraryId': appleLibraryId,
    'appleCatalogId': appleCatalogId,
    'name': name,
    'description': description,
    'curatorName': curatorName,
    'artworkUrlTemplate': artworkUrlTemplate,
    'artworkWidth': artworkWidth,
    'artworkHeight': artworkHeight,
    'artworkBgColor': artworkBgColor,
    'kind': kind,
    'canEdit': canEdit,
    'appleDateAdded': appleDateAdded,
    'appleLastModifiedAt': appleLastModifiedAt,
    'sourceFingerprint': sourceFingerprint,
    'entryCount': entryCount,
  };
}

class PlaylistSnapshotEntry {
  const PlaylistSnapshotEntry({
    required this.position,
    required this.appleLibraryEntryId,
    required this.titleSnapshot,
    required this.artistSnapshot,
    this.appleLibraryTrackId,
    this.appleCatalogId,
    this.isrcSnapshot,
    this.albumSnapshot,
    this.durationMsSnapshot,
    this.artworkUrlTemplateSnapshot,
    this.artworkWidthSnapshot,
    this.artworkHeightSnapshot,
    this.artworkBgColorSnapshot,
  });

  final int position;
  final String appleLibraryEntryId;
  final String? appleLibraryTrackId;
  final String? appleCatalogId;
  final String? isrcSnapshot;
  final String titleSnapshot;
  final String artistSnapshot;
  final String? albumSnapshot;
  final int? durationMsSnapshot;
  final String? artworkUrlTemplateSnapshot;
  final int? artworkWidthSnapshot;
  final int? artworkHeightSnapshot;
  final String? artworkBgColorSnapshot;

  factory PlaylistSnapshotEntry.fromMap(Map<dynamic, dynamic> map) =>
      PlaylistSnapshotEntry(
        position: _nonnegativeInt(map, 'position'),
        appleLibraryEntryId: _requiredString(map, 'appleLibraryEntryId'),
        appleLibraryTrackId: _nullableString(map, 'appleLibraryTrackId'),
        appleCatalogId: _nullableString(map, 'appleCatalogId'),
        isrcSnapshot: _nullableString(map, 'isrcSnapshot'),
        titleSnapshot: _requiredString(map, 'titleSnapshot'),
        artistSnapshot: _requiredString(map, 'artistSnapshot'),
        albumSnapshot: _nullableString(map, 'albumSnapshot', allowEmpty: true),
        durationMsSnapshot: _nonnegativeNullableInt(map, 'durationMsSnapshot'),
        artworkUrlTemplateSnapshot: _nullableString(
          map,
          'artworkUrlTemplateSnapshot',
        ),
        artworkWidthSnapshot: _positiveNullableInt(map, 'artworkWidthSnapshot'),
        artworkHeightSnapshot: _positiveNullableInt(
          map,
          'artworkHeightSnapshot',
        ),
        artworkBgColorSnapshot: _artworkColor(map, 'artworkBgColorSnapshot'),
      );

  Map<String, dynamic> toJson() => {
    'position': position,
    'appleLibraryEntryId': appleLibraryEntryId,
    'appleLibraryTrackId': appleLibraryTrackId,
    'appleCatalogId': appleCatalogId,
    'isrcSnapshot': isrcSnapshot,
    'titleSnapshot': titleSnapshot,
    'artistSnapshot': artistSnapshot,
    'albumSnapshot': albumSnapshot,
    'durationMsSnapshot': durationMsSnapshot,
    'artworkUrlTemplateSnapshot': artworkUrlTemplateSnapshot,
    'artworkWidthSnapshot': artworkWidthSnapshot,
    'artworkHeightSnapshot': artworkHeightSnapshot,
    'artworkBgColorSnapshot': artworkBgColorSnapshot,
  };
}

class PlaylistSnapshotPage {
  const PlaylistSnapshotPage({required this.playlists, required this.total});
  final List<PlaylistSnapshotPlaylist> playlists;
  final int total;
}

class PlaylistEntryPage {
  const PlaylistEntryPage({required this.entries, required this.total});
  final List<PlaylistSnapshotEntry> entries;
  final int total;
}

String _requiredString(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

String? _nullableString(
  Map<dynamic, dynamic> map,
  String key, {
  bool allowEmpty = false,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

int _nonnegativeInt(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! int || value < 0) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

int? _nullableInt(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

int? _nonnegativeNullableInt(Map<dynamic, dynamic> map, String key) {
  final value = _nullableInt(map, key);
  if (value != null && value < 0) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

int? _positiveNullableInt(Map<dynamic, dynamic> map, String key) {
  final value = _nullableInt(map, key);
  if (value != null && value <= 0) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

bool _requiredBool(Map<dynamic, dynamic> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

String? _artworkColor(Map<dynamic, dynamic> map, String key) {
  final value = _nullableString(map, key);
  if (value != null && !RegExp(r'^[0-9a-f]{6}$').hasMatch(value)) {
    throw MusicKitException('malformed playlist snapshot payload');
  }
  return value;
}

/// Thrown for any failure talking to the native MusicKit bridge: a platform-side
/// error, the bridge not being registered, or a malformed/absent response.
class MusicKitException implements Exception {
  MusicKitException(this.message);
  final String message;
  @override
  String toString() => 'MusicKitException: $message';
}

class MusicKitBridge {
  /// [callTimeout] guards `playQueue`/`createPlaylist`'s native round trips
  /// (see each method's doc). Injectable (not just a hardcoded literal)
  /// purely so tests can exercise a real "the native completion never
  /// fires" path with a tiny duration instead of actually waiting out the
  /// 20s production default. `createPlaylist` additionally scales its
  /// timeout by track count — see [perTrackTimeout].
  MusicKitBridge({
    Duration callTimeout = const Duration(seconds: 20),
    Duration perTrackTimeout = const Duration(seconds: 3),
    Duration snapshotTimeout = const Duration(minutes: 2),
  }) : _callTimeout = callTimeout,
       _perTrackTimeout = perTrackTimeout,
       _snapshotTimeout = snapshotTimeout;

  static const _channel = MethodChannel('mixtape/musickit');
  final Duration _callTimeout;
  final Duration _snapshotTimeout;

  /// Extra timeout budget per track for `createPlaylist`: the native side
  /// adds tracks ONE AT A TIME (each `addItem(withProductID:)` is its own
  /// network round trip, sequenced to preserve queue order), so a flat 20s
  /// cap can expire mid-save on a healthy 10+ track queue — the Dart side
  /// would report failure while the native chain keeps going and the
  /// playlist quietly appears anyway.
  final Duration _perTrackTimeout;

  /// Prefers the platform-side `details` (Apple's actual
  /// localizedDescription, e.g. why getPlaylist refused) over the bridge's
  /// static message — without it every native failure collapses into an
  /// undiagnosable generic string.
  static MusicKitException _fromPlatform(PlatformException e) {
    final base = e.message ?? e.code;
    final detail = e.details;
    return MusicKitException(
      detail is String && detail.isNotEmpty ? '$base ($detail)' : base,
    );
  }

  static MusicKitException _fromSnapshotPlatform(PlatformException e) =>
      MusicKitException(e.code.isEmpty ? 'playlist_snapshot_failed' : e.code);

  Future<bool> requestAuthorization() async {
    try {
      return await _channel.invokeMethod<bool>('requestAuthorization') ?? false;
    } on PlatformException catch (e) {
      throw _fromPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    }
  }

  /// Pages from a native snapshot taken at offset 0 — always start a sync at offset 0.
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    final clampedLimit = limit.clamp(1, 500); // server batch ceiling
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchLibrarySongs',
        {'offset': offset, 'limit': clampedLimit},
      );
      if (raw == null) throw MusicKitException('null payload from platform');
      final songs = (raw['songs'] as List)
          .map((s) => LibrarySong.fromMap(s as Map<dynamic, dynamic>))
          .toList();
      return LibraryPage(songs: songs, total: raw['total'] as int);
    } on PlatformException catch (e) {
      throw _fromPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    }
  }

  Future<PlaylistSnapshotHeader> beginPlaylistSnapshot() async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('beginPlaylistSnapshot')
          .timeout(_snapshotTimeout);
      try {
        if (raw is! Map) {
          throw MusicKitException('malformed playlist snapshot header');
        }
        return PlaylistSnapshotHeader.fromMap(raw);
      } catch (_) {
        try {
          await cancelPlaylistSnapshot();
        } catch (_) {
          // Preserve the malformed-header category if native cleanup also fails.
        }
        throw MusicKitException('malformed playlist snapshot header');
      }
    } on PlatformException catch (e) {
      throw _fromSnapshotPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      try {
        await cancelPlaylistSnapshot();
      } catch (_) {
        // The original timeout is the useful fixed failure category.
      }
      throw MusicKitException('playlist snapshot timed out');
    }
  }

  Future<PlaylistSnapshotPage> fetchPlaylistSnapshotPage({
    required String snapshotId,
    required int offset,
    required int limit,
  }) async {
    _validatePageArguments(snapshotId: snapshotId, offset: offset);
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('fetchPlaylistSnapshotPage', {
            'snapshotId': snapshotId,
            'offset': offset,
            'limit': limit.clamp(1, 50),
          })
          .timeout(_callTimeout);
      if (raw == null || raw['playlists'] is! List) {
        throw MusicKitException('malformed playlist snapshot page');
      }
      final playlists = (raw['playlists'] as List)
          .map((value) {
            if (value is! Map) {
              throw MusicKitException('malformed playlist snapshot page');
            }
            return PlaylistSnapshotPlaylist.fromMap(value);
          })
          .toList(growable: false);
      return PlaylistSnapshotPage(
        playlists: playlists,
        total: _nonnegativeInt(raw, 'total'),
      );
    } on PlatformException catch (e) {
      throw _fromSnapshotPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      throw MusicKitException('playlist snapshot page timed out');
    }
  }

  Future<PlaylistEntryPage> fetchPlaylistEntryPage({
    required String snapshotId,
    required String playlistAppleId,
    required int offset,
    required int limit,
  }) async {
    _validatePageArguments(snapshotId: snapshotId, offset: offset);
    if (playlistAppleId.isEmpty) {
      throw MusicKitException('playlist id is required');
    }
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('fetchPlaylistEntryPage', {
            'snapshotId': snapshotId,
            'playlistAppleId': playlistAppleId,
            'offset': offset,
            'limit': limit.clamp(1, 200),
          })
          .timeout(_callTimeout);
      if (raw == null || raw['entries'] is! List) {
        throw MusicKitException('malformed playlist entry page');
      }
      final entries = (raw['entries'] as List)
          .map((value) {
            if (value is! Map) {
              throw MusicKitException('malformed playlist entry page');
            }
            return PlaylistSnapshotEntry.fromMap(value);
          })
          .toList(growable: false);
      return PlaylistEntryPage(
        entries: entries,
        total: _nonnegativeInt(raw, 'total'),
      );
    } on PlatformException catch (e) {
      throw _fromSnapshotPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      throw MusicKitException('playlist entry page timed out');
    }
  }

  Future<bool> cancelPlaylistSnapshot() async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('cancelPlaylistSnapshot')
          .timeout(_callTimeout);
      return raw is bool && raw;
    } on PlatformException catch (e) {
      throw _fromSnapshotPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      throw MusicKitException('playlist snapshot cancel timed out');
    }
  }

  Future<bool> releasePlaylistSnapshot(String snapshotId) async {
    if (snapshotId.isEmpty) {
      throw MusicKitException('snapshot id is required');
    }
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('releasePlaylistSnapshot', {
            'snapshotId': snapshotId,
          })
          .timeout(_callTimeout);
      return raw is bool && raw;
    } on PlatformException catch (e) {
      throw _fromSnapshotPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      throw MusicKitException('playlist snapshot release timed out');
    }
  }

  static void _validatePageArguments({
    required String snapshotId,
    required int offset,
  }) {
    if (snapshotId.isEmpty) {
      throw MusicKitException('snapshot id is required');
    }
    if (offset < 0) {
      throw MusicKitException('playlist snapshot offset must be nonnegative');
    }
  }

  /// Hands playback off to the Music app: `setQueue` + `play()` over
  /// `MPMusicPlayerController.systemMusicPlayer` on the native side.
  /// Playback then lives in the Music app and survives this app closing —
  /// this call only starts it. Guards against an empty [appleIds] BEFORE
  /// touching the channel, since the native side has nothing meaningful to
  /// queue and would otherwise have to invent its own "empty" error code.
  Future<bool> playQueue(List<String> appleIds) async {
    if (appleIds.isEmpty) {
      throw MusicKitException('cannot play an empty queue');
    }
    try {
      // Decoded via `dynamic` (not `invokeMethod<bool>`) so a wrong-typed
      // platform result degrades to false rather than a type-cast
      // TypeError escaping uncaught — the same same-shape-guard idiom as
      // createPlaylist's added/failed below.
      final result = await _channel
          .invokeMethod<dynamic>('playQueue', {'appleIds': appleIds})
          .timeout(_callTimeout);
      return result is bool ? result : false;
    } on PlatformException catch (e) {
      throw _fromPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      // A native completion that never fires (e.g. prepareToPlay hangs)
      // must not leave this Future unresolved forever.
      throw MusicKitException('timed out waiting for the Music app');
    }
  }

  /// Creates a new library playlist named [name] and adds [appleIds] to it.
  /// Per-track add failures are counted, not fatal — the native side keeps
  /// going and reports `added`/`failed` counts rather than aborting on the
  /// first bad id. Guards against an empty [name] or [appleIds] BEFORE
  /// touching the channel — there is no such thing as an empty-named or
  /// empty playlist worth creating.
  /// [author]/[description] land on the playlist's creation metadata —
  /// without an explicit author, Apple attributes the playlist to the Xcode
  /// product name ("Runner"). Omitted (null) keys are simply absent from
  /// the channel payload.
  Future<({int added, int failed})> createPlaylist(
    String name,
    List<String> appleIds, {
    String? author,
    String? description,
  }) async {
    if (name.isEmpty) {
      throw MusicKitException('playlist name cannot be empty');
    }
    if (appleIds.isEmpty) {
      throw MusicKitException('cannot create a playlist with no tracks');
    }
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(
            'createPlaylist',
            {
              'name': name,
              'appleIds': appleIds,
              if (author != null) 'author': author,
              if (description != null) 'description': description,
            },
          )
          .timeout(_callTimeout + _perTrackTimeout * appleIds.length);
      // Parsed defensively: any shape drift from the platform side — a
      // missing key OR a wrong-typed value — degrades to 0 rather than a
      // type-cast crash reaching the UI layer.
      final rawAdded = raw?['added'];
      final rawFailed = raw?['failed'];
      final added = rawAdded is int ? rawAdded : 0;
      final failed = rawFailed is int ? rawFailed : 0;
      return (added: added, failed: failed);
    } on PlatformException catch (e) {
      throw _fromPlatform(e);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      // A native completion that never fires (e.g. a stuck getPlaylist/
      // addItem chain) must not leave this Future unresolved forever.
      throw MusicKitException('timed out waiting for the Music app');
    }
  }
}
