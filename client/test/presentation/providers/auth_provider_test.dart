import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/name_page_store.dart';
import 'package:mixtape/data/auth/sign_in_preference_store.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/name_page_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart'
    show authorStoreProvider;

import '../../helpers/fake_listening_api.dart';

class ThrowingTokenStore implements TokenStore {
  @override
  Future<String?> read() async => throw StateError('keychain unavailable');
  @override
  Future<bool> readAnonymous() async => throw StateError('keychain unavailable');
  @override
  Future<void> write(String token, {bool anonymous = false}) async {}
  @override
  Future<void> clear() async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _Google implements GoogleAuthGateway {
  int disconnects = 0;
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'google-id';
  @override
  Future<void> disconnect() async => disconnects++;
}

/// Holds a session and flips the flag the way AuthNotifier's private setter
/// does: a notify with no status change.
class _FlippableAuth extends AuthNotifier {
  bool _flag = true;
  @override
  bool get isAnonymous => _flag;
  @override
  AuthStatus build() => AuthStatus.session;
  void flip(bool value) {
    _flag = value;
    ref.notifyListeners();
  }
}

/// A container whose API answers the anonymous and social sign-in endpoints,
/// recording each request's path and Authorization header.
({ProviderContainer container, List<(String, String?)> requests}) _authHarness(
  InMemoryTokenStore store, {
  NamePageStore? names,
}) {
  final requests = <(String, String?)>[];
  final container = ProviderContainer(overrides: [
    tokenStoreProvider.overrideWithValue(store),
    if (names != null) namePageStoreProvider.overrideWithValue(names),
    googleAuthGatewayProvider.overrideWithValue(_Google()),
    apiClientProvider.overrideWithValue(ApiClient(
      baseUrl: 'https://example.test',
      tokenStore: store,
      inner: MockClient((req) async {
        requests.add((req.url.path, req.headers['Authorization']));
        final token = req.url.path == '/api/auth/sign-in/anonymous'
            ? 'anon-token'
            : 'account-token';
        return http.Response('{}', 200, headers: {'set-auth-token': token});
      }),
    )),
  ]);
  return (container: container, requests: requests);
}

void main() {
  test('empty store settles on noSession', () async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.noSession);
  });

  test('store seeded with a token settles on session', () async {
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.session);
  });

  test('a TokenStore whose read() throws settles on noSession, not stuck on unknown', () async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(ThrowingTokenStore()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.noSession);
  });

  test('signOut() moves to noSession and empties the store', () async {
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();
    expect(container.read(authProvider), AuthStatus.session);

    await container.read(authProvider.notifier).signOut();

    expect(container.read(authProvider), AuthStatus.noSession);
    expect(await store.read(), isNull);
  });

  test('signOut() forgets the device-local state of the departing listener: the service '
      'flag, the funnel milestones, and the request reminder', () async {
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('u1', 'spotify');
    final milestones = InMemoryFunnelOnceStore();
    await milestones.mark('u1', FunnelEventType.firstOutput);
    final reminders = FakeReminderScheduler();
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
      servicePreferenceStoreProvider.overrideWithValue(prefs),
      funnelOnceStoreProvider.overrideWithValue(milestones),
      reminderSchedulerProvider.overrideWithValue(reminders),
    ]);
    addTearDown(container.dispose);
    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();
    expect(container.read(authProvider), AuthStatus.session);

    await container.read(authProvider.notifier).signOut();

    expect(container.read(authProvider), AuthStatus.noSession);
    expect(await prefs.read('u1'), isNull);
    expect(await milestones.has('u1', FunnelEventType.firstOutput), isFalse);
    expect(reminders.cancelled, 1);
  });

  group('three-way status and isAnonymous', () {
    test('an anonymous token settles on session with isAnonymous true',
        () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);

      expect(container.read(authProvider), AuthStatus.unknown);
      await _settle();

      expect(container.read(authProvider), AuthStatus.session);
      expect(container.read(authProvider.notifier).isAnonymous, isTrue);
    });

    test('an account token settles on session with isAnonymous false',
        () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.read(authProvider);
      await _settle();

      expect(container.read(authProvider), AuthStatus.session);
      expect(container.read(authProvider.notifier).isAnonymous, isFalse);
    });

    test('an empty store is noSession and not anonymous', () async {
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      ]);
      addTearDown(container.dispose);
      container.read(authProvider);
      await _settle();

      expect(container.read(authProvider), AuthStatus.noSession);
      expect(container.read(authProvider.notifier).isAnonymous, isFalse);
    });

    test('signInAnonymously moves noSession to an anonymous session and '
        'stores the flagged token', () async {
      final store = InMemoryTokenStore();
      final h = _authHarness(store);
      addTearDown(h.container.dispose);
      h.container.read(authProvider);
      await _settle();
      expect(h.container.read(authProvider), AuthStatus.noSession);

      await h.container.read(authProvider.notifier).signInAnonymously();

      expect(h.container.read(authProvider), AuthStatus.session);
      expect(h.container.read(authProvider.notifier).isAnonymous, isTrue);
      expect(h.requests.single, ('/api/auth/sign-in/anonymous', null));
      expect(await store.read(), 'anon-token');
      expect(await store.readAnonymous(), isTrue);
    });

    test('signing in from an anonymous session sends the anonymous bearer, '
        'lands on an account session and resets user-scoped providers',
        () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final h = _authHarness(store);
      addTearDown(h.container.dispose);
      var builds = 0;
      final userScoped = Provider<int>((ref) {
        ref.watch(authProvider);
        return ++builds;
      });
      h.container.listen(userScoped, (_, __) {});
      await _settle();
      expect(h.container.read(authProvider), AuthStatus.session);
      expect(h.container.read(authProvider.notifier).isAnonymous, isTrue);
      final before = h.container.read(userScoped);

      await h.container
          .read(authProvider.notifier)
          .signIn(provider: AccountProvider.google);
      await _settle();

      expect(h.requests.single,
          ('/api/auth/sign-in/social', 'Bearer anon-token'));
      expect(h.container.read(authProvider), AuthStatus.session);
      expect(h.container.read(authProvider.notifier).isAnonymous, isFalse);
      expect(h.container.read(userScoped), greaterThan(before));
      expect(await store.read(), 'account-token');
      expect(await store.readAnonymous(), isFalse);
    });

    test('a sign-in resets the name page flag before the session lands, so '
        'the root waits for /me (2026-11-02 profile name)', () async {
      final store = InMemoryTokenStore();
      final names = InMemoryNamePageStore(settled: true);
      final h = _authHarness(store, names: names);
      final c = h.container;
      addTearDown(c.dispose);
      c.listen(namePageSettledProvider, (_, _) {});
      await _settle();
      expect(c.read(namePageSettledProvider), isTrue);

      bool? atSession;
      c.listen<AuthStatus>(authProvider, (_, next) {
        if (next == AuthStatus.session) {
          atSession = c.read(namePageSettledProvider);
        }
      });
      await c.read(authProvider.notifier).signIn(provider: AccountProvider.google);
      await _settle();
      expect(atSession, isFalse);
      expect(await names.read(), isFalse);
    });

    test('signing out of an anonymous session clears anonymity', () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.read(authProvider);
      await _settle();

      await container.read(authProvider.notifier).signOut();

      expect(container.read(authProvider), AuthStatus.noSession);
      expect(container.read(authProvider.notifier).isAnonymous, isFalse);
      expect(await store.readAnonymous(), isFalse);
    });
  });

  group('signInAnonymously guards', () {
    test('from an account session it returns without a request and keeps '
        'the account token', () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final h = _authHarness(store);
      addTearDown(h.container.dispose);
      h.container.read(authProvider);
      await _settle();
      expect(h.container.read(authProvider), AuthStatus.session);

      await h.container.read(authProvider.notifier).signInAnonymously();

      expect(h.requests, isEmpty);
      expect(await store.read(), 'account-token');
      expect(await store.readAnonymous(), isFalse);
      expect(h.container.read(authProvider.notifier).isAnonymous, isFalse);
    });

    test('before restore settles it throws a StateError and sends nothing',
        () async {
      final store = InMemoryTokenStore();
      final h = _authHarness(store);
      addTearDown(h.container.dispose);
      expect(h.container.read(authProvider), AuthStatus.unknown);

      await expectLater(
        h.container.read(authProvider.notifier).signInAnonymously(),
        throwsA(isA<StateError>()),
      );
      expect(h.requests, isEmpty);
      expect(await store.read(), isNull);
    });
  });

  group('isAnonymousProvider', () {
    test('a watcher rebuilds when the flag flips without a status change',
        () async {
      final auth = _FlippableAuth();
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(() => auth),
      ]);
      addTearDown(container.dispose);
      var builds = 0;
      final watcher = Provider<bool>((ref) {
        builds++;
        return ref.watch(isAnonymousProvider);
      });
      container.listen(watcher, (_, __) {});
      expect(container.read(watcher), isTrue);
      final before = builds;

      auth.flip(false);

      expect(container.read(authProvider), AuthStatus.session);
      expect(container.read(watcher), isFalse);
      expect(builds, before + 1);
    });

    test('the link flips the flag with a session -> session notification '
        'and lands not anonymous', () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final h = _authHarness(store);
      addTearDown(h.container.dispose);
      final log = <String>[];
      h.container.listen<AuthStatus>(
        authProvider,
        (prev, next) => log.add('$prev -> $next'),
      );
      await _settle();
      expect(h.container.read(isAnonymousProvider), isTrue);
      log.clear();

      await h.container
          .read(authProvider.notifier)
          .signIn(provider: AccountProvider.google);
      await _settle();

      // The setter's notifyListeners, before the link's rebuild.
      expect(log.first, 'AuthStatus.session -> AuthStatus.session');
      expect(h.container.read(isAnonymousProvider), isFalse);
      expect(h.container.read(authProvider), AuthStatus.session);
    });

    test('follows the restored flag and sign-out', () async {
      final store = InMemoryTokenStore();
      await store.write('anon-token', anonymous: true);
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.listen<bool>(isAnonymousProvider, (_, __) {});
      expect(container.read(isAnonymousProvider), isFalse);
      await _settle();
      expect(container.read(isAnonymousProvider), isTrue);

      await container.read(authProvider.notifier).signOut();

      expect(container.read(isAnonymousProvider), isFalse);
    });
  });

  group('deleteAccount', () {
    ({
      ProviderContainer container,
      List<(String, String, String)> requests,
      InMemorySignInPreferenceStore hints,
      InMemoryServicePreferenceStore prefs,
      FakeReminderScheduler reminders,
      InMemoryAuthorStore author,
      _Google google,
    }) deleteHarness(
      InMemoryTokenStore store, {
      int status = 200,
      Future<void>? hold,
    }) {
      final requests = <(String, String, String)>[];
      final hints = InMemorySignInPreferenceStore();
      final author = InMemoryAuthorStore('Noble');
      final google = _Google();
      final prefs = InMemoryServicePreferenceStore();
      final reminders = FakeReminderScheduler();
      final container = ProviderContainer(overrides: [
        tokenStoreProvider.overrideWithValue(store),
        googleAuthGatewayProvider.overrideWithValue(google),
        signInPreferenceStoreProvider.overrideWithValue(hints),
        authorStoreProvider.overrideWithValue(author),
        servicePreferenceStoreProvider.overrideWithValue(prefs),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        reminderSchedulerProvider.overrideWithValue(reminders),
        apiClientProvider.overrideWithValue(ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient((req) async {
            requests.add((req.method, req.url.path, req.body));
            if (hold != null) await hold;
            return status == 200
                ? http.Response('{"deleted":true,"apple":"revoked"}', 200)
                : http.Response('{"error":"internal"}', status);
          }),
        )),
      ]);
      return (
        container: container,
        requests: requests,
        hints: hints,
        prefs: prefs,
        reminders: reminders,
        author: author,
        google: google,
      );
    }

    test('deletes on the server, then forgets everything locally without a '
        'sign-out request', () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final h = deleteHarness(store);
      addTearDown(h.container.dispose);
      await h.hints.write(AccountProvider.apple);
      await h.prefs.write('u1', 'apple');
      var builds = 0;
      final userScoped = Provider<int>((ref) {
        ref.watch(authProvider);
        return ++builds;
      });
      h.container.listen(userScoped, (_, __) {});
      await _settle();
      expect(h.container.read(authProvider), AuthStatus.session);
      final before = h.container.read(userScoped);

      await h.container
          .read(authProvider.notifier)
          .deleteAccount(appleAuthorizationCode: 'apple-code');

      expect(h.requests, hasLength(1));
      expect(h.requests.single.$1, 'DELETE');
      expect(h.requests.single.$2, '/me');
      expect(
        jsonDecode(h.requests.single.$3),
        {'appleAuthorizationCode': 'apple-code'},
      );
      expect(h.container.read(authProvider), AuthStatus.noSession);
      expect(h.container.read(authProvider.notifier).isAnonymous, isFalse);
      expect(h.container.read(userScoped), greaterThan(before));
      expect(await store.read(), isNull);
      expect(await h.hints.read(), isNull);
      expect(await h.prefs.read('u1'), isNull);
      expect(h.reminders.cancelled, 1);
      expect(await h.author.read(), isNull);
      expect(h.google.disconnects, 1);
    });

    test('a 401 means the account is already gone: forget it locally',
        () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final h = deleteHarness(store, status: 401);
      addTearDown(h.container.dispose);
      await h.hints.write(AccountProvider.apple);
      h.container.read(authProvider);
      await _settle();

      await h.container.read(authProvider.notifier).deleteAccount();

      expect(h.container.read(authProvider), AuthStatus.noSession);
      expect(await store.read(), isNull);
      expect(await h.hints.read(), isNull);
      expect(await h.author.read(), isNull);
    });

    test('a sign-out landing mid-delete still gets the full local cleanup',
        () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final release = Completer<void>();
      final h = deleteHarness(store, hold: release.future);
      addTearDown(h.container.dispose);
      await h.hints.write(AccountProvider.google);
      h.container.read(authProvider);
      await _settle();

      final deleting = h.container.read(authProvider.notifier).deleteAccount();
      await _settle();
      await h.container.read(authProvider.notifier).signOut();
      release.complete();
      await deleting;

      expect(h.container.read(authProvider), AuthStatus.noSession);
      expect(await h.hints.read(), isNull);
      expect(await h.author.read(), isNull);
      expect(h.google.disconnects, 1);
    });

    test('a failed delete keeps the session and the token', () async {
      final store = InMemoryTokenStore();
      await store.write('account-token');
      final h = deleteHarness(store, status: 500);
      addTearDown(h.container.dispose);
      await h.hints.write(AccountProvider.google);
      h.container.read(authProvider);
      await _settle();

      await expectLater(
        h.container.read(authProvider.notifier).deleteAccount(),
        throwsA(isA<ApiException>()),
      );

      expect(h.requests.single.$3, isEmpty);
      expect(h.container.read(authProvider), AuthStatus.session);
      expect(await store.read(), 'account-token');
      expect(await h.hints.read(), AccountProvider.google);
      expect(h.reminders.cancelled, 0);
      expect(await h.author.read(), 'Noble');
    });
  });
}
