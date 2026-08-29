import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/token_store.dart';

class FakeGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => 'apple-id-token';
}

void main() {
  test('signs in: posts idToken, stores bearer token from header', () async {
    late Map<String, dynamic> sentBody;
    final inner = MockClient((req) async {
      expect(req.url.path, '/api/auth/sign-in/social');
      sentBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{"user":{}}', 200, headers: {'set-auth-token': 'bearer-abc'});
    });
    final store = InMemoryTokenStore();
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: store,
      gateway: FakeGateway(),
      inner: inner,
    );

    await repo.signInWithApple();

    expect(sentBody['provider'], 'apple');
    expect(sentBody['idToken'], {'token': 'apple-id-token'});
    expect(await store.read(), 'bearer-abc');
  });

  test('throws when the server omits set-auth-token', () async {
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      gateway: FakeGateway(),
      inner: MockClient((_) async => http.Response('{"user":{}}', 200)),
    );
    await expectLater(repo.signInWithApple(), throwsA(isA<StateError>()));
  });

  test('surfaces server rejection without storing a token', () async {
    final store = InMemoryTokenStore();
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: store,
      gateway: FakeGateway(),
      inner: MockClient((_) async => http.Response('{"error":"bad token"}', 401)),
    );
    await expectLater(repo.signInWithApple(), throwsA(anything));
    expect(await store.read(), isNull);
  });

  test('signOut clears the token', () async {
    final store = InMemoryTokenStore();
    await store.write('t');
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: store,
      gateway: FakeGateway(),
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    await repo.signOut();
    expect(await store.read(), isNull);
  });
}
