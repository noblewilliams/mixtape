import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/listening/listening_api.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/import/listening_import_service.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart';

import '../helpers/fake_bridge.dart';
import 'fixtures.dart';

const _lagos = ImportOptions(timeZone: 'Africa/Lagos');

/// A stand-in for the listening and playlist protocols: records every
/// request, accepts every chunk, and answers complete() from the counts the
/// begin body promised. [override] answers a `'METHOD /path'` first;
/// [onRequest] sees every request before it is answered.
class _Server {
  _Server({this.override = const {}, this.onRequest});

  final Map<String, http.Response Function(http.Request request)> override;
  final void Function(http.Request request)? onRequest;
  final List<http.Request> requests = [];
  Map<String, dynamic>? beginBody;
  Map<String, dynamic>? playlistBeginBody;

  MockClient get client => MockClient((request) async {
        onRequest?.call(request);
        requests.add(request);
        final key = '${request.method} ${request.url.path}';
        final custom = override[key];
        if (custom != null) return custom(request);
        return _answer(request);
      });

  http.Response _answer(http.Request request) {
    final path = request.url.path;
    if (path == '/me/funnel-events') return http.Response('{"ok":true}', 201);
    if (path == '/ingest/listening/imports') {
      beginBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{"importId":"run-1","expiresAt":1788203600000}', 201);
    }
    if (path == '/ingest/listening/imports/run-1/complete') {
      final begin = beginBody!;
      return http.Response(
        jsonEncode({
          'tracks': begin['expectedTracks'],
          'days': begin['expectedDays'],
          'libraryTracks': begin['expectedLibraryTracks'],
          'artists': begin['expectedArtists'],
          'unresolvedRows': begin['unresolvedRows'],
          'unresolvedPlays': begin['unresolvedPlays'],
          'ledgerFrom': null,
          'ledgerTo': null,
          'likedRemoved': 0,
          'likedRemovalSkipped': false,
        }),
        200,
      );
    }
    if (path == '/ingest/playlists/syncs') {
      playlistBeginBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{"syncId":"sync-1","expiresAt":1788203600000}', 201);
    }
    if (path == '/ingest/playlists/syncs/sync-1/complete') {
      final begin = playlistBeginBody!;
      return http.Response(
        jsonEncode({
          'playlists': begin['expectedPlaylists'],
          'entries': begin['expectedEntries'],
          'resolvedEntries': begin['expectedEntries'],
          'unresolvedEntries': 0,
        }),
        200,
      );
    }
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final rows = body.values.whereType<List>().single;
      return http.Response('{"accepted":${rows.length}}', 200);
    }
    throw StateError('unexpected ${request.method} $path');
  }

  /// `'METHOD /path'` of every protocol request, funnel events excluded.
  List<String> get protocol => requests
      .where((r) => r.url.path != '/me/funnel-events')
      .map((r) => '${r.method} ${r.url.path}')
      .toList();

  List<String> get funnelTypes => requests
      .where((r) => r.url.path == '/me/funnel-events')
      .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['type'] as String)
      .toList();

  List<http.Request> puts(String suffix) =>
      requests.where((r) => r.method == 'PUT' && r.url.path.endsWith(suffix)).toList();

  List<List<Map<String, dynamic>>> chunks(String suffix, String key) => puts(suffix)
      .map((r) => ((jsonDecode(r.body) as Map<String, dynamic>)[key] as List)
          .cast<Map<String, dynamic>>())
      .toList();
}

Future<ListeningImportService> _service(
  _Server server, {
  ExportParser? parser,
  ExportInspector? inspector,
}) async =>
    ListeningImportService(
      api: ListeningApi(await apiWith(server.client)),
      parser: parser,
      inspector: inspector,
    );

List<int> _ordinals(List<List<Map<String, dynamic>>> chunks) =>
    [for (final chunk in chunks) for (final row in chunk) row['ordinal'] as int];

/// A parser hook that answers with a prepared snapshot after honouring the
/// cancel token, so cancellation tests need no archive.
ExportParser _parserFor(ListeningExportSnapshot snapshot) => (path, options) async {
      options.cancelToken?.throwIfCancelled();
      return ParsedExport(inventory: ExportInventory.empty, snapshot: snapshot);
    };

ListeningExportSnapshot _synthetic({
  ExportPackage package = ExportPackage.spotifyExtended,
  int tracks = 0,
  int days = 0,
  int library = 0,
  int artists = 0,
  List<SnapshotPlaylist> playlists = const [],
}) =>
    ListeningExportSnapshot(
      package: package,
      timeZone: 'Africa/Lagos',
      country: 'NG',
      tracks: [
        for (var i = 0; i < tracks; i++)
          SnapshotTrack(
            platformId: 'track${i.toString().padLeft(18, '0')}',
            title: 'T$i',
            artist: 'A',
            album: null,
            durationMs: null,
          ),
      ],
      days: [
        for (var i = 0; i < days; i++)
          SnapshotDay(
            platformId: 'track${(i % 500).toString().padLeft(18, '0')}',
            day: '2026-01-${(1 + i ~/ 500).toString().padLeft(2, '0')}',
            plays: 1,
            skips: 0,
            completes: 1,
            msPlayed: 30000,
            hoursMask: 1,
          ),
      ],
      library: [
        for (var i = 0; i < library; i++)
          SnapshotLibraryRow(platformId: 'liked${i.toString().padLeft(18, '0')}'),
      ],
      artists: [
        for (var i = 0; i < artists; i++)
          SnapshotArtist(name: 'Artist ${i.toString().padLeft(4, '0')}', spotifyId: null),
      ],
      playlists: playlists,
      unresolved: const SnapshotUnresolved(rows: 3, plays: 1),
      ledgerFrom: days == 0 ? null : '2026-01-01',
      ledgerTo: days == 0 ? null : '2026-01-05',
    );

SnapshotPlaylist _playlist(int ordinal, int entries) => SnapshotPlaylist(
      ordinal: ordinal,
      key: 'k' * 63 + ordinal.toString(),
      name: 'P$ordinal',
      description: null,
      lastModifiedAt: null,
      entries: [
        for (var i = 0; i < entries; i++)
          SnapshotEntry(
            position: i,
            platformId: null,
            title: 'E$i',
            artist: 'A',
            album: null,
            addedAt: null,
          ),
      ],
    );

void main() {
  group('extended package (extended-basic fixture)', () {
    late _Server server;
    late List<double> progress;
    late ListeningImportResult result;

    setUpAll(() async {
      server = _Server();
      progress = [];
      result = await (await _service(server)).import(
        fixtureArchive('extended-basic').path,
        _lagos,
        onProgress: progress.add,
      );
      await pumpEventQueue();
    });

    test('begins with the snapshot header and the expected counts', () {
      expect(server.beginBody, {
        'source': 'spotify_export',
        'package': 'spotify_extended',
        'timeZone': 'Africa/Lagos',
        'country': 'NG',
        'expectedTracks': 6,
        'expectedDays': 13,
        'expectedLibraryTracks': 0,
        'expectedArtists': 0,
        'unresolvedRows': 0,
        'unresolvedPlays': 0,
      });
    });

    test('uploads tracks and days only, then completes, and never syncs playlists', () {
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'PUT /ingest/listening/imports/run-1/tracks',
        'PUT /ingest/listening/imports/run-1/days',
        'POST /ingest/listening/imports/run-1/complete',
      ]);
      expect(result.playlistSummary, isNull);
    });

    test('rows are the canonical snapshot rows with their index as ordinal', () {
      final expected = expectedFor('extended-basic', 'default')['snapshot'] as Map<String, dynamic>;
      final tracks = server.chunks('/tracks', 'tracks').single;
      final days = server.chunks('/days', 'days').single;
      expect(tracks, [
        for (var i = 0; i < 6; i++) {'ordinal': i, ...(expected['tracks'] as List)[i] as Map},
      ]);
      expect(days, [
        for (var i = 0; i < 13; i++) {'ordinal': i, ...(expected['days'] as List)[i] as Map},
      ]);
    });

    test('returns the inventory and the server summary', () {
      final expected = expectedFor('extended-basic', 'default');
      expect(result.inventory.toCanonicalJson(), expected['inventory']);
      expect(result.summary.tracks, 6);
      expect(result.summary.days, 13);
      expect(result.summary.libraryTracks, 0);
      expect(result.summary.artists, 0);
    });

    test('posts import_completed once, after the run', () {
      expect(server.funnelTypes, ['import_completed']);
      expect(server.requests.last.url.path, '/me/funnel-events');
    });

    test('progress runs through the staged bounds and ends at 1.0', () {
      expect(progress.last, 1.0);
      expect(progress, contains(0.4));
      expect(progress, contains(0.95));
      final parse = progress.takeWhile((p) => p < 0.4);
      expect(parse, isNotEmpty);
      expect(progress.where((p) => p > 0.4 && p < 0.95), [0.4 + 0.55 * 6 / 19]);
      expect(progress, isNot(contains(0.99)));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    });
  });

  group('account package (account-basic fixture)', () {
    late _Server server;
    late List<double> progress;
    late ListeningImportResult result;

    setUpAll(() async {
      server = _Server();
      progress = [];
      result = await (await _service(server)).import(
        fixtureArchive('account-basic').path,
        _lagos,
        onProgress: progress.add,
      );
      await pumpEventQueue();
    });

    test('begins with expectedDays 0 and a null country', () {
      expect(server.beginBody, {
        'source': 'spotify_export',
        'package': 'spotify_account',
        'timeZone': 'Africa/Lagos',
        'country': null,
        'expectedTracks': 7,
        'expectedDays': 0,
        'expectedLibraryTracks': 5,
        'expectedArtists': 2,
        'unresolvedRows': 0,
        'unresolvedPlays': 0,
      });
    });

    test('uploads tracks, library, and artists, completes, then syncs playlists', () {
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'PUT /ingest/listening/imports/run-1/tracks',
        'PUT /ingest/listening/imports/run-1/library',
        'PUT /ingest/listening/imports/run-1/artists',
        'POST /ingest/listening/imports/run-1/complete',
        'POST /ingest/playlists/syncs',
        'PUT /ingest/playlists/syncs/sync-1/playlists',
        'PUT /ingest/playlists/syncs/sync-1/entries',
        'PUT /ingest/playlists/syncs/sync-1/entries',
        'POST /ingest/playlists/syncs/sync-1/complete',
      ]);
      expect(_ordinals(server.chunks('/library', 'tracks')), [0, 1, 2, 3, 4]);
      expect(_ordinals(server.chunks('/artists', 'artists')), [0, 1]);
    });

    test('opens the playlist sync as a Spotify export with no storefront', () {
      expect(server.playlistBeginBody, {
        'source': 'spotify_export',
        'storefront': null,
        'expectedPlaylists': 2,
        'expectedEntries': 5,
      });
    });

    test('playlist snapshots are exact, with the entry fingerprint', () {
      expect(server.chunks('/playlists', 'playlists').single, [
        {
          'ordinal': 0,
          'appleLibraryId': '3c88137edc1b39c79d1e8cbe6089c0b3e5eb4f751d0947990347c6aa95f2231e',
          'appleCatalogId': null,
          'name': 'Late Nights on the Ferry',
          'description': 'Slow ones for the crossing.',
          'curatorName': null,
          'artworkUrlTemplate': null,
          'artworkWidth': null,
          'artworkHeight': null,
          'artworkBgColor': null,
          'kind': 'user',
          'canEdit': false,
          'appleDateAdded': null,
          'appleLastModifiedAt': 1785542400000,
          // sha256 of "0\tLowTideRadio0000000001\tLow Tide Radio\tThe Copper Hours\n
          //             1\tPaperLanterns000000001\tPaper Lanterns\tMeridian Vale\n
          //             2\tWinterHarbour000000001\tWinter Harbour\tIvory Kestrel"
          'sourceFingerprint': '02c2a788eee9e5237c2edde74f9e407d9251d18e30ba619eb40696a3a304c539',
          'entryCount': 3,
        },
        {
          'ordinal': 1,
          'appleLibraryId': '8c09ae7ec3931a633140ce84a1f0f1064827fdcf3bff7608b4c88395169a917b',
          'appleCatalogId': null,
          'name': 'Running Uphill',
          'description': null,
          'curatorName': null,
          'artworkUrlTemplate': null,
          'artworkWidth': null,
          'artworkHeight': null,
          'artworkBgColor': null,
          'kind': 'user',
          'canEdit': false,
          'appleDateAdded': null,
          'appleLastModifiedAt': 1773532800000,
          // sha256 of "0\tKiteSeason000000000001\tKite Season\tIvory Kestrel\n
          //             1\tMothToNeon000000000001\tMoth to Neon\tVarious Artists"
          'sourceFingerprint': 'fbf9d77ffc96b59b8dc4c78b203276718ecaa895583dc76a82207e48de9b751e',
          'entryCount': 2,
        },
      ]);
    });

    test('entry snapshots are exact and keyed by playlist and position', () {
      final bodies = server.puts('/entries').map((r) => jsonDecode(r.body)).toList();
      const key0 = '3c88137edc1b39c79d1e8cbe6089c0b3e5eb4f751d0947990347c6aa95f2231e';
      const key1 = '8c09ae7ec3931a633140ce84a1f0f1064827fdcf3bff7608b4c88395169a917b';
      Map<String, Object?> entry(String key, int position, String id, String title, String artist, String album) => {
            'position': position,
            'appleLibraryEntryId': '$key:$position',
            'appleLibraryTrackId': null,
            'appleCatalogId': null,
            'spotifyId': id,
            'isrcSnapshot': null,
            'titleSnapshot': title,
            'artistSnapshot': artist,
            'albumSnapshot': album,
            'durationMsSnapshot': null,
            'artworkUrlTemplateSnapshot': null,
            'artworkWidthSnapshot': null,
            'artworkHeightSnapshot': null,
            'artworkBgColorSnapshot': null,
          };
      expect(bodies, [
        {
          'playlistAppleId': key0,
          'entries': [
            entry(key0, 0, 'LowTideRadio0000000001', 'Low Tide Radio', 'The Copper Hours', 'Night Ferry'),
            entry(key0, 1, 'PaperLanterns000000001', 'Paper Lanterns', 'Meridian Vale', 'Glasswork'),
            entry(key0, 2, 'WinterHarbour000000001', 'Winter Harbour', 'Ivory Kestrel', 'Signal Fires'),
          ],
        },
        {
          'playlistAppleId': key1,
          'entries': [
            entry(key1, 0, 'KiteSeason000000000001', 'Kite Season', 'Ivory Kestrel', 'Signal Fires'),
            entry(key1, 1, 'MothToNeon000000000001', 'Moth to Neon', 'Various Artists', 'Harbour Lights: A Compilation'),
          ],
        },
      ]);
    });

    test('returns both summaries and posts import_completed once', () {
      expect(result.summary.libraryTracks, 5);
      expect(result.playlistSummary?.playlists, 2);
      expect(result.playlistSummary?.entries, 5);
      expect(server.funnelTypes, ['import_completed']);
    });

    test('progress passes through the playlist stage before 1.0', () {
      expect(progress.last, 1.0);
      expect(progress, contains(0.95));
      expect(progress, contains(0.99));
      expect(progress.where((p) => p > 0.95 && p < 0.99), isNotEmpty);
      expect(progress.indexOf(0.99), lessThan(progress.length - 1));
    });
  });

  group('chunk boundaries', () {
    test('501 tracks and 2001 days split at 500 and 2000 with continuous ordinals', () async {
      final server = _Server();
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 501, days: 2001)));
      await service.import('any.zip', _lagos);

      final tracks = server.chunks('/tracks', 'tracks');
      final days = server.chunks('/days', 'days');
      expect(tracks.map((c) => c.length), [500, 1]);
      expect(days.map((c) => c.length), [2000, 1]);
      expect(_ordinals(tracks), List.generate(501, (i) => i));
      expect(_ordinals(days), List.generate(2001, (i) => i));
      expect(server.beginBody!['expectedTracks'], 501);
      expect(server.beginBody!['expectedDays'], 2001);
      expect(server.beginBody!['unresolvedRows'], 3);
      expect(server.beginBody!['unresolvedPlays'], 1);
    });

    test('501 liked, 501 artists, 51 playlists, and 201 entries split at 500, 500, 50, 200', () async {
      final server = _Server();
      final snapshot = _synthetic(
        package: ExportPackage.spotifyAccount,
        tracks: 1,
        library: 501,
        artists: 501,
        playlists: [_playlist(0, 201), for (var i = 1; i < 51; i++) _playlist(i, 0)],
      );
      final service = await _service(server, parser: _parserFor(snapshot));
      await service.import('any.zip', _lagos);

      expect(server.chunks('/library', 'tracks').map((c) => c.length), [500, 1]);
      expect(server.chunks('/artists', 'artists').map((c) => c.length), [500, 1]);
      expect(_ordinals(server.chunks('/artists', 'artists')), List.generate(501, (i) => i));
      expect(server.chunks('/playlists', 'playlists').map((c) => c.length), [50, 1]);
      expect(server.playlistBeginBody!['expectedPlaylists'], 51);
      expect(server.playlistBeginBody!['expectedEntries'], 201);

      final entryPuts = server.puts('/entries').map((r) => jsonDecode(r.body) as Map<String, dynamic>);
      final byPlaylist = <String, List<int>>{};
      for (final put in entryPuts) {
        byPlaylist.putIfAbsent(put['playlistAppleId'] as String, () => []).add((put['entries'] as List).length);
      }
      expect(byPlaylist['${'k' * 63}0'], [200, 1]);
      // An empty playlist sends no entries page, as the web service does.
      expect(byPlaylist, isNot(contains('${'k' * 63}1')));
      expect(byPlaylist, hasLength(1));
      expect(server.chunks('/playlists', 'playlists').first.first['sourceFingerprint'], hasLength(64));
      expect(
        server.chunks('/playlists', 'playlists').first[1]['sourceFingerprint'],
        // sha256 of the empty string: a playlist with no entries.
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('an empty extended snapshot begins, completes, and reports 0.95 then 1.0', () async {
      final server = _Server();
      final progress = <double>[];
      final service = await _service(server, parser: _parserFor(_synthetic()));
      await service.import('any.zip', _lagos, onProgress: progress.add);
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'POST /ingest/listening/imports/run-1/complete',
      ]);
      expect(progress, [0.4, 0.95, 1.0]);
    });
  });

  group('cancellation', () {
    test('between chunks stops further requests and throws ImportCancelled', () async {
      late ListeningImportService service;
      final server = _Server(
        onRequest: (request) {
          if (request.url.path.endsWith('/tracks')) service.cancel();
        },
      );
      service = await _service(server, parser: _parserFor(_synthetic(tracks: 501, days: 1)));

      await expectLater(service.import('any.zip', _lagos), throwsA(isA<ImportCancelled>()));
      await pumpEventQueue();
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'PUT /ingest/listening/imports/run-1/tracks',
      ]);
      expect(server.funnelTypes, isEmpty);
    });

    test('during the parse cancels the parser token and sends nothing', () async {
      final server = _Server();
      late ListeningImportService service;
      var tokenCancelled = false;
      service = await _service(
        server,
        parser: (path, options) async {
          service.cancel();
          tokenCancelled = options.cancelToken!.isCancelled;
          options.cancelToken!.throwIfCancelled();
          throw StateError('unreachable');
        },
      );

      await expectLater(service.import('any.zip', _lagos), throwsA(isA<ImportCancelled>()));
      expect(tokenCancelled, isTrue);
      expect(server.requests, isEmpty);
    });

    test('cancel() with no run in flight is a no-op and the next run proceeds', () async {
      final server = _Server();
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 1)));
      service.cancel();
      final result = await service.import('any.zip', _lagos);
      expect(result.summary.tracks, 1);
    });

    test('between playlist entry chunks stops the sync and throws ImportCancelled', () async {
      late ListeningImportService service;
      final server = _Server(
        onRequest: (request) {
          if (request.url.path.endsWith('/entries')) service.cancel();
        },
      );
      final snapshot = _synthetic(package: ExportPackage.spotifyAccount, tracks: 1, playlists: [_playlist(0, 201)]);
      service = await _service(server, parser: _parserFor(snapshot));

      await expectLater(service.import('any.zip', _lagos), throwsA(isA<ImportCancelled>()));
      await pumpEventQueue();
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'PUT /ingest/listening/imports/run-1/tracks',
        'POST /ingest/listening/imports/run-1/complete',
        'POST /ingest/playlists/syncs',
        'PUT /ingest/playlists/syncs/sync-1/playlists',
        'PUT /ingest/playlists/syncs/sync-1/entries',
      ]);
      expect(server.funnelTypes, isEmpty);
    });

    test('after a cancel, the next import() starts a fresh run', () async {
      late ListeningImportService service;
      var cancelled = false;
      final server = _Server(
        onRequest: (request) {
          if (cancelled || !request.url.path.endsWith('/tracks')) return;
          cancelled = true;
          service.cancel();
        },
      );
      service = await _service(server, parser: _parserFor(_synthetic(tracks: 501)));

      await expectLater(service.import('any.zip', _lagos), throwsA(isA<ImportCancelled>()));
      final result = await service.import('any.zip', _lagos);
      await pumpEventQueue();
      expect(result.summary.tracks, 501);
      expect(server.protocol.where((r) => r == 'POST /ingest/listening/imports'), hasLength(2));
      expect(server.protocol.last, 'POST /ingest/listening/imports/run-1/complete');
      expect(server.funnelTypes, ['import_completed']);
    });

    test("a joiner's cancel() aborts the shared run for the first caller too", () async {
      final begun = Completer<void>();
      final server = _Server(
        onRequest: (request) {
          if (request.url.path == '/ingest/listening/imports' && !begun.isCompleted) begun.complete();
        },
      );
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 501)));

      final first = service.import('any.zip', _lagos);
      await begun.future;
      final joined = service.import('other.zip', _lagos);
      service.cancel();

      await expectLater(joined, throwsA(isA<ImportCancelled>()));
      await expectLater(first, throwsA(isA<ImportCancelled>()));
      await pumpEventQueue();
      expect(server.protocol, ['POST /ingest/listening/imports']);
      expect(server.funnelTypes, isEmpty);
    });

    test('cancel() during inspect() rejects with ImportCancelled and leaves the service usable', () async {
      final server = _Server();
      late ListeningImportService service;
      var inspections = 0;
      service = await _service(
        server,
        inspector: (path, {cancelToken}) async {
          if (++inspections == 1) {
            service.cancel();
            cancelToken!.throwIfCancelled();
            throw StateError('unreachable');
          }
          return ExportInventory.empty;
        },
        parser: _parserFor(_synthetic(tracks: 1)),
      );

      await expectLater(service.inspect('any.zip'), throwsA(isA<ImportCancelled>()));
      await pumpEventQueue();
      expect(server.funnelTypes, isEmpty);

      final inventory = await service.inspect('any.zip');
      final result = await service.import('any.zip', _lagos);
      await pumpEventQueue();
      expect(inventory.package, isNull);
      expect(result.summary.tracks, 1);
      expect(server.funnelTypes, ['file_inspected', 'import_completed']);
    });
  });

  group('errors', () {
    test('an API error propagates as ApiException with its code and stops the run', () async {
      final server = _Server(override: {
        'PUT /ingest/listening/imports/run-1/tracks': (_) =>
            http.Response('{"error":"sync_conflict"}', 409),
      });
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 501, days: 1)));

      await expectLater(
        service.import('any.zip', _lagos),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(ListeningApiErrorCode.of, 'code', ListeningApiErrorCode.syncConflict),
        ),
      );
      await pumpEventQueue();
      expect(server.protocol, [
        'POST /ingest/listening/imports',
        'PUT /ingest/listening/imports/run-1/tracks',
      ]);
      expect(server.funnelTypes, isEmpty);
    });

    test('an accepted count that differs from the chunk is a protocol failure', () async {
      final server = _Server(override: {
        'PUT /ingest/listening/imports/run-1/tracks': (_) => http.Response('{"accepted":499}', 200),
      });
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 500)));
      await expectLater(
        service.import('any.zip', _lagos),
        throwsA(isA<ListeningImportProtocolException>()),
      );
      expect(server.protocol, isNot(contains('POST /ingest/listening/imports/run-1/complete')));
    });

    test('a summary whose counts differ from the snapshot is a protocol failure', () async {
      final server = _Server(override: {
        'POST /ingest/listening/imports/run-1/complete': (_) => http.Response(
              '{"tracks":1,"days":0,"libraryTracks":0,"artists":0,"unresolvedRows":0,"unresolvedPlays":0,"ledgerFrom":null,"ledgerTo":null,"likedRemoved":0,"likedRemovalSkipped":false}',
              200,
            ),
      });
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 2)));
      await expectLater(
        service.import('any.zip', _lagos),
        throwsA(isA<ListeningImportProtocolException>()),
      );
    });

    test('a playlist summary that does not add up is a protocol failure', () async {
      final server = _Server(override: {
        'POST /ingest/playlists/syncs/sync-1/complete': (_) => http.Response(
              '{"playlists":1,"entries":2,"resolvedEntries":1,"unresolvedEntries":0}',
              200,
            ),
      });
      final snapshot = _synthetic(package: ExportPackage.spotifyAccount, tracks: 1, playlists: [_playlist(0, 2)]);
      final service = await _service(server, parser: _parserFor(snapshot));
      await expectLater(
        service.import('any.zip', _lagos),
        throwsA(isA<ListeningImportProtocolException>()),
      );
    });

    test('an unreadable archive surfaces as UnreadableExportException before any request', () async {
      final server = _Server();
      final service = await _service(server);
      await expectLater(
        service.import(fixtureArchive('extended-malformed').path, _lagos),
        throwsA(isA<UnreadableExportException>()),
      );
      expect(server.requests, isEmpty);
    });

    test('a transport failure surfaces as NetworkException', () async {
      final service = ListeningImportService(
        api: ListeningApi(await apiWith(MockClient((_) async => throw http.ClientException('down')))),
        parser: _parserFor(_synthetic(tracks: 1)),
      );
      await expectLater(service.import('any.zip', _lagos), throwsA(isA<NetworkException>()));
    });
  });

  group('funnel events', () {
    test('a failing funnel endpoint never surfaces from import()', () async {
      final server = _Server(override: {
        'POST /me/funnel-events': (_) => http.Response('{"error":"boom"}', 500),
      });
      final service = await _service(server, parser: _parserFor(_synthetic(tracks: 1)));
      final result = await service.import('any.zip', _lagos);
      await pumpEventQueue();
      expect(result.summary.tracks, 1);
      expect(server.funnelTypes, ['import_completed']);
    });

    test('a funnel transport failure never surfaces from inspect()', () async {
      final service = ListeningImportService(
        api: ListeningApi(await apiWith(MockClient((_) async => throw http.ClientException('down')))),
        inspector: (path, {cancelToken}) async => ExportInventory.empty,
      );
      final inventory = await service.inspect('any.zip');
      await pumpEventQueue();
      expect(inventory.package, isNull);
    });

    test('inspect() lists the archive and posts file_inspected', () async {
      final server = _Server();
      final service = await _service(server);
      final inventory = await service.inspect(fixtureArchive('account-basic').path);
      await pumpEventQueue();
      expect(inventory.toCanonicalJson(), expectedFor('account-basic', 'default')['inventory']);
      expect(server.protocol, isEmpty);
      expect(server.funnelTypes, ['file_inspected']);
    });
  });

  test('re-entrant import calls join the in-flight run, then reset for the next call', () async {
    final server = _Server();
    final service = await _service(server, parser: _parserFor(_synthetic(tracks: 1)));

    final results = await Future.wait([
      service.import('any.zip', _lagos),
      service.import('other.zip', _lagos),
    ]);
    expect(results.map((r) => r.summary.tracks), [1, 1]);
    expect(server.protocol.where((r) => r == 'POST /ingest/listening/imports'), hasLength(1));

    await service.import('any.zip', _lagos);
    expect(server.protocol.where((r) => r == 'POST /ingest/listening/imports'), hasLength(2));
  });

  test('playlistFingerprint orders by position and blanks a missing id', () {
    const entries = [
      SnapshotEntry(position: 1, platformId: null, title: 'B', artist: 'Y', album: null, addedAt: null),
      SnapshotEntry(position: 0, platformId: 'LowTideRadio0000000001', title: 'A', artist: 'X', album: null, addedAt: null),
    ];
    // sha256 of "0\tLowTideRadio0000000001\tA\tX\n1\t\tB\tY"
    expect(
      playlistFingerprint(entries),
      'fb43ea7fb21ba3bb300531af5f18660622385cb685d490dde82978839aa7cbe3',
    );
  });
}
