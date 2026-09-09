import 'dart:convert';

/// Immutable models for a parsed Spotify export, mirroring the fixture
/// contract in `fixtures/listening-exports/README.md`. Every
/// `toCanonicalJson()` emits keys in the contract's order and sorts its lists
/// canonically, so the encoded document is byte-identical to the fixtures'
/// expected files (and to the web parser's output).

/// Which Spotify package a set of files classifies as.
enum ExportPackage {
  spotifyExtended('spotify_extended'),
  spotifyAccount('spotify_account'),
  spotifyExportify('spotify_exportify');

  const ExportPackage(this.wire);

  /// The value the snapshot and the import protocol carry.
  final String wire;
}

int _compareNullLast(String? a, String? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

String _encode(Object? json) =>
    '${const JsonEncoder.withIndent('  ').convert(json)}\n';

/// Two-space pretty print with a trailing newline: the fixture suite's format.
String canonicalJsonString(Object? json) => _encode(json);

class SnapshotTrack {
  const SnapshotTrack({
    required this.platformId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
  });

  final String platformId;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;

  Map<String, Object?> toCanonicalJson() => {
    'platformId': platformId,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
  };
}

class SnapshotDay {
  const SnapshotDay({
    required this.platformId,
    required this.day,
    required this.plays,
    required this.skips,
    required this.completes,
    required this.msPlayed,
    required this.hoursMask,
  });

  final String platformId;
  final String day;
  final int plays;
  final int skips;
  final int completes;
  final int msPlayed;
  final int hoursMask;

  Map<String, Object?> toCanonicalJson() => {
    'platformId': platformId,
    'day': day,
    'plays': plays,
    'skips': skips,
    'completes': completes,
    'msPlayed': msPlayed,
    'hoursMask': hoursMask,
  };
}

/// A liked track. Spotify's library export carries no counts, so every
/// count column is null.
class SnapshotLibraryRow {
  const SnapshotLibraryRow({required this.platformId, this.dateAdded});

  final int? dateAdded;

  final String platformId;

  Map<String, Object?> toCanonicalJson() => {
    'platformId': platformId,
    'playCount': null,
    'skipCount': null,
    'lastPlayedAt': null,
    'dateAdded': dateAdded,
    'likeRating': null,
  };
}

class SnapshotArtist {
  const SnapshotArtist({required this.name, required this.spotifyId});

  final String name;
  final String? spotifyId;

  Map<String, Object?> toCanonicalJson() => {
    'name': name,
    'spotifyId': spotifyId,
  };
}

class SnapshotEntry {
  const SnapshotEntry({
    required this.position,
    required this.platformId,
    required this.title,
    required this.artist,
    required this.album,
    required this.addedAt,
  });

  final int position;
  final String? platformId;
  final String title;
  final String artist;
  final String? album;
  final int? addedAt;

  Map<String, Object?> toCanonicalJson() => {
    'position': position,
    'platformId': platformId,
    'title': title,
    'artist': artist,
    'album': album,
    'addedAt': addedAt,
  };
}

class SnapshotPlaylist {
  const SnapshotPlaylist({
    required this.ordinal,
    required this.key,
    required this.name,
    required this.description,
    required this.lastModifiedAt,
    required this.entries,
  });

  final int ordinal;

  /// Lowercase hex SHA-256 of `name + " " + ordinal`.
  final String key;
  final String name;
  final String? description;
  final int? lastModifiedAt;
  final List<SnapshotEntry> entries;

  Map<String, Object?> toCanonicalJson() => {
    'ordinal': ordinal,
    'key': key,
    'name': name,
    'description': description,
    'lastModifiedAt': lastModifiedAt,
    'entries':
        (List.of(entries)..sort((a, b) => a.position.compareTo(b.position)))
            .map((e) => e.toCanonicalJson())
            .toList(),
  };
}

class SnapshotUnresolved {
  const SnapshotUnresolved({required this.rows, required this.plays});

  final int rows;
  final int plays;

  Map<String, Object?> toCanonicalJson() => {'rows': rows, 'plays': plays};
}

class ListeningExportSnapshot {
  const ListeningExportSnapshot({
    required this.package,
    required this.timeZone,
    required this.country,
    required this.tracks,
    required this.days,
    required this.library,
    required this.artists,
    required this.playlists,
    required this.unresolved,
    required this.ledgerFrom,
    required this.ledgerTo,
  });

  static const String source = 'spotify_export';

  final ExportPackage package;
  final String timeZone;
  final String? country;
  final List<SnapshotTrack> tracks;
  final List<SnapshotDay> days;
  final List<SnapshotLibraryRow> library;
  final List<SnapshotArtist> artists;
  final List<SnapshotPlaylist> playlists;
  final SnapshotUnresolved unresolved;
  final String? ledgerFrom;
  final String? ledgerTo;

  Map<String, Object?> toCanonicalJson() {
    final sortedTracks = List.of(tracks)
      ..sort((a, b) => a.platformId.compareTo(b.platformId));
    final sortedDays = List.of(days)
      ..sort((a, b) {
        final byId = a.platformId.compareTo(b.platformId);
        return byId != 0 ? byId : a.day.compareTo(b.day);
      });
    final sortedLibrary = List.of(library)
      ..sort((a, b) => a.platformId.compareTo(b.platformId));
    final sortedArtists = List.of(artists)
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0
            ? byName
            : _compareNullLast(a.spotifyId, b.spotifyId);
      });
    final sortedPlaylists = List.of(playlists)
      ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return {
      'source': source,
      'package': package.wire,
      'timeZone': timeZone,
      'country': country,
      'tracks': sortedTracks.map((t) => t.toCanonicalJson()).toList(),
      'days': sortedDays.map((d) => d.toCanonicalJson()).toList(),
      'library': sortedLibrary.map((l) => l.toCanonicalJson()).toList(),
      'artists': sortedArtists.map((a) => a.toCanonicalJson()).toList(),
      'playlists': sortedPlaylists.map((p) => p.toCanonicalJson()).toList(),
      'unresolved': unresolved.toCanonicalJson(),
      'ledgerFrom': ledgerFrom,
      'ledgerTo': ledgerTo,
    };
  }

  String canonicalJsonString() => _encode(toCanonicalJson());
}

/// An allow-listed file the parser reads; [rows] is null when it failed to
/// decode.
class InventoryReadFile {
  const InventoryReadFile({required this.path, required this.rows});

  final String path;
  final int? rows;

  Map<String, Object?> toCanonicalJson() => {'path': path, 'rows': rows};
}

/// Any other file entry: the parser knows its path and byte size only.
class InventoryIgnoredFile {
  const InventoryIgnoredFile({required this.path, required this.bytes});

  final String path;
  final int bytes;

  Map<String, Object?> toCanonicalJson() => {'path': path, 'bytes': bytes};
}

class ExportInventory {
  const ExportInventory({
    required this.package,
    required this.read,
    required this.ignored,
  });

  static const empty = ExportInventory(package: null, read: [], ignored: []);

  final ExportPackage? package;
  final List<InventoryReadFile> read;
  final List<InventoryIgnoredFile> ignored;

  /// Base name of the first read file that failed to decode, in path order.
  String? get unreadableFile {
    for (final file in read) {
      if (file.rows == null) {
        return file.path.substring(file.path.lastIndexOf('/') + 1);
      }
    }
    return null;
  }

  /// Whether a parse of this archive would produce a snapshot.
  bool get isReadable => package != null && unreadableFile == null;

  Map<String, Object?> toCanonicalJson() {
    final sortedRead = List.of(read)..sort((a, b) => a.path.compareTo(b.path));
    final sortedIgnored = List.of(ignored)
      ..sort((a, b) => a.path.compareTo(b.path));
    return {
      'package': package?.wire,
      'read': sortedRead.map((f) => f.toCanonicalJson()).toList(),
      'ignored': sortedIgnored.map((f) => f.toCanonicalJson()).toList(),
    };
  }

  String canonicalJsonString() => _encode(toCanonicalJson());
}

/// One file entry in a diagnostics report: names, sizes, counts, and the
/// top-level keys of a read JSON file. Never a value.
class DiagnosticsFile {
  const DiagnosticsFile({
    required this.path,
    required this.bytes,
    required this.rows,
    required this.headers,
  });

  final String path;
  final int bytes;
  final int? rows;
  final List<String>? headers;

  Map<String, Object?> toCanonicalJson() => {
    'path': path,
    'bytes': bytes,
    'rows': rows,
    'headers': headers == null ? null : List<String>.of(headers!),
  };
}

class ExportDiagnostics {
  const ExportDiagnostics({
    required this.source,
    required this.files,
    required this.parserVersion,
  });

  /// `spotify_export`, `apple_export`, or `unknown`.
  final String source;
  final List<DiagnosticsFile> files;
  final String parserVersion;

  Map<String, Object?> toCanonicalJson() {
    final sortedFiles = List.of(files)
      ..sort((a, b) => a.path.compareTo(b.path));
    return {
      'source': source,
      'files': sortedFiles.map((f) => f.toCanonicalJson()).toList(),
      'parserVersion': parserVersion,
    };
  }

  String canonicalJsonString() => _encode(toCanonicalJson());
}
