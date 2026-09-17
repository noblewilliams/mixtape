import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/token_store.dart';
import '../../data/auth/sign_in_preference_store.dart';
import 'device_providers.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    tokenStore: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(client.close);
  return client;
});

final appleAuthGatewayProvider = Provider<AppleAuthGateway>(
  (ref) => RealAppleAuthGateway(),
);

final googleAuthGatewayProvider = Provider<GoogleAuthGateway>(
  (ref) => RealGoogleAuthGateway(),
);

final signInPreferenceStoreProvider = Provider<SignInPreferenceStore>(
  (ref) => SecureSignInPreferenceStore(),
);

final lastSignInProvider = FutureProvider<AccountProvider?>((ref) async {
  try {
    return await ref.watch(signInPreferenceStoreProvider).read();
  } catch (_) {
    return null;
  }
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final repository = AuthRepository(
    tokenStore: ref.watch(tokenStoreProvider),
    gateway: ref.watch(appleAuthGatewayProvider),
    googleGateway: ref.watch(googleAuthGatewayProvider),
    preferenceStore: ref.watch(signInPreferenceStoreProvider),
    api: ref.watch(apiClientProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

enum AuthStatus { unknown, signedOut, signedIn }

// Invalidating authProvider rebuilds user-scoped providers and cancels their
// in-flight work (e.g. a running library sync) — recoverable but lossy.
class AuthNotifier extends Notifier<AuthStatus> {
  int _operation = 0;
  bool _busy = false;

  @override
  AuthStatus build() {
    _busy = false;
    final repository = ref.read(authRepositoryProvider);
    ref.onDispose(() {
      _operation++;
      repository.cancelPending();
    });
    _restore(_operation);
    return AuthStatus.unknown;
  }

  Future<void> _restore(int operation) async {
    bool signedIn;
    try {
      signedIn = await ref.read(authRepositoryProvider).isSignedIn();
    } catch (_) {
      if (kDebugMode) debugPrint('auth restore failed');
      signedIn = false;
    }
    if (!ref.mounted || operation != _operation) return;
    state = signedIn ? AuthStatus.signedIn : AuthStatus.signedOut;
  }

  Future<void> signIn({
    AccountProvider provider = AccountProvider.apple,
  }) async {
    if (_busy) throw const AuthOperationBusy();
    _busy = true;
    final operation = ++_operation;
    try {
      final repository = ref.read(authRepositoryProvider);
      if (provider == AccountProvider.apple) {
        await repository.signInWithApple();
      } else {
        await repository.signInWithGoogle();
      }
      if (!ref.mounted || operation != _operation) {
        throw const AuthOperationCancelled();
      }
      ref.invalidate(lastSignInProvider);
      state = AuthStatus.signedIn;
    } catch (_) {
      if (!ref.mounted || operation != _operation) {
        throw const AuthOperationCancelled();
      }
      rethrow;
    } finally {
      if (operation == _operation) _busy = false;
    }
  }

  Future<void> signOut() async {
    final operation = ++_operation;
    _busy = true;
    try {
      await ref.read(authRepositoryProvider).signOut();
      if (!ref.mounted || operation != _operation) return;
      // Reset protected state before slower, best-effort device cleanup.
      state = AuthStatus.signedOut;
      await _forgetDeviceState();
    } finally {
      if (operation == _operation) _busy = false;
    }
  }

  /// Device-local state that belongs to the departing listener, dropped
  /// alongside the token: the "service chosen" flag (keyed by their id, so
  /// stale at worst), the once-only funnel milestones (same keying; the
  /// server tolerates a repeat), and the pending request reminder. Best
  /// effort: a failing keychain or notification plugin must never leave a
  /// listener unable to sign out.
  Future<void> _forgetDeviceState() async {
    try {
      await ref.read(servicePreferenceStoreProvider).clear();
    } catch (e) {
      if (kDebugMode) debugPrint('service flag clear failed');
    }
    try {
      await ref.read(funnelOnceStoreProvider).clear();
    } catch (e) {
      if (kDebugMode) debugPrint('funnel flag clear failed');
    }
    try {
      await ref.read(reminderSchedulerProvider).cancelRequestReminder();
    } catch (e) {
      if (kDebugMode) debugPrint('reminder cancel failed');
    }
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthStatus>(
  AuthNotifier.new,
);
