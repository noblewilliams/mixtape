import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'snapshot.dart';
import 'zip_reader.dart';
import 'zone_clock.dart';

/// Spotify export parser: the Dart implementation of the contract in
/// `fixtures/listening-exports/README.md`. Only allow-listed entries are ever
/// read; names are never logged.

const int playThresholdMs = 30000;
const String unknownArtist = 'Unknown Artist';
const String untitled = 'Untitled';

/// Rows between cancellation checkpoints and progress reports.
const int rowsPerCheckpoint = 4096;

/// Thrown when the [CancelToken] of a run is cancelled.
class ImportCancelled implements Exception {}

/// The archive cannot yield a snapshot: no allow-listed file, or a read file
/// that is not valid UTF-8 JSON of the right shape. [file] is the base name
/// of the first broken file in path order (null when no file was readable at
/// all); [inventory] still lists every entry, the broken file with null rows.
class UnreadableExportException implements Exception {
  const UnreadableExportException({required this.file, required this.inventory});

  final String? file;
  final ExportInventory inventory;

  @override
  String toString() => 'UnreadableExportException(file: $file)';
}

/// Cooperative cancellation. The parser checks it before every file and every
/// [rowsPerCheckpoint] rows, yielding to the event loop first so a cancel
/// requested from a port or a UI event gets through.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw ImportCancelled();
  }
}

enum ParseStage {
  /// Entries listed; `completed` / `total` count the files to read.
  inspecting,

  /// Files being decoded and aggregated; `completed` / `total` are
  /// uncompressed bytes of the files the parser reads, so the ratio is a
  /// stable overall progress. `file` is the path being processed.
  parsing,
}

typedef ParseProgress = void Function(ParseStage stage, String? file, int completed, int total);

class ParseOptions {
  const ParseOptions({
    required this.timeZone,
    this.includePrivateSessions = false,
    this.cancelToken,
    this.onProgress,
  });

  /// IANA zone the run records and converts to.
  final String timeZone;
  final bool includePrivateSessions;
  final CancelToken? cancelToken;
  final ParseProgress? onProgress;
}

class ParsedExport {
  const ParsedExport({required this.inventory, required this.snapshot});

  final ExportInventory inventory;
  final ListeningExportSnapshot snapshot;
}

enum ExportFileKind { history, library, playlist }

/// A file entry with its allow-list classification (null: never opened).
class ExportFile {
  const ExportFile({required this.path, required this.bytes, required this.kind});

  final String path;
  final int bytes;
  final ExportFileKind? kind;
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// ASCII-only case folding: A-Z become a-z, every other code unit is kept.
String asciiLower(String text) {
  final units = text.codeUnits;
  final folded = List<int>.generate(units.length, (i) {
    final unit = units[i];
    return unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit;
  });
  return String.fromCharCodes(folded);
}

final RegExp _historyName = RegExp(r'^streaming_history_audio_.*\.json$');
final RegExp _libraryName = RegExp(r'^yourlibrary\.json$');
final RegExp _playlistName = RegExp(r'^playlist.*\.json$');

ExportFileKind? classifyEntry(String path) {
  final base = asciiLower(baseName(path));
  if (_historyName.hasMatch(base)) return ExportFileKind.history;
  if (_libraryName.hasMatch(base)) return ExportFileKind.library;
  if (_playlistName.hasMatch(base)) return ExportFileKind.playlist;
  return null;
}

/// File entries in ordinal path order, classified; directory entries skipped.
Future<List<ExportFile>> listExportFiles(ExportArchive archive) async {
  final entries = await archive.entries();
  final files = [
    for (final entry in entries)
      if (!entry.path.endsWith('/'))
        ExportFile(path: entry.path, bytes: entry.bytes, kind: classifyEntry(entry.path)),
  ];
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

ExportPackage? detectPackage(List<ExportFile> files) {
  if (files.any((f) => f.kind == ExportFileKind.history)) return ExportPackage.spotifyExtended;
  if (files.any((f) => f.kind == ExportFileKind.library || f.kind == ExportFileKind.playlist)) {
    return ExportPackage.spotifyAccount;
  }
  return null;
}

Set<ExportFileKind> readKindsFor(ExportPackage? package) => switch (package) {
  ExportPackage.spotifyExtended => const {ExportFileKind.history},
  ExportPackage.spotifyAccount => const {ExportFileKind.library, ExportFileKind.playlist},
  null => const {},
};

/// A playlist record with its `items` normalized to a list.
class LoadedPlaylist {
  const LoadedPlaylist({required this.record, required this.items});

  /// The playlist object, or null when the array element was not an object.
  final Map<dynamic, dynamic>? record;
  final List<dynamic> items;
}

/// A decoded, shape-checked read file with its inventory row count and the
/// top-level keys diagnostics may report.
class LoadedExportFile {
  const LoadedExportFile({
    required this.kind,
    required this.rows,
    required this.headers,
    this.history = const [],
    this.libraryTracks = const [],
    this.libraryArtists = const [],
    this.playlists = const [],
  });

  final ExportFileKind kind;
  final int rows;
  final List<String> headers;
  final List<dynamic> history;
  final List<dynamic> libraryTracks;
  final List<dynamic> libraryArtists;
  final List<LoadedPlaylist> playlists;
}

List<String> _keysOf(Object? value) =>
    value is Map ? value.keys.map((k) => k.toString()).toList() : const [];

/// Reads and decodes one allow-listed file. Returns null when the bytes, the
/// JSON, or the top-level shape are wrong: the file is unreadable.
Future<LoadedExportFile?> loadExportFile(ExportArchive archive, ExportFile file) async {
  final kind = file.kind;
  if (kind == null) throw ArgumentError.value(file.path, 'file', 'not an allow-listed entry');
  final String text;
  try {
    text = await archive.readText(file.path);
  } catch (_) {
    // Any failure while reading the entry makes the file unreadable; the
    // error itself is dropped so nothing from the archive can ride along.
    return null;
  }
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return null;
  }
  switch (kind) {
    case ExportFileKind.history:
      if (data is! List) return null;
      return LoadedExportFile(
        kind: kind,
        rows: data.length,
        headers: _keysOf(data.isEmpty ? null : data.first),
        history: data,
      );
    case ExportFileKind.library:
      if (data is! Map) return null;
      final tracks = data['tracks'];
      final artists = data['artists'];
      final trackList = tracks is List ? tracks : const <dynamic>[];
      final artistList = artists is List ? artists : const <dynamic>[];
      return LoadedExportFile(
        kind: kind,
        rows: trackList.length + artistList.length,
        headers: _keysOf(data),
        libraryTracks: trackList,
        libraryArtists: artistList,
      );
    case ExportFileKind.playlist:
      if (data is! Map) return null;
      final raw = data['playlists'];
      final playlists = <LoadedPlaylist>[];
      var rows = 0;
      if (raw is List) {
        for (final playlist in raw) {
          final record = playlist is Map ? playlist : null;
          final items = record?['items'];
          final itemList = items is List ? items : const <dynamic>[];
          rows += itemList.length;
          playlists.add(LoadedPlaylist(record: record, items: itemList));
        }
      }
      return LoadedExportFile(kind: kind, rows: rows, headers: _keysOf(data), playlists: playlists);
  }
}

final RegExp _spotifyId = RegExp(r'^[0-9A-Za-z]{22}$');

/// The 22-character id after `spotify:<kind>:`, or null for anything else.
String? spotifyIdFromUri(Object? uri, String kind) {
  if (uri is! String) return null;
  final prefix = 'spotify:$kind:';
  if (!uri.startsWith(prefix)) return null;
  final tail = uri.substring(prefix.length);
  return _spotifyId.hasMatch(tail) ? tail : null;
}

/// A JSON number truncated toward zero; anything else counts as 0.
int asInteger(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.truncate();
  return 0;
}

/// A non-empty JSON string, else null.
String? asText(Object? value) => value is String && value.isNotEmpty ? value : null;

final RegExp _ts = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$');

/// Epoch ms for a `ts` in the only accepted grammar; null drops the row.
int? instantFromTs(Object? value) {
  if (value is! String) return null;
  final match = _ts.firstMatch(value);
  if (match == null) return null;
  // Years before 1900 are outside the grammar (interpretation 7); this also
  // keeps Dart clear of JavaScript's 0-99 -> 1900s mapping in Date.UTC.
  if (int.parse(match[1]!) < 1900) return null;
  final fraction = match[7];
  final millis = fraction == null ? 0 : int.parse(fraction.padRight(3, '0'));
  return DateTime.utc(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
    millis,
  ).millisecondsSinceEpoch;
}

final RegExp _dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// `YYYY-MM-DD` -> epoch ms of that date's midnight UTC; anything else null.
int? epochMsFromExportDate(Object? value) {
  if (value is! String) return null;
  final match = _dateOnly.firstMatch(value);
  if (match == null) return null;
  if (int.parse(match[1]!) < 1900) return null; // same year floor as `ts` (interpretation 13)
  return DateTime.utc(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
  ).millisecondsSinceEpoch;
}

/// Lowercase hex SHA-256 of the UTF-8 bytes of `name + " " + ordinal`.
String playlistKey(String name, int ordinal) => sha256.convert(utf8.encode('$name $ordinal')).toString();

final RegExp _country = RegExp(r'^[A-Z]{2}$');

/// Lists the archive and counts rows without aggregating: the inventory the
/// UI shows before an import. A broken file has `rows: null`; see
/// [ExportInventory.unreadableFile].
Future<ExportInventory> inspectExport(ExportArchive archive, {CancelToken? cancelToken}) async {
  final scan = await _scan(archive, aggregate: false, cancelToken: cancelToken);
  return scan.inventory;
}

/// Parses the archive into its inventory and snapshot, or throws
/// [UnreadableExportException] / [ImportCancelled].
Future<ParsedExport> parseExport(ExportArchive archive, ParseOptions options) async {
  final scan = await _scan(
    archive,
    aggregate: true,
    timeZone: options.timeZone,
    includePrivateSessions: options.includePrivateSessions,
    cancelToken: options.cancelToken,
    onProgress: options.onProgress,
  );
  final inventory = scan.inventory;
  final snapshot = scan.snapshot;
  if (snapshot == null) {
    throw UnreadableExportException(file: inventory.unreadableFile, inventory: inventory);
  }
  return ParsedExport(inventory: inventory, snapshot: snapshot);
}

class _Scan {
  const _Scan(this.inventory, this.snapshot);

  final ExportInventory inventory;
  final ListeningExportSnapshot? snapshot;
}

Future<void> _checkpoint(CancelToken? token) async {
  if (token == null) return;
  // Let queued events (a cancel message from another isolate, UI input) run.
  await Future<void>.delayed(Duration.zero);
  token.throwIfCancelled();
}

class _Progress {
  _Progress(this.onProgress, this.totalBytes);

  final ParseProgress? onProgress;
  final int totalBytes;
  int bytesDone = 0;

  void file(ExportFile file, int done, int total) {
    if (onProgress == null) return;
    final within = total == 0 ? file.bytes : file.bytes * done ~/ total;
    onProgress!(ParseStage.parsing, file.path, bytesDone + within, totalBytes);
  }
}

Future<_Scan> _scan(
  ExportArchive archive, {
  required bool aggregate,
  String timeZone = 'UTC',
  bool includePrivateSessions = false,
  CancelToken? cancelToken,
  ParseProgress? onProgress,
}) async {
  cancelToken?.throwIfCancelled();
  final files = await listExportFiles(archive);
  final package = detectPackage(files);
  final readKinds = readKindsFor(package);
  final toRead = files.where((f) => readKinds.contains(f.kind)).toList();
  final progress = _Progress(onProgress, toRead.fold<int>(0, (sum, f) => sum + f.bytes));
  onProgress?.call(ParseStage.inspecting, null, 0, toRead.length);

  final extended = aggregate && package == ExportPackage.spotifyExtended
      ? _ExtendedAggregator(timeZone: timeZone, includePrivateSessions: includePrivateSessions)
      : null;
  final account = aggregate && package == ExportPackage.spotifyAccount ? _AccountAggregator() : null;

  final read = <InventoryReadFile>[];
  final ignored = <InventoryIgnoredFile>[];
  var broken = false;
  for (final file in files) {
    if (!readKinds.contains(file.kind)) {
      ignored.add(InventoryIgnoredFile(path: file.path, bytes: file.bytes));
      continue;
    }
    await _checkpoint(cancelToken);
    progress.file(file, 0, 1);
    final loaded = await loadExportFile(archive, file);
    if (loaded == null) {
      broken = true;
      read.add(InventoryReadFile(path: file.path, rows: null));
    } else {
      read.add(InventoryReadFile(path: file.path, rows: loaded.rows));
      if (!broken) {
        if (extended != null) await extended.consume(loaded, file, progress, cancelToken);
        account?.consume(loaded);
      }
    }
    progress.file(file, 1, 1);
    progress.bytesDone += file.bytes;
  }

  final inventory = ExportInventory(package: package, read: read, ignored: ignored);
  if (!aggregate || broken || package == null) return _Scan(inventory, null);
  final snapshot = extended?.snapshot(timeZone) ?? account!.snapshot(timeZone);
  return _Scan(inventory, snapshot);
}

class _Track {
  _Track(this.platformId);

  final String platformId;
  String? title;
  String? artist;
  String? album;
  int? durationMs;
}

class _Day {
  _Day(this.platformId, this.day);

  final String platformId;
  final String day;
  int plays = 0;
  int skips = 0;
  int completes = 0;
  int msPlayed = 0;
  int hoursMask = 0;
}

class _ExtendedAggregator {
  _ExtendedAggregator({required String timeZone, required this.includePrivateSessions})
    : clock = ZoneClock(timeZone);

  final bool includePrivateSessions;
  final ZoneClock clock;
  final Map<String, _Track> tracks = {};
  final Map<String, _Day> days = {};
  final Map<String, int> countries = {};
  int unresolvedRows = 0;
  int unresolvedPlays = 0;

  Future<void> consume(
    LoadedExportFile loaded,
    ExportFile file,
    _Progress progress,
    CancelToken? token,
  ) async {
    final rows = loaded.history;
    for (var i = 0; i < rows.length; i++) {
      if (i > 0 && i % rowsPerCheckpoint == 0) {
        progress.file(file, i, rows.length);
        await _checkpoint(token);
      }
      final row = rows[i];
      if (row is Map) _row(row);
    }
  }

  void _row(Map<dynamic, dynamic> row) {
    if (row['incognito_mode'] == true && !includePrivateSessions) return;
    if (row['spotify_episode_uri'] != null || row['audiobook_uri'] != null) return;
    final msPlayed = asInteger(row['ms_played']);
    final isPlay = msPlayed >= playThresholdMs;
    final platformId = spotifyIdFromUri(row['spotify_track_uri'], 'track');
    if (platformId == null) {
      unresolvedRows += 1;
      if (isPlay) unresolvedPlays += 1;
      return;
    }
    final utcMs = instantFromTs(row['ts']);
    if (utcMs == null) return;

    final skipped = row['skipped'];
    final reasonEnd = row['reason_end'];
    final isSkip = skipped == true || (skipped == null && reasonEnd == 'fwdbtn');
    final isComplete = reasonEnd == 'trackdone';
    final local = clock.local(utcMs);

    final track = tracks.putIfAbsent(platformId, () => _Track(platformId));
    track.title ??= asText(row['master_metadata_track_name']);
    track.artist ??= asText(row['master_metadata_album_artist_name']);
    track.album ??= asText(row['master_metadata_album_album_name']);
    if (isComplete) {
      final duration = track.durationMs;
      if (duration == null || msPlayed > duration) track.durationMs = msPlayed;
    }

    final day = days.putIfAbsent('$platformId|${local.day}', () => _Day(platformId, local.day));
    day.msPlayed += msPlayed;
    if (isPlay) {
      day.plays += 1;
      day.hoursMask |= 1 << local.hour;
    }
    if (isSkip) day.skips += 1;
    if (isComplete) day.completes += 1;

    final country = row['conn_country'];
    if (country is String && _country.hasMatch(country)) {
      countries[country] = (countries[country] ?? 0) + 1;
    }
  }

  ListeningExportSnapshot snapshot(String timeZone) {
    final trackRows = tracks.values
        .map(
          (t) => SnapshotTrack(
            platformId: t.platformId,
            title: t.title ?? t.platformId,
            artist: t.artist ?? unknownArtist,
            album: t.album,
            durationMs: t.durationMs,
          ),
        )
        .toList()
      ..sort((a, b) => a.platformId.compareTo(b.platformId));
    final dayRows = days.values
        .where((d) => d.plays > 0 || d.skips > 0)
        .map(
          (d) => SnapshotDay(
            platformId: d.platformId,
            day: d.day,
            plays: d.plays,
            skips: d.skips,
            completes: d.completes,
            msPlayed: d.msPlayed,
            hoursMask: d.hoursMask,
          ),
        )
        .toList()
      ..sort((a, b) {
        final byId = a.platformId.compareTo(b.platformId);
        return byId != 0 ? byId : a.day.compareTo(b.day);
      });

    String? country;
    var countryCount = 0;
    for (final entry in countries.entries) {
      final code = entry.key;
      final count = entry.value;
      if (count > countryCount || (count == countryCount && country != null && code.compareTo(country) < 0)) {
        country = code;
        countryCount = count;
      }
    }

    String? ledgerFrom;
    String? ledgerTo;
    for (final row in dayRows) {
      if (ledgerFrom == null || row.day.compareTo(ledgerFrom) < 0) ledgerFrom = row.day;
      if (ledgerTo == null || row.day.compareTo(ledgerTo) > 0) ledgerTo = row.day;
    }

    return ListeningExportSnapshot(
      package: ExportPackage.spotifyExtended,
      timeZone: timeZone,
      country: country,
      tracks: trackRows,
      days: dayRows,
      library: const [],
      artists: const [],
      playlists: const [],
      unresolved: SnapshotUnresolved(rows: unresolvedRows, plays: unresolvedPlays),
      ledgerFrom: ledgerFrom,
      ledgerTo: ledgerTo,
    );
  }
}

/// Names for one platform id: the library file's first non-empty values win
/// over the playlists' first non-empty values, whatever the file order.
class _NamedTrack {
  _NamedTrack(this.platformId);

  final String platformId;
  String? libraryTitle;
  String? libraryArtist;
  String? libraryAlbum;
  String? playlistTitle;
  String? playlistArtist;
  String? playlistAlbum;
}

class _AccountAggregator {
  final Map<String, _NamedTrack> tracks = {};
  final Map<String, SnapshotLibraryRow> library = {};
  final List<SnapshotArtist> artists = [];
  final List<SnapshotPlaylist> playlists = [];
  int ordinal = 0;
  int unresolvedRows = 0;

  void consume(LoadedExportFile loaded) {
    switch (loaded.kind) {
      case ExportFileKind.library:
        _library(loaded);
      case ExportFileKind.playlist:
        _playlists(loaded);
      case ExportFileKind.history:
        break;
    }
  }

  void _library(LoadedExportFile loaded) {
    for (final liked in loaded.libraryTracks) {
      if (liked is! Map) continue;
      final platformId = spotifyIdFromUri(liked['uri'], 'track');
      if (platformId == null) continue;
      final track = tracks.putIfAbsent(platformId, () => _NamedTrack(platformId));
      track.libraryTitle ??= asText(liked['track']);
      track.libraryArtist ??= asText(liked['artist']);
      track.libraryAlbum ??= asText(liked['album']);
      library.putIfAbsent(platformId, () => SnapshotLibraryRow(platformId: platformId));
    }
    for (final followed in loaded.libraryArtists) {
      if (followed is! Map) continue;
      final name = asText(followed['name']);
      if (name == null) continue;
      artists.add(SnapshotArtist(name: name, spotifyId: spotifyIdFromUri(followed['uri'], 'artist')));
    }
  }

  void _playlists(LoadedExportFile loaded) {
    for (final playlist in loaded.playlists) {
      final record = playlist.record;
      final name = asText(record?['name']) ?? untitled;
      final entries = <SnapshotEntry>[];
      for (var position = 0; position < playlist.items.length; position++) {
        final item = playlist.items[position];
        final Map<dynamic, dynamic> entry = item is Map ? item : const {};
        String? platformId;
        String? title;
        String? artist;
        String? album;
        final track = entry['track'];
        final localTrack = entry['localTrack'];
        final episode = entry['episode'];
        if (track is Map) {
          platformId = spotifyIdFromUri(track['trackUri'], 'track');
          title = asText(track['trackName']);
          artist = asText(track['artistName']);
          album = asText(track['albumName']);
        } else if (localTrack is Map) {
          title = asText(localTrack['trackName']);
          artist = asText(localTrack['artistName']);
          album = asText(localTrack['albumName']);
        } else if (episode is Map) {
          title = asText(episode['episodeName']);
          artist = asText(episode['showName']);
        }
        if (platformId == null) {
          unresolvedRows += 1;
        } else {
          final named = tracks.putIfAbsent(platformId, () => _NamedTrack(platformId!));
          named.playlistTitle ??= title;
          named.playlistArtist ??= artist;
          named.playlistAlbum ??= album;
        }
        entries.add(
          SnapshotEntry(
            position: position,
            platformId: platformId,
            title: title ?? platformId ?? untitled,
            artist: artist ?? unknownArtist,
            album: album,
            addedAt: epochMsFromExportDate(entry['addedDate']),
          ),
        );
      }
      playlists.add(
        SnapshotPlaylist(
          ordinal: ordinal,
          key: playlistKey(name, ordinal),
          name: name,
          description: asText(record?['description']),
          lastModifiedAt: epochMsFromExportDate(record?['lastModifiedDate']),
          entries: entries,
        ),
      );
      ordinal += 1;
    }
  }

  ListeningExportSnapshot snapshot(String timeZone) {
    final trackRows = tracks.values
        .map(
          (t) => SnapshotTrack(
            platformId: t.platformId,
            title: t.libraryTitle ?? t.playlistTitle ?? t.platformId,
            artist: t.libraryArtist ?? t.playlistArtist ?? unknownArtist,
            album: t.libraryAlbum ?? t.playlistAlbum,
            durationMs: null,
          ),
        )
        .toList()
      ..sort((a, b) => a.platformId.compareTo(b.platformId));
    final libraryRows = library.values.toList()..sort((a, b) => a.platformId.compareTo(b.platformId));
    final artistRows = List.of(artists)
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        if (byName != 0) return byName;
        final x = a.spotifyId;
        final y = b.spotifyId;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return x.compareTo(y);
      });
    return ListeningExportSnapshot(
      package: ExportPackage.spotifyAccount,
      timeZone: timeZone,
      country: null,
      tracks: trackRows,
      days: const [],
      library: libraryRows,
      artists: artistRows,
      playlists: List.of(playlists),
      unresolved: SnapshotUnresolved(rows: unresolvedRows, plays: 0),
      ledgerFrom: null,
      ledgerTo: null,
    );
  }
}
