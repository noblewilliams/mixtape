import 'dart:convert';

import '../api/api_client.dart';
import 'apple_auth_gateway.dart';
import 'account_api.dart';
import 'sign_in_preference_store.dart';
import 'google_auth_gateway.dart';
import 'identity_token.dart';
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

enum StoredSession { none, anonymous, account }

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

  /// Apple discloses the name only on the first-ever authorization. If that
  /// sign-in's POST fails, the retry's token comes without it, so the name
  /// is held here (memory only, this app session) for a retry by the same
  /// Apple ID, and dropped once a sign-in succeeds.
  _HeldAppleName? _heldAppleName;

  Future<void> signInWithApple() async {
    IdentityToken? sent;
    await _signIn('apple', () async {
      final identity = await gateway.getIdentityToken();
      final subject = _jwtSubject(identity.token);
      final held = _heldAppleName;
      if (_hasName(identity)) {
        _heldAppleName = _HeldAppleName(subject, identity);
        sent = identity;
      } else if (held != null && subject != null && held.subject == subject) {
        sent = IdentityToken(
          identity.token,
          givenName: held.identity.givenName,
          familyName: held.identity.familyName,
        );
      } else {
        sent = identity;
      }
      return sent!;
    });
    _heldAppleName = null;
  }

  Future<void> signInWithGoogle() {
    final google = googleGateway;
    if (google == null || !google.isAvailable) {
      throw const GoogleSignInUnavailable();
    }
    return _signIn(
      'google',
      () async => IdentityToken(await google.getIdentityToken()),
    );
  }

  /// Creates an anonymous session and stores its token flagged anonymous.
  Future<void> signInAnonymously() => _authenticate(
    path: '/api/auth/sign-in/anonymous',
    body: () async => const <String, Object>{},
    anonymous: true,
  );

  /// Social sign-in. When an anonymous token is stored, [ApiClient] sends it
  /// as `Authorization: Bearer` on this request, which is what lets the
  /// server's anonymous plugin link that user into the account. The
  /// response's token is the account's and replaces the anonymous one.
  Future<void> _signIn(
    String provider,
    Future<IdentityToken> Function() identity,
  ) => _authenticate(
    path: '/api/auth/sign-in/social',
    body: () async {
      final idToken = await identity();
      if (idToken.token.trim().isEmpty) {
        throw StateError('Missing identity token');
      }
      return {'provider': provider, 'idToken': idToken.toJson()};
    },
    provider: provider,
  );

  Future<void> _authenticate({
    required String path,
    required Future<Map<String, Object>> Function() body,
    String? provider,
    bool anonymous = false,
  }) async {
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
      final payload = await body();
      ensureCurrent();
      final res = await api.postJson(path, payload);
      ensureCurrent();
      final token = res.headers['set-auth-token'];
      if (token == null || token.trim().isEmpty) {
        throw StateError('No set-auth-token header in response');
      }
      await _withStore(() async {
        ensureCurrent();
        await tokenStore.write(token, anonymous: anonymous);
        if (provider != null && !_disposed && generation == _generation) {
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

  /// What the keychain holds, read without a network call.
  Future<StoredSession> storedSession() => _withStore(() async {
    final token = await tokenStore.read();
    if (token == null || token.trim().isEmpty) return StoredSession.none;
    return await tokenStore.readAnonymous()
        ? StoredSession.anonymous
        : StoredSession.account;
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

  /// After `DELETE /me` succeeded: the server already ended every session,
  /// so this is local only. The token goes first, behind any write in
  /// flight, as on sign-out; then the last-used hint (it named an account
  /// that no longer exists) and the Google grant, both best effort.
  Future<void> forgetDeletedAccount() async {
    await signOut();
    try {
      await preferenceStore?.clear();
    } catch (_) {
      // A convenience hint must not leave the deleted account half-forgotten.
    }
    try {
      await googleGateway?.disconnect();
    } catch (_) {
      // Best effort by contract; a fake or plugin failure changes nothing.
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

class _HeldAppleName {
  const _HeldAppleName(this.subject, this.identity);
  final String? subject;
  final IdentityToken identity;
}

bool _hasName(IdentityToken identity) =>
    (identity.givenName?.trim().isNotEmpty ?? false) ||
    (identity.familyName?.trim().isNotEmpty ?? false);

/// The `sub` claim of a JWT, read without verifying it: only used to tell
/// whether a retry is the same Apple ID. Null when it cannot be read.
String? _jwtSubject(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final sub = payload is Map<String, dynamic> ? payload['sub'] : null;
    return sub is String && sub.isNotEmpty ? sub : null;
  } catch (_) {
    return null;
  }
}

class _AuthStorageQueue {
  Future<void> tail = Future<void>.value();
}
