import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';

class Apple implements AppleAuthGateway {
  Future<String> Function()? onToken;
  @override
  Future<String> getIdentityToken() async =>
      onToken == null ? 'apple-id' : onToken!();
}

class Google implements GoogleAuthGateway {
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'google-id';
}

class SlowStore extends InMemoryTokenStore {
  final writing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String token) async {
    if (!writing.isCompleted) writing.complete();
    await release.future;
    await super.write(token);
  }
}

void main() {
  test(
    'Google uses direct ID exchange and stores only the returned session',
    () async {
      final store = InMemoryTokenStore();
      final repo = AuthRepository(
        tokenStore: store,
        gateway: Apple(),
        googleGateway: Google(),
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient((request) async {
            expect(request.url.path, '/api/auth/sign-in/social');
            expect(jsonDecode(request.body), {
              'provider': 'google',
              'idToken': {'token': 'google-id'},
            });
            return http.Response(
              '{}',
              200,
              headers: {'set-auth-token': 'session-token'},
            );
          }),
        ),
      );
      await repo.signInWithGoogle();
      expect(await store.read(), 'session-token');
    },
  );
  test(
    'parallel sign-in is blocked and sign-out discards a late identity result',
    () async {
      final token = Completer<String>();
      final store = InMemoryTokenStore();
      var calls = 0;
      final repo = AuthRepository(
        tokenStore: store,
        gateway: Apple()..onToken = () => token.future,
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient((_) async {
            calls++;
            return http.Response(
              '{}',
              200,
              headers: {'set-auth-token': 'late'},
            );
          }),
        ),
      );
      final first = repo.signInWithApple();
      await expectLater(
        repo.signInWithApple(),
        throwsA(isA<AuthOperationBusy>()),
      );
      await repo.signOut();
      token.complete('late-identity');
      await expectLater(first, throwsA(isA<AuthOperationCancelled>()));
      expect(calls, 0);
      expect(await store.read(), isNull);
    },
  );
  test('sign-out wins when a token store write has already started', () async {
    final store = SlowStore();
    final repo = AuthRepository(
      tokenStore: store,
      gateway: Apple(),
      api: ApiClient(
        baseUrl: 'https://example.test',
        tokenStore: store,
        inner: MockClient(
          (_) async =>
              http.Response('{}', 200, headers: {'set-auth-token': 'late'}),
        ),
      ),
    );
    final first = repo.signInWithApple();
    await store.writing.future;
    final out = repo.signOut();
    store.release.complete();
    await expectLater(first, throwsA(isA<AuthOperationCancelled>()));
    await out;
    expect(await store.read(), isNull);
  });
  test(
    'disposal clears a write already in flight before a replacement repository writes',
    () async {
      final store = SlowStore();
      AuthRepository makeRepo(String token) => AuthRepository(
        tokenStore: store,
        gateway: Apple(),
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient(
            (_) async =>
                http.Response('{}', 200, headers: {'set-auth-token': token}),
          ),
        ),
      );
      final old = makeRepo('old');
      final first = old.signInWithApple();
      await store.writing.future;
      old.dispose();
      store.release.complete();
      await expectLater(first, throwsA(isA<AuthOperationCancelled>()));
      expect(await store.read(), isNull);
      // A subsequent session must survive cleanup from the disposed repository.
      await makeRepo('new').signInWithApple();
      expect(await store.read(), 'new');
    },
  );
  test('blank bearer and identity tokens are rejected', () async {
    for (final blankIdentity in [true, false]) {
      final store = InMemoryTokenStore();
      var calls = 0;
      final repo = AuthRepository(
        tokenStore: store,
        gateway: Apple()..onToken = () async => blankIdentity ? ' ' : 'id',
        api: ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient((_) async {
            calls++;
            return http.Response('{}', 200, headers: {'set-auth-token': ' '});
          }),
        ),
      );
      await expectLater(repo.signInWithApple(), throwsA(isA<StateError>()));
      expect(await store.read(), isNull);
      expect(calls, blankIdentity ? 0 : 1);
    }
  });
}
