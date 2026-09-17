/// What the dock's mini-player shows
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock).
library;

import 'package:flutter/foundation.dart';

/// The mini-player's whole state: one line of identity and one of transport.
///
/// The same value drives the native dock (through [toMap] over
/// `mixtape/shell`) and the Flutter `FrostedDock` fallback, so the two never
/// drift. Nothing plays → [MiniPlayerState.hidden], and the board's rule that
/// the layout must not shift when the player appears is the dock's job, not
/// this value's.
@immutable
class MiniPlayerState {
  const MiniPlayerState({
    required this.visible,
    this.title = '',
    this.artist = '',
    this.artworkUrl,
    this.playing = false,
  });

  /// Nothing is playing: no mini-player, no text, no artwork.
  const MiniPlayerState.hidden()
    : visible = false,
      title = '',
      artist = '',
      artworkUrl = null,
      playing = false;

  final bool visible;
  final String title;
  final String artist;

  /// Absent until the artwork URL is known; the dock draws tape fill instead.
  final String? artworkUrl;
  final bool playing;

  MiniPlayerState copyWith({
    bool? visible,
    String? title,
    String? artist,
    String? artworkUrl,
    bool? playing,
  }) => MiniPlayerState(
    visible: visible ?? this.visible,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    artworkUrl: artworkUrl ?? this.artworkUrl,
    playing: playing ?? this.playing,
  );

  /// The channel payload. Keys are the `setMiniPlayer` contract.
  Map<String, Object?> toMap() => <String, Object?>{
    'visible': visible,
    'title': title,
    'artist': artist,
    'artworkUrl': artworkUrl,
    'playing': playing,
  };

  @override
  bool operator ==(Object other) =>
      other is MiniPlayerState &&
      other.visible == visible &&
      other.title == title &&
      other.artist == artist &&
      other.artworkUrl == artworkUrl &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(visible, title, artist, artworkUrl, playing);

  @override
  String toString() =>
      'MiniPlayerState(visible: $visible, title: $title, artist: $artist, '
      'artworkUrl: $artworkUrl, playing: $playing)';
}
