import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/listening/listening_api.dart';
import 'package:mixtape/data/listening/listening_models.dart';

import '../helpers/fake_bridge.dart';

/// Records every request and answers each path from [responses]
/// (`'METHOD /path'` → body), defaulting to `{}` 200.
class _Recorder {
  _Recorder(this.responses);

  final Map<String, http.Response> responses;
  final List<http.Request> requests = [];

  MockClient get client => MockClient((request) async {
        requests.add(request);
        return responses['${request.method} ${request.url.path}'] ??
            http.Response('{}', 200);
      });

  http.Request get single {
    expect(requests, hasLength(1));
    return requests.single;
  }

  Map<String, dynamic> get singleBody =>
      jsonDecode(single.body) as Map<String, dynamic>;
}

Future<ListeningApi> _api(_Recorder recorder) async =>
    ListeningApi(await apiWith(recorder.client));

const _beginBody = BeginListeningImport(
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  expectedTracks: 6,
  expectedDays: 13,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
  unresolvedRows: 1,
  unresolvedPlays: 2,
);

void main() {
  group('listening import protocol', () {
    test('beginImport posts the begin body and parses the run', () async {
      final recorder = _Recorder({
        'POST /ingest/listening/imports':
            http.Response('{"importId":"run-1","expiresAt":1788203600000}', 201),
      });
      final run = await (await _api(recorder)).beginImport(_beginBody);

      expect(recorder.single.method, 'POST');
      expect(recorder.singleBody, {
        'source': 'spotify_export',
        'package': 'spotify_extended',
        'timeZone': 'Africa/Lagos',
        'country': 'NG',
        'expectedTracks': 6,
        'expectedDays': 13,
        'expectedLibraryTracks': 0,
        'expectedArtists': 0,
        'unresolvedRows': 1,
        'unresolvedPlays': 2,
      });
      expect(run.importId, 'run-1');
      expect(run.expiresAt, DateTime.fromMillisecondsSinceEpoch(1788203600000, isUtc: true));
    });

    test('beginImport rejects a malformed run', () async {
      final recorder = _Recorder({
        'POST /ingest/listening/imports': http.Response('{"importId":""}', 201),
      });
      await expectLater(
        (await _api(recorder)).beginImport(_beginBody),
        throwsA(isA<ListeningModelException>()),
      );
    });

    test('putTracks PUTs the chunk under `tracks` and returns accepted', () async {
      final recorder = _Recorder({
        'PUT /ingest/listening/imports/run-1/tracks': http.Response('{"accepted":2}', 200),
      });
      final rows = [
        {'ordinal': 0, 'platformId': 'a', 'title': 'T', 'artist': 'A', 'album': null, 'durationMs': null},
        {'ordinal': 1, 'platformId': 'b', 'title': 'U', 'artist': 'B', 'album': 'X', 'durationMs': 5},
      ];
      final accepted = await (await _api(recorder)).putTracks('run-1', rows);

      expect(recorder.single.method, 'PUT');
      expect(recorder.singleBody, {'tracks': rows});
      expect(accepted, 2);
    });

    test('putDays / putLibrary / putArtists use their own paths and keys', () async {
      final recorder = _Recorder({
        'PUT /ingest/listening/imports/run-1/days': http.Response('{"accepted":1}', 200),
        'PUT /ingest/listening/imports/run-1/library': http.Response('{"accepted":1}', 200),
        'PUT /ingest/listening/imports/run-1/artists': http.Response('{"accepted":1}', 200),
      });
      final api = await _api(recorder);
      final day = {'ordinal': 0, 'platformId': 'a', 'day': '2026-01-01', 'plays': 1, 'skips': 0, 'completes': 1, 'msPlayed': 1, 'hoursMask': 1};
      final library = {'ordinal': 0, 'platformId': 'a', 'playCount': null, 'skipCount': null, 'lastPlayedAt': null, 'dateAdded': null, 'likeRating': null};
      final artist = {'ordinal': 0, 'name': 'A', 'spotifyId': null};

      expect(await api.putDays('run-1', [day]), 1);
      expect(await api.putLibrary('run-1', [library]), 1);
      expect(await api.putArtists('run-1', [artist]), 1);

      expect(recorder.requests.map((r) => '${r.method} ${r.url.path}'), [
        'PUT /ingest/listening/imports/run-1/days',
        'PUT /ingest/listening/imports/run-1/library',
        'PUT /ingest/listening/imports/run-1/artists',
      ]);
      expect(jsonDecode(recorder.requests[0].body), {'days': [day]});
      expect(jsonDecode(recorder.requests[1].body), {'tracks': [library]});
      expect(jsonDecode(recorder.requests[2].body), {'artists': [artist]});
    });

    test('a chunk response without a non-negative accepted count is malformed', () async {
      final recorder = _Recorder({
        'PUT /ingest/listening/imports/run-1/tracks': http.Response('{"accepted":-1}', 200),
      });
      await expectLater(
        (await _api(recorder)).putTracks('run-1', [{'ordinal': 0}]),
        throwsA(isA<ListeningModelException>()),
      );
    });

    test('completeImport posts an empty body and parses the summary', () async {
      final recorder = _Recorder({
        'POST /ingest/listening/imports/run-1/complete': http.Response(
          jsonEncode({
            'tracks': 6,
            'days': 13,
            'libraryTracks': 0,
            'artists': 0,
            'unresolvedRows': 1,
            'unresolvedPlays': 2,
            'ledgerFrom': '2024-03-02',
            'ledgerTo': '2026-04-05',
            'likedRemoved': 0,
            'likedRemovalSkipped': false,
          }),
          200,
        ),
      });
      final summary = await (await _api(recorder)).completeImport('run-1');

      expect(recorder.single.method, 'POST');
      expect(recorder.singleBody, <String, dynamic>{});
      expect(summary.tracks, 6);
      expect(summary.days, 13);
      expect(summary.libraryTracks, 0);
      expect(summary.artists, 0);
      expect(summary.unresolvedRows, 1);
      expect(summary.unresolvedPlays, 2);
      expect(summary.ledgerFrom, '2024-03-02');
      expect(summary.ledgerTo, '2026-04-05');
      expect(summary.likedRemoved, 0);
      expect(summary.likedRemovalSkipped, isFalse);
    });

    test('completeImport parses null ledger bounds', () async {
      final recorder = _Recorder({
        'POST /ingest/listening/imports/run-1/complete': http.Response(
          '{"tracks":7,"days":0,"libraryTracks":5,"artists":2,"unresolvedRows":0,"unresolvedPlays":0,"ledgerFrom":null,"ledgerTo":null,"likedRemoved":3,"likedRemovalSkipped":true}',
          200,
        ),
      });
      final summary = await (await _api(recorder)).completeImport('run-1');
      expect(summary.ledgerFrom, isNull);
      expect(summary.ledgerTo, isNull);
      expect(summary.likedRemoved, 3);
      expect(summary.likedRemovalSkipped, isTrue);
    });

    test('deleteSource DELETEs the source and parses the result', () async {
      final recorder = _Recorder({
        'DELETE /ingest/listening/sources/spotify_export':
            http.Response('{"deletedDays":4,"deletedTracks":2,"unlibraried":1}', 200),
      });
      final result = await (await _api(recorder)).deleteSource('spotify_export');
      expect(recorder.single.method, 'DELETE');
      expect(result.deletedDays, 4);
      expect(result.deletedTracks, 2);
      expect(result.unlibraried, 1);
    });
  });

  group('playlist sync protocol (Spotify export)', () {
    test('beginPlaylistSync sends the source with a null storefront', () async {
      final recorder = _Recorder({
        'POST /ingest/playlists/syncs':
            http.Response('{"syncId":"sync-1","expiresAt":1788203600000}', 201),
      });
      final run = await (await _api(recorder)).beginPlaylistSync(
        expectedPlaylists: 2,
        expectedEntries: 5,
      );
      expect(recorder.singleBody, {
        'source': 'spotify_export',
        'storefront': null,
        'expectedPlaylists': 2,
        'expectedEntries': 5,
      });
      expect(run.syncId, 'sync-1');
    });

    test('putPlaylists / putPlaylistEntries / completePlaylistSync', () async {
      final recorder = _Recorder({
        'PUT /ingest/playlists/syncs/sync-1/playlists': http.Response('{"accepted":1}', 200),
        'PUT /ingest/playlists/syncs/sync-1/entries': http.Response('{"accepted":0}', 200),
        'POST /ingest/playlists/syncs/sync-1/complete': http.Response(
          '{"playlists":1,"entries":0,"resolvedEntries":0,"unresolvedEntries":0}',
          200,
        ),
      });
      final api = await _api(recorder);
      expect(await api.putPlaylists('sync-1', [{'ordinal': 0}]), 1);
      expect(await api.putPlaylistEntries('sync-1', 'key', []), 0);
      final summary = await api.completePlaylistSync('sync-1');

      expect(jsonDecode(recorder.requests[0].body), {'playlists': [{'ordinal': 0}]});
      expect(jsonDecode(recorder.requests[1].body), {'playlistAppleId': 'key', 'entries': []});
      expect(recorder.requests[2].method, 'POST');
      expect(summary.playlists, 1);
      expect(summary.entries, 0);
      expect(summary.resolvedEntries, 0);
      expect(summary.unresolvedEntries, 0);
    });
  });

  group('onboarding and sources', () {
    const source = {
      'source': 'spotify_export',
      'connectedAt': '2026-09-01T10:00:00.000Z',
      'lastImportedAt': '2026-09-02T10:00:00.000Z',
      'ledgerFrom': '2024-03-02',
      'ledgerTo': '2026-04-05',
      'packages': ['spotify_account', 'spotify_extended'],
    };

    test('getOnboarding GETs /me/onboarding and parses every field', () async {
      final recorder = _Recorder({
        'GET /me/onboarding': http.Response(
          jsonEncode({
            'userId': 'user-1',
            'sources': [source],
            'hasLibrary': true,
            'chosenService': 'spotify',
            'markedRequestedAt': '2026-09-01T11:00:00.000Z',
            'interviewCompletedAt': '2026-09-01T12:00:00.000Z',
            'importCompletedAt': '2026-09-02T10:00:00.000Z',
            'interview': {'artists': 4, 'notes': 5},
          }),
          200,
        ),
      });
      final state = await (await _api(recorder)).getOnboarding();
      expect(recorder.single.method, 'GET');
      expect(state.userId, 'user-1');
      expect(state.sources, hasLength(1));
      expect(state.sources.single.source, 'spotify_export');
      expect(state.sources.single.packages, ['spotify_account', 'spotify_extended']);
      expect(state.interview?.artists, 4);
      expect(state.interview?.notes, 5);
      expect(state.withChosenService('spotify').interview?.notes, 5);
      expect(state.sources.single.connectedAt, DateTime.utc(2026, 9, 1, 10));
      expect(state.sources.single.lastImportedAt, DateTime.utc(2026, 9, 2, 10));
      expect(state.sources.single.ledgerFrom, '2024-03-02');
      expect(state.sources.single.ledgerTo, '2026-04-05');
      expect(state.hasLibrary, isTrue);
      expect(state.chosenService, 'spotify');
      expect(state.markedRequestedAt, DateTime.utc(2026, 9, 1, 11));
      expect(state.interviewCompletedAt, DateTime.utc(2026, 9, 1, 12));
      expect(state.importCompletedAt, DateTime.utc(2026, 9, 2, 10));
    });

    test('getOnboarding parses a fresh listener (nulls everywhere)', () async {
      final recorder = _Recorder({
        'GET /me/onboarding': http.Response(
          '{"userId":"user-1","sources":[],"hasLibrary":false,"chosenService":null,"markedRequestedAt":null,"interviewCompletedAt":null,"importCompletedAt":null}',
          200,
        ),
      });
      final state = await (await _api(recorder)).getOnboarding();
      expect(state.userId, 'user-1');
      expect(state.sources, isEmpty);
      expect(state.hasLibrary, isFalse);
      expect(state.chosenService, isNull);
      expect(state.markedRequestedAt, isNull);
      expect(state.interview, isNull);
    });

    test('getOnboarding reads a null interview and a source without packages', () async {
      final recorder = _Recorder({
        'GET /me/onboarding': http.Response(
          '{"userId":"user-1","sources":[{"source":"apple_live","connectedAt":"2026-09-01T10:00:00.000Z",'
          '"lastImportedAt":null,"ledgerFrom":null,"ledgerTo":null}],"hasLibrary":true,'
          '"chosenService":"apple","markedRequestedAt":null,"interviewCompletedAt":null,'
          '"importCompletedAt":null,"interview":null}',
          200,
        ),
      });
      final state = await (await _api(recorder)).getOnboarding();
      expect(state.sources.single.packages, isEmpty);
      expect(state.interview, isNull);
    });

    test('getOnboarding rejects packages that are not strings and a malformed interview', () async {
      for (final body in [
        '{"userId":"user-1","sources":[{"source":"spotify_export","connectedAt":"2026-09-01T10:00:00.000Z",'
            '"lastImportedAt":null,"ledgerFrom":null,"ledgerTo":null,"packages":[1]}],"hasLibrary":false,'
            '"chosenService":null,"markedRequestedAt":null,"interviewCompletedAt":null,"importCompletedAt":null}',
        '{"userId":"user-1","sources":[],"hasLibrary":false,"chosenService":null,"markedRequestedAt":null,'
            '"interviewCompletedAt":null,"importCompletedAt":null,"interview":{"artists":-1,"notes":2}}',
      ]) {
        final recorder = _Recorder({'GET /me/onboarding': http.Response(body, 200)});
        await expectLater(
          (await _api(recorder)).getOnboarding(),
          throwsA(isA<ListeningModelException>()),
          reason: body,
        );
      }
    });

    test('getOnboarding rejects an answer without the listener id', () async {
      final recorder = _Recorder({
        'GET /me/onboarding': http.Response(
          '{"sources":[],"hasLibrary":false,"chosenService":null,"markedRequestedAt":null,"interviewCompletedAt":null,"importCompletedAt":null}',
          200,
        ),
      });
      await expectLater(
        (await _api(recorder)).getOnboarding(),
        throwsA(isA<ListeningModelException>()),
      );
    });

    test('getMusicSources parses a bare source (nothing landed yet)', () async {
      final recorder = _Recorder({
        'GET /me/music-sources': http.Response(
          '{"sources":[{"source":"apple_live","connectedAt":"2026-09-01T10:00:00.000Z","lastImportedAt":null,"ledgerFrom":null,"ledgerTo":null}]}',
          200,
        ),
      });
      final sources = await (await _api(recorder)).getMusicSources();
      expect(recorder.single.url.path, '/me/music-sources');
      expect(sources.single.source, 'apple_live');
      expect(sources.single.lastImportedAt, isNull);
      expect(sources.single.ledgerFrom, isNull);
      expect(sources.single.packages, isEmpty);
    });

    test('getMusicSources parses the packages that landed', () async {
      final recorder = _Recorder({
        'GET /me/music-sources': http.Response(
          '{"sources":[{"source":"spotify_export","connectedAt":"2026-09-01T10:00:00.000Z","lastImportedAt":"2026-09-02T10:00:00.000Z","ledgerFrom":null,"ledgerTo":null,"packages":["spotify_account"]}]}',
          200,
        ),
      });
      final sources = await (await _api(recorder)).getMusicSources();
      expect(sources.single.packages, ['spotify_account']);
    });
  });

  group('funnel, interview, seeds', () {
    test('postFunnelEvent posts the type with the ios surface', () async {
      final recorder = _Recorder({
        'POST /me/funnel-events': http.Response('{"ok":true}', 201),
      });
      await (await _api(recorder)).postFunnelEvent(FunnelEventType.fileInspected);
      expect(recorder.single.method, 'POST');
      expect(recorder.singleBody, {'type': 'file_inspected', 'surface': 'ios'});
    });

    test('every funnel event type carries its wire name', () {
      expect(FunnelEventType.values.map((t) => t.wire), [
        'chose_spotify',
        'marked_requested',
        'file_inspected',
        'import_completed',
        'first_personal_mix',
        'first_output',
      ]);
    });

    test('postInterview posts the answers and parses the counts', () async {
      final recorder = _Recorder({
        'POST /me/interview': http.Response(
          '{"seeds":2,"notes":{"saved":4,"duplicate":1,"capped":0}}',
          200,
        ),
      });
      final result = await (await _api(recorder)).postInterview(
        const InterviewAnswers(
          neverSkip: ['Ivory Kestrel', 'Meridian Vale'],
          playsMost: 'slow ones',
          listensWhen: 'late',
          neverWants: '',
          era: '2010s',
        ),
      );
      expect(recorder.singleBody, {
        'surface': 'ios',
        'neverSkip': ['Ivory Kestrel', 'Meridian Vale'],
        'playsMost': 'slow ones',
        'listensWhen': 'late',
        'neverWants': '',
        'era': '2010s',
      });
      expect(result.seeds, 2);
      expect(result.notesSaved, 4);
      expect(result.notesDuplicate, 1);
      expect(result.notesCapped, 0);
    });

    const seed = {
      'name': 'Ivory Kestrel',
      'spotifyId': null,
      'source': 'interview',
      'createdAt': '2026-09-01T10:00:00.000Z',
    };

    test('getArtistSeeds and putArtistSeeds', () async {
      final recorder = _Recorder({
        'GET /me/artist-seeds': http.Response(jsonEncode({'seeds': [seed]}), 200),
        'PUT /me/artist-seeds': http.Response(jsonEncode({'seeds': [seed]}), 200),
      });
      final api = await _api(recorder);
      final listed = await api.getArtistSeeds();
      final replaced = await api.putArtistSeeds(['Ivory Kestrel']);

      expect(recorder.requests[0].method, 'GET');
      expect(recorder.requests[1].method, 'PUT');
      expect(jsonDecode(recorder.requests[1].body), {'names': ['Ivory Kestrel']});
      for (final seeds in [listed, replaced]) {
        expect(seeds.single.name, 'Ivory Kestrel');
        expect(seeds.single.spotifyId, isNull);
        expect(seeds.single.source, 'interview');
        expect(seeds.single.createdAt, DateTime.utc(2026, 9, 1, 10));
      }
    });

    test('getSeedTracks / postSeedTracks / deleteSeedTrack', () async {
      final recorder = _Recorder({
        'GET /me/seed-tracks': http.Response(
          '{"tracks":[{"trackId":"t1","spotifyId":"4uLU6hMCjMI75M1A2tKUQC","title":"T","artist":"A","album":null}]}',
          200,
        ),
        'POST /me/seed-tracks': http.Response(
          '{"resolved":[{"spotifyId":"4uLU6hMCjMI75M1A2tKUQC","trackId":"t1","title":"T","artist":"A"}],"unresolved":["0000000000000000000000"]}',
          200,
        ),
        'DELETE /me/seed-tracks/t1': http.Response('{"removed":true,"deleted":false}', 200),
      });
      final api = await _api(recorder);

      final listed = await api.getSeedTracks();
      expect(listed.single.trackId, 't1');
      expect(listed.single.spotifyId, '4uLU6hMCjMI75M1A2tKUQC');
      expect(listed.single.album, isNull);

      final posted = await api.postSeedTracks(['4uLU6hMCjMI75M1A2tKUQC', '0000000000000000000000']);
      expect(jsonDecode(recorder.requests[1].body), {
        'spotifyIds': ['4uLU6hMCjMI75M1A2tKUQC', '0000000000000000000000'],
      });
      expect(posted.resolved.single.trackId, 't1');
      expect(posted.resolved.single.spotifyId, '4uLU6hMCjMI75M1A2tKUQC');
      expect(posted.unresolved, ['0000000000000000000000']);

      final deleted = await api.deleteSeedTrack('t1');
      expect(recorder.requests[2].method, 'DELETE');
      expect(deleted.removed, isTrue);
      expect(deleted.deleted, isFalse);
    });
  });

  group('error codes', () {
    test('reads every typed code from an ApiException body', () {
      const wire = {
        'not_found': ListeningApiErrorCode.notFound,
        'sync_conflict': ListeningApiErrorCode.syncConflict,
        'invalid_state': ListeningApiErrorCode.invalidState,
        'count_mismatch': ListeningApiErrorCode.countMismatch,
        'invalid_id': ListeningApiErrorCode.invalidId,
        'invalid_request': ListeningApiErrorCode.invalidRequest,
        'invalid_storefront': ListeningApiErrorCode.invalidStorefront,
        'upstream': ListeningApiErrorCode.upstream,
      };
      wire.forEach((name, code) {
        expect(ListeningApiErrorCode.of(ApiException(400, '{"error":"$name"}')), code);
      });
    });

    test('is null for an unknown code, a non-string error, or a non-JSON body', () {
      expect(ListeningApiErrorCode.of(ApiException(500, '{"error":"boom"}')), isNull);
      expect(ListeningApiErrorCode.of(ApiException(400, '{"error":{"issues":[]}}')), isNull);
      expect(ListeningApiErrorCode.of(ApiException(502, 'Bad Gateway')), isNull);
      expect(ListeningApiErrorCode.of(ApiException(400, '[]')), isNull);
    });

    test('an error response surfaces as ApiException with its code', () async {
      final recorder = _Recorder({
        'POST /ingest/listening/imports': http.Response('{"error":"sync_conflict"}', 409),
      });
      await expectLater(
        (await _api(recorder)).beginImport(_beginBody),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(ListeningApiErrorCode.of, 'code', ListeningApiErrorCode.syncConflict),
        ),
      );
    });
  });
}
