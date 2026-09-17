import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';

class _Apple implements AppleAuthGateway {
  final token = Completer<String>();
  @override
  Future<String> getIdentityToken() => token.future;
}

class _Google implements GoogleAuthGateway {
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'google-token';
}

void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  test(
    'Google transitions only after successful exchange; default Apple stays compatible',
    () async {
      final store = InMemoryTokenStore();
      final apple = _Apple();
      final response = Completer<http.Response>();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          appleAuthGatewayProvider.overrideWithValue(apple),
          googleAuthGatewayProvider.overrideWithValue(_Google()),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: 'https://example.test',
              tokenStore: store,
              inner: MockClient((_) => response.future),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider);
      await settle();
      final notifier = container.read(authProvider.notifier);
      final request = notifier.signIn(provider: AccountProvider.google);
      expect(container.read(authProvider), AuthStatus.signedOut);
      await expectLater(notifier.signIn(), throwsA(isA<AuthOperationBusy>()));
      response.complete(
        http.Response('{}', 200, headers: {'set-auth-token': 'session'}),
      );
      await request;
      expect(container.read(authProvider), AuthStatus.signedIn);
    },
  );
  test(
    'sign-out during native chooser discards completion and leaves protected state signed out',
    () async {
      final store = InMemoryTokenStore();
      final apple = _Apple();
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          appleAuthGatewayProvider.overrideWithValue(apple),
          apiClientProvider.overrideWithValue(
            ApiClient(
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
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider);
      await settle();
      final notifier = container.read(authProvider.notifier);
      final request = notifier.signIn();
      await notifier.signOut();
      apple.token.complete('late-identity');
      await expectLater(request, throwsA(isA<AuthOperationCancelled>()));
      expect(container.read(authProvider), AuthStatus.signedOut);
      expect(await store.read(), isNull);
      expect(calls, 0);
    },
  );
  test(
    'invalidating during login does not leave the rebuilt notifier busy forever',
    () async {
      final store = InMemoryTokenStore();
      final apple = _Apple();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          appleAuthGatewayProvider.overrideWithValue(apple),
          googleAuthGatewayProvider.overrideWithValue(_Google()),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: 'https://example.test',
              tokenStore: store,
              inner: MockClient(
                (_) async => http.Response(
                  '{}',
                  200,
                  headers: {'set-auth-token': 'new'},
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider);
      await settle();
      final request = container.read(authProvider.notifier).signIn();
      container.invalidate(authProvider);
      container.read(authProvider);
      await settle();
      apple.token.complete('old');
      await expectLater(request, throwsA(isA<AuthOperationCancelled>()));
      expect(await store.read(), isNull);
      await container
          .read(authProvider.notifier)
          .signIn(provider: AccountProvider.google);
      expect(container.read(authProvider), AuthStatus.signedIn);
      expect(await store.read(), 'new');
    },
  );
  test(
    'disposed auth cannot publish a late Google exchange or persist its token',
    () async {
      final store = InMemoryTokenStore();
      final response = Completer<http.Response>();
      final requested = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          googleAuthGatewayProvider.overrideWithValue(_Google()),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: 'https://example.test',
              tokenStore: store,
              inner: MockClient((_) {
                requested.complete();
                return response.future;
              }),
            ),
          ),
        ],
      );
      container.read(authProvider);
      await settle();
      final request = container
          .read(authProvider.notifier)
          .signIn(provider: AccountProvider.google);
      await requested.future;
      container.dispose();
      response.complete(
        http.Response('{}', 200, headers: {'set-auth-token': 'late'}),
      );
      await expectLater(request, throwsA(isA<AuthOperationCancelled>()));
      expect(await store.read(), isNull);
    },
  );
}
