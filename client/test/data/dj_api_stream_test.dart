import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';

// The streamed mix turn (spec 2026-11-13-dj-turn-steps-design.md, "Wire
// contract"): the progress calls ask for `text/event-stream` and still end
// in exactly today's results and exceptions.

const _jsonType = {'content-type': 'application/json'};

Map<String, dynamic> _track(int position) => {
  'position': position,
  'trackId': 'track-$position',
  'appleId': 'apple-$position',
  'title': 'Canción $position',
  'artist': 'Sigur Rós',
  'reason': 'fits the “night” vibe',
  'durationMs': 200000,
};

Map<String, dynamic> _sessionRow() => {
  'id': 's1',
  'title': 'Café – 夜 🎧',
  'status': 'active',
  'queueVersion': 1,
  'updatedAt': '2026-11-13T12:00:00.000Z',
};

Map<String, dynamic> _djMessage() => {
  'id': 'm1',
  'role': 'dj',
  'content': 'Here’s your night tape ✓',
  'queueVersion': 1,
  'createdAt': '2026-11-13T12:00:01.000Z',
};

/// A create-session success body with names that are not ASCII.
Map<String, dynamic> _createBody() => {
  'session': _sessionRow(),
  'messages': [_djMessage()],
  'queue': [_track(0), _track(1)],
  'sessionTitle': 'Café – 夜 🎧',
  'supportsInsert': true,
  'addMusic': 'history',
};

/// A message-turn success body.
Map<String, dynamic> _turnBody() => {
  'djMessage': _djMessage(),
  'queue': [_track(0), _track(1), _track(2)],
  'queueVersion': 2,
  'sessionTitle': 'Beyoncé at dawn',
  'addMusic': 'history',
};

List<Object?> _detailSummary(SessionDetail d) => [
  d.session.id,
  d.session.title,
  d.session.status,
  d.session.queueVersion,
  d.session.updatedAt,
  d.session.kind,
  for (final m in d.messages) [m.id, m.role, m.content, m.queueVersion],
  for (final t in d.queue)
    [t.position, t.trackId, t.appleId, t.title, t.artist, t.reason],
  d.sessionTitle,
  d.supportsInsert,
  d.addMusic,
  d.playlistSeed,
  d.pickState,
];

List<Object?> _turnSummary(TurnResult r) => [
  r.djMessage.id,
  r.djMessage.content,
  r.djMessage.queueVersion,
  for (final t in r.queue)
    [t.position, t.trackId, t.appleId, t.title, t.artist, t.reason],
  r.queueVersion,
  r.sessionTitle,
  r.addMusic,
  r.pickState,
];

/// What a caller can see of an exception, for comparing two of them.
List<Object?> _describe(Object e) => switch (e) {
  DjApiException() => [
    'DjApiException',
    e.kind,
    e.message,
    e.queue?.length,
    e.queueVersion,
    e.sessionId,
    e.step,
  ],
  ApiException() => ['ApiException', e.statusCode, jsonDecode(e.body)],
  AnonymousCapException() => ['AnonymousCapException', e.limit],
  _ => [e.runtimeType.toString()],
};

String _sse(String event, Object data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

http.StreamedResponse _streamed(
  Stream<List<int>> bytes, {
  int status = 200,
  String contentType = 'text/event-stream',
}) => http.StreamedResponse(
  bytes,
  status,
  headers: {'content-type': contentType, 'cache-control': 'no-cache'},
);

http.StreamedResponse _streamedText(String text) =>
    _streamed(Stream.value(utf8.encode(text)));

/// A server that answers every request with [answer], recording what it
/// was sent.
class _Server {
  _Server(this.answer);

  FutureOr<http.StreamedResponse> Function(http.BaseRequest request) answer;
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];

  late final client = MockClient.streaming((request, body) async {
    requests.add(request);
    bodies.add(await body.bytesToString());
    return answer(request);
  });
}

/// An answer in today's JSON shape, as a streamed response.
http.StreamedResponse _json(
  Object body,
  int status, {
  Map<String, String> headers = _jsonType,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: headers,
);

DjApi _api(
  http.Client inner, {
  Duration timeout = const Duration(seconds: 120),
  Duration idle = const Duration(seconds: 45),
  TokenStore? store,
  Future<void> Function(String token)? onUnauthorized,
}) => DjApi(
  baseUrl: 'http://x',
  tokenStore: store ?? InMemoryTokenStore(),
  inner: inner,
  timeout: timeout,
  streamIdleTimeout: idle,
  onUnauthorized: onUnauthorized,
);

/// The three streamed calls, run against [api] with [progress] collecting.
typedef _Call = Future<Object> Function(DjApi api, List<TurnProgress> progress);

final Map<String, _Call> _calls = {
  'create': (api, progress) =>
      api.createSessionWithProgress('night drive', onProgress: progress.add),
  'message': (api, progress) =>
      api.sendMessageWithProgress('s1', 'more', onProgress: progress.add),
  'remake': (api, progress) =>
      api.sendRemakeWithProgress('s1', onProgress: progress.add),
};

Future<Object> _caught(Future<Object> call) async {
  try {
    await call;
  } catch (e) {
    return e;
  }
  fail('expected the call to throw');
}

void main() {
  group('request', () {
    test(
      'without onProgress the request is today\'s: no Accept header',
      () async {
        final server = _Server((_) => _json(_createBody(), 200));
        final api = _api(server.client);

        await api.createSession('night drive');
        await api.createSessionWithProgress('night drive');
        server.answer = (_) => _json(_turnBody(), 200);
        await api.sendMessage('s1', 'more');
        await api.sendMessageWithProgress('s1', 'more');
        await api.sendRemake('s1');
        await api.sendRemakeWithProgress('s1');

        expect(server.requests, hasLength(6));
        for (final request in server.requests) {
          expect(request.headers.containsKey('accept'), isFalse);
        }
      },
    );

    test(
      'with onProgress, the same request asks for an event stream',
      () async {
        final store = InMemoryTokenStore();
        await store.write('tok');
        final server = _Server((_) => _json(_createBody(), 200));
        final api = _api(server.client, store: store);
        const seed = InitialPlaylistSeed(
          playlistId: 'p1',
          excludeSourceTracks: true,
        );

        await api.createSession('Night “drive”', playlistSeed: seed);
        await api.createSessionWithProgress(
          'Night “drive”',
          playlistSeed: seed,
          onProgress: (_) {},
        );
        server.answer = (_) => _json(_turnBody(), 200);
        await api.sendMessage('s1', 'más');
        await api.sendMessageWithProgress('s1', 'más', onProgress: (_) {});
        await api.sendRemake('s1');
        await api.sendRemakeWithProgress('s1', onProgress: (_) {});

        for (var i = 0; i < 6; i += 2) {
          final (plain, streamed) = (
            server.requests[i],
            server.requests[i + 1],
          );
          expect(streamed.method, 'POST');
          expect(streamed.url, plain.url);
          expect(streamed.headers['accept'], 'text/event-stream');
          expect(
            streamed.headers['content-type'],
            plain.headers['content-type'],
          );
          expect(streamed.headers['authorization'], 'Bearer tok');
          // Dart's default User-Agent is left alone (the server reads it).
          expect(streamed.headers.containsKey('user-agent'), isFalse);
          expect(server.bodies[i + 1], server.bodies[i]);
        }
        expect(server.requests[1].url.toString(), 'http://x/sessions');
        expect(jsonDecode(server.bodies[5]), {
          'text': remakeText,
          'remake': true,
        });
      },
    );

    test('an album create never asks for a stream', () async {
      final server = _Server(
        (_) => _json({
          ..._createBody(),
          'session': {..._sessionRow(), 'kind': 'album'},
        }, 200),
      );
      final progress = <TurnProgress>[];

      await _api(server.client).createSessionWithProgress(
        'a record for rain',
        kind: SessionKind.album,
        onProgress: progress.add,
      );

      expect(server.requests.single.headers.containsKey('accept'), isFalse);
      expect(jsonDecode(server.bodies.single)['kind'], 'album');
      expect(progress, isEmpty);
    });
  });

  group('streamed result', () {
    test('create: session and steps arrive as progress; the result parses '
        'exactly as the JSON answer of the same body', () async {
      final jsonDetail = await _api(
        MockClient(
          (_) async =>
              http.Response(jsonEncode(_createBody()), 200, headers: _jsonType),
        ),
      ).createSession('night drive');

      final server = _Server(
        (_) => _streamedText(
          [
            ': keepalive\n\n',
            _sse('session', {'session': _sessionRow()}),
            _sse('step', {
              'step': 'digging',
              'scope': 'catalogue',
              'artists': ['Tems', 'Asake'],
            }),
            _sse('step', {'step': 'pressing', 'count': 2}),
            _sse('step', {'step': 'labelling', 'title': 'Café – 夜 🎧'}),
            'event: result\ndata: ${jsonEncode(_createBody())}\n\n',
          ].join(),
        ),
      );
      final progress = <TurnProgress>[];
      final detail = await _api(
        server.client,
      ).createSessionWithProgress('night drive', onProgress: progress.add);

      expect(progress, [
        const TurnStreamOpened(),
        const TurnSessionStarted('s1'),
        const TurnStep(
          'digging',
          scope: 'catalogue',
          artists: ['Tems', 'Asake'],
        ),
        const TurnStep('pressing', count: 2),
        const TurnStep('labelling', title: 'Café – 夜 🎧'),
      ]);
      expect(_detailSummary(detail), _detailSummary(jsonDetail));
    });

    test('message and remake: the result parses exactly as the JSON answer '
        'of the same body', () async {
      final jsonResult = await _api(
        MockClient(
          (_) async =>
              http.Response(jsonEncode(_turnBody()), 200, headers: _jsonType),
        ),
      ).sendMessage('s1', 'more');

      final server = _Server(
        (_) => _streamed(
          Stream.value(
            utf8.encode(
              '${_sse('step', {'step': 'editing'})}'
              'event: result\ndata: ${jsonEncode(_turnBody())}\n\n',
            ),
          ),
          contentType: 'text/event-stream; charset=utf-8',
        ),
      );
      for (final call in [_calls['message']!, _calls['remake']!]) {
        final progress = <TurnProgress>[];
        final result = await call(_api(server.client), progress) as TurnResult;
        expect(progress, [const TurnStreamOpened(), const TurnStep('editing')]);
        expect(_turnSummary(result), _turnSummary(jsonResult));
      }
    });

    test('a stream in one-byte chunks parses the same', () async {
      final text = [
        _sse('session', {'session': _sessionRow()}),
        _sse('step', {
          'step': 'picking',
          'artists': ['Beyoncé'],
        }),
        'event: result\ndata: ${jsonEncode(_createBody())}\n\n',
      ].join();
      final server = _Server(
        (_) => _streamed(
          Stream.fromIterable([
            for (final b in utf8.encode(text)) [b],
          ]),
        ),
      );
      final progress = <TurnProgress>[];

      final detail = await _api(
        server.client,
      ).createSessionWithProgress('night drive', onProgress: progress.add);

      expect(progress.last, const TurnStep('picking', artists: ['Beyoncé']));
      expect(detail.session.title, 'Café – 夜 🎧');
      expect(detail.messages.single.content, 'Here’s your night tape ✓');
    });

    test('keepalives hold the stream open past the total timeout', () async {
      final server = _Server(
        (_) => _streamed(() async* {
          for (var i = 0; i < 8; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            yield utf8.encode(': keepalive\n\n');
          }
          yield utf8.encode(
            'event: result\ndata: ${jsonEncode(_turnBody())}\n\n',
          );
        }()),
      );

      final result = await _api(
        server.client,
        timeout: const Duration(milliseconds: 100),
        idle: const Duration(milliseconds: 150),
      ).sendMessageWithProgress('s1', 'more', onProgress: (_) {});

      expect(result.queueVersion, 2);
    });

    test('a result that does not parse is a malformed response', () async {
      final server = _Server(
        (_) => _streamedText('event: result\ndata: {"djMessage":null}\n\n'),
      );
      await expectLater(
        _api(
          server.client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
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

  group('streamed error', () {
    final errors = <String, (int, Object)>{
      '409 conflict': (409, {'error': 'conflict', 'message': 'try that again'}),
      '409 without a message': (409, {'error': 'wrong_session_kind'}),
      '502 curation, with a queue and the session id': (
        502,
        {
          'error': 'curation',
          'message': 'the DJ is taking a breather',
          'queue': [_track(0)],
          'queueVersion': 3,
          'sessionId': 'orphan-session',
        },
      ),
      '400 with a message': (
        400,
        {'error': 'too_long', 'message': 'keep it under 2000 characters'},
      ),
      '400 zod shape': (
        400,
        {
          'success': false,
          'error': {'name': 'ZodError', 'message': '[{"code":"too_small"}]'},
        },
      ),
      '500 internal': (500, {'error': 'internal'}),
    };

    for (final MapEntry(key: name, value: (status, body)) in errors.entries) {
      for (final MapEntry(key: callName, value: call) in _calls.entries) {
        test(
          '$name ($callName): the same exception as today\'s status',
          () async {
            final today = await _caught(
              call(_api(_Server((_) => _json(body, status)).client), []),
            );
            final progress = <TurnProgress>[];
            final streamed = await _caught(
              call(
                _api(
                  _Server(
                    (_) => _streamedText(
                      _sse('step', {'step': 'picking'}) +
                          _sse('error', {'status': status, 'body': body}),
                    ),
                  ).client,
                ),
                progress,
              ),
            );

            expect(_describe(streamed), _describe(today));
            expect(progress, [
              const TurnStreamOpened(),
              const TurnStep('picking'),
            ]);
          },
        );
      }
    }

    test('an error event without a status is a malformed response', () async {
      final server = _Server(
        (_) => _streamedText(
          _sse('error', {
            'body': {'error': 'internal'},
          }),
        ),
      );
      await expectLater(
        _api(
          server.client,
        ).createSessionWithProgress('night drive', onProgress: (_) {}),
        throwsA(
          isA<DjApiException>().having(
            (e) => e.kind,
            'kind',
            'malformed_response',
          ),
        ),
      );
    });

    test('an in-band 401 reports the expired session, as a 401 status '
        'does; other in-band errors do not', () async {
      final store = InMemoryTokenStore();
      await store.write('tok');
      final expired = <String>[];
      DjApi api(int status) => _api(
        _Server(
          (_) => _streamedText(
            _sse('error', {
              'status': status,
              'body': {'error': 'nope', 'message': 'No.'},
            }),
          ),
        ).client,
        store: store,
        onUnauthorized: (token) async => expired.add(token),
      );

      await expectLater(
        api(409).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<DjApiException>()),
      );
      expect(expired, isEmpty);

      await expectLater(
        api(401).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(expired, ['tok']);
    });
  });

  group('JSON answers to a stream request', () {
    test('an older server\'s JSON parses as today, with no progress', () async {
      final progress = <TurnProgress>[];
      final detail = await _api(
        _Server((_) => _json(_createBody(), 200)).client,
      ).createSessionWithProgress('night drive', onProgress: progress.add);
      final result = await _api(
        _Server((_) => _json(_turnBody(), 200)).client,
      ).sendMessageWithProgress('s1', 'more', onProgress: progress.add);

      expect(detail.session.title, 'Café – 夜 🎧');
      expect(result.queueVersion, 2);
      expect(progress, isEmpty);
    });

    test('refusals before the turn map as today, with no progress', () async {
      final refusals = <(int, Object), Matcher>{
        (403, {'error': 'anonymous_cap', 'limit': 5}):
            isA<AnonymousCapException>().having((e) => e.limit, 'limit', 5),
        (403, {'error': 'ai_consent_required'}):
            isA<AiConsentRequiredException>(),
        (404, {'error': 'not_found'}): isA<ApiException>().having(
          (e) => e.statusCode,
          'statusCode',
          404,
        ),
        (
          400,
          {'error': 'playlist_not_ready', 'message': 'Not yet.'},
        ): isA<DjApiException>().having(
          (e) => e.kind,
          'kind',
          'playlist_not_ready',
        ),
      };
      for (final MapEntry(key: (status, body), value: matcher)
          in refusals.entries) {
        final progress = <TurnProgress>[];
        await expectLater(
          _api(
            _Server((_) => _json(body, status)).client,
          ).createSessionWithProgress('night drive', onProgress: progress.add),
          throwsA(matcher),
          reason: '$status $body',
        );
        expect(progress, isEmpty);
      }
    });

    test('a 401 still reports the expired session', () async {
      final store = InMemoryTokenStore();
      await store.write('tok');
      final expired = <String>[];
      await expectLater(
        _api(
          _Server((_) => _json({'error': 'unauthorized'}, 401)).client,
          store: store,
          onUnauthorized: (token) async => expired.add(token),
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(expired, ['tok']);
    });

    test('a failed status typed text/event-stream (an edge 500) is read '
        'whole and maps as today', () async {
      final progress = <TurnProgress>[];
      await expectLater(
        _api(
          _Server(
            (_) => _streamed(
              Stream.value(utf8.encode('upstream fell over')),
              status: 500,
            ),
          ).client,
        ).sendMessageWithProgress('s1', 'more', onProgress: progress.add),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.body, 'body', 'upstream fell over'),
        ),
      );
      expect(progress, isEmpty);
    });
  });

  group('dropped streams', () {
    test(
      'a stream that ends before its result is a NetworkException',
      () async {
        final progress = <TurnProgress>[];
        await expectLater(
          _api(
            _Server(
              (_) => _streamedText(_sse('step', {'step': 'digging'})),
            ).client,
          ).sendMessageWithProgress('s1', 'more', onProgress: progress.add),
          throwsA(isA<NetworkException>()),
        );
        expect(progress, [const TurnStreamOpened(), const TurnStep('digging')]);
      },
    );

    test('a stream cut off inside its result is a NetworkException', () async {
      final whole = 'event: result\ndata: ${jsonEncode(_turnBody())}\n\n';
      await expectLater(
        _api(
          _Server(
            (_) => _streamedText(whole.substring(0, whole.length - 30)),
          ).client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<NetworkException>()),
      );
    });

    test('a stream that goes quiet fails after the idle timeout and lets go '
        'of the connection', () async {
      final body = StreamController<List<int>>();
      final watch = Stopwatch()..start();

      await expectLater(
        _api(
          _Server((_) => _streamed(body.stream)).client,
          idle: const Duration(milliseconds: 50),
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await pumpEventQueue();
      expect(body.hasListener, isFalse);
      await body.close();
    });

    test('headers that never come keep today\'s total timeout', () async {
      final server = _Server((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _streamedText('event: result\ndata: {}\n\n');
      });
      await expectLater(
        _api(
          server.client,
          timeout: const Duration(milliseconds: 100),
        ).createSessionWithProgress('night drive', onProgress: (_) {}),
        throwsA(isA<NetworkException>()),
      );
    });

    test('a transport error mid-stream is a NetworkException', () async {
      for (final error in <Object>[
        http.ClientException('Connection reset by peer'),
        const SocketException('Broken pipe'),
        StateError('anything else the body throws'),
      ]) {
        final body = StreamController<List<int>>();
        final call = _api(
          _Server((_) => _streamed(body.stream)).client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {});
        body.add(utf8.encode(_sse('step', {'step': 'digging'})));
        body.addError(error);

        await expectLater(
          call,
          throwsA(
            isA<NetworkException>().having((e) => e.cause, 'cause', error),
          ),
        );
        await body.close();
      }
    });

    for (final (name, end) in [
      ('result', 'event: result\ndata: ${jsonEncode(_turnBody())}\n\n'),
      (
        'error',
        _sse('error', {
          'status': 409,
          'body': {'error': 'conflict', 'message': 'try that again'},
        }),
      ),
    ]) {
      test('the body is let go of at the $name, without waiting for the '
          'server to close it', () async {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        final call = _api(
          _Server((_) => _streamed(body.stream)).client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {});
        body.add(utf8.encode('${_sse('step', {'step': 'picking'})}$end'));

        await call.then((_) {}, onError: (Object _) {});
        await pumpEventQueue();
        expect(cancelled, isTrue);
        expect(body.hasListener, isFalse);
        await body.close();
      });
    }

    test('an answer that comes after the header wait timed out is aborted '
        'and let go of', () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () => cancelled.complete(),
      );
      http.BaseRequest? sent;
      final server = _Server((request) async {
        sent = request;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return _streamed(body.stream);
      });

      await expectLater(
        _api(
          server.client,
          timeout: const Duration(milliseconds: 50),
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<NetworkException>()),
      );

      // A real client tears the request down on the abort trigger...
      expect(sent, isA<http.Abortable>());
      await expectLater((sent! as http.Abortable).abortTrigger, completes);
      // ...and one that ignores it still has its late answer let go of.
      await cancelled.future.timeout(const Duration(seconds: 2));
      expect(body.hasListener, isFalse);
      await body.close();
    });

    group('fake time', () {
      const idle = Duration(seconds: 45);
      final result = 'event: result\ndata: ${jsonEncode(_turnBody())}\n\n';

      /// A body whose cancel completes in fake time. Without an onCancel, a
      /// controller's cancel() is a completed future of the root zone, so
      /// an `await for` that ends early would wait on a real microtask that
      /// fake time never runs.
      StreamController<List<int>> fakeTimeBody() =>
          StreamController<List<int>>(onCancel: () => Future<void>.value());

      /// Starts a streamed turn over [body] and lets it reach the stream
      /// (request sent, body listened to, idle timer armed).
      Future<List<Object>> start(
        WidgetTester tester,
        StreamController<List<int>> body,
      ) async {
        final outcome = <Object>[];
        _api(_Server((_) => _streamed(body.stream)).client, idle: idle)
            .sendMessageWithProgress('s1', 'more', onProgress: (_) {})
            .then(outcome.add, onError: outcome.add);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(body.hasListener, isTrue);
        return outcome;
      }

      testWidgets('bytes that arrive in the tick the idle timer fires (an '
          'app resumed after a long suspension) do not fail the turn', (
        tester,
      ) async {
        final body = fakeTimeBody();
        final outcome = await start(tester, body);

        // Armed after the idle timer, due at the same moment: on resume the
        // overdue timer fires first, then the bytes already on the socket.
        Timer(idle, () => body.add(utf8.encode(result)));
        await tester.pump(idle);
        await tester.pump();

        expect(outcome.single, isA<TurnResult>());
        // Not awaited: closing a cancelled controller also answers with a
        // root-zone future.
        unawaited(body.close());
      });

      testWidgets('with nothing arriving, the idle timeout still fails the '
          'turn', (tester) async {
        final body = fakeTimeBody();
        final outcome = await start(tester, body);

        await tester.pump(idle);
        await tester.pump();

        expect(outcome.single, isA<NetworkException>());
        unawaited(body.close());
      });
    });
  });

  test('a throwing onProgress never breaks the turn', () async {
    var calls = 0;
    final detail =
        await _api(
          _Server(
            (_) => _streamedText(
              [
                _sse('session', {'session': _sessionRow()}),
                _sse('step', {'step': 'digging'}),
                'event: result\ndata: ${jsonEncode(_createBody())}\n\n',
              ].join(),
            ),
          ).client,
        ).createSessionWithProgress(
          'night drive',
          onProgress: (_) {
            calls++;
            throw StateError('a caption bug');
          },
        );

    expect(calls, 3);
    expect(detail.session.id, 's1');
  });

  group('stand-ins', () {
    test('a DjTurnProgressSender answers the progress calls itself', () async {
      final DjApi api = _ProgressFake();
      final progress = <TurnProgress>[];

      await api.createSessionWithProgress(
        'night drive',
        kind: SessionKind.mix,
        onProgress: progress.add,
      );
      await api.sendMessageWithProgress('s1', 'more', onProgress: progress.add);
      await api.sendRemakeWithProgress('s1', onProgress: progress.add);

      expect((api as _ProgressFake).calls, [
        'create night drive',
        'message s1 more',
        'remake s1',
      ]);
      expect(progress, hasLength(3));
    });

    test('any other stand-in answers through its plain calls, without '
        'progress', () async {
      final DjApi api = _PlainFake();
      final progress = <TurnProgress>[];

      await api.createSessionWithProgress(
        'night drive',
        onProgress: progress.add,
      );
      await api.sendMessageWithProgress('s1', 'more', onProgress: progress.add);
      await api.sendRemakeWithProgress('s1', onProgress: progress.add);

      expect((api as _PlainFake).calls, [
        'create night drive',
        'message s1 more',
        'remake s1',
      ]);
      expect(progress, isEmpty);
    });
  });
}

class _ProgressFake implements DjApi, DjTurnProgressSender {
  final calls = <String>[];

  @override
  Future<SessionDetail> createSessionWithProgress(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  }) async {
    calls.add('create $prompt');
    onProgress?.call(const TurnStep('digging'));
    return SessionDetail.fromJson(_createBody());
  }

  @override
  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) async {
    calls.add('message $id $text');
    onProgress?.call(const TurnStep('editing'));
    return TurnResult.fromJson(_turnBody());
  }

  @override
  Future<TurnResult> sendRemakeWithProgress(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  }) async {
    calls.add('remake $id');
    onProgress?.call(const TurnStep('picking'));
    return TurnResult.fromJson(_turnBody());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlainFake implements DjApi, DjRemakeSender {
  final calls = <String>[];

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) async {
    calls.add('create $prompt');
    return SessionDetail.fromJson(_createBody());
  }

  @override
  Future<TurnResult> sendMessage(String id, String text) async {
    calls.add('message $id $text');
    return TurnResult.fromJson(_turnBody());
  }

  @override
  Future<TurnResult> sendRemake(String id) async {
    calls.add('remake $id');
    return TurnResult.fromJson(_turnBody());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
