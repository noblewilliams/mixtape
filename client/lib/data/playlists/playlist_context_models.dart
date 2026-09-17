/// A malformed response cannot safely supply the revision for a later write.
class PlaylistContextModelException implements Exception {
  const PlaylistContextModelException();

  @override
  String toString() => 'Invalid playlist context response';
}

enum PlaylistSeedStatus { none, ready, unavailable, insufficientProfile }

enum PlaylistSeedSource { apple, spotifyExport }

class InitialPlaylistSeed {
  const InitialPlaylistSeed({
    required this.playlistId,
    this.excludeSourceTracks = false,
  });

  final String playlistId;
  final bool excludeSourceTracks;

  Map<String, Object?> toJson() => {
    'playlistId': playlistId,
    'excludeSourceTracks': excludeSourceTracks,
  };
}

class PlaylistSeedProfile {
  const PlaylistSeedProfile({
    required this.sampledRecordings,
    required this.tempo,
    required this.energy,
    required this.releaseYear,
    required this.artists,
    required this.genres,
  });

  factory PlaylistSeedProfile.fromJson(Map<String, dynamic> json) =>
      PlaylistSeedProfile(
        sampledRecordings: _count(json['sampledRecordings']),
        tempo: _number(json['tempo']),
        energy: _number(json['energy']),
        releaseYear: _number(json['releaseYear']),
        artists: _strings(json['artists']),
        genres: _strings(json['genres']),
      );

  final int sampledRecordings;
  final double? tempo;
  final double? energy;
  final double? releaseYear;
  final List<String> artists;
  final List<String> genres;
}

class PlaylistSeedState {
  const PlaylistSeedState({
    required this.playlistId,
    required this.revision,
    required this.excludeSourceTracks,
    required this.status,
    required this.name,
    required this.source,
    required this.fingerprint,
    required this.updatedAt,
    required this.entries,
    required this.resolvedEntries,
    required this.recordings,
    required this.profile,
  });

  factory PlaylistSeedState.fromJson(Map<String, dynamic> json) {
    const fields = [
      'playlistId',
      'revision',
      'excludeSourceTracks',
      'status',
      'name',
      'source',
      'fingerprint',
      'updatedAt',
      'entries',
      'resolvedEntries',
      'recordings',
      'profile',
    ];
    if (fields.any((field) => !json.containsKey(field))) {
      throw const PlaylistContextModelException();
    }
    final status = switch (json['status']) {
      'none' => PlaylistSeedStatus.none,
      'ready' => PlaylistSeedStatus.ready,
      'unavailable' => PlaylistSeedStatus.unavailable,
      'insufficient_profile' => PlaylistSeedStatus.insufficientProfile,
      _ => throw const PlaylistContextModelException(),
    };
    final source = switch (json['source']) {
      null => null,
      'apple' => PlaylistSeedSource.apple,
      'spotify_export' => PlaylistSeedSource.spotifyExport,
      _ => throw const PlaylistContextModelException(),
    };
    final exclude = json['excludeSourceTracks'];
    if (exclude is! bool) throw const PlaylistContextModelException();
    final updatedAt = _text(json['updatedAt']);
    if (updatedAt != null && DateTime.tryParse(updatedAt) == null) {
      throw const PlaylistContextModelException();
    }
    return PlaylistSeedState(
      playlistId: _text(json['playlistId']),
      revision: _count(json['revision']),
      excludeSourceTracks: exclude,
      status: status,
      name: _text(json['name']),
      source: source,
      fingerprint: _text(json['fingerprint']),
      updatedAt: updatedAt == null ? null : DateTime.parse(updatedAt),
      entries: _count(json['entries']),
      resolvedEntries: _count(json['resolvedEntries']),
      recordings: _count(json['recordings']),
      profile: json['profile'] == null
          ? null
          : PlaylistSeedProfile.fromJson(
              playlistContextObject(json['profile']),
            ),
    );
  }

  final String? playlistId;
  final int revision;
  final bool excludeSourceTracks;
  final PlaylistSeedStatus status;
  final String? name;
  final PlaylistSeedSource? source;
  final String? fingerprint;
  final DateTime? updatedAt;
  final int entries;
  final int resolvedEntries;
  final int recordings;
  final PlaylistSeedProfile? profile;
}

Map<String, dynamic> playlistContextObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const PlaylistContextModelException();
  }
  return value;
}

int _count(Object? value) {
  if (value is! int || value < 0) throw const PlaylistContextModelException();
  return value;
}

String? _text(Object? value) {
  if (value == null || value is String) return value as String?;
  throw const PlaylistContextModelException();
}

double? _number(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw const PlaylistContextModelException();
  }
  return value.toDouble();
}

List<String> _strings(Object? value) {
  if (value is! List || value.any((entry) => entry is! String)) {
    throw const PlaylistContextModelException();
  }
  return List<String>.unmodifiable(value.cast<String>());
}
