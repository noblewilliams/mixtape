import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Future<void> write(String token) async {}
  @override
  Future<void> clear() async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('empty store settles on signedOut', () async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.signedOut);
  });

  test('store seeded with a token settles on signedIn', () async {
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.signedIn);
  });

  test('a TokenStore whose read() throws settles on signedOut, not stuck on unknown', () async {
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(ThrowingTokenStore()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();

    expect(container.read(authProvider), AuthStatus.signedOut);
  });

  test('signOut() moves to signedOut and empties the store', () async {
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final container = ProviderContainer(overrides: [
      tokenStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    expect(container.read(authProvider), AuthStatus.unknown);
    await _settle();
    expect(container.read(authProvider), AuthStatus.signedIn);

    await container.read(authProvider.notifier).signOut();

    expect(container.read(authProvider), AuthStatus.signedOut);
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
    expect(container.read(authProvider), AuthStatus.signedIn);

    await container.read(authProvider.notifier).signOut();

    expect(container.read(authProvider), AuthStatus.signedOut);
    expect(await prefs.read('u1'), isNull);
    expect(await milestones.has('u1', FunnelEventType.firstOutput), isFalse);
    expect(reminders.cancelled, 1);
  });
}
