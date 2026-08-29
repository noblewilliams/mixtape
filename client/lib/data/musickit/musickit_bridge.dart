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
  /// 20s production default.
  MusicKitBridge({Duration callTimeout = const Duration(seconds: 20)})
    : _callTimeout = callTimeout;

  static const _channel = MethodChannel('mixtape/musickit');
  final Duration _callTimeout;

  Future<bool> requestAuthorization() async {
    try {
      return await _channel.invokeMethod<bool>('requestAuthorization') ?? false;
    } on PlatformException catch (e) {
      throw MusicKitException(e.message ?? e.code);
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
      throw MusicKitException(e.message ?? e.code);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
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
      throw MusicKitException(e.message ?? e.code);
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
  Future<({int added, int failed})> createPlaylist(String name, List<String> appleIds) async {
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
            {'name': name, 'appleIds': appleIds},
          )
          .timeout(_callTimeout);
      // Parsed defensively: any shape drift from the platform side — a
      // missing key OR a wrong-typed value — degrades to 0 rather than a
      // type-cast crash reaching the UI layer.
      final rawAdded = raw?['added'];
      final rawFailed = raw?['failed'];
      final added = rawAdded is int ? rawAdded : 0;
      final failed = rawFailed is int ? rawFailed : 0;
      return (added: added, failed: failed);
    } on PlatformException catch (e) {
      throw MusicKitException(e.message ?? e.code);
    } on MissingPluginException {
      throw MusicKitException('MusicKit bridge not registered');
    } on TimeoutException {
      // A native completion that never fires (e.g. a stuck getPlaylist/
      // addItem chain) must not leave this Future unresolved forever.
      throw MusicKitException('timed out waiting for the Music app');
    }
  }
}
