import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/playlists/playlist_context_api.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';

Map<String, Object?> seed({String status = 'ready', int revision = 4}) => {
  'playlistId': status == 'none' ? null : 'playlist-a',
  'revision': revision,
  'excludeSourceTracks': status != 'none',
  'status': status,
  'name': status == 'ready' ? 'Evening' : null,
  'source': status == 'ready' ? 'apple' : null,
  'fingerprint': status == 'ready' ? 'fingerprint' : null,
  'updatedAt': status == 'ready' ? '2026-09-08T10:00:00.000Z' : null,
  'entries': status == 'ready' ? 5 : 0,
  'resolvedEntries': status == 'ready' ? 4 : 0,
  'recordings': status == 'ready' ? 3 : 0,
  'profile': null,
};

PlaylistContextApi apiWith(Future<http.Response> Function(http.Request) call) =>
    PlaylistContextApi(
      ApiClient(
        baseUrl: 'https://example.test',
        tokenStore: InMemoryTokenStore(),
        inner: MockClient(call),
      ),
    );

void main() {
  test('legacy omission is distinct from canonical none', () async {
    var count = 0;
    final api = apiWith((request) async {
      expect(request.url.path, '/sessions/mix-a');
      return http.Response(
        jsonEncode(
          count++ == 0
              ? <String, Object?>{}
              : {'playlistSeed': seed(status: 'none', revision: 0)},
        ),
        200,
      );
    });
    expect(await api.getSessionSeed('mix-a'), isNull);
    final result = await api.getSessionSeed('mix-a');
    expect(result!.status, PlaylistSeedStatus.none);
    expect(result.revision, 0);
    expect(result.playlistId, isNull);
    expect(result.excludeSourceTracks, isFalse);
    expect(result.name, isNull);
    expect(result.source, isNull);
    expect(result.recordings, 0);
  });

  test(
    'unavailable selection preserves identity without invented metadata',
    () async {
      final api = apiWith(
        (_) async => http.Response(
          jsonEncode({'playlistSeed': seed(status: 'unavailable')}),
          200,
        ),
      );
      final result = await api.getSessionSeed('mix-a');
      expect(result!.status, PlaylistSeedStatus.unavailable);
      expect(result.playlistId, 'playlist-a');
      expect(result.revision, 4);
      expect(result.excludeSourceTracks, isTrue);
      expect(result.name, isNull);
      expect(result.source, isNull);
      expect(result.fingerprint, isNull);
      expect(result.updatedAt, isNull);
      expect(result.profile, isNull);
      expect(result.entries, 0);
    },
  );

  test(
    'selection uses exact identity and revision, returns canonical state',
    () async {
      final api = apiWith((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/sessions/mix-a/playlist-seed');
        expect(jsonDecode(request.body), {
          'playlistId': 'playlist-a',
          'expectedRevision': 3,
          'excludeSourceTracks': true,
        });
        return http.Response(jsonEncode({'playlistSeed': seed()}), 200);
      });
      final result = await api.selectSeed(
        'mix-a',
        playlistId: 'playlist-a',
        expectedRevision: 3,
        excludeSourceTracks: true,
      );
      expect(result.revision, 4);
      expect(result.name, 'Evening');
      expect(result.recordings, 3);
    },
  );

  test('detach sends explicit null without generating a turn', () async {
    final api = apiWith((request) async {
      expect(request.method, 'PUT');
      expect(jsonDecode(request.body), {
        'playlistId': null,
        'expectedRevision': 4,
        'excludeSourceTracks': false,
      });
      return http.Response(
        jsonEncode({'playlistSeed': seed(status: 'none', revision: 5)}),
        200,
      );
    });
    expect(
      (await api.selectSeed(
        'mix-a',
        playlistId: null,
        expectedRevision: 4,
      )).status,
      PlaylistSeedStatus.none,
    );
  });

  test('stale selection stays a context conflict and never retries', () async {
    var requests = 0;
    final api = apiWith((_) async {
      requests++;
      return http.Response('{"error":"stale"}', 409);
    });
    await expectLater(
      api.selectSeed('mix-a', playlistId: 'playlist-a', expectedRevision: 1),
      throwsA(
        isA<PlaylistContextException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.isStale, 'isStale', true),
      ),
    );
    expect(requests, 1);
  });

  test(
    'taste removal sends false and ineligibility remains distinct',
    () async {
      var requests = 0;
      final api = apiWith((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/playlists/playlist-a/taste-confirmation');
        expect(jsonDecode(request.body), {'confirmed': requests == 1});
        return ++requests == 1
            ? http.Response('{"ok":true}', 200)
            : http.Response('{"error":"playlist_not_eligible"}', 409);
      });
      await api.confirmTaste('playlist-a', confirmed: false);
      await expectLater(
        api.confirmTaste('playlist-a', confirmed: true),
        throwsA(
          isA<PlaylistContextException>()
              .having((e) => e.isIneligible, 'isIneligible', true)
              .having((e) => e.isStale, 'isStale', false),
        ),
      );
      expect(requests, 2);
    },
  );

  test('malformed seed cannot masquerade as an empty selection', () async {
    for (final value in [
      null,
      {},
      {...seed(), 'revision': -1},
      {...seed(), 'status': 'future'},
    ]) {
      final api = apiWith(
        (_) async => http.Response(jsonEncode({'playlistSeed': value}), 200),
      );
      await expectLater(
        api.getSessionSeed('mix-a'),
        throwsA(isA<PlaylistContextModelException>()),
      );
    }
  });

  test('authentication status survives non-JSON error responses', () async {
    final api = apiWith((_) async => http.Response('Unauthorized', 401));
    await expectLater(
      api.getSessionSeed('mix-a'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
  });

  test('profile fields and source are validated without coercion', () {
    final json = {
      ...seed(),
      'profile': {
        'sampledRecordings': 3,
        'tempo': 95,
        'energy': 0.7,
        'releaseYear': 2001,
        'artists': ['Artist'],
        'genres': ['Soul'],
      },
    };
    final value = PlaylistSeedState.fromJson(json);
    expect(value.profile!.tempo, 95.0);
    expect(value.source, PlaylistSeedSource.apple);
    expect(() => value.profile!.artists.add('Other'), throwsUnsupportedError);
    for (final malformed in [
      {...json, 'source': 'future'},
      {...json, 'excludeSourceTracks': 1},
      {...json, 'recordings': '3'},
      {
        ...json,
        'profile': {'sampledRecordings': 3},
      },
    ]) {
      expect(
        () => PlaylistSeedState.fromJson(malformed),
        throwsA(isA<PlaylistContextModelException>()),
      );
    }
  });

  test('initial selection has no revision or queue operation', () {
    expect(
      const InitialPlaylistSeed(
        playlistId: 'playlist-a',
        excludeSourceTracks: true,
      ).toJson(),
      {'playlistId': 'playlist-a', 'excludeSourceTracks': true},
    );
  });
}
