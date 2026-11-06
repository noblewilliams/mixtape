import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/play_destination_provider.dart';

class _BrokenStore implements PlayDestinationStore {
  @override
  Future<PlayDestination?> read() async => throw Exception('no keychain');
  @override
  Future<void> write(PlayDestination destination) async =>
      throw Exception('no keychain');
  @override
  Future<bool> spotifyIntroSeen() async => throw Exception('no keychain');
  @override
  Future<void> markSpotifyIntroSeen() async => throw Exception('no keychain');
}

void main() {
  test('Spotify is a destination of its own, on the wire as spotify', () {
    expect(PlayDestination.spotify.wire, 'spotify');
    expect(PlayDestination.fromWire('spotify'), PlayDestination.spotify);
  });

  test('the Spotify explainer is remembered as seen on the device', () async {
    final store = InMemoryPlayDestinationStore();
    expect(await store.spotifyIntroSeen(), isFalse);
    await store.markSpotifyIntroSeen();
    expect(await store.spotifyIntroSeen(), isTrue);
  });

  test('nothing is chosen until the listener chooses or the store says', () async {
    final container = ProviderContainer(
      overrides: [
        playDestinationStoreProvider.overrideWithValue(
          InMemoryPlayDestinationStore(PlayDestination.appleMusic),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(playDestinationProvider), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(playDestinationProvider), PlayDestination.appleMusic);
  });

  test('a choice is remembered on the device', () async {
    final store = InMemoryPlayDestinationStore();
    final container = ProviderContainer(
      overrides: [playDestinationStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(playDestinationProvider);
    await container
        .read(playDestinationProvider.notifier)
        .choose(PlayDestination.appleMusic);
    expect(container.read(playDestinationProvider), PlayDestination.appleMusic);
    expect(await store.read(), PlayDestination.appleMusic);
  });

  test('a store that fails leaves nothing chosen and still takes choices', () async {
    final container = ProviderContainer(
      overrides: [
        playDestinationStoreProvider.overrideWithValue(_BrokenStore()),
      ],
    );
    addTearDown(container.dispose);
    container.read(playDestinationProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(playDestinationProvider), isNull);
    await container
        .read(playDestinationProvider.notifier)
        .choose(PlayDestination.appleMusic);
    expect(container.read(playDestinationProvider), PlayDestination.appleMusic);
  });
}
