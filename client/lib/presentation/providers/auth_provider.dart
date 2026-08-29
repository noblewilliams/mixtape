import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/token_store.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUrl: AppConfig.apiBaseUrl, tokenStore: ref.watch(tokenStoreProvider));
  ref.onDispose(client.close);
  return client;
});

final appleAuthGatewayProvider = Provider<AppleAuthGateway>((ref) => RealAppleAuthGateway());

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    tokenStore: ref.watch(tokenStoreProvider),
    gateway: ref.watch(appleAuthGatewayProvider),
    api: ref.watch(apiClientProvider),
  );
});

enum AuthStatus { unknown, signedOut, signedIn }

class AuthNotifier extends Notifier<AuthStatus> {
  @override
  AuthStatus build() {
    _restore();
    return AuthStatus.unknown;
  }

  Future<void> _restore() async {
    bool signedIn;
    try {
      signedIn = await ref.read(authRepositoryProvider).isSignedIn();
    } catch (e) {
      if (kDebugMode) debugPrint('auth restore failed: $e');
      signedIn = false; // unreadable keychain == not signed in
    }
    if (!ref.mounted) return;
    state = signedIn ? AuthStatus.signedIn : AuthStatus.signedOut;
  }

  Future<void> signIn() async {
    await ref.read(authRepositoryProvider).signInWithApple();
    state = AuthStatus.signedIn;
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    state = AuthStatus.signedOut;
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthStatus>(AuthNotifier.new);
