import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/diagnostics.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';
import 'package:mixtape/import/zone_clock.dart';

import 'fixtures.dart';

const lagos = ParseOptions(timeZone: 'Africa/Lagos');

void main() {
  group('PII case', () {
    const sentinels = ['Identity', 'Inferences', 'Payments', 'Userdata', '__MACOSX'];

    test('parse never reads a sentinel entry', () async {
      final archive = RecordingArchive(ZipExportArchive.open(fixtureArchive('account-pii-present')));
      try {
        final parsed = await parseExport(archive, lagos);
        expect(parsed.inventory.package, ExportPackage.spotifyAccount);
        expect(
          archive.reads,
          ['Spotify Account Data/Playlist1.json', 'Spotify Account Data/YourLibrary.json'],
        );
        for (final read in archive.reads) {
          for (final sentinel in sentinels) {
            expect(read, isNot(contains(sentinel)));
          }
        }
      } finally {
        await archive.close();
      }
    });

    test('inspect and diagnose never read a sentinel entry either', () async {
      final archive = RecordingArchive(ZipExportArchive.open(fixtureArchive('account-pii-present')));
      try {
        await inspectExport(archive);
        await diagnoseExport(archive);
        expect(archive.reads.toSet(), {
          'Spotify Account Data/Playlist1.json',
          'Spotify Account Data/YourLibrary.json',
        });
      } finally {
        await archive.close();
      }
    });
  });

  group('cancellation', () {
    test('a token cancelled between files throws ImportCancelled', () async {
      final token = CancelToken();
      final inner = ZipExportArchive.open(fixtureArchive('extended-basic'));
      final archive = _CancelAfterFirstRead(inner, token);
      try {
        await expectLater(
          parseExport(archive, ParseOptions(timeZone: 'Africa/Lagos', cancelToken: token)),
          throwsA(isA<ImportCancelled>()),
        );
        expect(archive.reads, 1);
      } finally {
        await inner.close();
      }
    });

    test('a token cancelled mid-file throws ImportCancelled at the next checkpoint', () async {
      final token = CancelToken();
      final archive = ZipExportArchive.fromBytes(_syntheticArchive(files: 1, rowsPerFile: 20000).bytes);
      var rowEvents = 0;
      try {
        await expectLater(
          parseExport(
            archive,
            ParseOptions(
              timeZone: 'Africa/Lagos',
              cancelToken: token,
              onProgress: (stage, file, completed, total) {
                if (stage == ParseStage.parsing && completed > 0 && completed < total) {
                  rowEvents += 1;
                  token.cancel();
                }
              },
            ),
          ),
          throwsA(isA<ImportCancelled>()),
        );
        expect(rowEvents, 1);
      } finally {
        await archive.close();
      }
    });

    test('a token cancelled before the run throws before any read', () async {
      final token = CancelToken()..cancel();
      final archive = RecordingArchive(ZipExportArchive.open(fixtureArchive('extended-basic')));
      try {
        await expectLater(
          parseExport(archive, ParseOptions(timeZone: 'Africa/Lagos', cancelToken: token)),
          throwsA(isA<ImportCancelled>()),
        );
        expect(archive.reads, isEmpty);
      } finally {
        await archive.close();
      }
    });
  });

  group('progress', () {
    test('reports inspecting once and parsing per file in byte terms', () async {
      final events = <(ParseStage, String?, int, int)>[];
      final archive = ZipExportArchive.open(fixtureArchive('extended-basic'));
      try {
        await parseExport(
          archive,
          ParseOptions(
            timeZone: 'Africa/Lagos',
            onProgress: (stage, file, completed, total) => events.add((stage, file, completed, total)),
          ),
        );
      } finally {
        await archive.close();
      }
      expect(events.first.$1, ParseStage.inspecting);
      expect(events.first.$4, 3);
      final parsing = events.where((e) => e.$1 == ParseStage.parsing).toList();
      expect(parsing.map((e) => e.$2).whereType<String>().toSet(), hasLength(3));
      expect(parsing.last.$3, parsing.last.$4);
      final completed = parsing.map((e) => e.$3).toList();
      expect(completed, orderedEquals(List.of(completed)..sort()));
    });
  });

  group('large archive', () {
    test('parses 15 files / ~200k rows under the ceiling', () async {
      final synthetic = _syntheticArchive(files: 15, rowsPerFile: 13334);
      final archive = ZipExportArchive.fromBytes(synthetic.bytes);
      final stopwatch = Stopwatch()..start();
      final parsed = await parseExport(archive, lagos);
      stopwatch.stop();
      await archive.close();
      // ignore: avoid_print
      print('large archive: ${synthetic.rows} rows parsed in ${stopwatch.elapsedMilliseconds} ms');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));

      final snapshot = parsed.snapshot;
      expect(parsed.inventory.read, hasLength(15));
      expect(parsed.inventory.read.fold<int>(0, (sum, f) => sum + (f.rows ?? 0)), synthetic.rows);
      expect(snapshot.tracks, hasLength(synthetic.trackCount));
      expect(snapshot.days.fold<int>(0, (sum, d) => sum + d.plays), synthetic.plays);
      expect(snapshot.days.fold<int>(0, (sum, d) => sum + d.msPlayed), synthetic.msPlayed);
      expect(snapshot.days.fold<int>(0, (sum, d) => sum + d.completes), synthetic.completes);
      expect(snapshot.unresolved.rows, 0);
      expect(snapshot.country, 'NG');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('ZoneClock', () {
    test('converts exactly inside a half-hour zone transition hour', () {
      final clock = ZoneClock('America/St_Johns');
      // Spring forward 2025-03-09: 02:00 -03:30 -> 03:00 -02:30. The UTC hour
      // 05:00-06:00Z starts on -03:30 and ends on -02:30.
      expect(clock.local(DateTime.utc(2025, 3, 9, 5, 15).millisecondsSinceEpoch), const LocalTime('2025-03-09', 1));
      expect(clock.local(DateTime.utc(2025, 3, 9, 5, 45).millisecondsSinceEpoch), const LocalTime('2025-03-09', 3));
      // Fall back 2025-11-02: 02:00 -02:30 -> 01:00 -03:30.
      expect(clock.local(DateTime.utc(2025, 11, 2, 4, 15).millisecondsSinceEpoch), const LocalTime('2025-11-02', 1));
      expect(clock.local(DateTime.utc(2025, 11, 2, 4, 45).millisecondsSinceEpoch), const LocalTime('2025-11-02', 1));
      // Repeating the same hour uses the cache decision consistently.
      expect(clock.local(DateTime.utc(2025, 3, 9, 5, 45).millisecondsSinceEpoch), const LocalTime('2025-03-09', 3));
    });

    test('crosses the local midnight boundary in Lagos and Los Angeles', () {
      final lagosClock = ZoneClock('Africa/Lagos');
      expect(lagosClock.local(DateTime.utc(2025, 6, 10, 23, 30).millisecondsSinceEpoch), const LocalTime('2025-06-11', 0));
      final la = ZoneClock('America/Los_Angeles');
      expect(la.local(DateTime.utc(2025, 6, 11, 0, 30).millisecondsSinceEpoch), const LocalTime('2025-06-10', 17));
      // Spring-forward instant: 2025-03-09 10:00Z is 03:00 PDT.
      expect(la.local(DateTime.utc(2025, 3, 9, 10, 0).millisecondsSinceEpoch), const LocalTime('2025-03-09', 3));
      expect(la.local(DateTime.utc(2025, 3, 9, 9, 59).millisecondsSinceEpoch), const LocalTime('2025-03-09', 1));
    });
  });

  group('rules not pinned by a fixture', () {
    test('a ZIP with no allow-listed file is unreadable with a null file', () async {
      final built = Archive()..add(ArchiveFile.string('Spotify Account Data/Userdata.json', '{"x":1}'));
      final archive = ZipExportArchive.fromBytes(ZipEncoder().encodeBytes(built));
      try {
        final inventory = await inspectExport(archive);
        expect(inventory.package, isNull);
        expect(inventory.read, isEmpty);
        expect(inventory.ignored.map((f) => f.path).toList(), ['Spotify Account Data/Userdata.json']);
        await expectLater(
          parseExport(archive, lagos),
          throwsA(isA<UnreadableExportException>().having((e) => e.file, 'file', isNull)),
        );
      } finally {
        await archive.close();
      }
    });

    test('a history file whose top level is an object is unreadable', () async {
      final built = Archive()
        ..add(ArchiveFile.string('Streaming_History_Audio_2025_0.json', '{"not":"an array"}'));
      final archive = ZipExportArchive.fromBytes(ZipEncoder().encodeBytes(built));
      try {
        await expectLater(
          parseExport(archive, lagos),
          throwsA(
            isA<UnreadableExportException>()
                .having((e) => e.file, 'file', 'Streaming_History_Audio_2025_0.json'),
          ),
        );
      } finally {
        await archive.close();
      }
    });

    test('a malformed track uri counts as unresolved and non-object rows are skipped', () async {
      final rows = [
        _row(ts: '2025-06-10T10:00:00Z', ms: 60000, uri: 'spotify:track:tooshort'),
        42,
        _row(ts: '2025-06-10T10:00:00.5Z', ms: 60000, uri: 'spotify:track:Good000000000000000001'),
      ];
      final built = Archive()
        ..add(ArchiveFile.string('Streaming_History_Audio_2025_0.json', jsonEncode(rows)));
      final archive = ZipExportArchive.fromBytes(ZipEncoder().encodeBytes(built));
      try {
        final parsed = await parseExport(archive, lagos);
        expect(parsed.inventory.read.single.rows, 3);
        expect(parsed.snapshot.unresolved.rows, 1);
        expect(parsed.snapshot.unresolved.plays, 1);
        expect(parsed.snapshot.tracks.single.platformId, 'Good000000000000000001');
        expect(parsed.snapshot.days.single.hoursMask, 1 << 11);
      } finally {
        await archive.close();
      }
    });
  });

  // Stats are not part of the fixture contract: the fixture suite compares
  // inventory and snapshot only. The numbers here are hand-counted from the
  // cases' `src/<case>/case.json` (invented data).
  group('stats (not compared by the fixture contract)', () {
    Future<ExportStats> statsFor(String caseName, {bool includePrivateSessions = false}) async {
      final archive = ZipExportArchive.open(fixtureArchive(caseName));
      try {
        final parsed = await parseExport(
          archive,
          ParseOptions(timeZone: 'Africa/Lagos', includePrivateSessions: includePrivateSessions),
        );
        return parsed.stats;
      } finally {
        await archive.close();
      }
    }

    test('extended-podcasts-and-local: two episodes and an audiobook, three rows with no track uri', () async {
      final stats = await statsFor('extended-podcasts-and-local');
      expect(stats.podcastOrAudiobook, 3);
      expect(stats.localFile, 3);
      expect(stats.privateSession, 0);
      expect(stats.badTimestamp, 0);
      expect(stats.privatePlays, 0);
    });

    test('extended-private-sessions: four private rows dropped by default, all four at or over 30 s', () async {
      final stats = await statsFor('extended-private-sessions');
      expect(stats.privateSession, 4);
      // Three resolved private plays plus one private local-file row of 90 s:
      // the 30 s rule counts it, whether or not it resolves to a track.
      expect(stats.privatePlays, 4);
      // Private rows are filtered first, so the private local-file row is
      // not a local-file drop under the default.
      expect(stats.localFile, 0);
      expect(stats.podcastOrAudiobook, 0);
      expect(stats.badTimestamp, 0);
    });

    test('extended-private-sessions with private sessions included drops nothing for privacy', () async {
      final stats = await statsFor('extended-private-sessions', includePrivateSessions: true);
      expect(stats.privateSession, 0);
      expect(stats.privatePlays, 0);
      expect(stats.localFile, 1);
    });

    test('extended-basic: three resolved rows with a timestamp outside the grammar', () async {
      final stats = await statsFor('extended-basic');
      expect(stats.badTimestamp, 3);
      expect(stats.podcastOrAudiobook, 0);
      expect(stats.localFile, 0);
      expect(stats.privateSession, 0);
      expect(stats.privatePlays, 0);
    });

    test('the account package has no row drops', () async {
      final stats = await statsFor('account-basic');
      expect(stats, ExportStats.zero);
      expect(ExportStats.zero.podcastOrAudiobook + ExportStats.zero.localFile, 0);
    });

    test('stats never reach the canonical documents', () async {
      final archive = ZipExportArchive.open(fixtureArchive('extended-podcasts-and-local'));
      try {
        final parsed = await parseExport(archive, lagos);
        expect(parsed.inventory.toCanonicalJson().keys, ['package', 'read', 'ignored']);
        expect(parsed.snapshot.toCanonicalJson().keys, isNot(contains('stats')));
      } finally {
        await archive.close();
      }
    });
  });
}

Map<String, Object?> _row({required String ts, required int ms, required String? uri}) => {
  'ts': ts,
  'ms_played': ms,
  'conn_country': 'NG',
  'master_metadata_track_name': 'Synthetic',
  'master_metadata_album_artist_name': 'Synthetic Artist',
  'master_metadata_album_album_name': null,
  'spotify_track_uri': uri,
  'spotify_episode_uri': null,
  'audiobook_uri': null,
  'reason_end': 'trackdone',
  'skipped': false,
  'incognito_mode': false,
};

class _CancelAfterFirstRead extends ExportArchive {
  _CancelAfterFirstRead(this.inner, this.token);

  final ExportArchive inner;
  final CancelToken token;
  int reads = 0;

  @override
  Future<List<ArchiveEntryInfo>> entries() => inner.entries();

  @override
  Future<String> readText(String path) async {
    reads += 1;
    final text = await inner.readText(path);
    token.cancel();
    return text;
  }
}

class _Synthetic {
  _Synthetic(this.bytes, {required this.rows, required this.plays, required this.msPlayed, required this.completes, required this.trackCount});

  final Uint8List bytes;
  final int rows;
  final int plays;
  final int msPlayed;
  final int completes;
  final int trackCount;
}

/// Builds an extended-history archive with invented names: [files] history
/// files of [rowsPerFile] rows each, cycling over 500 ids, four play lengths,
/// and three end reasons, with ascending timestamps.
_Synthetic _syntheticArchive({required int files, required int rowsPerFile}) {
  const trackCount = 500;
  const lengths = [12000, 45000, 200000, 250000];
  const reasons = ['fwdbtn', 'endplay', 'trackdone', 'trackdone'];
  final built = Archive();
  var rows = 0;
  var plays = 0;
  var msPlayed = 0;
  var completes = 0;
  final start = DateTime.utc(2019, 1, 1).millisecondsSinceEpoch;
  for (var f = 0; f < files; f++) {
    final buffer = StringBuffer('[');
    for (var i = 0; i < rowsPerFile; i++) {
      final n = f * rowsPerFile + i;
      final track = n % trackCount;
      final ms = lengths[n % lengths.length];
      final reason = reasons[n % reasons.length];
      final ts = DateTime.fromMillisecondsSinceEpoch(start + n * 97000, isUtc: true)
          .toIso8601String()
          .replaceFirst('.000Z', 'Z');
      if (i > 0) buffer.write(',');
      buffer.write('{"ts":"$ts","platform":"ios","ms_played":$ms,"conn_country":"NG",'
          '"ip_addr":"203.0.113.9","master_metadata_track_name":"Synthetic Song $track",'
          '"master_metadata_album_artist_name":"Synthetic Artist ${track % 40}",'
          '"master_metadata_album_album_name":"Synthetic Album ${track % 90}",'
          '"spotify_track_uri":"spotify:track:${'Synth${track.toString().padLeft(3, '0')}'.padRight(22, '0')}",'
          '"episode_name":null,"episode_show_name":null,"spotify_episode_uri":null,'
          '"audiobook_title":null,"audiobook_uri":null,"audiobook_chapter_uri":null,'
          '"audiobook_chapter_title":null,"reason_start":"clickrow","reason_end":"$reason",'
          '"shuffle":false,"offline":false,"offline_timestamp":null,"incognito_mode":false}');
      rows += 1;
      msPlayed += ms;
      if (ms >= 30000) plays += 1;
      if (reason == 'trackdone') completes += 1;
    }
    buffer.write(']');
    built.add(ArchiveFile.string(
      'Spotify Extended Streaming History/Streaming_History_Audio_2019-2026_$f.json',
      buffer.toString(),
    ));
  }
  return _Synthetic(
    ZipEncoder().encodeBytes(built),
    rows: rows,
    plays: plays,
    msPlayed: msPlayed,
    completes: completes,
    trackCount: trackCount,
  );
}

