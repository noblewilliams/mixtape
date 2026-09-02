import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/zip_reader.dart';

import 'fixtures.dart';

void main() {
  const nestedHistory =
      'my_spotify_data/Spotify Extended Streaming History/Streaming_History_Audio_2023-2025_0.json';

  test('lists file entries with central-directory sizes and skips directories', () async {
    final archive = ZipExportArchive.open(fixtureArchive('extended-nested-folder'));
    try {
      final entries = await archive.entries();
      final paths = entries.map((e) => e.path).toList();
      expect(paths, isNot(contains(endsWith('/'))));
      expect(paths, hasLength(4));
      expect(paths, contains(nestedHistory));
      final pdf = entries.singleWhere(
        (e) => e.path == 'my_spotify_data/ReadMeFirst_ExtendedStreamingHistory.pdf',
      );
      expect(pdf.bytes, 2070);
      final library = entries.singleWhere(
        (e) => e.path == 'my_spotify_data/Spotify Account Data/YourLibrary.json',
      );
      expect(library.bytes, 306);
    } finally {
      await archive.close();
    }
  });

  test('reads a data-descriptor entry (general-purpose bit 3)', () async {
    final archive = ZipExportArchive.open(fixtureArchive('extended-nested-folder'));
    try {
      final text = await archive.readText(nestedHistory);
      final rows = jsonDecode(text) as List;
      expect(rows, hasLength(2));
    } finally {
      await archive.close();
    }
  });

  test('strips a leading byte-order mark', () async {
    final archive = ZipExportArchive.open(fixtureArchive('extended-bom'));
    try {
      final entries = await archive.entries();
      final text = await archive.readText(entries.single.path);
      expect(text.codeUnitAt(0), isNot(0xFEFF));
      expect(text.trimLeft(), startsWith('['));
      expect(jsonDecode(text), isA<List>());
    } finally {
      await archive.close();
    }
  });

  test('throws FormatException on malformed UTF-8', () async {
    final archive = ZipExportArchive.open(fixtureArchive('extended-bad-utf8'));
    try {
      const broken =
          'Spotify Extended Streaming History/Streaming_History_Audio_2025_1.json';
      await expectLater(archive.readText(broken), throwsA(isA<FormatException>()));
      const fine =
          'Spotify Extended Streaming History/Streaming_History_Audio_2025_0.json';
      expect(jsonDecode(await archive.readText(fine)), isA<List>());
    } finally {
      await archive.close();
    }
  });

  test('fromBytes reads the same entries as open', () async {
    final file = fixtureArchive('account-basic');
    final fromFile = ZipExportArchive.open(file);
    final fromBytes = ZipExportArchive.fromBytes(file.readAsBytesSync());
    try {
      final a = await fromFile.entries();
      final b = await fromBytes.entries();
      expect(b.map((e) => e.path).toList(), a.map((e) => e.path).toList());
      expect(b.map((e) => e.bytes).toList(), a.map((e) => e.bytes).toList());
      const path = 'Spotify Account Data/YourLibrary.json';
      expect(await fromBytes.readText(path), await fromFile.readText(path));
    } finally {
      await fromFile.close();
      await fromBytes.close();
    }
  });

  test('rejects a path that is not in the archive', () async {
    final archive = ZipExportArchive.open(fixtureArchive('account-basic'));
    try {
      await expectLater(archive.readText('nope.json'), throwsA(isA<ArgumentError>()));
    } finally {
      await archive.close();
    }
  });

  test('rejects bytes that are not a ZIP archive', () {
    expect(
      () => ZipExportArchive.fromBytes(Uint8List.fromList(utf8.encode('not a zip'))),
      throwsA(isA<ArchiveFormatException>()),
    );
  });

  test('round-trips an archive written by ZipEncoder', () async {
    final built = Archive()
      ..add(ArchiveFile.string('deep/YourLibrary.json', '{"tracks":[]}'))
      ..add(ArchiveFile.string('deep/notes.txt', 'hello'));
    final bytes = ZipEncoder().encodeBytes(built);
    final archive = ZipExportArchive.fromBytes(bytes);
    try {
      final entries = await archive.entries();
      expect(entries.map((e) => e.path).toList(), ['deep/YourLibrary.json', 'deep/notes.txt']);
      expect(entries.first.bytes, '{"tracks":[]}'.length);
      expect(await archive.readText('deep/notes.txt'), 'hello');
    } finally {
      await archive.close();
    }
  });
}
