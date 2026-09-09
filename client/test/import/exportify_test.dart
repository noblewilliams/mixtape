import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/exportify_headers.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';

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
}
