import 'package:flutter/services.dart';

class LibrarySong {
  const LibrarySong({
    required this.appleId,
    required this.title,
    required this.artist,
    required this.playCount,
    this.album,
    this.genre,
    this.lastPlayedAt,
    this.dateAdded,
  });

  final String appleId;
  final String title;
  final String artist;
  final int playCount;
  final String? album;
  final String? genre;
  final int? lastPlayedAt; // epoch ms
  final int? dateAdded; // epoch ms

  factory LibrarySong.fromMap(Map<dynamic, dynamic> m) => LibrarySong(
        appleId: m['appleId'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        playCount: m['playCount'] as int,
        album: m['album'] as String?,
        genre: m['genre'] as String?,
        lastPlayedAt: m['lastPlayedAt'] as int?,
        dateAdded: m['dateAdded'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'appleId': appleId,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
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

class MusicKitBridge {
  static const _channel = MethodChannel('mixtape/musickit');

  Future<bool> requestAuthorization() async =>
      await _channel.invokeMethod<bool>('requestAuthorization') ?? false;

  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'fetchLibrarySongs',
      {'offset': offset, 'limit': limit},
    );
    final songs = (raw!['songs'] as List)
        .map((s) => LibrarySong.fromMap(s as Map<dynamic, dynamic>))
        .toList();
    return LibraryPage(songs: songs, total: raw['total'] as int);
  }
}
