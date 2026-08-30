import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';

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

Map<String, dynamic> _track({int position = 0, String? appleId = 'apple-1'}) => {
      'position': position,
      'trackId': 'track-$position',
      'appleId': appleId,
      'title': 'Song $position',
      'artist': 'Artist $position',
      'reason': 'fits the vibe',
      'durationMs': 200000,
    };

DjApi _api({required http.Client inner, Duration timeout = const Duration(seconds: 120)}) => DjApi(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: inner,
      timeout: timeout,
    );

void main() {
  group('createSession', () {
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
}
