import '../api/api_client.dart';
import 'apple_auth_gateway.dart';
import 'token_store.dart';

class AuthRepository {
  AuthRepository({
    required this.tokenStore,
    required this.gateway,
    required this.api,
  });

  final TokenStore tokenStore;
  final AppleAuthGateway gateway;
  final ApiClient api;

  Future<void> signInWithApple() async {
    final idToken = await gateway.getIdentityToken();
    // ApiClient attaches a stale bearer header if one exists from a previous
    // session; harmless here since sign-in doesn't require authentication.
    final res = await api.postJson('/api/auth/sign-in/social', {
      'provider': 'apple',
      'idToken': {'token': idToken},
    });
    final token = res.headers['set-auth-token'];
    if (token == null) throw StateError('No set-auth-token header in response');
    await tokenStore.write(token);
  }

  Future<bool> isSignedIn() async => await tokenStore.read() != null;

  Future<void> signOut() => tokenStore.clear();
}
