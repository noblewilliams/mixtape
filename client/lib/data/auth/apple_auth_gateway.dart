import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Thin seam over sign_in_with_apple so tests can fake the native dialog.
abstract class AppleAuthGateway {
  Future<String> getIdentityToken();
}

/// Thrown when the user dismisses the native Apple sign-in sheet.
/// Callers (screens) should treat this as a no-op, not an error.
class AppleSignInCancelled implements Exception {}

class RealAppleAuthGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      );
      final token = credential.identityToken;
      if (token == null) throw StateError('Apple returned no identity token');
      return token;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw AppleSignInCancelled();
      rethrow;
    }
  }
}
