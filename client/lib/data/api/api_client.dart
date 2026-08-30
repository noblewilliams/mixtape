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

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokenStore,
    http.Client? inner,
    this.timeout = const Duration(seconds: 30),
  })  : _inner = inner ?? http.Client(),
        _ownsInner = inner == null;

  final String baseUrl;
  final TokenStore tokenStore;
  final Duration timeout;
  final http.Client _inner;
  final bool _ownsInner;

  Future<Map<String, String>> _headers() async {
    final token = await tokenStore.read();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
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
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
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
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }

  Future<http.Response> getJson(String path) async {
    final headers = await _headers();
    final res = await _guard(
        () => _inner.get(Uri.parse(baseUrl).resolve(path), headers: headers));
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }

  Future<http.Response> deleteJson(String path) async {
    final headers = await _headers();
    final res = await _guard(
        () => _inner.delete(Uri.parse(baseUrl).resolve(path), headers: headers));
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }

  void close() {
    if (_ownsInner) _inner.close();
  }
}
