import 'dart:convert';
import 'package:http/http.dart' as http;
import '../auth/token_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.tokenStore, http.Client? inner})
      : _inner = inner ?? http.Client();

  final String baseUrl;
  final TokenStore tokenStore;
  final http.Client _inner;

  Future<Map<String, String>> _headers() async {
    final token = await tokenStore.read();
    return {
      'content-type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> postJson(String path, Object body) async {
    final res = await _inner.post(
      Uri.parse('$baseUrl$path'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }

  Future<http.Response> getJson(String path) async {
    final res = await _inner.get(Uri.parse('$baseUrl$path'), headers: await _headers());
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }
}
