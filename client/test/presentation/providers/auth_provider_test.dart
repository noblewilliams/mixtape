import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';

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
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'google-id';
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
  InMemoryTokenStore store,
) {
  final requests = <(String, String?)>[];
  final container = ProviderContainer(overrides: [
    tokenStoreProvider.overrideWithValue(store),
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
}
