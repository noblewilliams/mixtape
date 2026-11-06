/// Where a mix's Play button plays (`docs/mockups/approved/2026-11-03-mix-
/// conversation-redesign.md` → Split Play; Spotify added 2026-11-06): the
/// app's own player, Apple Music's, or Spotify by way of the TuneMyMusic
/// handoff. A device preference like the playlist author, so it is not
/// user-scoped and survives sign-out (and the anonymous-to-account merge).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum PlayDestination {
  /// The app's own player — the default.
  here,

  /// Apple Music's player (the Music app).
  appleMusic,

  /// Spotify: the song list is copied and TuneMyMusic builds the playlist.
  spotify;

  static PlayDestination? fromWire(String? value) => switch (value) {
    'here' => PlayDestination.here,
    'apple_music' => PlayDestination.appleMusic,
    'spotify' => PlayDestination.spotify,
    _ => null,
  };

  String get wire => switch (this) {
    PlayDestination.here => 'here',
    PlayDestination.appleMusic => 'apple_music',
    PlayDestination.spotify => 'spotify',
  };
}

abstract class PlayDestinationStore {
  /// The remembered destination, or null when nothing (or nothing readable)
  /// is stored.
  Future<PlayDestination?> read();
  Future<void> write(PlayDestination destination);

  /// Whether the Play on Spotify explainer has been carried through once on
  /// this device; after that a tap copies and opens TuneMyMusic directly.
  Future<bool> spotifyIntroSeen();
  Future<void> markSpotifyIntroSeen();
}

class SecurePlayDestinationStore implements PlayDestinationStore {
  SecurePlayDestinationStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mixtape_play_destination';
  static const _introKey = 'mixtape_spotify_intro_seen';
  final FlutterSecureStorage _storage;

  @override
  Future<PlayDestination?> read() async =>
      PlayDestination.fromWire(await _storage.read(key: _key));

  @override
  Future<void> write(PlayDestination destination) =>
      _storage.write(key: _key, value: destination.wire);

  @override
  Future<bool> spotifyIntroSeen() async =>
      await _storage.read(key: _introKey) != null;

  @override
  Future<void> markSpotifyIntroSeen() =>
      _storage.write(key: _introKey, value: 'seen');
}

class InMemoryPlayDestinationStore implements PlayDestinationStore {
  InMemoryPlayDestinationStore([this._destination]);
  PlayDestination? _destination;

  @override
  Future<PlayDestination?> read() async => _destination;

  @override
  Future<void> write(PlayDestination destination) async =>
      _destination = destination;

  bool _introSeen = false;

  @override
  Future<bool> spotifyIntroSeen() async => _introSeen;

  @override
  Future<void> markSpotifyIntroSeen() async => _introSeen = true;
}
