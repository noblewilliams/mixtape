class PlaylistModelException implements Exception {
  const PlaylistModelException();

  @override
  String toString() => 'PlaylistModelException';
}

enum PlaylistStatus {
  active('active'),
  all('all');

  const PlaylistStatus(this.wireValue);

  final String wireValue;
}

class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.name,
    required this.kind,
    required this.entryCount,
    required this.inLibrary,
    required this.capability,
    this.curatorName,
    this.artworkUrlTemplate,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
    this.knownDurationMs,
    this.lastModifiedAt,
    this.syncedAt,
  });

  factory PlaylistSummary.fromJson(Map<String, dynamic> json) {
    return PlaylistSummary(
      id: _requiredString(json['id']),
      name: _requiredString(json['name']),
      curatorName: _optionalString(json['curatorName']),
      kind: _requiredString(json['kind']),
      artworkUrlTemplate: _optionalString(json['artworkUrlTemplate']),
      artworkWidth: _optionalPositiveInt(json['artworkWidth']),
      artworkHeight: _optionalPositiveInt(json['artworkHeight']),
      artworkBgColor: _optionalHexColor(json['artworkBgColor']),
      entryCount: _requiredNonNegativeInt(json['entryCount']),
      knownDurationMs: _optionalNonNegativeInt(json['knownDurationMs']),
      lastModifiedAt: _optionalDateTime(json['lastModifiedAt']),
      syncedAt: _optionalDateTime(json['syncedAt']),
      inLibrary: _requiredBool(json['inLibrary']),
      capability: _requiredString(json['capability']),
    );
  }

  final String id;
  final String name;
  final String? curatorName;
  final String kind;
  final String? artworkUrlTemplate;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  final int entryCount;
  final int? knownDurationMs;
  final DateTime? lastModifiedAt;
  final DateTime? syncedAt;
  final bool inLibrary;
  final String capability;
}

class PlaylistEntry {
  const PlaylistEntry({
    required this.id,
    required this.position,
    required this.title,
    required this.artist,
    required this.resolved,
    this.trackId,
    this.appleCatalogId,
    this.album,
    this.durationMs,
    this.artworkUrlTemplate,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
  });

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) {
    return PlaylistEntry(
      id: _requiredString(json['id']),
      position: _requiredNonNegativeInt(json['position']),
      trackId: _optionalString(json['trackId']),
      appleCatalogId: _optionalString(json['appleCatalogId']),
      title: _requiredString(json['title']),
      artist: _requiredString(json['artist']),
      album: _optionalString(json['album']),
      durationMs: _optionalNonNegativeInt(json['durationMs']),
      artworkUrlTemplate: _optionalString(json['artworkUrlTemplate']),
      artworkWidth: _optionalPositiveInt(json['artworkWidth']),
      artworkHeight: _optionalPositiveInt(json['artworkHeight']),
      artworkBgColor: _optionalHexColor(json['artworkBgColor']),
      resolved: _requiredBool(json['resolved']),
    );
  }

  final String id;
  final int position;
  final String? trackId;
  final String? appleCatalogId;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artworkUrlTemplate;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  final bool resolved;
}

class PlaylistPage {
  const PlaylistPage({required this.playlists, this.nextCursor});

  final List<PlaylistSummary> playlists;
  final String? nextCursor;
}

class PlaylistDetail {
  const PlaylistDetail({
    required this.playlist,
    required this.entries,
    this.nextEntryCursor,
  });

  final PlaylistSummary playlist;
  final List<PlaylistEntry> entries;
  final String? nextEntryCursor;
}

String _requiredString(Object? value) {
  if (value is! String || value.isEmpty) throw const PlaylistModelException();
  return value;
}

bool _requiredBool(Object? value) {
  if (value is! bool) throw const PlaylistModelException();
  return value;
}

int _requiredNonNegativeInt(Object? value) {
  if (value is! int || value < 0) throw const PlaylistModelException();
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}

int? _optionalNonNegativeInt(Object? value) {
  if (value is! int || value < 0) return null;
  return value;
}

int? _optionalPositiveInt(Object? value) {
  if (value is! int || value <= 0) return null;
  return value;
}

String? _optionalHexColor(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{6}$').hasMatch(value)) {
    return null;
  }
  return value;
}

DateTime? _optionalDateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}
