/// Where a mix's Play button plays (`docs/mockups/approved/2026-11-03-mix-
/// conversation-redesign.md` → Split Play): the app's own player, or Apple
/// Music's. A device preference like the playlist author, so it is not
/// user-scoped and survives sign-out.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum PlayDestination {
  /// The app's own player — the default.
  here,

  /// Apple Music's player (the Music app).
  appleMusic;

  static PlayDestination? fromWire(String? value) => switch (value) {
    'here' => PlayDestination.here,
    'apple_music' => PlayDestination.appleMusic,
    _ => null,
  };

  String get wire => switch (this) {
    PlayDestination.here => 'here',
    PlayDestination.appleMusic => 'apple_music',
  };
}

abstract class PlayDestinationStore {
  /// The remembered destination, or null when nothing (or nothing readable)
  /// is stored.
  Future<PlayDestination?> read();
  Future<void> write(PlayDestination destination);
}

class SecurePlayDestinationStore implements PlayDestinationStore {
  SecurePlayDestinationStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mixtape_play_destination';
  final FlutterSecureStorage _storage;

  @override
  Future<PlayDestination?> read() async =>
      PlayDestination.fromWire(await _storage.read(key: _key));

  @override
  Future<void> write(PlayDestination destination) =>
      _storage.write(key: _key, value: destination.wire);
}

class InMemoryPlayDestinationStore implements PlayDestinationStore {
  InMemoryPlayDestinationStore([this._destination]);
  PlayDestination? _destination;

  @override
  Future<PlayDestination?> read() async => _destination;

  @override
  Future<void> write(PlayDestination destination) async =>
      _destination = destination;
}
