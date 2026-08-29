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
  static const _channel = MethodChannel('mixtape/musickit');

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
}
