import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';

Map<String, dynamic> _session({
  String id = 's1',
  String title = 'a mellow tape',
  String status = 'active',
  int queueVersion = 1,
  String updatedAt = '2026-08-29T12:00:00.000Z',
}) => {
      'id': id,
      'title': title,
      'status': status,
      'queueVersion': queueVersion,
      'updatedAt': updatedAt,
    };

Map<String, dynamic> _djMessage({
  String id = 'm1',
  String content = 'here you go',
  int? queueVersion = 1,
  String createdAt = '2026-08-29T12:00:01.000Z',
}) => {
      'id': id,
      'role': 'dj',
      'content': content,
      'queueVersion': queueVersion,
      'createdAt': createdAt,
    };

Map<String, dynamic> _track({
  int position = 0,
  String? appleId = 'apple-1',
  Object? artworkUrl = 'https://is1-ssl.mzstatic.com/image/thumb/cover/{w}x{h}.{f}',
  Object? artworkWidth = 3000,
  Object? artworkHeight = 3000,
  Object? artworkBgColor = '1a2b3c',
}) => {
      'position': position,
      'trackId': 'track-$position',
      'appleId': appleId,
      'title': 'Song $position',
      'artist': 'Artist $position',
      'reason': 'fits the vibe',
      'durationMs': 200000,
      'artworkUrl': artworkUrl,
      'artworkWidth': artworkWidth,
      'artworkHeight': artworkHeight,
      'artworkBgColor': artworkBgColor,
    };

DjApi _api({required http.Client inner, Duration timeout = const Duration(seconds: 120)}) => DjApi(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: inner,
      timeout: timeout,
    );

void main() {
  group('createSession', () {
    test('sends exact optional inspiration and preserves legacy unknown state', () async {
      final inner = MockClient((req) async {
        expect(jsonDecode(req.body), {'prompt': 'Night drive', 'playlistSeed': {'playlistId': 'exact-playlist-id', 'excludeSourceTracks': true}});
        return http.Response(jsonEncode({'session': _session(), 'messages': [], 'queue': []}), 200);
      });
      final result = await _api(inner: inner).createSession('Night drive', playlistSeed: const InitialPlaylistSeed(playlistId: 'exact-playlist-id', excludeSourceTracks: true));
      expect(result.playlistSeed, isNull);
    });


    test('parses canonical empty seed but rejects malformed seed capability', () async {
      Map<String, dynamic>? wireSeed = {
        'playlistId': null, 'revision': 4, 'excludeSourceTracks': false,
        'status': 'none', 'name': null, 'source': null, 'fingerprint': null,
        'updatedAt': null, 'entries': 0, 'resolvedEntries': 0, 'recordings': 0, 'profile': null,
      };
      final api = _api(inner: MockClient((_) async => http.Response(jsonEncode({'session': _session(), 'messages': [], 'queue': [], 'playlistSeed': wireSeed}), 200)));
      expect((await api.getSession('s1')).playlistSeed!.revision, 4);
      wireSeed = null;
      await expectLater(api.getSession('s1'), throwsA(isA<DjApiException>()));
    });

    test('POSTs prompt to /sessions and parses SessionDetail', () async {
      String? seenMethod;
      Uri? seenUrl;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenMethod = req.method;
        seenUrl = req.url;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'session': _session(),
            'messages': [_djMessage()],
            'queue': [_track()],
          }),
          200,
        );
      });

      final detail = await _api(inner: inner).createSession('play me something mellow');

      expect(seenMethod, 'POST');
      expect(seenUrl.toString(), 'http://x/sessions');
      expect(seenBody, {'prompt': 'play me something mellow'});
      expect(detail.session.id, 's1');
      expect(detail.messages, hasLength(1));
      expect(detail.queue, hasLength(1));
      expect(detail.queue.first.appleId, 'apple-1');
      expect(detail.queue.first.artworkUrl,
          'https://is1-ssl.mzstatic.com/image/thumb/cover/{w}x{h}.{f}');
      expect(detail.queue.first.artworkWidth, 3000);
      expect(detail.queue.first.artworkHeight, 3000);
      expect(detail.queue.first.artworkBgColor, '1a2b3c');
    });

    test('parses explicit null artwork without affecting the queue', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'session': _session(),
              'messages': [_djMessage()],
              'queue': [
                _track(
                  artworkUrl: null,
                  artworkWidth: null,
                  artworkHeight: null,
                  artworkBgColor: null,
                ),
              ],
            }),
            200,
          ));

      final detail = await _api(inner: inner).createSession('anything');

      expect(detail.queue.single.artworkUrl, isNull);
      expect(detail.queue.single.artworkWidth, isNull);
      expect(detail.queue.single.artworkHeight, isNull);
      expect(detail.queue.single.artworkBgColor, isNull);
    });

    test('rejects malformed optional artwork types through the typed API exit', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'session': _session(),
              'messages': [_djMessage()],
              'queue': [_track(artworkWidth: '3000')],
            }),
            200,
          ));

      await expectLater(
        _api(inner: inner).createSession('anything'),
        throwsA(
          isA<DjApiException>().having(
            (error) => error.kind,
            'kind',
            'malformed_response',
          ),
        ),
      );
    });

    test('502 with message+queue -> DjApiException carrying both', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'error': 'llm',
              'message': 'the DJ is taking a breather',
              'queue': [_track()],
              'sessionId': 'orphan-session',
            }),
            502,
          ));

      try {
        await _api(inner: inner).createSession('anything');
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'llm');
        expect(e.message, 'the DJ is taking a breather');
        expect(e.queue, isNotNull);
        expect(e.queue, hasLength(1));
        expect(e.sessionId, 'orphan-session');
      }
    });

    test('403 anonymous_cap -> AnonymousCapException carrying the limit', () async {
      final inner = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/sessions');
        return http.Response(jsonEncode({'error': 'anonymous_cap', 'limit': 3}), 403);
      });
      await expectLater(
        _api(inner: inner).createSession('one more'),
        throwsA(isA<AnonymousCapException>().having((e) => e.limit, 'limit', 3)),
      );
    });

    test('403 anonymous_cap without an integer limit -> AnonymousCapException(3)', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'anonymous_cap', 'limit': 'three'}), 403));
      await expectLater(
        _api(inner: inner).createSession('one more'),
        throwsA(isA<AnonymousCapException>().having((e) => e.limit, 'limit', 3)),
      );
      final bare = MockClient((_) async => http.Response(jsonEncode({'error': 'anonymous_cap'}), 403));
      await expectLater(
        _api(inner: bare).createSession('one more'),
        throwsA(isA<AnonymousCapException>().having((e) => e.limit, 'limit', 3)),
      );
    });

    test('any other 403 still passes through as a plain ApiException', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'forbidden'}), 403));
      await expectLater(
        _api(inner: inner).createSession('hi'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('400 zod-default shape (error is a Map, not a string) -> kind invalid, '
        'generic message (the serialized blob is never rendered)', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'success': false,
              'error': {
                'name': 'ZodError',
                // zod@4's real serialization: a JSON-stringified issues blob,
                // not a structured {issues:[...]} object. Never fit to render.
                'message': '[{"code":"too_small","minimum":1,"path":["prompt"],"message":"Too small"}]',
              },
            }),
            400,
          ));

      try {
        await _api(inner: inner).createSession('');
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'invalid');
        expect(e.message, isNot(contains('ZodError')));
        expect(e.message, isNot(contains('too_small')));
      }
    });
  });

  group('listSessions', () {
    test('GETs /sessions and parses the list', () async {
      String? seenMethod;
      Uri? seenUrl;
      final inner = MockClient((req) async {
        seenMethod = req.method;
        seenUrl = req.url;
        return http.Response(
          jsonEncode({
            'sessions': [_session(id: 'a'), _session(id: 'b', status: 'archived')],
          }),
          200,
        );
      });

      final sessions = await _api(inner: inner).listSessions();

      expect(seenMethod, 'GET');
      expect(seenUrl.toString(), 'http://x/sessions');
      expect(sessions.map((s) => s.id), ['a', 'b']);
      expect(sessions[1].status, 'archived');
    });
  });

  group('getSession', () {
    test('GETs /sessions/:id and parses SessionDetail', () async {
      Uri? seenUrl;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        return http.Response(
          jsonEncode({'session': _session(id: 's42'), 'messages': [], 'queue': []}),
          200,
        );
      });

      final detail = await _api(inner: inner).getSession('s42');

      expect(seenUrl.toString(), 'http://x/sessions/s42');
      expect(detail.session.id, 's42');
      expect(detail.queue, isEmpty);
    });
  });

  group('sendMessage', () {
    test('POSTs text to /sessions/:id/messages and parses TurnResult', () async {
      Uri? seenUrl;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'djMessage': _djMessage(), 'queue': [_track()], 'queueVersion': 2}),
          200,
        );
      });

      final result = await _api(inner: inner).sendMessage('s1', 'swap track 2');

      expect(seenUrl.toString(), 'http://x/sessions/s1/messages');
      expect(seenBody, {'text': 'swap track 2'});
      expect(result.djMessage.content, 'here you go');
      expect(result.queueVersion, 2);
    });

    test('409 conflict with message -> DjApiException(kind: conflict)', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'conflict', 'message': 'try that again'}),
            409,
          ));

      try {
        await _api(inner: inner).sendMessage('s1', 'anything');
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'conflict');
        expect(e.message, 'try that again');
      }
    });

    test('{error,message} 400 shape -> kind keeps the server\'s error code, message verbatim', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'too_long', 'message': 'keep it under 2000 characters'}),
            400,
          ));

      try {
        await _api(inner: inner).sendMessage('s1', 'x' * 2001);
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'too_long');
        expect(e.message, 'keep it under 2000 characters');
      }
    });

    test('a plain 404 (not_found) passes through as ApiException, not DjApiException', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'not_found'}), 404));

      await expectLater(
        _api(inner: inner).sendMessage('missing', 'anything'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('applyQueueOps', () {
    test('POSTs ops + expectedVersion to /sessions/:id/queue-ops and parses QueueOpsResult', () async {
      Uri? seenUrl;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'queueVersion': 3,
            'requested': 0,
            'added': 0,
            'removed': 1,
            'queue': [_track()],
          }),
          200,
        );
      });

      final result = await _api(inner: inner)
          .applyQueueOps('s1', [const QueueOp.remove(2), const QueueOp.move(0, 1)], 2);

      expect(seenUrl.toString(), 'http://x/sessions/s1/queue-ops');
      expect(seenBody, {
        'ops': [
          {'op': 'remove', 'position': 2},
          {'op': 'move', 'from': 0, 'to': 1},
        ],
        'expectedVersion': 2,
      });
      expect(result.queueVersion, 3);
      expect(result.removed, 1);
    });

    test('omits expectedVersion from the body when null', () async {
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'queueVersion': 1, 'requested': 0, 'added': 0, 'removed': 0, 'queue': []}),
          200,
        );
      });

      await _api(inner: inner).applyQueueOps('s1', [const QueueOp.remove(0)], null);

      expect(seenBody!.containsKey('expectedVersion'), isFalse);
    });

    test('409 stale -> StaleQueueException with fresh queue + version', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'error': 'stale',
              'queueVersion': 5,
              'queue': [_track(position: 0), _track(position: 1)],
            }),
            409,
          ));

      try {
        await _api(inner: inner).applyQueueOps('s1', [const QueueOp.remove(0)], 2);
        fail('expected StaleQueueException');
      } on StaleQueueException catch (e) {
        expect(e.queueVersion, 5);
        expect(e.queue, hasLength(2));
      }
    });

    test('400 dj_required (swap/extend attempted) -> DjApiException keeps kind dj_required '
        'with the hint message', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'dj_required', 'message': 'swap/extend require the DJ - send a message instead'}),
            400,
          ));

      try {
        await _api(inner: inner).applyQueueOps('s1', [const QueueOp.remove(0)], 2);
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'dj_required');
        expect(e.message, contains('send a message instead'));
      }
    });

    test('400 invalid_ops with no message -> DjApiException keeps kind invalid_ops, '
        'falls back to a generic message', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'invalid_ops'}), 400));

      try {
        await _api(inner: inner).applyQueueOps('s1', [const QueueOp.remove(0)], 2);
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'invalid_ops');
        expect(e.message, isNotEmpty);
      }
    });

    test('malformed (non-JSON) body never throws a secondary parse error', () async {
      final inner = MockClient((_) async => http.Response('not json at all', 400));

      try {
        await _api(inner: inner).applyQueueOps('s1', [const QueueOp.remove(0)], 2);
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'invalid');
        expect(e.message, isNotEmpty);
      }
    });
  });

  group('setStatus', () {
    test('PATCHes {status} to /sessions/:id and parses the returned session', () async {
      Uri? seenUrl;
      String? seenMethod;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        seenMethod = req.method;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'session': _session(status: 'archived')}), 200);
      });

      final session = await _api(inner: inner).setStatus('s1', 'archived');

      expect(seenMethod, 'PATCH');
      expect(seenUrl.toString(), 'http://x/sessions/s1');
      expect(seenBody, {'status': 'archived'});
      expect(session.status, 'archived');
    });
  });

  group('renameSession', () {
    test('PATCHes {title} to /sessions/:id and parses the returned session', () async {
      Uri? seenUrl;
      String? seenMethod;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        seenMethod = req.method;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'session': _session(title: 'Lagos Nights')}), 200);
      });

      final session = await _api(inner: inner).renameSession('s1', 'Lagos Nights');

      expect(seenMethod, 'PATCH');
      expect(seenUrl.toString(), 'http://x/sessions/s1');
      expect(seenBody, {'title': 'Lagos Nights'});
      expect(session.title, 'Lagos Nights');
    });

    test('400 invalid_title -> DjApiException(kind: invalid_title)', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'invalid_title', 'message': 'title cannot be empty'}),
            400,
          ));

      try {
        await _api(inner: inner).renameSession('s1', '   ');
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'invalid_title');
        expect(e.message, 'title cannot be empty');
      }
    });
  });

  group('malformed 200 response (typed exit)', () {
    test('non-JSON 200 body -> DjApiException(kind: malformed_response)', () async {
      final inner = MockClient((_) async => http.Response('not json at all', 200));

      try {
        await _api(inner: inner).listSessions();
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'malformed_response');
        expect(e.message, isNotEmpty);
      }
    });

    test('200 body missing a required key -> DjApiException(kind: malformed_response)', () async {
      // 'sessions' is the key listSessions() reads — a body that omits it
      // (e.g. server/client drift) must not surface as an uncaught
      // NoSuchMethodError/type-cast error.
      final inner = MockClient((_) async => http.Response(jsonEncode({'oops': true}), 200));

      try {
        await _api(inner: inner).listSessions();
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'malformed_response');
        expect(e.message, isNotEmpty);
      }
    });
  });

  group('DjApi.from', () {
    test('shares the base ApiClient\'s baseUrl and tokenStore, keeps its own 120s timeout', () async {
      final store = InMemoryTokenStore();
      await store.write('shared-tok');
      Uri? seenUrl;
      String? seenAuth;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        seenAuth = req.headers['Authorization'];
        return http.Response(jsonEncode({'sessions': []}), 200);
      });
      final base = ApiClient(baseUrl: 'http://shared', tokenStore: store, inner: inner);

      // inner isn't read off `base` (ApiClient doesn't expose it) — passed
      // again here so this test can observe what DjApi.from's derived
      // client actually sends, over the baseUrl/tokenStore it DID inherit.
      final dj = DjApi.from(base, inner: inner);
      await dj.listSessions();

      expect(seenUrl.toString(), 'http://shared/sessions');
      expect(seenAuth, 'Bearer shared-tok');
      expect(dj.timeout, const Duration(seconds: 120));
    });
  });

  group('timeout configuration', () {
    test('the default-constructed instance reports a 120s timeout', () {
      final dj = DjApi(baseUrl: 'http://x', tokenStore: InMemoryTokenStore());
      expect(dj.timeout, const Duration(seconds: 120));
    });

    test('a response within the configured DJ timeout does not throw', () async {
      final inner = MockClient((_) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response(jsonEncode({'sessions': []}), 200);
      });

      await expectLater(
        _api(inner: inner, timeout: const Duration(milliseconds: 500)).listSessions(),
        completes,
      );
    });

    test('a response slower than the configured DJ timeout still throws NetworkException '
        '(the 120s default is not silently unbounded)', () async {
      final inner = MockClient((_) async {
        await Future.delayed(const Duration(milliseconds: 500));
        return http.Response(jsonEncode({'sessions': []}), 200);
      });

      await expectLater(
        _api(inner: inner, timeout: const Duration(milliseconds: 200)).listSessions(),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('QueueOp', () {
    test('remove/move serialize to the 0-based wire shape', () {
      expect(const QueueOp.remove(3).toJson(), {'op': 'remove', 'position': 3});
      expect(const QueueOp.move(1, 4).toJson(), {'op': 'move', 'from': 1, 'to': 4});
    });
  });

  group('postSessionEvent', () {
    test('records the exact playlist ID against the originating mix', () async {
      final inner = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/playlists/creation-receipts');
        expect(jsonDecode(req.body), {'sessionId': 's1', 'appleLibraryId': 'p.created'});
        return http.Response('{"ok":true}', 200);
      });
      await _api(inner: inner).recordPlaylistCreation('s1', 'p.created');
    });
    test('POSTs {type} to /sessions/:id/events, resolves void on {ok:true}', () async {
      String? seenMethod;
      Uri? seenUrl;
      Map<String, dynamic>? seenBody;
      final inner = MockClient((req) async {
        seenMethod = req.method;
        seenUrl = req.url;
        seenBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      await _api(inner: inner).postSessionEvent('s1', 'played');

      expect(seenMethod, 'POST');
      expect(seenUrl.toString(), 'http://x/sessions/s1/events');
      expect(seenBody, {'type': 'played'});
    });

    test('a 404 (unknown session) passes through as ApiException, not DjApiException', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'not_found'}), 404));

      await expectLater(
        _api(inner: inner).postSessionEvent('missing', 'saved_playlist'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('a 400 (bad type) surfaces as DjApiException with the server\'s kind', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'invalid', 'message': 'unknown event type'}),
            400,
          ));

      try {
        await _api(inner: inner).postSessionEvent('s1', 'bogus');
        fail('expected DjApiException');
      } on DjApiException catch (e) {
        expect(e.kind, 'invalid');
        expect(e.message, 'unknown event type');
      }
    });

    test('an empty 200 body resolves (void) instead of throwing malformed_response', () async {
      final inner = MockClient((_) async => http.Response('', 200));

      // Must complete with no error at all — a void call has nothing this
      // class needs to read out of the body.
      await _api(inner: inner).postSessionEvent('s1', 'played');
    });

    test('a non-object 200 body (e.g. bare "true") also resolves as void', () async {
      final inner = MockClient((_) async => http.Response('true', 200));

      await _api(inner: inner).postSessionEvent('s1', 'played');
    });
  });

  group('listMemories', () {
    test('GETs /me/memories and parses newest-first DjMemory list', () async {
      Uri? seenUrl;
      final inner = MockClient((req) async {
        seenUrl = req.url;
        return http.Response(
          jsonEncode({
            'memories': [
              {'id': 'm2', 'note': 'always play Wizkid on party tapes', 'createdAt': '2026-08-30T10:00:00.000Z'},
              {'id': 'm1', 'note': 'no sad songs before noon', 'createdAt': '2026-08-29T09:00:00.000Z'},
            ],
          }),
          200,
        );
      });

      final memories = await _api(inner: inner).listMemories();

      expect(seenUrl.toString(), 'http://x/me/memories');
      expect(memories, hasLength(2));
      expect(memories[0].id, 'm2');
      expect(memories[0].note, 'always play Wizkid on party tapes');
      expect(memories[0].createdAt, DateTime.parse('2026-08-30T10:00:00.000Z'));
      expect(memories[1].id, 'm1');
    });

    test('an empty list parses to an empty list', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'memories': []}), 200));

      final memories = await _api(inner: inner).listMemories();

      expect(memories, isEmpty);
    });
  });

  group('deleteMemory', () {
    test('DELETEs /me/memories/:id, resolves void on {ok:true}', () async {
      String? seenMethod;
      Uri? seenUrl;
      final inner = MockClient((req) async {
        seenMethod = req.method;
        seenUrl = req.url;
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      await _api(inner: inner).deleteMemory('m1');

      expect(seenMethod, 'DELETE');
      expect(seenUrl.toString(), 'http://x/me/memories/m1');
    });

    test('a 404 (not_found, e.g. someone else\'s note) passes through as ApiException', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'not_found'}), 404));

      await expectLater(
        _api(inner: inner).deleteMemory('not-mine'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('an empty 200 body resolves (void) instead of throwing malformed_response', () async {
      final inner = MockClient((_) async => http.Response('', 200));

      await _api(inner: inner).deleteMemory('m1');
    });
  });

  group('album sessions', () {
    test('createSession sends kind only for album', () async {
      final bodies = <Map<String, dynamic>>[];
      final inner = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        if (body['kind'] == 'album') {
          return http.Response(
            jsonEncode({
              'session': {..._session(), 'kind': 'album'},
              'messages': [],
              'pick': _albumView(id: 'a'),
              'runnersUp': [_albumView(id: 'b')],
              'passed': [],
              'version': 1,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'session': _session(), 'messages': [], 'queue': []}), 200);
      });
      final api = _api(inner: inner);

      final mix = await api.createSession('rainy');
      final album = await api.createSession('a record for sunday', kind: SessionKind.album);

      expect(bodies[0], {'prompt': 'rainy'});
      expect(bodies[1], {'prompt': 'a record for sunday', 'kind': 'album'});
      expect(mix.kind, SessionKind.mix);
      expect(album.kind, SessionKind.album);
      expect(album.pickState!.pick!.id, 'a');
      expect(album.queue, isEmpty);
    });

    test('404 album_picks_off -> DjApiException(album_picks_off)', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'album_picks_off'}), 404));
      await expectLater(
        _api(inner: inner).createSession('x', kind: SessionKind.album),
        throwsA(isA<DjApiException>()
            .having((e) => e.kind, 'kind', 'album_picks_off')
            .having((e) => e.message, 'message', 'Album picks are not available right now.')),
      );
    });

    test('403 anonymous_albums -> DjApiException(anonymous_albums)', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'anonymous_albums'}), 403));
      await expectLater(
        _api(inner: inner).createSession('x', kind: SessionKind.album),
        throwsA(isA<DjApiException>().having((e) => e.kind, 'kind', 'anonymous_albums')),
      );
    });

    test('a 502 album error carries the step, the pick state and the session id', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'error': 'upstream',
              'message': 'The DJ lost the thread.',
              'step': 'verify',
              'pick': _albumView(id: 'a', version: 2),
              'runnersUp': [],
              'passed': [],
              'version': 2,
              'sessionId': 's9',
            }),
            502,
          ));
      await expectLater(
        _api(inner: inner).createSession('x', kind: SessionKind.album),
        throwsA(isA<DjApiException>()
            .having((e) => e.kind, 'kind', 'upstream')
            .having((e) => e.message, 'message', 'The DJ lost the thread.')
            .having((e) => e.step, 'step', 'verify')
            .having((e) => e.sessionId, 'sessionId', 's9')
            .having((e) => e.pickState?.version, 'pickState.version', 2)
            .having((e) => e.pickState?.pick?.id, 'pickState.pick', 'a')
            .having((e) => e.queue, 'queue', isNull)),
      );
    });

    test('an album error without a version carries no pick state', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({'error': 'conflict', 'message': 'Busy.'}),
            409,
          ));
      await expectLater(
        _api(inner: inner).sendMessage('s1', 'older'),
        throwsA(isA<DjApiException>()
            .having((e) => e.kind, 'kind', 'conflict')
            .having((e) => e.pickState, 'pickState', isNull)),
      );
    });

    test('an album turn parses version as the queue version', () async {
      final inner = MockClient((req) async {
        expect(req.url.path, '/sessions/s1/messages');
        return http.Response(
          jsonEncode({
            'djMessage': _djMessage(queueVersion: 4),
            'pick': _albumView(id: 'a', version: 4),
            'runnersUp': [],
            'passed': [_albumView(id: 'z', version: 3)],
            'version': 4,
          }),
          200,
        );
      });
      final result = await _api(inner: inner).sendMessage('s1', 'older');
      expect(result.queueVersion, 4);
      expect(result.queue, isEmpty);
      expect(result.pickState!.passed.single.id, 'z');
    });

    test('getSession for an album session parses with no queue', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'session': {..._session(), 'kind': 'album'},
              'messages': [],
              'pick': _albumView(id: 'a'),
              'runnersUp': [],
              'passed': [],
              'version': 1,
            }),
            200,
          ));
      final detail = await _api(inner: inner).getSession('s1');
      expect(detail.queue, isEmpty);
      expect(detail.pickState!.pick!.id, 'a');
    });

    test('listSessions parses kind and pick per row, defaulting to mix', () async {
      final inner = MockClient((_) async => http.Response(
            jsonEncode({
              'sessions': [
                {..._session(id: 'm'), 'trackCount': 3, 'durationMs': 1},
                {
                  ..._session(id: 'a'),
                  'kind': 'album',
                  'trackCount': 0,
                  'durationMs': 0,
                  'pick': {'title': 'Blue', 'artist': 'Joni Mitchell', 'artwork': null},
                },
              ],
            }),
            200,
          ));
      final sessions = await _api(inner: inner).listSessions();
      expect(sessions[0].kind, SessionKind.mix);
      expect(sessions[0].pick, isNull);
      expect(sessions[1].kind, SessionKind.album);
      expect(sessions[1].pick!.title, 'Blue');
    });
  });

  group('pick route', () {
    test('choosePick POSTs albumId and expectedVersion to /sessions/:id/pick', () async {
      final inner = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/sessions/s1/pick');
        expect(jsonDecode(req.body), {'albumId': 'b', 'expectedVersion': 2});
        return http.Response(
          jsonEncode({'pick': _albumView(id: 'b', version: 3), 'runnersUp': [], 'passed': [_albumView(id: 'a')], 'version': 3}),
          200,
        );
      });
      final state = await _api(inner: inner).choosePick('s1', albumId: 'b', expectedVersion: 2);
      expect(state.version, 3);
      expect(state.pick!.id, 'b');
      expect(state.passed.single.id, 'a');
    });

    test('goBackToPick POSTs version (and omits a null expectedVersion)', () async {
      final inner = MockClient((req) async {
        expect(req.url.path, '/sessions/s1/pick');
        expect(jsonDecode(req.body), {'version': 1});
        return http.Response(
          jsonEncode({'pick': _albumView(id: 'a', version: 4), 'runnersUp': [], 'passed': [], 'version': 4}),
          200,
        );
      });
      final state = await _api(inner: inner).goBackToPick('s1', version: 1);
      expect(state.version, 4);
    });

    test('409 stale with the album shape -> DjApiException(stale), never a parse error', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'stale', 'version': 5}), 409));
      await expectLater(
        _api(inner: inner).choosePick('s1', albumId: 'b', expectedVersion: 2),
        throwsA(isA<DjApiException>().having((e) => e.kind, 'kind', 'stale')),
      );
    });

    test('409 wrong_session_kind -> DjApiException keeping the kind', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'wrong_session_kind'}), 409));
      await expectLater(
        _api(inner: inner).goBackToPick('s1', version: 1),
        throwsA(isA<DjApiException>().having((e) => e.kind, 'kind', 'wrong_session_kind')),
      );
    });

    test('404 album_picks_off translates; a plain 404 stays ApiException', () async {
      final off = MockClient((_) async => http.Response(jsonEncode({'error': 'album_picks_off'}), 404));
      await expectLater(
        _api(inner: off).choosePick('s1', albumId: 'b'),
        throwsA(isA<DjApiException>().having((e) => e.kind, 'kind', 'album_picks_off')),
      );
      final missing = MockClient((_) async => http.Response(jsonEncode({'error': 'not_found'}), 404));
      await expectLater(
        _api(inner: missing).choosePick('s1', albumId: 'b'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('listen later', () {
    test('listListenLater GETs /me/listen-later in server order', () async {
      final inner = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/me/listen-later');
        return http.Response(jsonEncode({'entries': [_entry(id: 'a'), _entry(id: 'b', listenedAt: '2026-10-21T00:00:00.000Z')]}), 200);
      });
      final entries = await _api(inner: inner).listListenLater();
      expect(entries.map((e) => e.id), ['a', 'b']);
      expect(entries[1].listened, isTrue);
    });

    test('saveForLater PUTs the session id when given, an empty body otherwise', () async {
      final bodies = <Object?>[];
      final inner = MockClient((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/me/listen-later/al-1');
        bodies.add(jsonDecode(req.body));
        return http.Response(jsonEncode({'entry': _entry(id: 'al-1')}), 200);
      });
      final api = _api(inner: inner);
      final entry = await api.saveForLater('al-1', sessionId: 's1');
      await api.saveForLater('al-1');
      expect(entry.id, 'al-1');
      expect(bodies, [
        {'sessionId': 's1'},
        <String, dynamic>{},
      ]);
    });

    test('unsaveForLater DELETEs /me/listen-later/:albumId', () async {
      String? method;
      String? path;
      final inner = MockClient((req) async {
        method = req.method;
        path = req.url.path;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      await _api(inner: inner).unsaveForLater('al-1');
      expect(method, 'DELETE');
      expect(path, '/me/listen-later/al-1');
    });

    test('markListened POSTs /me/listen-later/:albumId/listened and parses the entry', () async {
      final inner = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/me/listen-later/al-1/listened');
        return http.Response(jsonEncode({'entry': _entry(id: 'al-1', listenedAt: '2026-10-21T00:00:00.000Z')}), 200);
      });
      final entry = await _api(inner: inner).markListened('al-1');
      expect(entry.listened, isTrue);
    });

    test('album_picks_off on the shelf translates too', () async {
      final inner = MockClient((_) async => http.Response(jsonEncode({'error': 'album_picks_off'}), 404));
      await expectLater(
        _api(inner: inner).listListenLater(),
        throwsA(isA<DjApiException>().having((e) => e.kind, 'kind', 'album_picks_off')),
      );
    });
  });
}

Map<String, dynamic> _albumView({String id = 'al-1', int version = 1}) => {
      'id': id,
      'upc': null,
      'appleId': 'apple-$id',
      'title': 'Album $id',
      'artist': 'Artist',
      'releaseYear': 2001,
      'type': 'album',
      'trackCount': 9,
      'durationMs': 2000000,
      'artwork': null,
      'newToThem': false,
      'reason': 'why $id',
      'savedForLater': false,
      'version': version,
    };

Map<String, dynamic> _entry({String id = 'al-1', String? listenedAt}) => {
      'id': id,
      'upc': null,
      'appleId': 'apple-$id',
      'title': 'Album $id',
      'artist': 'Artist',
      'releaseYear': 2001,
      'type': 'album',
      'trackCount': 9,
      'durationMs': 2000000,
      'artwork': null,
      'sessionId': null,
      'savedAt': '2026-10-20T00:00:00.000Z',
      'listenedAt': listenedAt,
      'reason': null,
    };
