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

/// `session` covers anonymous and account sessions alike: gating treats them
/// as one state, and [AuthNotifier.isAnonymous] tells them apart for the You
/// row and the mix cap.
enum AuthStatus { unknown, noSession, session }

// Invalidating authProvider rebuilds user-scoped providers and cancels their
// in-flight work (e.g. a running library sync) — recoverable but lossy.
class AuthNotifier extends Notifier<AuthStatus> {
  int _operation = 0;
  bool _busy = false;
  bool _anonymous = false;

  /// Whether the current session is anonymous. Read from the flag the token
  /// store keeps beside the token, so it is known on a cold start without a
  /// network call. False whenever [state] is not [AuthStatus.session].
  bool get isAnonymous => _anonymous;

  /// Every write to the flag after build goes through here, so a flip without
  /// a status change still tells watchers (see [isAnonymousProvider]).
  set _isAnonymous(bool value) {
    if (_anonymous == value) return;
    _anonymous = value;
    ref.notifyListeners();
  }

  @override
  AuthStatus build() {
    _busy = false;
    // Direct write: build's own result notifies, and notifying from inside
    // build is not allowed.
    _anonymous = false;
    final repository = ref.read(authRepositoryProvider);
    ref.onDispose(() {
      _operation++;
      repository.cancelPending();
    });
    _restore(_operation);
    return AuthStatus.unknown;
  }

  Future<void> _restore(int operation) async {
    StoredSession stored;
    try {
      stored = await ref.read(authRepositoryProvider).storedSession();
    } catch (_) {
      if (kDebugMode) debugPrint('auth restore failed');
      stored = StoredSession.none;
    }
    if (!ref.mounted || operation != _operation) return;
    _isAnonymous = stored == StoredSession.anonymous;
    state = stored == StoredSession.none
        ? AuthStatus.noSession
        : AuthStatus.session;
  }

  /// Starts an anonymous session (lazily, at the first action that needs the
  /// server). Moves noSession to session without invalidating anything:
  /// there is no user-scoped state to reset yet. Only meaningful from
  /// noSession: with a session already stored (anonymous or account) it
  /// returns without a request, so it can never overwrite an account token;
  /// before restore has settled it throws, because the answer is not known.
  Future<void> signInAnonymously() async {
    switch (state) {
      case AuthStatus.unknown:
        throw StateError('signInAnonymously before auth restore settled');
      case AuthStatus.session:
        return;
      case AuthStatus.noSession:
        break;
    }
    if (_busy) throw const AuthOperationBusy();
    _busy = true;
    final operation = ++_operation;
    try {
      await ref.read(authRepositoryProvider).signInAnonymously();
      if (!ref.mounted || operation != _operation) {
        throw const AuthOperationCancelled();
      }
      _isAnonymous = true;
      state = AuthStatus.session;
    } catch (_) {
      if (!ref.mounted || operation != _operation) {
        throw const AuthOperationCancelled();
      }
      rethrow;
    } finally {
      if (operation == _operation) _busy = false;
    }
  }

  /// Social sign-in. From an anonymous session the request carries the
  /// anonymous token so the server links it; the status stays `session`, so
  /// the provider invalidates itself to reset every user-scoped provider,
  /// exactly as a sign-in from noSession does by changing state.
  Future<void> signIn({
    AccountProvider provider = AccountProvider.apple,
  }) async {
    if (_busy) throw const AuthOperationBusy();
    _busy = true;
    final operation = ++_operation;
    final linking = state == AuthStatus.session && _anonymous;
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
      _isAnonymous = false;
      if (linking) {
        // Rebuild re-reads the stored (now account) token.
        ref.invalidateSelf();
      } else {
        state = AuthStatus.session;
      }
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
      _isAnonymous = false;
      state = AuthStatus.noSession;
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

/// [AuthNotifier.isAnonymous] as something widgets can watch: it rebuilds on
/// every status change and on a flag flip that leaves the status alone.
final isAnonymousProvider = Provider<bool>((ref) {
  ref.watch(authProvider);
  return ref.read(authProvider.notifier).isAnonymous;
});
