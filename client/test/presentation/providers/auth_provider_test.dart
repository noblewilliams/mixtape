import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';

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
}
