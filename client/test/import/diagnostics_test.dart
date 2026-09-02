import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/diagnostics.dart';
import 'package:mixtape/import/zip_reader.dart';

import 'fixtures.dart';

void main() {
  test('lists every file with bytes; rows and headers only for files the parser reads', () async {
    final archive = ZipExportArchive.open(fixtureArchive('account-pii-present'));
    try {
      final diagnostics = await diagnoseExport(archive);
      expect(diagnostics.source, 'spotify_export');
      expect(diagnostics.parserVersion, isNotEmpty);

      final byPath = {for (final f in diagnostics.files) f.path: f};
      expect(byPath.keys.toList(), [
        'Spotify Account Data/Identity.json',
        'Spotify Account Data/Inferences.json',
        'Spotify Account Data/Payments.json',
        'Spotify Account Data/Playlist1.json',
        'Spotify Account Data/Userdata.json',
        'Spotify Account Data/YourLibrary.json',
        '__MACOSX/._YourLibrary.json',
      ]);

      for (final sentinel in [
        'Spotify Account Data/Identity.json',
        'Spotify Account Data/Inferences.json',
        'Spotify Account Data/Payments.json',
        'Spotify Account Data/Userdata.json',
        '__MACOSX/._YourLibrary.json',
      ]) {
        final file = byPath[sentinel]!;
        expect(file.rows, isNull, reason: sentinel);
        expect(file.headers, isNull, reason: sentinel);
        expect(file.bytes, greaterThanOrEqualTo(2048), reason: sentinel);
      }
      expect(byPath['Spotify Account Data/Identity.json']!.bytes, 2068);

      final playlist = byPath['Spotify Account Data/Playlist1.json']!;
      expect(playlist.rows, 1);
      expect(playlist.headers, ['playlists']);
      final library = byPath['Spotify Account Data/YourLibrary.json']!;
      expect(library.rows, 2);
      expect(library.headers, contains('tracks'));
      expect(library.headers, contains('artists'));

      final text = diagnostics.canonicalJsonString();
      expect(text, isNot(contains('DO-NOT-READ')));
      expect(text, isNot(contains('spotify:')));
      // No value from the read files leaks: only keys are reported.
      final definition = caseDefinition(fixtureCases().singleWhere((d) => d.path.endsWith('account-pii-present')));
      for (final value in _leafStrings(definition['entries'])) {
        expect(text, isNot(contains(value)), reason: 'value leaked');
      }
    } finally {
      await archive.close();
    }
  });

  test('history headers come from the first array element and a broken file has null rows', () async {
    final archive = ZipExportArchive.open(fixtureArchive('extended-malformed'));
    try {
      final diagnostics = await diagnoseExport(archive);
      expect(diagnostics.files, hasLength(2));
      final fine = diagnostics.files.first;
      expect(fine.rows, 2);
      expect(fine.headers, contains('ts'));
      expect(fine.headers, contains('ms_played'));
      final broken = diagnostics.files.last;
      expect(broken.rows, isNull);
      expect(broken.headers, isNull);
      expect(broken.bytes, greaterThan(0));
      final json = diagnostics.toCanonicalJson();
      expect(json.keys.toList(), ['source', 'files', 'parserVersion']);
      expect((json['files'] as List).first, {
        'path': fine.path,
        'bytes': fine.bytes,
        'rows': 2,
        'headers': fine.headers,
      });
    } finally {
      await archive.close();
    }
  });
}

Iterable<String> _leafStrings(Object? node) sync* {
  if (node is Map) {
    for (final entry in node.entries) {
      // Entry paths are reported by design; bodies are not.
      if (entry.key == 'path') continue;
      yield* _leafStrings(entry.value);
    }
  } else if (node is List) {
    for (final item in node) {
      yield* _leafStrings(item);
    }
  } else if (node is String && node.length >= 4) {
    yield node;
  }
}
