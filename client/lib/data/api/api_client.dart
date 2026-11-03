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

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokenStore,
    http.Client? inner,
    this.timeout = const Duration(seconds: 30),
    this.onUnauthorized,
  })  : _inner = inner ?? http.Client(),
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
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Throws for a failed status, reporting an expired session first.
  void _check(http.Response res, String path, Map<String, String> headers) {
    if (res.statusCode < 400) return;
    final auth = headers['Authorization'];
    if (res.statusCode == 401 &&
        auth != null &&
        !path.startsWith(_signInPrefix)) {
      // Detached: the caller's error path must not wait on, or fail with,
      // the sign-out.
      unawaited(
        onUnauthorized
            ?.call(auth.substring('Bearer '.length))
            .catchError((Object _) {}),
      );
    }
    throw ApiException(res.statusCode, res.body);
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call().timeout(timeout);
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
    final res = await _guard(() => _inner.post(
          Uri.parse(baseUrl).resolve(path),
          headers: headers,
          body: jsonEncode(body),
        ));
    _check(res, path, headers);
    return res;
  }

  Future<http.Response> patchJson(String path, Object body) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    final res = await _guard(() => _inner.patch(
          Uri.parse(baseUrl).resolve(path),
          headers: headers,
          body: jsonEncode(body),
        ));
    _check(res, path, headers);
    return res;
  }

  Future<http.Response> putJson(String path, Object body) async {
    final headers = await _headers();
    headers['content-type'] = 'application/json';
    final res = await _guard(() => _inner.put(
          Uri.parse(baseUrl).resolve(path),
          headers: headers,
          body: jsonEncode(body),
        ));
    _check(res, path, headers);
    return res;
  }

  Future<http.Response> getJson(String path) async {
    final headers = await _headers();
    final res = await _guard(
        () => _inner.get(Uri.parse(baseUrl).resolve(path), headers: headers));
    _check(res, path, headers);
    return res;
  }

  /// [body], when given, is sent as JSON; without it the request has none.
  Future<http.Response> deleteJson(String path, {Object? body}) async {
    final headers = await _headers();
    if (body != null) headers['content-type'] = 'application/json';
    final res = await _guard(() => _inner.delete(
          Uri.parse(baseUrl).resolve(path),
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ));
    _check(res, path, headers);
    return res;
  }

  void close() {
    if (_ownsInner) _inner.close();
  }
}
