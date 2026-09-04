import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/token_store.dart';
import 'device_providers.dart';

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

// Invalidating authProvider rebuilds user-scoped providers and cancels their
// in-flight work (e.g. a running library sync) — recoverable but lossy.
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
    await _forgetDeviceState();
    state = AuthStatus.signedOut;
  }

  /// Device-local state that belongs to the departing listener, dropped
  /// alongside the token: the "service chosen" flag (keyed by their id, so
  /// stale at worst) and the pending request reminder. Best effort: a
  /// failing keychain or notification plugin must never leave a listener
  /// unable to sign out.
  Future<void> _forgetDeviceState() async {
    try {
      await ref.read(servicePreferenceStoreProvider).clear();
    } catch (e) {
      if (kDebugMode) debugPrint('service flag clear failed: $e');
    }
    try {
      await ref.read(reminderSchedulerProvider).cancelRequestReminder();
    } catch (e) {
      if (kDebugMode) debugPrint('reminder cancel failed: $e');
    }
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthStatus>(AuthNotifier.new);
