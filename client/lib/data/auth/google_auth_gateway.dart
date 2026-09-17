import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Public IDs only. The callback flag stays false until Info.plist has the
/// matching reversed iOS client scheme; Dart IDs cannot register that scheme.
class GoogleAuthConfiguration {
  const GoogleAuthConfiguration({
    this.iosClientId = const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
    this.serverClientId = const String.fromEnvironment(
      'GOOGLE_SERVER_CLIENT_ID',
    ),
    this.callbackConfigured = const bool.fromEnvironment(
      'GOOGLE_IOS_CALLBACK_CONFIGURED',
    ),
  });
  final String iosClientId;
  final String serverClientId;
  final bool callbackConfigured;
  bool get isConfigured =>
      iosClientId.trim().isNotEmpty &&
      serverClientId.trim().isNotEmpty &&
      callbackConfigured;
}

abstract class GoogleAuthGateway {
  bool get isAvailable;
  Future<String> getIdentityToken();
}

class GoogleSignInCancelled implements Exception {
  const GoogleSignInCancelled();
  @override
  String toString() => 'Google sign-in cancelled';
}

class GoogleSignInUnavailable implements Exception {
  const GoogleSignInUnavailable();
  @override
  String toString() => 'Google sign-in is not configured for this app';
}

class GoogleSignInFailed implements Exception {
  const GoogleSignInFailed();
  @override
  String toString() => 'Google sign-in did not finish';
}

class GoogleSignInBusy implements Exception {
  const GoogleSignInBusy();
  @override
  String toString() => 'Google sign-in is already in progress';
}

/// Thin SDK seam: tests never need real Google identities or provider UI.
abstract class GoogleNativeSdk {
  Future<void> initialize({
    required String clientId,
    required String serverClientId,
  });
  Future<String?> authenticateIdentityToken();
}

class _OfficialGoogleSdk implements GoogleNativeSdk {
  static Future<void>? _initialization;
  static String? _clientId;
  static String? _serverClientId;
  final GoogleSignIn _google = GoogleSignIn.instance;

  @override
  Future<void> initialize({
    required String clientId,
    required String serverClientId,
  }) async {
    if (_initialization != null) {
      if (_clientId != clientId || _serverClientId != serverClientId) {
        throw const GoogleSignInUnavailable();
      }
      return _initialization;
    }
    _clientId = clientId;
    _serverClientId = serverClientId;
    final pending = _google.initialize(
      clientId: clientId,
      serverClientId: serverClientId,
    );
    _initialization = pending;
    try {
      await pending;
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  @override
  Future<String?> authenticateIdentityToken() async {
    if (!_google.supportsAuthenticate()) throw const GoogleSignInUnavailable();
    // Explicitly choose an identity each time. This does not revoke Google
    // consent, change the Mixtape session, or request extra data scopes.
    await _google.signOut();
    final account = await _google.authenticate();
    return account.authentication.idToken;
  }
}

class RealGoogleAuthGateway implements GoogleAuthGateway {
  RealGoogleAuthGateway({
    GoogleNativeSdk? sdk,
    this.configuration = const GoogleAuthConfiguration(),
    bool? supportedPlatform,
  }) : _sdk = sdk ?? _OfficialGoogleSdk(),
       _supportedPlatform =
           supportedPlatform ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final GoogleNativeSdk _sdk;
  final GoogleAuthConfiguration configuration;
  final bool _supportedPlatform;
  bool _busy = false;
  bool _initialized = false;

  @override
  bool get isAvailable => _supportedPlatform && configuration.isConfigured;

  @override
  Future<String> getIdentityToken() async {
    if (!isAvailable) throw const GoogleSignInUnavailable();
    if (_busy) throw const GoogleSignInBusy();
    _busy = true;
    try {
      if (!_initialized) {
        await _sdk.initialize(
          clientId: configuration.iosClientId,
          serverClientId: configuration.serverClientId,
        );
        _initialized = true;
      }
      final token = await _sdk.authenticateIdentityToken();
      if (token == null || token.trim().isEmpty) {
        throw const GoogleSignInFailed();
      }
      return token;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const GoogleSignInCancelled();
      }
      if (error.code == GoogleSignInExceptionCode.clientConfigurationError ||
          error.code == GoogleSignInExceptionCode.providerConfigurationError) {
        throw const GoogleSignInUnavailable();
      }
      throw const GoogleSignInFailed();
    } on GoogleSignInUnavailable {
      rethrow;
    } catch (_) {
      throw const GoogleSignInFailed();
    } finally {
      _busy = false;
    }
  }
}
