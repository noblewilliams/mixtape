import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../auth/token_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() {
    final truncated = body.length > 200 ? '${body.substring(0, 200)}...' : body;
    return 'ApiException($statusCode): $truncated';
  }
}

/// Thrown for transport-level failures (no response from the server at all).
/// Retryable, unlike [ApiException] which represents a terminal server response.
class NetworkException implements Exception {
  NetworkException(this.cause);
  final Object cause;
  @override
  String toString() => 'NetworkException: $cause';
}

/// `403 {error: 'ai_consent_required'}`: the server enforces AI consent
/// (`AI_CONSENT=enforce`) and this listener has not agreed. The caller shows
/// the consent sheet instead of an error, and keeps what was typed.
class AiConsentRequiredException implements Exception {
  const AiConsentRequiredException();

  /// The server's error code.
  static const String code = 'ai_consent_required';

  /// Whether [statusCode] and [body] are this answer.
  static bool matches(int statusCode, String body) {
    if (statusCode != 403) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['error'] == code;
    } on FormatException {
      return false;
    }
  }

  @override
  String toString() => 'AiConsentRequiredException';
}

/// What [ApiClient.postEventStream] got back.
sealed class StreamingReply {
  const StreamingReply();
}

/// The server answered with a whole body rather than a stream: an older
/// server, a refusal before the work started, or a request it never
/// streams. Only a successful status gets here (a failed one throws).
final class WholeReply extends StreamingReply {
  const WholeReply(this.response);

  final http.Response response;
}

/// The server opened an event stream (2xx, `text/event-stream`).
final class EventStreamReply extends StreamingReply {
  const EventStreamReply(this.bytes, this._failure);

  /// The response body. Fails with [NetworkException] on a transport error
  /// or when it goes quiet past the idle timeout. Cancelling it lets go of
  /// the connection.
  final Stream<List<int>> bytes;

  final ApiException Function(int status, String body) _failure;

  /// The [ApiException] for a failure the stream reported in-band, with the
  /// status and body a failed response would have carried. A 401 reports
  /// the expired session first, exactly as a 401 status does.
  ApiException failure(int status, String body) => _failure(status, body);
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokenStore,
    http.Client? inner,
    this.timeout = const Duration(seconds: 30),
    this.onUnauthorized,
  }) : _inner = inner ?? http.Client(),
       _ownsInner = inner == null;

  final String baseUrl;
  final TokenStore tokenStore;
  final Duration timeout;
  final http.Client _inner;
  final bool _ownsInner;

  /// Called with the token a request carried when the server answered 401:
  /// the session is over, and the auth layer signs the listener out rather
  /// than leave every screen failing one by one. Not called for requests
  /// that carried no token, nor for the sign-in endpoints, whose 401 is a
  /// refused sign-in rather than an expired session. The request still
  /// throws its [ApiException].
  final Future<void> Function(String token)? onUnauthorized;

  static const String _signInPrefix = '/api/auth/sign-in/';

  Future<Map<String, String>> _headers() async {
    final token = await tokenStore.read();
    return {if (token != null) 'Authorization': 'Bearer $token'};
  }

  /// Throws for a failed status, reporting an expired session first.
  void _check(http.Response res, String path, Map<String, String> headers) {
    if (res.statusCode < 400) return;
    throw _failure(res.statusCode, res.body, path, headers);
  }

  /// The [ApiException] for a failed [status], reporting an expired session
  /// first when the request ([path], [headers]) carried a token.
  ApiException _failure(
    int status,
    String body,
    String path,
    Map<String, String> headers,
  ) {
    final auth = headers['Authorization'];
    if (status == 401 && auth != null && !path.startsWith(_signInPrefix)) {
      // Detached: the caller's error path must not wait on, or fail with,
      // the sign-out.
      unawaited(
        onUnauthorized
            ?.call(auth.substring('Bearer '.length))
            .catchError((Object _) {}),
      );
    }
    return ApiException(status, body);
  }

  /// Runs [call] within [timeout]. [onTimeout], when given, runs the moment
  /// the time is up (before the failure reaches the caller).
  Future<T> _guard<T>(
    Future<T> Function() call, {
    void Function()? onTimeout,
  }) async {
    try {
      final pending = call();
      return await (onTimeout == null
          ? pending.timeout(timeout)
          : pending.timeout(
              timeout,
              onTimeout: () {
                onTimeout();
                throw TimeoutException('Future not completed', timeout);
              },
            ));
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    } on SocketException catch (e) {
      throw NetworkException(e);
    } on TimeoutException catch (e) {
      throw NetworkException(e);
    }
  }

  /// Returns the raw [http.Response] so callers can read response headers (e.g. set-auth-token).
  Future<http.Response> postJson(String path, Object body) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    final res = await _guard(
      () => _inner.post(
        Uri.parse(baseUrl).resolve(path),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
    _check(res, path, headers);
    return res;
  }

  /// [postJson] asking for `text/event-stream`: the same request (headers,
  /// auth, JSON body, Dart's default User-Agent) plus `accept`.
  ///
  /// [timeout] covers waiting for the response headers. A 2xx answer typed
  /// `text/event-stream` comes back as an [EventStreamReply] as soon as its
  /// headers arrive; from then on [timeout] no longer applies, and its bytes
  /// fail with [NetworkException] on any transport error or when no bytes
  /// arrive for [idleTimeout]. Any other answer is read whole within
  /// [timeout]: a failed status throws [ApiException] (and reports a 401) as
  /// [postJson] does, and a success comes back as a [WholeReply].
  Future<StreamingReply> postEventStream(
    String path,
    Object body, {
    required Duration idleTimeout,
  }) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    headers['accept'] = 'text/event-stream';
    // Pulled when the wait times out: a client that honours it (IOClient)
    // tears the request down, and an answer that still turns up from one
    // that does not is let go of below, so no connection stays busy.
    final abort = Completer<void>();
    final reply = await _guard<StreamingReply>(() async {
      // Built as http's own post() builds it, so only `accept` and the
      // abort trigger differ.
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse(baseUrl).resolve(path),
              abortTrigger: abort.future,
            )
            ..headers.addAll(headers)
            ..body = jsonEncode(body);
      final res = await _inner.send(request);
      if (abort.isCompleted) {
        // Nobody is waiting for this answer any more.
        unawaited(
          res.stream
              .listen(null, onError: (Object _) {})
              .cancel()
              .catchError((Object _) {}),
        );
        throw TimeoutException('The answer came after the wait', timeout);
      }
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          _isEventStream(res.headers['content-type'])) {
        return EventStreamReply(
          _idleGuarded(res.stream, idleTimeout),
          (status, body) => _failure(status, body, path, headers),
        );
      }
      return WholeReply(await http.Response.fromStream(res));
    }, onTimeout: abort.complete);
    if (reply is WholeReply) _check(reply.response, path, headers);
    return reply;
  }

  static bool _isEventStream(String? contentType) =>
      contentType != null &&
      contentType.split(';').first.trim().toLowerCase() == 'text/event-stream';

  /// [bytes], failing with [NetworkException] when nothing arrives for
  /// [idle] and with every other error wrapped in one.
  ///
  /// When the idle timer fires, pending I/O gets one more turn of the event
  /// loop before the stream fails: iOS suspends a backgrounded app and fires
  /// its overdue timers on resume, possibly ahead of bytes (even the result)
  /// that reached the socket meanwhile. Bytes delivered in that turn re-arm
  /// the timer instead.
  static Stream<List<int>> _idleGuarded(
    Stream<List<int>> bytes,
    Duration idle,
  ) {
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? source;
    Timer? timer;
    // Which arming is current: bumped by every disarm, so a check scheduled
    // by an older arming knows bytes came (or the stream ended) since.
    var arming = 0;

    void disarm() {
      timer?.cancel();
      timer = null;
      arming++;
    }

    void fail() {
      disarm();
      unawaited(source?.cancel().catchError((Object _) {}));
      out
        ..addError(
          NetworkException(
            TimeoutException('No bytes from the stream for $idle', idle),
          ),
        )
        ..close();
    }

    void arm() {
      disarm();
      final mine = arming;
      timer = Timer(idle, () {
        Timer.run(() {
          if (mine == arming && !out.isClosed) fail();
        });
      });
    }

    out = StreamController<List<int>>(
      sync: true,
      onListen: () {
        source = bytes.listen(
          (chunk) {
            if (out.isClosed) return;
            arm();
            out.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (out.isClosed) return;
            out.addError(
              error is NetworkException ? error : NetworkException(error),
              stack,
            );
          },
          onDone: () {
            disarm();
            out.close();
          },
        );
        arm();
      },
      onPause: () {
        disarm();
        source?.pause();
      },
      onResume: () {
        source?.resume();
        arm();
      },
      onCancel: () {
        disarm();
        return source?.cancel();
      },
    );
    return out.stream;
  }

  Future<http.Response> patchJson(String path, Object body) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    final res = await _guard(
      () => _inner.patch(
        Uri.parse(baseUrl).resolve(path),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
    _check(res, path, headers);
    return res;
  }

  Future<http.Response> putJson(String path, Object body) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    final res = await _guard(
      () => _inner.put(
        Uri.parse(baseUrl).resolve(path),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
    _check(res, path, headers);
    return res;
  }

  Future<http.Response> getJson(String path) async {
    final headers = await _headers();
    final res = await _guard(
      () => _inner.get(Uri.parse(baseUrl).resolve(path), headers: headers),
    );
    _check(res, path, headers);
    return res;
  }

  /// [body], when given, is sent as JSON; without it the request has none.
  Future<http.Response> deleteJson(String path, {Object? body}) async {
    final headers = await _headers();
    if (body != null) headers['content-type'] = 'application/json';
    final res = await _guard(
      () => _inner.delete(
        Uri.parse(baseUrl).resolve(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );
    _check(res, path, headers);
    return res;
  }

  void close() {
    if (_ownsInner) _inner.close();
  }
}
