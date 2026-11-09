/// The device's one music platform (decision 1 of
/// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`): Apple
/// Music or Spotify. It decides every mix's actions. A device preference like
/// the playlist author, so it is not user-scoped and survives sign-out (and
/// the anonymous-to-account merge).
///
/// It replaces the three-way Play destination under the same storage key: a
/// stored `here` (the app's player) or `apple_music` (the Music app) both
/// read as Apple Music.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum MusicPlatform {
  /// Apple Music: Play (the app's player, falling back to the Music app) and
  /// Create playlist.
  apple,

  /// Spotify: the song list is copied and TuneMyMusic builds the playlist.
  spotify;

  static MusicPlatform? fromWire(String? value) => switch (value) {
    'here' || 'apple_music' => MusicPlatform.apple,
    'spotify' => MusicPlatform.spotify,
    _ => null,
  };

  /// Apple is written as `apple_music`, which every build (this one and the
  /// split-Play builds before it) reads as Apple Music.
  String get wire => switch (this) {
    MusicPlatform.apple => 'apple_music',
    MusicPlatform.spotify => 'spotify',
  };
}

abstract class MusicPlatformStore {
  /// The remembered platform, or null when nothing (or nothing readable) is
  /// stored.
  Future<MusicPlatform?> read();
  Future<void> write(MusicPlatform platform);

  /// Whether the Spotify playlist explainer has been carried through once on
  /// this device; after that a tap copies and opens TuneMyMusic directly.
  Future<bool> spotifyIntroSeen();
  Future<void> markSpotifyIntroSeen();
}

class SecureMusicPlatformStore implements MusicPlatformStore {
  SecureMusicPlatformStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  /// The Play destination's key, kept so earlier answers carry over.
  static const _key = 'mixtape_play_destination';
  static const _introKey = 'mixtape_spotify_intro_seen';
  final FlutterSecureStorage _storage;

  @override
  Future<MusicPlatform?> read() async =>
      MusicPlatform.fromWire(await _storage.read(key: _key));

  @override
  Future<void> write(MusicPlatform platform) =>
      _storage.write(key: _key, value: platform.wire);

  @override
  Future<bool> spotifyIntroSeen() async =>
      await _storage.read(key: _introKey) != null;

  @override
  Future<void> markSpotifyIntroSeen() =>
      _storage.write(key: _introKey, value: 'seen');
}

class InMemoryMusicPlatformStore implements MusicPlatformStore {
  InMemoryMusicPlatformStore([this._platform]);
  MusicPlatform? _platform;

  @override
  Future<MusicPlatform?> read() async => _platform;

  @override
  Future<void> write(MusicPlatform platform) async => _platform = platform;

  bool _introSeen = false;

  @override
  Future<bool> spotifyIntroSeen() async => _introSeen;

  @override
  Future<void> markSpotifyIntroSeen() async => _introSeen = true;
}
