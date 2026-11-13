import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';

const _token = 'AbCdEfGhIjKlMnOpQrStUv';

Map<String, dynamic> _shared({bool isOwner = false}) => {
  'token': _token,
  'title': 'Night drive',
  'caseColor': '#335577',
  'sharerName': 'Ada',
  'sharedAt': '2026-11-13T10:00:00.000Z',
  'isOwner': isOwner,
  if (isOwner) 'sessionId': 's1',
  'tracks': [
    {
      'title': 'Song',
      'artist': 'Artist',
      'album': null,
      'durationMs': 200000,
      'artwork': null,
      'appleId': '1',
      'isrc': null,
    },
  ],
};

class _Seen {
  String? method;
  Uri? url;
  String? auth;
  String? body;
}

Future<(DjApi, _Seen, List<String>)> _api(
  http.Response Function(http.Request req) answer, {
  String? token = 'tok',
}) async {
  final store = InMemoryTokenStore();
  if (token != null) await store.write(token);
  final seen = _Seen();
  final signedOut = <String>[];
  final api = DjApi(
    baseUrl: 'http://x',
    tokenStore: store,
    inner: MockClient((req) async {
      seen
        ..method = req.method
        ..url = req.url
        ..auth = req.headers['Authorization']
        ..body = req.body;
      return answer(req);
    }),
    onUnauthorized: (t) async => signedOut.add(t),
  );
  return (api, seen, signedOut);
}

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('getSharedMix', () {
    test('GETs /shared/:token with the session and parses it', () async {
      final (api, seen, _) = await _api((_) => _json(_shared(), 200));
      final mix = await api.getSharedMix(_token);
      expect(seen.method, 'GET');
      expect(seen.url.toString(), 'http://x/shared/$_token');
      expect(seen.auth, 'Bearer tok');
      expect(mix.title, 'Night drive');
      expect(mix.tracks.single.appleId, '1');
    });

    test('works signed out (no Authorization header)', () async {
      final (api, seen, _) = await _api(
        (_) => _json(_shared(), 200),
        token: null,
      );
      final mix = await api.getSharedMix(_token);
      expect(seen.auth, isNull);
      expect(mix.isOwner, isFalse);
    });

    test('404 not_found is gone (not found)', () async {
      final (api, _, _) = await _api((_) => _json({'error': 'not_found'}, 404));
      await expectLater(
        api.getSharedMix(_token),
        throwsA(
          isA<SharedMixGoneException>().having(
            (e) => e.reason,
            'reason',
            SharedMixGoneReason.notFound,
          ),
        ),
      );
    });

    test('410 revoked is gone (revoked)', () async {
      final (api, _, _) = await _api((_) => _json({'error': 'revoked'}, 410));
      await expectLater(
        api.getSharedMix(_token),
        throwsA(
          isA<SharedMixGoneException>().having(
            (e) => e.reason,
            'reason',
            SharedMixGoneReason.revoked,
          ),
        ),
      );
    });

    test('429 is the generic ApiException', () async {
      final (api, _, _) = await _api(
        (_) => _json({'error': 'rate_limited'}, 429),
      );
      await expectLater(
        api.getSharedMix(_token),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 429)),
      );
    });

    test('a 401 never signs the listener out', () async {
      final (api, _, signedOut) = await _api(
        (_) => _json({'error': 'unauthorized'}, 401),
      );
      await expectLater(api.getSharedMix(_token), throwsA(isA<ApiException>()));
      await Future<void>.delayed(Duration.zero);
      expect(signedOut, isEmpty);
    });

    test('a malformed 200 is a malformed_response DjApiException', () async {
      final (api, _, _) = await _api((_) => _json({'token': _token}, 200));
      await expectLater(
        api.getSharedMix(_token),
        throwsA(
          isA<DjApiException>().having(
            (e) => e.kind,
            'kind',
            'malformed_response',
          ),
        ),
      );
    });
  });

  group('saveSharedMix', () {
    test('POSTs /shared/:token/save with the session', () async {
      final (api, seen, _) = await _api((_) => http.Response('', 204));
      await api.saveSharedMix(_token);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'http://x/shared/$_token/save');
      expect(seen.auth, 'Bearer tok');
    });

    test('410 is gone (revoked); 404 is gone (not found)', () async {
      var (api, _, _) = await _api((_) => _json({'error': 'revoked'}, 410));
      await expectLater(
        api.saveSharedMix(_token),
        throwsA(
          isA<SharedMixGoneException>().having(
            (e) => e.reason,
            'reason',
            SharedMixGoneReason.revoked,
          ),
        ),
      );
      (api, _, _) = await _api((_) => _json({'error': 'not_found'}, 404));
      await expectLater(
        api.saveSharedMix(_token),
        throwsA(isA<SharedMixGoneException>()),
      );
    });

    test('a 401 with a token still signs out (an expired session)', () async {
      final (api, _, signedOut) = await _api(
        (_) => _json({'error': 'unauthorized'}, 401),
      );
      await expectLater(
        api.saveSharedMix(_token),
        throwsA(isA<ApiException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(signedOut, ['tok']);
    });
  });

  group('removeSharedMix', () {
    test('DELETEs /shared/:token/save', () async {
      final (api, seen, _) = await _api((_) => http.Response('', 204));
      await api.removeSharedMix(_token);
      expect(seen.method, 'DELETE');
      expect(seen.url.toString(), 'http://x/shared/$_token/save');
      expect(seen.auth, 'Bearer tok');
    });
  });

  group('listSharedMixes', () {
    test('GETs /me/shared-mixes and parses the rows', () async {
      final (api, seen, _) = await _api(
        (_) => _json({
          'mixes': [
            {
              'token': _token,
              'title': 'Night drive',
              'caseColor': '#335577',
              'sharerName': null,
              'savedAt': '2026-11-13T11:00:00.000Z',
              'trackCount': 3,
              'durationMs': 600000,
              'artwork': null,
            },
          ],
        }, 200),
      );
      final rows = await api.listSharedMixes();
      expect(seen.method, 'GET');
      expect(seen.url.toString(), 'http://x/me/shared-mixes');
      expect(seen.auth, 'Bearer tok');
      expect(rows.single.sharerName, isNull);
      expect(rows.single.trackCount, 3);
    });

    test('a malformed row is a malformed_response DjApiException', () async {
      final (api, _, _) = await _api(
        (_) => _json({
          'mixes': [
            {'token': _token},
          ],
        }, 200),
      );
      await expectLater(api.listSharedMixes(), throwsA(isA<DjApiException>()));
    });
  });

  group('shareSession', () {
    test('POSTs /sessions/:id/share and returns token and url', () async {
      final (api, seen, _) = await _api(
        (_) => _json({
          'token': _token,
          'url': 'https://miixtape.netlify.app/m/$_token',
        }, 200),
      );
      final link = await api.shareSession('s1');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'http://x/sessions/s1/share');
      expect(seen.auth, 'Bearer tok');
      expect(link.token, _token);
      expect(link.url, 'https://miixtape.netlify.app/m/$_token');
    });

    test('409 name_required is ShareNameRequiredException', () async {
      final (api, _, _) = await _api(
        (_) => _json({'error': 'name_required'}, 409),
      );
      await expectLater(
        api.shareSession('s1'),
        throwsA(isA<ShareNameRequiredException>()),
      );
    });

    test('422 empty_mix is EmptyMixException', () async {
      final (api, _, _) = await _api((_) => _json({'error': 'empty_mix'}, 422));
      await expectLater(
        api.shareSession('s1'),
        throwsA(isA<EmptyMixException>()),
      );
    });

    test('404 passes through as ApiException', () async {
      final (api, _, _) = await _api((_) => _json({'error': 'not_found'}, 404));
      await expectLater(
        api.shareSession('s1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('429 is the generic ApiException', () async {
      final (api, _, _) = await _api(
        (_) => _json({'error': 'rate_limited'}, 429),
      );
      await expectLater(
        api.shareSession('s1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 429)),
      );
    });
  });

  group('stopSharing', () {
    test('DELETEs /sessions/:id/share', () async {
      final (api, seen, _) = await _api((_) => http.Response('', 204));
      await api.stopSharing('s1');
      expect(seen.method, 'DELETE');
      expect(seen.url.toString(), 'http://x/sessions/s1/share');
      expect(seen.auth, 'Bearer tok');
    });
  });
}
