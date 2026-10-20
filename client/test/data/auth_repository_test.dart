import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/token_store.dart';

class FakeGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => 'apple-id-token';
}

class CancellingGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => throw AppleSignInCancelled();
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
      tokenStore: store,
      gateway: FakeGateway(),
      api: ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner),
    );

    await repo.signInWithApple();

    expect(sentBody['provider'], 'apple');
    expect(sentBody['idToken'], {'token': 'apple-id-token'});
    expect(await store.read(), 'bearer-abc');
  });

  test('throws when the server omits set-auth-token', () async {
    final store = InMemoryTokenStore();
    final repo = AuthRepository(
      tokenStore: store,
      gateway: FakeGateway(),
      api: ApiClient(
        baseUrl: 'http://x',
        tokenStore: store,
        inner: MockClient((_) async => http.Response('{"user":{}}', 200)),
      ),
    );
    await expectLater(repo.signInWithApple(), throwsA(isA<StateError>()));
  });

  test('surfaces server rejection without storing a token', () async {
    final store = InMemoryTokenStore();
    final repo = AuthRepository(
      tokenStore: store,
      gateway: FakeGateway(),
      api: ApiClient(
        baseUrl: 'http://x',
        tokenStore: store,
        inner: MockClient((_) async => http.Response('{"error":"bad token"}', 401)),
      ),
    );
    await expectLater(repo.signInWithApple(), throwsA(isA<ApiException>()));
    expect(await store.read(), isNull);
  });

  test('signOut clears the token', () async {
    final store = InMemoryTokenStore();
    await store.write('t');
    final repo = AuthRepository(
      tokenStore: store,
      gateway: FakeGateway(),
      api: ApiClient(
        baseUrl: 'http://x',
        tokenStore: store,
        inner: MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    await repo.signOut();
    expect(await store.read(), isNull);
  });

  test('sign-in throws NetworkException on a slow server and stores nothing', () async {
    final store = InMemoryTokenStore();
    final inner = MockClient((req) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response('{"user":{}}', 200, headers: {'set-auth-token': 'bearer-abc'});
    });
    final repo = AuthRepository(
      tokenStore: store,
      gateway: FakeGateway(),
      api: ApiClient(
        baseUrl: 'http://x',
        tokenStore: store,
        inner: inner,
        timeout: const Duration(milliseconds: 50),
      ),
    );

    await expectLater(repo.signInWithApple(), throwsA(isA<NetworkException>()));
    expect(await store.read(), isNull);
  });

  test('sign-in rethrows AppleSignInCancelled and makes no HTTP request', () async {
    final store = InMemoryTokenStore();
    var requested = false;
    final repo = AuthRepository(
      tokenStore: store,
      gateway: CancellingGateway(),
      api: ApiClient(
        baseUrl: 'http://x',
        tokenStore: store,
        inner: MockClient((_) async {
          requested = true;
          return http.Response('{}', 200);
        }),
      ),
    );

    await expectLater(repo.signInWithApple(), throwsA(isA<AppleSignInCancelled>()));
    expect(requested, isFalse);
    expect(await store.read(), isNull);
  });

  group('anonymous sessions', () {
    test('signInAnonymously posts to the anonymous endpoint and stores the '
        'token flagged anonymous', () async {
      final store = InMemoryTokenStore();
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((req) async {
            expect(req.method, 'POST');
            expect(req.url.path, '/api/auth/sign-in/anonymous');
            expect(req.headers.containsKey('Authorization'), isFalse);
            return http.Response('{"user":{"isAnonymous":true}}', 200,
                headers: {'set-auth-token': 'anon-token'});
          }),
        ),
      );

      await repo.signInAnonymously();

      expect(await store.read(), 'anon-token');
      expect(await store.readAnonymous(), isTrue);
      expect(await repo.storedSession(), StoredSession.anonymous);
    });

    test('signInAnonymously without set-auth-token stores nothing', () async {
      final store = InMemoryTokenStore();
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
      await expectLater(repo.signInAnonymously(), throwsA(isA<StateError>()));
      expect(await store.read(), isNull);
    });

    test('social sign-in carries the stored anonymous bearer token so the '
        'server can link, then stores the new account token', () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      String? sentAuth;
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((req) async {
            expect(req.url.path, '/api/auth/sign-in/social');
            sentAuth = req.headers['Authorization'];
            return http.Response('{"user":{}}', 200,
                headers: {'set-auth-token': 'account-token'});
          }),
        ),
      );

      await repo.signInWithApple();

      expect(sentAuth, 'Bearer anon-token');
      expect(await store.read(), 'account-token');
      expect(await store.readAnonymous(), isFalse);
      expect(await repo.storedSession(), StoredSession.account);
    });

    test('social sign-in with no stored token sends no Authorization header',
        () async {
      final store = InMemoryTokenStore();
      var sawAuth = true;
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((req) async {
            sawAuth = req.headers.containsKey('Authorization');
            return http.Response('{"user":{}}', 200,
                headers: {'set-auth-token': 'account-token'});
          }),
        ),
      );

      await repo.signInWithApple();

      expect(sawAuth, isFalse);
      expect(await repo.storedSession(), StoredSession.account);
    });

    test('a failed link keeps the anonymous token and its flag', () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((_) async => http.Response('{"code":"X"}', 500)),
        ),
      );
      await expectLater(
          repo.signInWithApple(), throwsA(isA<AuthSignInException>()));
      expect(await store.read(), 'anon-token');
      expect(await repo.storedSession(), StoredSession.anonymous);
    });

    test('storedSession is none for an empty store', () async {
      final store = InMemoryTokenStore();
      final repo = AuthRepository(
        tokenStore: store,
        gateway: FakeGateway(),
        api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: store,
          inner: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
      expect(await repo.storedSession(), StoredSession.none);
    });
  });
}
