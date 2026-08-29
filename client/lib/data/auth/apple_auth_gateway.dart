import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Thin seam over sign_in_with_apple so tests can fake the native dialog.
abstract class AppleAuthGateway {
  Future<String> getIdentityToken();
}

class RealAppleAuthGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
    );
    final token = credential.identityToken;
    if (token == null) throw StateError('Apple returned no identity token');
    return token;
  }
}
