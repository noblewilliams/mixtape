import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'identity_token.dart';

/// Thin seam over sign_in_with_apple so tests can fake the native dialog.
abstract class AppleAuthGateway {
  /// The identity token, plus the given and family names Apple discloses only
  /// on the user's first-ever authorization (null otherwise).
  Future<IdentityToken> getIdentityToken();

  /// A fresh one-time code from the native sheet, asking for no scopes. The
  /// server exchanges it to revoke Apple's tokens when an account is deleted.
  Future<String> getAuthorizationCode();
}

/// Thrown when the user dismisses the native Apple sign-in sheet.
/// Callers (screens) should treat this as a no-op, not an error.
class AppleSignInCancelled implements Exception {}

class RealAppleAuthGateway implements AppleAuthGateway {
  @override
  Future<IdentityToken> getIdentityToken() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      );
      final token = credential.identityToken;
      if (token == null) throw StateError('Apple returned no identity token');
      return IdentityToken(
        token,
        givenName: credential.givenName,
        familyName: credential.familyName,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw AppleSignInCancelled();
      rethrow;
    }
  }

  @override
  Future<String> getAuthorizationCode() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(scopes: []);
      final code = credential.authorizationCode;
      if (code.trim().isEmpty) throw StateError('Apple returned no authorization code');
      return code;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw AppleSignInCancelled();
      rethrow;
    }
  }
}
