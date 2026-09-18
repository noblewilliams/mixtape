// `POST /transcribe`: the clip goes up as multipart `audio` under the session
// token, and every error code the route can answer with lands on exactly one
// failure the composer knows how to phrase.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/voice/transcription_api.dart';

/// Captures the multipart request instead of sending it.
class _FakeUploader extends http.BaseClient {
  _FakeUploader(this._respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request,
      List<int> body) _respond;

  http.BaseRequest? request;
  String? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    final bytes = await request.finalize().toBytes();
    body = latin1.decode(bytes);
    return _respond(request, bytes);
  }
}

http.StreamedResponse _response(int status, String body) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status);

void main() {
  late Directory temp;
  late File clip;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mixtape-transcribe-test');
    clip = File('${temp.path}/clip.m4a')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<TranscriptionApi> apiWith(_FakeUploader uploader,
      {String? token = 'session-token'}) async {
    final store = InMemoryTokenStore();
    if (token != null) await store.write(token);
    return TranscriptionApi(
      ApiClient(baseUrl: 'https://api.example.test', tokenStore: store),
      uploader: uploader,
    );
  }

  test('the clip goes up as multipart audio, bearing the session token', () async {
    final uploader =
        _FakeUploader((_, __) async => _response(200, '{"text":"a lift","language":"en"}'));
    final api = await apiWith(uploader);

    expect(await api.transcribe(clip), 'a lift');

    expect(uploader.request!.method, 'POST');
    expect(uploader.request!.url.toString(), 'https://api.example.test/transcribe');
    expect(uploader.request!.headers['Authorization'], 'Bearer session-token');
    expect(uploader.request!.headers['content-type'], startsWith('multipart/form-data'));
    expect(uploader.body, contains('name="audio"'));
    expect(uploader.body, contains('filename="clip.m4a"'));
  });

  test('the transcript comes back trimmed; a blank one is an upstream failure', () async {
    var api = await apiWith(
      _FakeUploader((_, __) async => _response(200, '{"text":"  two ideas  "}')),
    );
    expect(await api.transcribe(clip), 'two ideas');

    for (final body in const ['{"text":"   "}', '{"language":"en"}', 'not json']) {
      api = await apiWith(_FakeUploader((_, __) async => _response(200, body)));
      await expectLater(
        api.transcribe(clip),
        throwsA(
          isA<TranscriptionException>()
              .having((e) => e.failure, 'failure', TranscriptionFailure.upstream),
        ),
        reason: body,
      );
    }
  });

  test('every route error code maps to one failure', () async {
    const cases = <(int, String, TranscriptionFailure)>[
      (503, 'transcription_not_configured', TranscriptionFailure.notConfigured),
      (400, 'audio_too_short', TranscriptionFailure.tooShort),
      (400, 'audio_too_large', TranscriptionFailure.tooLarge),
      (400, 'invalid_request', TranscriptionFailure.upstream),
      (504, 'transcription_timeout', TranscriptionFailure.timeout),
      (502, 'upstream', TranscriptionFailure.upstream),
      (401, 'unauthorized', TranscriptionFailure.unauthorized),
      (403, 'forbidden', TranscriptionFailure.unauthorized),
      (500, 'boom', TranscriptionFailure.upstream),
    ];

    for (final (status, code, failure) in cases) {
      final api = await apiWith(
        _FakeUploader((_, __) async => _response(status, '{"error":"$code"}')),
      );
      await expectLater(
        api.transcribe(clip),
        throwsA(
          isA<TranscriptionException>().having((e) => e.failure, 'failure', failure),
        ),
        reason: '$status $code',
      );
    }
  });

  test('a transport failure is network; a stalled upload is a timeout', () async {
    for (final thrown in <Object>[
      http.ClientException('closed'),
      const SocketException('no route'),
    ]) {
      final api = await apiWith(_FakeUploader((_, __) async => throw thrown));
      await expectLater(
        api.transcribe(clip),
        throwsA(
          isA<TranscriptionException>()
              .having((e) => e.failure, 'failure', TranscriptionFailure.network),
        ),
        reason: '$thrown',
      );
    }

    final store = InMemoryTokenStore();
    await store.write('session-token');
    final api = TranscriptionApi(
      ApiClient(baseUrl: 'https://api.example.test', tokenStore: store),
      uploader: _FakeUploader(
        (_, __) => Future.delayed(
          const Duration(seconds: 5),
          () => _response(200, '{"text":"late"}'),
        ),
      ),
      timeout: const Duration(milliseconds: 20),
    );
    // The send resolves but the body never finishes arriving: both halves sit
    // under the one budget, and a stall is worth asking the device instead.
    await expectLater(
      api.transcribe(clip),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.failure, 'failure', TranscriptionFailure.timeout),
      ),
    );
  });

  test('a body that never finishes arriving is a timeout too', () async {
    final store = InMemoryTokenStore();
    await store.write('session-token');
    final api = TranscriptionApi(
      ApiClient(baseUrl: 'https://api.example.test', tokenStore: store),
      uploader: _FakeUploader(
        (_, __) async => http.StreamedResponse(
          StreamController<List<int>>().stream,
          200,
        ),
      ),
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      api.transcribe(clip),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.failure, 'failure', TranscriptionFailure.timeout),
      ),
    );
  });

  test('a clip that is gone is too short, not a crash', () async {
    final api = await apiWith(
      _FakeUploader((_, __) async => _response(200, '{"text":"never sent"}')),
    );
    clip.deleteSync();

    await expectLater(
      api.transcribe(clip),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.failure, 'failure', TranscriptionFailure.tooShort),
      ),
    );
  });

  test('a signed-out client is unauthorized before the clip leaves the device', () async {
    final uploader =
        _FakeUploader((_, __) async => _response(200, '{"text":"sent anyway"}'));
    final api = await apiWith(uploader, token: null);

    await expectLater(
      api.transcribe(clip),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.failure, 'failure', TranscriptionFailure.unauthorized),
      ),
    );
    expect(uploader.request, isNull);
  });
}
