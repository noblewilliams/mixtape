import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'exportify_headers.dart';
import 'snapshot.dart';
import 'spotify_parser.dart';
import 'zip_reader.dart';

bool isCsvPath(String path) =>
    path.toLowerCase().endsWith('.csv') &&
    !path.split('/').any((p) => p == '__MACOSX' || p.startsWith('._'));
Future<List<List<String>>> _csv(String text, CancelToken? token) async {
  final rows = <List<String>>[];
  var row = <String>[], field = '', quoted = false, closed = false;
  void cell() {
    row.add(field);
    field = '';
    closed = false;
    if (row.length > 100) throw const FormatException('columns');
  }

  void end() {
    cell();
    if (row.any((s) => s.isNotEmpty)) rows.add(row);
    row = [];
    if (rows.length > 100001) throw const FormatException('rows');
  }

  if (text.startsWith('\uFEFF')) text = text.substring(1);
  for (var i = 0; i < text.length; i++) {
    if (i % 65536 == 0) {
      await Future<void>.delayed(Duration.zero);
      token?.throwIfCancelled();
    }
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        field += c;
      }
    } else if (c == ',') {
      cell();
    } else if (c == '\r' || c == '\n') {
      end();
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else if (c == '"' && field.isEmpty && !closed) {
      quoted = true;
    } else if (closed || c == '"') {
      throw const FormatException('quoting');
    } else {
      field += c;
    }
    if (field.length > 10000) throw const FormatException('field');
  }
  if (quoted) throw const FormatException('quoting');
  if (field.isNotEmpty || row.isNotEmpty || closed) end();
  return rows;
}

Future<ParsedExport> parseExportify(
  ExportArchive archive,
  ParseOptions options,
) async {
  final files = (await archive.entries())
    ..sort((a, b) => a.path.compareTo(b.path));
  final selected = files.where((f) => isCsvPath(f.path)).toList();
  final read = <InventoryReadFile>[];
  ExportInventory inventory() => ExportInventory(
    package: ExportPackage.spotifyExportify,
    read: read,
    ignored: files
        .where((f) => !isCsvPath(f.path))
        .map((f) => InventoryIgnoredFile(path: f.path, bytes: f.bytes))
        .toList(),
  );
  Never fail(String? path) =>
      throw UnreadableExportException(file: path, inventory: inventory());
  if (selected.length > 2000 ||
      files.map((f) => f.path).toSet().length != files.length ||
      selected.fold<int>(0, (n, f) => n + f.bytes) > 64 * 1024 * 1024) {
    fail(null);
  }
  final tracks = <String, SnapshotTrack>{}, playlists = <SnapshotPlaylist>[];
  var unresolved = 0, totalRows = 0, completed = 0;
  for (final file in selected) {
    options.cancelToken?.throwIfCancelled();
    options.onProgress?.call(
      ParseStage.parsing,
      file.path,
      completed,
      selected.length,
    );
    try {
      final text = await archive.readText(file.path);
      if (text.length > 64 * 1024 * 1024) fail(file.path);
      final rows = await _csv(text, options.cancelToken);
      if (rows.isEmpty) fail(file.path);
      final header = rows.removeAt(0), columns = <String, int>{};
      for (var i = 0; i < header.length; i++) {
        for (final e in exportifyHeaders.entries) {
          if (e.value.any(
            (s) => s.trim().toLowerCase() == header[i].trim().toLowerCase(),
          )) {
            if (columns.containsKey(e.key)) fail(file.path);
            columns[e.key] = i;
          }
        }
      }
      if ([
        'track_uri',
        'track_name',
        'artist_names',
      ].any((k) => !columns.containsKey(k))) {
        fail(file.path);
      }
      totalRows += rows.length;
      if (totalRows > 100000) fail(file.path);
      String value(List<String> r, String key) =>
          columns.containsKey(key) ? r[columns[key]!] : '';
      final entries = <SnapshotEntry>[];
      for (final r in rows) {
        if (r.length != header.length) fail(file.path);
        final id = RegExp(
          r'^spotify:track:([A-Za-z0-9]{22})$',
        ).firstMatch(value(r, 'track_uri'))?.group(1);
        final title = value(r, 'track_name').trim().isEmpty
            ? 'Untitled'
            : value(r, 'track_name').trim();
        final artist = value(r, 'artist_names').trim().isEmpty
            ? 'Unknown Artist'
            : value(r, 'artist_names').trim().replaceAll(r'\,', ',');
        final album = value(r, 'album_name').trim().isEmpty
            ? null
            : value(r, 'album_name').trim();
        final duration = value(r, 'track_duration');
        final n = RegExp(r'^\d+$').hasMatch(duration)
            ? int.tryParse(duration)
            : null;
        if (id != null) {
          tracks.putIfAbsent(
            id,
            () => SnapshotTrack(
              platformId: id,
              title: title,
              artist: artist,
              album: album,
              durationMs: n != null && n <= 86400000 ? n : null,
            ),
          );
        } else {
          unresolved++;
        }
        final timestamp = value(r, 'added_at');
        final added =
            RegExp(
              r'^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$',
            ).hasMatch(timestamp)
            ? DateTime.tryParse(timestamp)?.millisecondsSinceEpoch
            : null;
        entries.add(
          SnapshotEntry(
            position: entries.length,
            platformId: id,
            title: title,
            artist: artist,
            album: album,
            addedAt: added,
          ),
        );
      }
      playlists.add(
        SnapshotPlaylist(
          ordinal: playlists.length,
          key: sha256.convert(utf8.encode(text)).toString(),
          name: file.path
              .split('/')
              .last
              .replaceFirst(RegExp(r'\.csv$', caseSensitive: false), '')
              .replaceAll('_', ' '),
          description: null,
          lastModifiedAt: null,
          entries: entries,
        ),
      );
      read.add(InventoryReadFile(path: file.path, rows: rows.length));
    } catch (_) {
      options.cancelToken?.throwIfCancelled();
      if (!read.any((f) => f.path == file.path)) {
        read.add(InventoryReadFile(path: file.path, rows: null));
      }
      fail(file.path);
    }
    completed++;
  }
  options.cancelToken?.throwIfCancelled();
  return ParsedExport(
    inventory: inventory(),
    snapshot: ListeningExportSnapshot(
      package: ExportPackage.spotifyExportify,
      timeZone: options.timeZone,
      country: null,
      tracks: tracks.values.toList(),
      days: [],
      library: [],
      artists: [],
      playlists: playlists,
      unresolved: SnapshotUnresolved(rows: unresolved, plays: 0),
      ledgerFrom: null,
      ledgerTo: null,
    ),
  );
}
