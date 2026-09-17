import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/sign_in_preference_store.dart';
import 'package:mixtape/data/auth/token_store.dart';

class _Apple implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => 'apple-id';
}

class _Google implements GoogleAuthGateway {
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'google-id';
}

class _BrokenHint implements SignInPreferenceStore {
  @override
  Future<AccountProvider?> read() async => null;
  @override
  Future<void> write(AccountProvider provider) async =>
      throw StateError('storage unavailable');
}

void main() {
  test('hint parser accepts only known provider identifiers', () {
    expect(SignInPreferenceStore.parse('apple'), AccountProvider.apple);
    expect(SignInPreferenceStore.parse('google'), AccountProvider.google);
    for (final value in [null, '', 'token', 'user@example.test', 'GOOGLE']) {
      expect(SignInPreferenceStore.parse(value), isNull);
    }
  });
  test(
    'only successful sign-in changes hint and sign-out retains it',
    () async {
      final tokens = InMemoryTokenStore();
      final hints = InMemorySignInPreferenceStore();
      var reject = false;
      final repo = AuthRepository(
        tokenStore: tokens,
        gateway: _Apple(),
        googleGateway: _Google(),
        preferenceStore: hints,
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: tokens,
          inner: MockClient(
            (_) async => reject
                ? http.Response('{"code":"INVALID_TOKEN"}', 401)
                : http.Response(
                    '{}',
                    200,
                    headers: {'set-auth-token': 'session'},
                  ),
          ),
        ),
      );
      await repo.signInWithGoogle();
      expect(await hints.read(), AccountProvider.google);
      await repo.signOut();
      expect(await hints.read(), AccountProvider.google);
      expect(await tokens.read(), isNull);
      reject = true;
      await expectLater(repo.signInWithApple(), throwsA(isA<ApiException>()));
      expect(await hints.read(), AccountProvider.google);
    },
  );
  test(
    'optional hint storage failure cannot turn successful login into failure',
    () async {
      final tokens = InMemoryTokenStore();
      final repo = AuthRepository(
        tokenStore: tokens,
        gateway: _Apple(),
        preferenceStore: _BrokenHint(),
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: tokens,
          inner: MockClient(
            (_) async => http.Response(
              '{}',
              200,
              headers: {'set-auth-token': 'session'},
            ),
          ),
        ),
      );
      await repo.signInWithApple();
      expect(await tokens.read(), 'session');
    },
  );
}
