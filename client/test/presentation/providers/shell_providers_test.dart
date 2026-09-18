/// The dock's mini-player, derived from the app player
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock; plan task 6.2).
///
/// The shell's own wiring — what reaches the channel, what the dock's buttons
/// do — is `test/screens/shell_screen_test.dart`. This file is only about the
/// value the two docks are built from.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playback/listening_meter.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/shell/mini_player_state.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';

import '../../data/playback/playback_controller_test.dart'
    show FakeApi, FakeBridge;

const _track = QueueTrack(
  position: 1,
  trackId: 'track',
  appleId: '123',
  title: 'Slow kitchen morning',
  artist: 'Khruangbin',
  artworkUrl: 'https://example.test/art.jpg',
  durationMs: 200000,
);

/// The same track, with artwork the dock must refuse to load.
const _insecureArtTrack = QueueTrack(
  position: 1,
  trackId: 'track',
  appleId: '123',
  title: 'Slow kitchen morning',
  artist: 'Khruangbin',
  artworkUrl: 'http://example.test/art.jpg',
  durationMs: 200000,
);

class _TestAuth extends AuthNotifier {
  _TestAuth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) => state = status;
}

/// A controller with a fake bridge, torn down with the test.
({PlaybackController player, FakeBridge bridge}) newPlayer() {
  final bridge = FakeBridge();
  final player = PlaybackController(FakeApi(), bridge);
  addTearDown(() async {
    player.dispose();
    await bridge.events.close();
  });
  return (player: player, bridge: bridge);
}

ProviderContainer containerFor(PlaybackController player, {AuthNotifier? auth}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(() => auth ?? _TestAuth(AuthStatus.signedIn)),
      playbackProvider.overrideWithValue(player),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the bridge's broadcast stream deliver.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('miniPlayerStateProvider', () {
    test('nothing on the player means no mini-player at all', () {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);

      expect(container.read(miniPlayerStateProvider), const MiniPlayerState.hidden());
      expect(container.read(miniPlayerStateProvider).visible, isFalse);
    });

    test('what the player is on becomes the dock\'s one line', () async {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);
      container.listen(miniPlayerStateProvider, (previous, next) {});

      // The arrangement's Play now, all the way through the controller.
      await player.start('mix', 1, 'A mix', [_track]);
      bridge.events.add(
        const PlayerSample(index: 0, positionMs: 0, status: 'playing'),
      );
      await settle();

      expect(
        container.read(miniPlayerStateProvider),
        const MiniPlayerState(
          visible: true,
          title: 'Slow kitchen morning',
          artist: 'Khruangbin',
          artworkUrl: 'https://example.test/art.jpg',
          playing: true,
        ),
      );
    });

    test('a paused player keeps its line and drops the play flag', () async {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);
      container.listen(miniPlayerStateProvider, (previous, next) {});

      await player.start('mix', 1, 'A mix', [_track]);
      bridge.events.add(
        const PlayerSample(index: 0, positionMs: 4000, status: 'paused'),
      );
      await settle();

      final mini = container.read(miniPlayerStateProvider);
      expect(mini.visible, isTrue);
      expect(mini.title, 'Slow kitchen morning');
      expect(mini.playing, isFalse);
    });

    test('only https artwork is handed to the dock', () async {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);

      await player.start('mix', 1, 'A mix', [_insecureArtTrack]);
      await settle();

      expect(container.read(miniPlayerStateProvider).artworkUrl, isNull);
    });

    test('a position tick alone leaves the state exactly as it was', () async {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);
      final changes = <MiniPlayerState>[];
      container.listen(miniPlayerStateProvider, (previous, next) => changes.add(next));

      await player.start('mix', 1, 'A mix', [_track]);
      bridge.events.add(
        const PlayerSample(index: 0, positionMs: 0, status: 'playing'),
      );
      await settle();
      final settled = container.read(miniPlayerStateProvider);
      changes.clear();

      for (var ms = 1000; ms <= 5000; ms += 1000) {
        bridge.events.add(
          PlayerSample(
            index: 0,
            positionMs: ms.toDouble(),
            status: 'playing',
          ),
        );
      }
      await settle();

      // The dock shows no position, so a tick must not reach it.
      expect(changes, isEmpty);
      expect(identical(container.read(miniPlayerStateProvider), settled), isTrue);
    });

    test('an unavailable track says so where the artist would be', () async {
      final (:player, :bridge) = newPlayer();
      final container = containerFor(player);
      container.listen(miniPlayerStateProvider, (previous, next) {});

      await player.start('mix', 1, 'A mix', [_track]);
      player.unavailableIndex = 0;
      bridge.events.add(
        const PlayerSample(index: 0, positionMs: 0, status: 'waiting'),
      );
      await settle();

      final mini = container.read(miniPlayerStateProvider);
      expect(mini.visible, isTrue);
      expect(mini.title, 'Slow kitchen morning');
      expect(mini.artist, MiniPlayerState.unavailableLine);
      expect(mini.artist, 'Not available in your region');
      expect(mini.unavailable, isTrue);
      // Nothing is coming out of the speakers, whatever the last sample said.
      expect(mini.playing, isFalse);
    });

    test('an auth transition re-derives the dock from the new player', () async {
      // `playbackProvider` is user-scoped: a sign-out builds a fresh
      // controller, and the mini-player must follow it rather than keep the
      // previous account's mix (CLAUDE.md → Ground rules).
      final signedIn = newPlayer();
      final signedOut = newPlayer();
      final auth = _TestAuth(AuthStatus.signedIn);
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          authProvider.overrideWith(() => auth),
          playbackProvider.overrideWith(
            (ref) => ref.watch(authProvider) == AuthStatus.signedIn
                ? signedIn.player
                : signedOut.player,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(miniPlayerStateProvider, (previous, next) {});

      await signedIn.player.start('mix', 1, 'A mix', [_track]);
      await settle();
      expect(container.read(miniPlayerStateProvider).visible, isTrue);

      auth.set(AuthStatus.signedOut);

      expect(
        container.read(miniPlayerStateProvider),
        const MiniPlayerState.hidden(),
      );
    });
  });

  group('the setMiniPlayer payload', () {
    test('carries every key of the contract, unavailable included', () {
      const state = MiniPlayerState(
        visible: true,
        title: 'Slow kitchen morning',
        artist: MiniPlayerState.unavailableLine,
        artworkUrl: 'https://example.test/art.jpg',
        playing: false,
        unavailable: true,
      );

      expect(state.toMap(), {
        'visible': true,
        'title': 'Slow kitchen morning',
        'artist': 'Not available in your region',
        'artworkUrl': 'https://example.test/art.jpg',
        'playing': false,
        'unavailable': true,
      });
    });

    test('hidden says nothing else', () {
      expect(const MiniPlayerState.hidden().toMap(), {
        'visible': false,
        'title': '',
        'artist': '',
        'artworkUrl': null,
        'playing': false,
        'unavailable': false,
      });
    });

    test('two states differing only in unavailable are not equal', () {
      const playing = MiniPlayerState(visible: true, title: 'A');
      expect(playing == playing.copyWith(unavailable: true), isFalse);
    });
  });
}
