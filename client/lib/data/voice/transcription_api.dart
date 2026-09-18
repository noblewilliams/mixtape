import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

/// Why `POST /transcribe` did not return a transcript. One value per error
/// code the route can answer with, plus the two the client decides itself.
enum TranscriptionFailure {
  /// The deployment has no `GROQ_API_KEY`: this route is off, the rest is not.
  notConfigured,

  /// Under the route's 1 KB floor — a mic that never really opened.
  tooShort,

  /// Over the route's 25 MB ceiling.
  tooLarge,

  /// The upstream transcription took longer than the route waits.
  timeout,

  /// Upstream refused, answered nothing usable, or the route itself failed.
  upstream,

  /// The clip never reached the server.
  network,

  /// No session, or a session the server rejected.
  unauthorized,
}

class TranscriptionException implements Exception {
  const TranscriptionException(this.failure);

  final TranscriptionFailure failure;

  @override
  String toString() => 'TranscriptionException(${failure.name})';
}

/// The server transcriber: a recorded clip goes up as multipart `audio` under
/// the session token, and a transcript comes back.
///
/// The upload does not go through [ApiClient]'s JSON helpers — it needs a
/// streamed multipart body — but it borrows that client's base URL and token
/// store so it speaks to the same API with the same session, and maps failures
/// into this layer's own enum rather than leaking [ApiException].
///
/// Neither the clip's bytes nor the transcript are ever logged.
class TranscriptionApi {
  TranscriptionApi(
    this._client, {
    http.Client? uploader,
    this.timeout = const Duration(seconds: 30),
  })  : _uploader = uploader ?? http.Client(),
        _ownsUploader = uploader == null;

  static const String path = '/transcribe';

  final ApiClient _client;
  final http.Client _uploader;
  final bool _ownsUploader;

  /// Longer than the route's own 15 s upstream budget, so a slow upload of a
  /// large clip is not cut off before the server has even tried.
  final Duration timeout;

  /// The transcript of [clip], trimmed. Throws [TranscriptionException].
  ///
  /// The clip is left on disk either way: the caller owns deleting it, because
  /// it may still be handed to the on-device fallback.
  Future<String> transcribe(File clip) async {
    final token = await _client.tokenStore.read();
    // No session means no route: sending the clip anyway would only spend a
    // listener's bandwidth on a 401.
    if (token == null || token.isEmpty) {
      throw const TranscriptionException(TranscriptionFailure.unauthorized);
    }
    if (!clip.existsSync()) {
      throw const TranscriptionException(TranscriptionFailure.tooShort);
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(_client.baseUrl).resolve(path),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        await http.MultipartFile.fromPath(
          'audio',
          clip.path,
          filename: 'clip.m4a',
        ),
      );

    final http.Response response;
    try {
      // The upload and the reply are one budget: a body that never finishes
      // arriving stalls just as long as a request that never gets a response.
      response = await Future(() async {
        final streamed = await _uploader.send(request);
        return http.Response.fromStream(streamed);
      }).timeout(timeout);
    } on http.ClientException {
      throw const TranscriptionException(TranscriptionFailure.network);
    } on SocketException {
      throw const TranscriptionException(TranscriptionFailure.network);
    } on TimeoutException {
      // The clip did reach us far enough to be worth another transcriber;
      // that is what `timeout` means to the caller, and `network` does not.
      throw const TranscriptionException(TranscriptionFailure.timeout);
    }

    if (response.statusCode >= 400) {
      throw TranscriptionException(
        _failureFor(response.statusCode, _errorCode(response.body)),
      );
    }

    final text = _text(response.body);
    if (text == null || text.isEmpty) {
      // A 200 with no transcript in it is an upstream fault, not an empty idea.
      throw const TranscriptionException(TranscriptionFailure.upstream);
    }
    return text;
  }

  void close() {
    if (_ownsUploader) _uploader.close();
  }

  static String? _text(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final text = decoded['text'];
      return text is String ? text.trim() : null;
    } on FormatException {
      return null;
    }
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final error = decoded['error'];
      return error is String ? error : null;
    } on FormatException {
      return null;
    }
  }

  static TranscriptionFailure _failureFor(int status, String? code) {
    if (status == 401 || status == 403) {
      return TranscriptionFailure.unauthorized;
    }
    return switch (code) {
      'transcription_not_configured' => TranscriptionFailure.notConfigured,
      'audio_too_short' => TranscriptionFailure.tooShort,
      'audio_too_large' => TranscriptionFailure.tooLarge,
      'transcription_timeout' => TranscriptionFailure.timeout,
      // `invalid_request`, `upstream`, and anything a future route adds: the
      // clip is fine, the server could not transcribe it.
      _ => TranscriptionFailure.upstream,
    };
  }
}
