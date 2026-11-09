// One platform per device (decision 1 of
// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`): the
// remembered answer, the legacy Play destinations it replaces, and the
// service the listener already told us about, written silently.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

class _BrokenStore implements MusicPlatformStore {
  @override
  Future<MusicPlatform?> read() async => throw Exception('no keychain');
  @override
  Future<void> write(MusicPlatform platform) async =>
      throw Exception('no keychain');
  @override
  Future<bool> spotifyIntroSeen() async => throw Exception('no keychain');
  @override
  Future<void> markSpotifyIntroSeen() async => throw Exception('no keychain');
}

/// A store whose raw wire value a test sets, as an older build left it.
class _WireStore implements MusicPlatformStore {
  _WireStore(this.wire);
  String? wire;

  @override
  Future<MusicPlatform?> read() async => MusicPlatform.fromWire(wire);
  @override
  Future<void> write(MusicPlatform platform) async => wire = platform.wire;
  @override
  Future<bool> spotifyIntroSeen() async => false;
  @override
  Future<void> markSpotifyIntroSeen() async {}
}

OnboardingState _onboarding({String? service, bool appleLive = false}) =>
    OnboardingState(
      userId: 'u1',
      sources: [
        if (appleLive)
          MusicSource(
            source: 'apple_live',
            connectedAt: DateTime(2026),
            lastImportedAt: null,
            ledgerFrom: null,
            ledgerTo: null,
          ),
      ],
      hasLibrary: true,
      chosenService: service,
      markedRequestedAt: null,
      interviewCompletedAt: null,
      importCompletedAt: null,
    );

class _Onboarding extends OnboardingNotifier {
  _Onboarding(this.answer);
  final Future<OnboardingState> answer;

  @override
  Future<OnboardingState> build() => answer;
}

ProviderContainer _container(
  MusicPlatformStore store, {
  Future<OnboardingState>? onboarding,
}) {
  final container = ProviderContainer(
    overrides: [
      musicPlatformStoreProvider.overrideWithValue(store),
      onboardingProvider.overrideWith(
        () => _Onboarding(onboarding ?? Future.value(_onboarding())),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('the wire', () {
    test('both legacy Apple destinations read as Apple Music', () {
      expect(MusicPlatform.fromWire('here'), MusicPlatform.apple);
      expect(MusicPlatform.fromWire('apple_music'), MusicPlatform.apple);
      expect(MusicPlatform.fromWire('spotify'), MusicPlatform.spotify);
      expect(MusicPlatform.fromWire('junk'), isNull);
      expect(MusicPlatform.fromWire(null), isNull);
    });

    test('Apple is written as a value every build reads as Apple', () {
      expect(
        MusicPlatform.fromWire(MusicPlatform.apple.wire),
        MusicPlatform.apple,
      );
      expect(MusicPlatform.spotify.wire, 'spotify');
    });

    test('the Spotify explainer is remembered as seen on the device', () async {
      final store = InMemoryMusicPlatformStore();
      expect(await store.spotifyIntroSeen(), isFalse);
      await store.markSpotifyIntroSeen();
      expect(await store.spotifyIntroSeen(), isTrue);
    });
  });

  group('resolution', () {
    for (final (wire, expected) in [
      ('here', MusicPlatform.apple),
      ('apple_music', MusicPlatform.apple),
      ('spotify', MusicPlatform.spotify),
    ]) {
      test('a stored "$wire" is $expected', () async {
        final container = _container(
          _WireStore(wire),
          onboarding: Future.value(_onboarding(service: 'spotify')),
        );
        expect(container.read(musicPlatformProvider), isNull);
        await _settle();
        expect(
          container.read(musicPlatformProvider),
          expected,
          reason: 'a stored answer beats the onboarding service',
        );
      });
    }

    for (final (service, expected) in [
      ('apple', MusicPlatform.apple),
      ('spotify', MusicPlatform.spotify),
    ]) {
      test(
        'chosenService $service is the platform, written silently',
        () async {
          final store = InMemoryMusicPlatformStore();
          final container = _container(
            store,
            onboarding: Future.value(_onboarding(service: service)),
          );
          container.read(musicPlatformProvider);
          await _settle();
          expect(container.read(musicPlatformProvider), expected);
          expect(await store.read(), expected);
        },
      );
    }

    test('a live Apple library is Apple Music', () async {
      final store = InMemoryMusicPlatformStore();
      final container = _container(
        store,
        onboarding: Future.value(
          _onboarding(service: 'skipped', appleLive: true),
        ),
      );
      container.read(musicPlatformProvider);
      await _settle();
      expect(container.read(musicPlatformProvider), MusicPlatform.apple);
      expect(await store.read(), MusicPlatform.apple);
    });

    test('chosenService wins over a live Apple library', () async {
      final container = _container(
        InMemoryMusicPlatformStore(),
        onboarding: Future.value(
          _onboarding(service: 'spotify', appleLive: true),
        ),
      );
      container.read(musicPlatformProvider);
      await _settle();
      expect(container.read(musicPlatformProvider), MusicPlatform.spotify);
    });

    test('nothing known stays unknown, and nothing is written', () async {
      final store = InMemoryMusicPlatformStore();
      final container = _container(
        store,
        onboarding: Future.value(_onboarding(service: 'skipped')),
      );
      container.read(musicPlatformProvider);
      await _settle();
      expect(container.read(musicPlatformProvider), isNull);
      expect(await store.read(), isNull);
      expect(container.read(musicPlatformProvider.notifier).unknown, isTrue);
    });

    test('a service that arrives after the store read is adopted', () async {
      final onboarding = Completer<OnboardingState>();
      final store = InMemoryMusicPlatformStore();
      final container = _container(store, onboarding: onboarding.future);
      container.read(musicPlatformProvider);
      await _settle();
      expect(container.read(musicPlatformProvider), isNull);
      expect(
        container.read(musicPlatformProvider.notifier).unknown,
        isFalse,
        reason: 'not unknown while onboarding has not answered',
      );
      onboarding.complete(_onboarding(service: 'apple'));
      await _settle();
      expect(container.read(musicPlatformProvider), MusicPlatform.apple);
      expect(await store.read(), MusicPlatform.apple);
    });

    test('an onboarding failure is never "unknown"', () async {
      final container = _container(
        InMemoryMusicPlatformStore(),
        onboarding: Future.error(Exception('offline')),
      );
      container.read(musicPlatformProvider);
      await _settle();
      expect(container.read(musicPlatformProvider), isNull);
      expect(container.read(musicPlatformProvider.notifier).unknown, isFalse);
    });
  });

  group('choosing', () {
    test('a choice is remembered on the device', () async {
      final store = InMemoryMusicPlatformStore();
      final container = _container(store);
      container.read(musicPlatformProvider);
      await container
          .read(musicPlatformProvider.notifier)
          .choose(MusicPlatform.spotify);
      expect(container.read(musicPlatformProvider), MusicPlatform.spotify);
      expect(await store.read(), MusicPlatform.spotify);
    });

    test('a choice made while the store is read wins', () async {
      final container = _container(
        InMemoryMusicPlatformStore(MusicPlatform.apple),
      );
      container.read(musicPlatformProvider);
      await container
          .read(musicPlatformProvider.notifier)
          .choose(MusicPlatform.spotify);
      await _settle();
      expect(container.read(musicPlatformProvider), MusicPlatform.spotify);
    });

    test(
      'a store that fails leaves nothing chosen and still takes choices',
      () async {
        final container = _container(
          _BrokenStore(),
          onboarding: Future.value(_onboarding(service: 'skipped')),
        );
        container.read(musicPlatformProvider);
        await _settle();
        expect(container.read(musicPlatformProvider), isNull);
        await container
            .read(musicPlatformProvider.notifier)
            .choose(MusicPlatform.apple);
        expect(container.read(musicPlatformProvider), MusicPlatform.apple);
      },
    );
  });
}
