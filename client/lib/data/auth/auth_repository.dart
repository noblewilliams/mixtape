import 'dart:convert';
import 'package:http/http.dart' as http;
import 'apple_auth_gateway.dart';
import 'token_store.dart';

class AuthRepository {
  AuthRepository({
    required this.baseUrl,
    required this.tokenStore,
    required this.gateway,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  final String baseUrl;
  final TokenStore tokenStore;
  final AppleAuthGateway gateway;
  final http.Client _inner;

  Future<void> signInWithApple() async {
    final idToken = await gateway.getIdentityToken();
    final res = await _inner.post(
      Uri.parse(baseUrl).resolve('/api/auth/sign-in/social'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'provider': 'apple',
        'idToken': {'token': idToken},
      }),
    );
    if (res.statusCode >= 400) {
      throw StateError('Sign-in failed (${res.statusCode}): ${res.body}');
    }
    final token = res.headers['set-auth-token'];
    if (token == null) throw StateError('No set-auth-token header in response');
    await tokenStore.write(token);
  }

  Future<bool> isSignedIn() async => await tokenStore.read() != null;

  Future<void> signOut() => tokenStore.clear();
}
