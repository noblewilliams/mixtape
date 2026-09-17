/// State the four-tab shell is built from
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock; plan task 2.2).
///
/// The user-scoped state here — the selected tab and the mini-player — watches
/// [authProvider] in `build()`, so an auth transition rebuilds it from scratch
/// rather than carrying the previous listener's tab or what they were playing
/// into the next account (see `CLAUDE.md` → Ground rules). Reduce Transparency
/// and the dock's availability are the device's, not an account's, and are
/// deliberately left alone by a sign-out.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../../data/playback/playback_controller.dart';
import '../../data/shell/mini_player_state.dart';
import '../../data/shell/shell_channel.dart';
import 'auth_provider.dart';
import 'playback_provider.dart';

/// The approved tabs, in dock order. The index is the wire value the native
/// dock speaks (`setTab`, `tabChanged`).
enum AppTab { home, mixes, library, you }

/// Which tab is up. Home on a fresh shell, and Home again after a sign-out.
class SelectedTabNotifier extends Notifier<int> {
  @override
  int build() {
    ref.watch(authProvider);
    return AppTab.home.index;
  }

  void selectTab(AppTab tab) => state = tab.index;

  /// From the dock, which speaks indices. An index the app does not have is
  /// ignored rather than trusted into an IndexedStack range error.
  void select(int index) {
    if (index < 0 || index >= AppTab.values.length) return;
    state = index;
  }
}

final selectedTabProvider = NotifierProvider<SelectedTabNotifier, int>(
  SelectedTabNotifier.new,
);

/// True only where the real `UITabBar` dock is installed (iOS 26). False
/// everywhere else, and the Flutter [FrostedDock] draws the same geometry.
///
/// Asked once per process — `ShellChannel.isAvailable` memoises, because the
/// answer cannot change inside a running app.
final nativeDockAvailableProvider = FutureProvider<bool>(
  (ref) => ShellChannel.instance.isAvailable,
);

/// iOS's Reduce Transparency setting: seeded from the platform and kept in
/// step while the app runs, so glass, panels and blur go opaque the moment
/// the listener flips the switch in Settings (board → Accessibility).
class ReduceTransparencyNotifier extends Notifier<bool> {
  @override
  bool build() {
    final shell = ShellChannel.instance;
    // Idempotent, and the only way the inbound stream below ever fires.
    shell.init();
    final subscription = shell.onReduceTransparencyChanged.listen((reduced) {
      state = reduced;
    });
    ref.onDispose(subscription.cancel);
    // Off iOS this resolves to false; `MediaQuery` already carries the
    // platform's own answer there.
    unawaited(
      shell.reduceTransparency.then((reduced) {
        if (ref.mounted && reduced) state = reduced;
      }),
    );
    return false;
  }

  void set(bool reduced) => state = reduced;
}

final reduceTransparencyProvider =
    NotifierProvider<ReduceTransparencyNotifier, bool>(
      ReduceTransparencyNotifier.new,
    );

/// What the dock's mini-player shows, derived from the app player.
///
/// One value drives both docks (native over `setMiniPlayer`, Flutter through
/// [FrostedDock.mini]), so the two can never drift. Nothing on the player →
/// [MiniPlayerState.hidden], which the board reads as no mini-player at all.
class MiniPlayerNotifier extends Notifier<MiniPlayerState> {
  @override
  MiniPlayerState build() {
    ref.watch(authProvider);
    final player = ref.watch(playbackProvider);
    void sync() {
      final next = stateOf(player);
      if (next != state) state = next;
    }

    player.addListener(sync);
    ref.onDispose(() => player.removeListener(sync));
    return stateOf(player);
  }

  /// The player's current track as the dock's one line of identity.
  ///
  /// `unavailableIndex` first, exactly as `PlaybackScreen` and `PlaybackMini`
  /// resolve it: a track the player could not play is still the one the
  /// listener is looking at.
  static MiniPlayerState stateOf(PlaybackController player) {
    if (player.sessionId == null) return const MiniPlayerState.hidden();
    final index = player.unavailableIndex ?? player.sample.index ?? 0;
    final QueueTrack? track = index >= 0 && index < player.tracks.length
        ? player.tracks[index]
        : null;
    if (track == null) return const MiniPlayerState.hidden();
    return MiniPlayerState(
      visible: true,
      title: track.title,
      artist: track.artist,
      artworkUrl: track.artworkUrl,
      playing: player.sample.status == 'playing',
    );
  }
}

final miniPlayerStateProvider =
    NotifierProvider<MiniPlayerNotifier, MiniPlayerState>(
      MiniPlayerNotifier.new,
    );
