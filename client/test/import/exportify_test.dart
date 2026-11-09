import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/exportify_headers.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';

import 'exportify_zip.dart';

class FilesArchive extends ExportArchive {
  FilesArchive(this.files);
  final Map<String, String> files;
  @override
  Future<List<ArchiveEntryInfo>> entries() async => [
    for (final e in files.entries)
      ArchiveEntryInfo(path: e.key, bytes: utf8.encode(e.value).length),
  ];
  @override
  Future<String> readText(String path) async => files[path]!;
}

const _id = '4uLU6hMCjMI75M1A2tKUQC', _second = '7ouMYWpwJ422jRcDASZB7P';
const _head = '"Track URI","Track Name","Artist Name(s)","ISRC"\n';
Future<List<Map<String, Object?>>> _tracks(Map<String, String> files) async {
  final parsed = await parseExport(
    FilesArchive(files),
    const ParseOptions(timeZone: 'UTC'),
  );
  return [for (final t in parsed.snapshot.tracks) t.toCanonicalJson()];
}

class CsvArchive extends ExportArchive {
  @override
  Future<List<ArchiveEntryInfo>> entries() async => [
    const ArchiveEntryInfo(path: 'liked.csv', bytes: 200),
  ];
  @override
  Future<String> readText(String path) async =>
      '"Track URI","Track Name","Artist Name(s)"\n"spotify:track:4uLU6hMCjMI75M1A2tKUQC","A ""quiet""\nnight","Artist"\n"spotify:track:4uLU6hMCjMI75M1A2tKUQC","Again","Artist"\n';
}

void main() {
  test('translated headers match the shared fixture', () async {
    expect(
      exportifyHeaders,
      jsonDecode(
        await File('../fixtures/exportify/headers.json').readAsString(),
      ),
    );
  });
  test('matches the shared web/native snapshot contract', () async {
    final archive = openExportArchive(File('../fixtures/exportify/sample.csv'));
    try {
      final parsed = await parseExport(
        archive,
        const ParseOptions(timeZone: 'UTC'),
      );
      expect(
        parsed.snapshot.toCanonicalJson(),
        jsonDecode(
          await File('../fixtures/exportify/expected.json').readAsString(),
        ),
      );
    } finally {
      await archive.close();
    }
  });
  test(
    'Exportify preserves ordered repeated songs without inferring Liked Songs',
    () async {
      final parsed = await parseExport(
        CsvArchive(),
        const ParseOptions(timeZone: 'UTC'),
      );
      expect(parsed.snapshot.package.wire, 'spotify_exportify');
      expect(parsed.snapshot.tracks.single.title, 'A "quiet"\nnight');
      expect(parsed.snapshot.playlists.single.entries.length, 2);
      expect(parsed.snapshot.library, isEmpty);
    },
  );
  test(
    'carries a well-formed ISRC on the track, normalised, and omits it otherwise',
    () async {
      final parsed = await parseExport(
        FilesArchive({
          'a.csv':
              '$_head"spotify:track:$_id","One","A"," us-rc1-76-07839 "\n'
              '"spotify:track:$_second","Two","B","not an isrc"\n',
        }),
        const ParseOptions(timeZone: 'UTC'),
      );
      expect(
        [for (final t in parsed.snapshot.tracks) t.toCanonicalJson()],
        [
          {
            'platformId': _id,
            'title': 'One',
            'artist': 'A',
            'album': null,
            'durationMs': null,
            'isrc': 'USRC17607839',
          },
          {
            'platformId': _second,
            'title': 'Two',
            'artist': 'B',
            'album': null,
            'durationMs': null,
          },
        ],
      );
      expect(
        parsed.snapshot.tracks[1].toCanonicalJson().containsKey('isrc'),
        isFalse,
      );
      expect(
        parsed.snapshot.playlists.single.entries.every(
          (e) => !e.toCanonicalJson().containsKey('isrc'),
        ),
        isTrue,
      );
    },
  );
  test(
    'keeps the first well-formed ISRC for a recording across rows and files',
    () async {
      final tracks = await _tracks({
        'a.csv': '$_head"spotify:track:$_id","One","A",""\n',
        'b.csv':
            '$_head"spotify:track:$_id","One","A","bad"\n'
            '"spotify:track:$_id","One","A","GBAYE0000001"\n'
            '"spotify:track:$_id","One","A","USRC17607839"\n',
        'c.csv': '$_head"spotify:track:$_id","One","A","FRZ039800212"\n',
      });
      expect(tracks.map((t) => t['isrc']), ['GBAYE0000001']);
      expect(tracks.single['title'], 'One');
    },
  );
  test(
    'reads the ISRC column beside translated headers and in any letter case',
    () async {
      final tracks = await _tracks({
        'quiet.csv':
            '"URI du titre","Nom du titre","Nom(s) de l\'artiste","isrc"\n'
            '"spotify:track:$_id","Un","A","FRZ039800212"\n',
      });
      expect(tracks.single['isrc'], 'FRZ039800212');
    },
  );
  test(
    'never lets a missing or ambiguous ISRC column change the rest of the import',
    () async {
      Future<ListeningExportSnapshot> parse(String text) async =>
          (await parseExport(
            FilesArchive({'a.csv': text}),
            const ParseOptions(timeZone: 'UTC'),
          )).snapshot;
      final plain = await parse(
        '"Track URI","Track Name","Artist Name(s)"\n"spotify:track:$_id","One","A"\n',
      );
      final doubled = await parse(
        '"Track URI","Track Name","Artist Name(s)","ISRC","ISRC"\n'
        '"spotify:track:$_id","One","A","USRC17607839","GBAYE0000001"\n',
      );
      expect(
        plain.tracks.single.toCanonicalJson().containsKey('isrc'),
        isFalse,
      );
      expect(
        doubled.tracks.single.toCanonicalJson().containsKey('isrc'),
        isFalse,
      );
      expect(
        doubled.tracks.map((t) => t.toCanonicalJson()).toList(),
        plain.tracks.map((t) => t.toCanonicalJson()).toList(),
      );
      expect(
        doubled.playlists.single.entries
            .map((e) => e.toCanonicalJson())
            .toList(),
        plain.playlists.single.entries.map((e) => e.toCanonicalJson()).toList(),
      );
    },
  );
  test(
    'an Export All ZIP with saved albums imports every playlist and sets the '
    'album list aside',
    () async {
      final archive = ZipExportArchive.fromBytes(exportifyExportAllZip());
      try {
        final parsed = await parseExport(
          archive,
          const ParseOptions(timeZone: 'UTC'),
        );
        expect(parsed.snapshot.package, ExportPackage.spotifyExportify);
        expect(parsed.snapshot.playlists.map((p) => p.name).toList(), [
          '#23',
          "abba's vibe",
          'audio hugs 🫂📝🥺💌',
          'liked',
          'zz last',
        ]);
        expect(
          parsed.snapshot.tracks.map((t) => t.platformId).toSet(),
          {'4uLU6hMCjMI75M1A2tKUQC', '7ouMYWpwJ422jRcDASZB7P'},
        );
        // The review pairs read files with playlists by index, so an album
        // list is never among the read files.
        expect(parsed.inventory.read.map((f) => f.path).toList(), [
          '#23.csv',
          "abba's_vibe.csv",
          'audio_hugs_🫂📝🥺💌.csv',
          'liked.csv',
          'zz_last.csv',
        ]);
        expect(parsed.inventory.unreadableFile, isNull);
        expect(parsed.inventory.ignored.map((f) => f.path).toList(), [
          'saved_albums.csv',
        ]);
        expect(
          parsed.inventory.ignored.single.bytes,
          utf8.encode(savedAlbumsCsv).length,
        );
        expect(
          (await inspectExport(archive)).ignored.map((f) => f.path),
          ['saved_albums.csv'],
        );
      } finally {
        await archive.close();
      }
    },
  );
  test('an album list is told apart by its album URIs, not its name or '
      'language', () async {
    final parsed = await parseExport(
      FilesArchive({
        'mes_albums.csv':
            '"URI de l\'album","Nom de l\'album"\n'
            '"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival"\n',
        'a.csv': '$_head"spotify:track:$_id","One","A",""\n',
      }),
      const ParseOptions(timeZone: 'UTC'),
    );
    expect(parsed.snapshot.playlists.map((p) => p.name), ['a']);
    expect(parsed.inventory.ignored.map((f) => f.path), ['mes_albums.csv']);
  });
  test('a CSV that is neither a track list nor an album list still stops the '
      'import, naming the file', () async {
    Future<String?> failing(Map<String, String> files) async {
      try {
        await parseExport(
          FilesArchive(files),
          const ParseOptions(timeZone: 'UTC'),
        );
      } on UnreadableExportException catch (e) {
        return e.file;
      }
      return null;
    }

    final good = '$_head"spotify:track:$_id","One","A",""\n';
    expect(
      await failing({'a.csv': good, 'notes.csv': '"Name","Value"\n"x","y"\n'}),
      'notes.csv',
    );
    // One row that is not an album makes it something else entirely.
    expect(
      await failing({
        'a.csv': good,
        'saved_albums.csv':
            '"Album URI","Album Name"\n'
            '"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival"\n'
            '"spotify:track:$_id","Not an album"\n',
      }),
      'saved_albums.csv',
    );
    // A header with no rows says nothing about what the file is.
    expect(
      await failing({
        'a.csv': good,
        'saved_albums.csv': '$exportifySavedAlbumsHeader\n',
      }),
      'saved_albums.csv',
    );
  });
  test('rejects ISRC shapes outside the contract', () async {
    for (final cell in [
      'USRC1760783',
      'USRC176078390',
      '1SRC17607839',
      'USRC1760783X',
      'US_RC17607839',
      'ÜSRC17607839',
    ]) {
      final tracks = await _tracks({
        'a.csv': '$_head"spotify:track:$_id","One","A","$cell"\n',
      });
      expect(tracks.single.containsKey('isrc'), isFalse, reason: cell);
    }
  });
}
