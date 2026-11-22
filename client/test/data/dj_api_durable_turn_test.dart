import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/dj/turn_stream.dart';

// Durable mix turns (spec 2026-11-21 durable-mix-turns): the `turn` event,
// the Idempotency-Key and its one retry, attach, seen, and the session
// reads' `turn` field.

const _turnId = '0b6f3c1e-5d1a-4c2b-9f00-2a7e4d9c1b11';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, dynamic> _sessionRow({Object? turn}) => {
  'id': 's1',
  'title': 'Night drive',
  'status': 'active',
  'queueVersion': 1,
  'updatedAt': '2026-11-22T12:00:00.000Z',
  'turn': ?turn,
};

Map<String, dynamic> _djMessage() => {
  'id': 'm1',
  'role': 'dj',
  'content': 'Here you go',
  'queueVersion': 1,
  'createdAt': '2026-11-22T12:00:01.000Z',
};

Map<String, dynamic> _turnBody() => {
  'djMessage': _djMessage(),
  'queue': <Object>[],
  'queueVersion': 2,
};

Map<String, dynamic> _createBody() => {
  'session': _sessionRow(),
  'messages': [_djMessage()],
  'queue': <Object>[],
};

String _sse(String event, Object data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

http.StreamedResponse _streamedText(String text) => http.StreamedResponse(
  Stream.value(utf8.encode(text)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

http.StreamedResponse _json(Object body, int status) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json'},
);

http.StreamedResponse _noContent() =>
    http.StreamedResponse(const Stream.empty(), 204);

class _Server {
  _Server(this.answer);

  FutureOr<http.StreamedResponse> Function(http.BaseRequest request, int n)
  answer;
  final requests = <http.BaseRequest>[];

  late final client = MockClient.streaming((request, body) async {
    await body.drain<void>();
    requests.add(request);
    return answer(request, requests.length);
  });
}

DjApi _api(http.Client inner) =>
    DjApi(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

Future<List<TurnProgress>> _read(String text) async {
  final progress = <TurnProgress>[];
  await readTurnStream(Stream.value(utf8.encode(text)), progress.add);
  return progress;
}

void main() {
  group('the turn event', () {
    test('parses into TurnStarted, after session on a create', () async {
      expect(
        await _read(
          [
            _sse('session', {'session': _sessionRow()}),
            _sse('turn', {'turnId': _turnId, 'push': true}),
            _sse('step', {'step': 'digging'}),
            _sse('result', _createBody()),
          ].join(),
        ),
        [
          const TurnSessionStarted('s1'),
          const TurnStarted(_turnId, push: true),
          const TurnStep('digging'),
        ],
      );
    });

    test('a missing or mistyped push reads as false; one without a turn id '
        'and unknown events are skipped', () async {
      expect(
        await _read(
          [
            _sse('turn', {'turnId': _turnId}),
            _sse('turn', {'turnId': _turnId, 'push': 'yes'}),
            _sse('turn', {'push': true}),
            'event: turn\ndata: not json\n\n',
            _sse('weather', {'turnId': _turnId}),
            _sse('step', {'step': 'picking'}),
            _sse('result', _turnBody()),
          ].join(),
        ),
        [
          const TurnStarted(_turnId),
          const TurnStarted(_turnId),
          const TurnStep('picking'),
        ],
      );
    });

    test('reaches onProgress through a streamed message turn', () async {
      final progress = <TurnProgress>[];
      final result = await _api(
        _Server(
          (_, _) => _streamedText(
            [
              _sse('turn', {'turnId': _turnId, 'push': false}),
              _sse('result', _turnBody()),
            ].join(),
          ),
        ).client,
      ).sendMessageWithProgress('s1', 'more', onProgress: progress.add);

      expect(result.queueVersion, 2);
      expect(progress, [const TurnStreamOpened(), const TurnStarted(_turnId)]);
    });
  });

  group('Idempotency-Key', () {
    final calls = <String, Future<Object> Function(DjApi api)>{
      'create': (api) =>
          api.createSessionWithProgress('night drive', onProgress: (_) {}),
      'message': (api) =>
          api.sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
      'remake': (api) => api.sendRemakeWithProgress('s1', onProgress: (_) {}),
    };

    for (final MapEntry(key: name, value: call) in calls.entries) {
      test('$name: a fresh UUID v4 per turn', () async {
        final server = _Server(
          (_, _) => _json(name == 'create' ? _createBody() : _turnBody(), 200),
        );
        final api = _api(server.client);

        await call(api);
        await call(api);

        final keys = [
          for (final r in server.requests) r.headers['Idempotency-Key'],
        ];
        expect(keys, everyElement(matches(_uuidV4)));
        expect(keys[0], isNot(keys[1]));
      });

      test('$name: once the server has shown a turn event, a drop before '
          'the stream opened retries once with the same key', () async {
        final server = _Server((_, n) {
          if (n == 2) throw http.ClientException('Connection reset by peer');
          return _streamedText(
            [
              _sse('turn', {'turnId': _turnId, 'push': false}),
              _sse('result', name == 'create' ? _createBody() : _turnBody()),
            ].join(),
          );
        });
        final api = _api(server.client);

        await call(api); // proves the server honours keys
        await call(api); // drops once, then retries

        expect(server.requests, hasLength(3));
        final key = server.requests[1].headers['Idempotency-Key'];
        expect(key, matches(_uuidV4));
        expect(key, isNot(server.requests[0].headers['Idempotency-Key']));
        expect(server.requests[2].headers['Idempotency-Key'], key);
        expect(server.requests[2].url, server.requests[1].url);
      });

      test('$name: a server that never sent a turn event gets no retry (it '
          'may ignore the key and make a second mix)', () async {
        final server = _Server(
          (_, _) => throw http.ClientException('Connection reset by peer'),
        );
        await expectLater(
          call(_api(server.client)),
          throwsA(isA<NetworkException>()),
        );
        expect(server.requests, hasLength(1));
      });
    }

    test('the retry is once: a second drop is the NetworkException', () async {
      final server = _Server((_, n) {
        if (n == 1) {
          return _streamedText(
            [
              _sse('turn', {'turnId': _turnId, 'push': false}),
              _sse('result', _turnBody()),
            ].join(),
          );
        }
        throw http.ClientException('Connection reset by peer');
      });
      final api = _api(server.client);
      await api.sendMessageWithProgress('s1', 'more', onProgress: (_) {});
      await expectLater(
        api.sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<NetworkException>()),
      );
      expect(server.requests, hasLength(3));
    });

    test('a drop after the stream opened is not retried', () async {
      final server = _Server(
        (_, _) => _streamedText(_sse('step', {'step': 'digging'})),
      );
      await expectLater(
        _api(
          server.client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<NetworkException>()),
      );
      expect(server.requests, hasLength(1));
    });

    test('a refusal is not retried', () async {
      final server = _Server(
        (_, _) => _json({'error': 'invalid_idempotency_key'}, 400),
      );
      await expectLater(
        _api(
          server.client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(isA<Exception>()),
      );
      expect(server.requests, hasLength(1));
    });

    test('an album create and the plain JSON calls send none', () async {
      final server = _Server((_, _) => _json(_createBody(), 200));
      final api = _api(server.client);
      await api.createSessionWithProgress(
        'records',
        kind: SessionKind.album,
        onProgress: (_) {},
      );
      await api.createSession('night drive');
      for (final r in server.requests) {
        expect(r.headers.containsKey('Idempotency-Key'), isFalse);
      }
    });

    test('a 204 (a replay whose answer is gone) is TurnAnswerGoneException, '
        'a NetworkException', () async {
      await expectLater(
        _api(
          _Server((_, _) => _noContent()).client,
        ).sendMessageWithProgress('s1', 'more', onProgress: (_) {}),
        throwsA(
          isA<TurnAnswerGoneException>().having(
            (e) => e,
            'a NetworkException',
            isA<NetworkException>(),
          ),
        ),
      );
    });
  });

  group('attachTurn', () {
    test('GETs the turn stream and resumes its step', () async {
      final server = _Server(
        (_, _) => _streamedText(
          [
            _sse('turn', {'turnId': _turnId, 'push': true}),
            _sse('step', {'step': 'picking'}),
            _sse('step', {'step': 'checking'}),
            _sse('result', _turnBody()),
          ].join(),
        ),
      );
      final progress = <TurnProgress>[];

      final end = await _api(
        server.client,
      ).attachTurn('s1', onProgress: progress.add);

      expect(end, TurnAttachEnd.result);
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'http://x/sessions/s1/turn/stream');
      expect(request.headers['accept'], 'text/event-stream');
      expect(progress, [
        const TurnStreamOpened(),
        const TurnStarted(_turnId, push: true),
        const TurnStep('picking'),
        const TurnStep('checking'),
      ]);
    });

    test('204 means nothing is running', () async {
      final progress = <TurnProgress>[];
      final end = await _api(
        _Server((_, _) => _noContent()).client,
      ).attachTurn('s1', onProgress: progress.add);
      expect(end, TurnAttachEnd.notRunning);
      expect(progress, isEmpty);
    });

    test('an error event ends it as error', () async {
      final end = await _api(
        _Server(
          (_, _) => _streamedText(
            _sse('error', {
              'status': 502,
              'body': {'error': 'upstream', 'message': 'try again'},
            }),
          ),
        ).client,
      ).attachTurn('s1');
      expect(end, TurnAttachEnd.error);
    });

    test('a stream that drops is a NetworkException', () async {
      await expectLater(
        _api(
          _Server((_, _) => _streamedText(_sse('step', {'step': 'x'}))).client,
        ).attachTurn('s1'),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  test('markTurnSeen POSTs seen', () async {
    final server = _Server((_, _) => _noContent());
    await _api(server.client).markTurnSeen('s1', _turnId);
    final request = server.requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'http://x/sessions/s1/turn/$_turnId/seen');
  });

  group('DjSession.turn', () {
    test('parsed from the list and the detail; absent is null', () async {
      final turn = {'id': _turnId, 'status': 'running', 'step': 'picking'};
      final server = _Server((request, _) {
        if (request.url.path == '/sessions') {
          return _json({
            'sessions': [
              _sessionRow(turn: turn),
              {..._sessionRow(), 'id': 's2'},
            ],
          }, 200);
        }
        return _json({
          'session': _sessionRow(
            turn: {'id': _turnId, 'status': 'queued', 'step': null},
          ),
          'messages': <Object>[],
          'queue': <Object>[],
        }, 200);
      });
      final api = _api(server.client);

      final list = await api.listSessions();
      expect(
        list[0].turn,
        const DjSessionTurn(id: _turnId, status: 'running', step: 'picking'),
      );
      expect(list[0].turn!.live, isTrue);
      expect(list[1].turn, isNull);

      final detail = await api.getSession('s1');
      expect(
        detail.session.turn,
        const DjSessionTurn(id: _turnId, status: 'queued'),
      );
    });

    test('a malformed field reads as none', () {
      for (final bad in <Object>[
        'running',
        3,
        <String, Object>{'id': 1},
      ]) {
        expect(DjSession.fromJson(_sessionRow(turn: bad)).turn, isNull);
      }
    });
  });
}
