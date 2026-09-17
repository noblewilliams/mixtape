import 'dart:convert';

import '../api/api_client.dart';
import 'apple_auth_gateway.dart';
import 'account_api.dart';
import 'sign_in_preference_store.dart';
import 'google_auth_gateway.dart';
import 'token_store.dart';

class AuthOperationBusy implements Exception {
  const AuthOperationBusy();
  @override
  String toString() => 'Authentication is already in progress';
}

class AuthOperationCancelled implements Exception {
  const AuthOperationCancelled();
  @override
  String toString() => 'Authentication no longer applies';
}

class AuthSignInException extends ApiException {
  AuthSignInException(super.statusCode, super.body, this.code);
  final String? code;
  @override
  String toString() => 'AuthSignInException($statusCode)';
}

class AuthRepository {
  AuthRepository({
    required this.tokenStore,
    required this.gateway,
    required this.api,
    this.googleGateway,
    this.preferenceStore,
  });

  final TokenStore tokenStore;
  final AppleAuthGateway gateway;
  final GoogleAuthGateway? googleGateway;
  final ApiClient api;
  final SignInPreferenceStore? preferenceStore;
  int _generation = 0;
  Object? _activeSignIn;
  bool _disposed = false;
  int _signingOut = 0;
  static final _storageQueues = Expando<_AuthStorageQueue>();
  late final _storageQueue = _storageQueues[tokenStore] ??= _AuthStorageQueue();

  bool get googleAvailable => googleGateway?.isAvailable ?? false;

  Future<void> signInWithApple() => _signIn('apple', gateway.getIdentityToken);

  Future<void> signInWithGoogle() {
    final google = googleGateway;
    if (google == null || !google.isAvailable) {
      throw const GoogleSignInUnavailable();
    }
    return _signIn('google', google.getIdentityToken);
  }

  Future<void> _signIn(
    String provider,
    Future<String> Function() identity,
  ) async {
    if (_disposed) throw const AuthOperationCancelled();
    if (_activeSignIn != null || _signingOut > 0) {
      throw const AuthOperationBusy();
    }
    final operation = Object();
    _activeSignIn = operation;
    final generation = ++_generation;
    void ensureCurrent() {
      if (_disposed || generation != _generation) {
        throw const AuthOperationCancelled();
      }
    }

    try {
      final idToken = await identity();
      ensureCurrent();
      if (idToken.trim().isEmpty) throw StateError('Missing identity token');
      final res = await api.postJson('/api/auth/sign-in/social', {
        'provider': provider,
        'idToken': {'token': idToken},
      });
      ensureCurrent();
      final token = res.headers['set-auth-token'];
      if (token == null || token.trim().isEmpty) {
        throw StateError('No set-auth-token header in response');
      }
      await _withStore(() async {
        ensureCurrent();
        await tokenStore.write(token);
        if (!_disposed && generation == _generation) {
          try {
            await preferenceStore?.write(
              provider == 'apple'
                  ? AccountProvider.apple
                  : AccountProvider.google,
            );
          } catch (_) {
            // A convenience hint must not prevent authentication.
          }
        }
        if (_disposed || generation != _generation) {
          // Disposal can arrive while keychain I/O is already running. Clear
          // inside the same shared queue, before a replacement repo can write.
          await tokenStore.clear();
          throw const AuthOperationCancelled();
        }
      });
      ensureCurrent();
    } on ApiException catch (error) {
      ensureCurrent();
      String? code;
      try {
        final json = jsonDecode(error.body);
        if (json is Map<String, dynamic> && json['code'] is String) {
          code = json['code'] as String;
        }
      } on FormatException {
        // Preserve status without exposing provider response text in logs.
      }
      throw AuthSignInException(error.statusCode, error.body, code);
    } finally {
      if (identical(_activeSignIn, operation)) _activeSignIn = null;
    }
  }

  Future<T> _withStore<T>(Future<T> Function() action) {
    final result = _storageQueue.tail.then((_) => action());
    _storageQueue.tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<bool> isSignedIn() => _withStore(() async {
    final token = await tokenStore.read();
    return token != null && token.trim().isNotEmpty;
  });

  Future<void> signOut() async {
    _generation++;
    _activeSignIn = null;
    _signingOut++;
    try {
      // Clear follows any write already in progress, so a late write cannot
      // bring the departing listener back after sign-out completes.
      await _withStore(tokenStore.clear);
    } finally {
      _signingOut--;
    }
  }

  void cancelPending() {
    _generation++;
  }

  void dispose() {
    _disposed = true;
    cancelPending();
  }
}

class _AuthStorageQueue {
  Future<void> tail = Future<void>.value();
}
