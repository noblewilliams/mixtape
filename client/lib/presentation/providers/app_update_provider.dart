// Over-the-air updates as the app sees them (decision 2026-11-20; board
// docs/mockups/approved/2026-11-20-ota-update-states.md, revised by
// docs/mockups/approved/2026-11-24-ota-restart-countdown.md). A patch
// downloads quietly; once it is waiting, the title note says "Update". The
// tap counts down from 5 in a capsule the listener can cancel or skip, then
// the app closes (iOS cannot relaunch itself) and leaves a "tap to reopen"
// banner. Leaving the app with a patch waiting applies it quietly. The next
// start finds the patch it recorded running and plays "Updating", then
// "Updated", in the note.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/updates/app_updater.dart';
import 'library_sync_provider.dart';
import 'listening_import_provider.dart';
import 'mix_activity_provider.dart';
import 'playback_provider.dart';
import 'voice_providers.dart';

final appUpdaterProvider = Provider<AppUpdater>((ref) => ShorebirdAppUpdater());

final pendingPatchStoreProvider = Provider<PendingPatchStore>(
  (ref) => SecurePendingPatchStore(),
);

final updateReopenNoticeProvider = Provider<UpdateReopenNotice>(
  (ref) => LocalUpdateReopenNotice(),
);

/// The wall clock, for telling a quiet-apply timer that fired on time from
/// one that fired late because iOS suspended the app.
final updateClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Whether mixtape's own player is playing: closing would stop it.
final updateMusicPlayingProvider = Provider<bool Function()>(
  (ref) =>
      () =>
          ref.read(playbackProvider.exists) &&
          ref.read(playbackProvider).sample.status == 'playing',
);

/// Whether closing now would cut something off, so a quiet apply waits for
/// the next trip to the background: music playing, a voice note recording
/// or transcribing, an import or library sync running, or a mix send not yet
/// handed to the server (a durable turn carries on without the app).
/// Providers nobody has built are idle by definition, so none is built here.
final updateQuietBlockedProvider = Provider<bool Function()>((ref) {
  final playing = ref.watch(updateMusicPlayingProvider);
  return () {
    if (playing()) return true;
    if (ref.read(voiceComposerControllerProvider.exists) &&
        ref.read(voiceComposerControllerProvider).busy) {
      return true;
    }
    if (ref.read(listeningImportProvider.exists) &&
        ref.read(listeningImportProvider).inProgress) {
      return true;
    }
    if (ref.read(librarySyncProvider.exists) &&
        ref.read(librarySyncProvider) is SyncRunning) {
      return true;
    }
    if (ref.read(mixActivityProvider.exists)) {
      final activity = ref.read(mixActivityProvider);
      if (activity.pending != null && activity.pendingTurn == null) {
        return true;
      }
      if (activity.working.keys.any((id) => activity.turns[id] == null)) {
        return true;
      }
    }
    return false;
  };
});

enum AppUpdatePhase {
  /// The first moments of a launch with the updater present, while the app
  /// reads whether this start is the one that applied a patch. Shows nothing.
  launching,

  /// This start applied the patch the app closed for: "Updating" for
  /// [updateAppliedFor], then [updated].
  applied,

  /// "Updated" for [updateUpdatedFor], then [current].
  updated,

  /// Running the newest patch it knows of (or no updater in this build).
  current,

  /// A newer patch is downloaded and runs from the next start.
  ready,

  /// The listener tapped "Update": "Restarting in [AppUpdateState.secondsLeft]"
  /// counts down with Cancel and Now.
  countdown,

  /// The countdown ran out or the listener tapped Now: "Restarting" shows and
  /// the app is about to close.
  closing,
}

@immutable
class AppUpdateState {
  const AppUpdateState(
    this.phase, {
    this.patch,
    this.secondsLeft,
    this.holding = false,
  });
  final AppUpdatePhase phase;

  /// The patch waiting ([AppUpdatePhase.ready], [AppUpdatePhase.countdown],
  /// [AppUpdatePhase.closing]) or just applied ([AppUpdatePhase.applied],
  /// [AppUpdatePhase.updated]).
  final int? patch;

  /// The seconds the countdown shows; only while counting down.
  final int? secondsLeft;

  /// The countdown waits for Now or Cancel instead of running itself (with
  /// VoiceOver, where 5 seconds is too short to hear it and find the button).
  final bool holding;
}

/// Where the countdown starts.
const int updateCountdownSeconds = 5;

/// One step of the countdown.
const Duration updateCountdownStep = Duration(seconds: 1);

/// How long "Restarting" holds before the app closes.
const Duration updateCloseDelay = Duration(milliseconds: 700);

/// The reopen banner goes off this long after it is scheduled, by when the
/// app has closed (iOS shows no banner for an app in front).
const Duration updateReopenAfter = Duration(seconds: 1);

/// How long the app waits in the background before applying quietly, so a
/// glance at another app costs nothing.
const Duration updateQuietDelay = Duration(seconds: 3);

/// A quiet-apply timer firing later than this past its time means iOS
/// suspended the app in between; it has just come back, so it stays open.
const Duration updateQuietLateBy = Duration(seconds: 2);

/// How long "Updating" shows on the start that boots the patch.
const Duration updateAppliedFor = Duration(milliseconds: 1400);

/// How long "Updated" shows before the note fades away.
const Duration updateUpdatedFor = Duration(milliseconds: 2500);

/// A launch never waits longer than this on the keychain or the updater.
const Duration updateLaunchReadLimit = Duration(seconds: 2);

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  bool _checking = false;
  Timer? _step;
  Timer? _countdown;
  Timer? _quiet;
  bool _inBackground = false;

  @override
  AppUpdateState build() {
    ref.onDispose(() {
      _step?.cancel();
      _countdown?.cancel();
      _quiet?.cancel();
    });
    final updater = ref.read(appUpdaterProvider);
    if (!updater.isAvailable) {
      return const AppUpdateState(AppUpdatePhase.current);
    }
    unawaited(_readLaunch());
    return const AppUpdateState(AppUpdatePhase.launching);
  }

  Future<void> _readLaunch() async {
    // A reopen banner still waiting is stale once the app is open again.
    unawaited(
      ref.read(updateReopenNoticeProvider).cancel().catchError((Object _) {}),
    );
    final store = ref.read(pendingPatchStoreProvider);
    final updater = ref.read(appUpdaterProvider);
    int? applied;
    try {
      final pending = await store.read().timeout(updateLaunchReadLimit);
      if (pending != null) {
        // Read once: a patch that failed to boot (rolled back) must not
        // show "updated" on every later launch.
        unawaited(store.clear());
        final running = await updater.currentPatch().timeout(
          updateLaunchReadLimit,
        );
        if (running == pending) applied = running;
      }
    } catch (_) {
      // A slow or failed read just opens the app.
    }
    if (!ref.mounted) return;
    if (applied == null) {
      state = const AppUpdateState(AppUpdatePhase.current);
      return;
    }
    // The timeline lives here, not in the note, so Home and You stay in
    // step and a listener on another tab simply misses it.
    final patch = applied;
    state = AppUpdateState(AppUpdatePhase.applied, patch: patch);
    _step = Timer(updateAppliedFor, () {
      if (!ref.mounted) return;
      state = AppUpdateState(AppUpdatePhase.updated, patch: patch);
      _step = Timer(updateUpdatedFor, () {
        if (!ref.mounted) return;
        state = const AppUpdateState(AppUpdatePhase.current);
      });
    });
  }

  /// Looks for a newer patch and downloads it. Only while running current:
  /// not during a launch, and not once one is already waiting.
  Future<void> check() async {
    if (_checking || state.phase != AppUpdatePhase.current) return;
    final updater = ref.read(appUpdaterProvider);
    if (!updater.isAvailable) return;
    _checking = true;
    try {
      final patch = await updater.downloadNewPatch();
      if (!ref.mounted || patch == null) return;
      if (state.phase != AppUpdatePhase.current) return;
      // Recorded now, not at the tap: a listener who never taps still gets
      // "Updated" on the next start, which is when the patch runs.
      await ref.read(pendingPatchStoreProvider).write(patch);
      if (!ref.mounted) return;
      state = AppUpdateState(AppUpdatePhase.ready, patch: patch);
    } finally {
      _checking = false;
    }
  }

  /// The tap on "Update": count down from [updateCountdownSeconds], then
  /// close. With [hold] (VoiceOver) the count waits for Now or Cancel.
  void startCountdown({bool hold = false}) {
    if (state.phase != AppUpdatePhase.ready) return;
    _quiet?.cancel();
    state = AppUpdateState(
      AppUpdatePhase.countdown,
      patch: state.patch,
      secondsLeft: updateCountdownSeconds,
      holding: hold,
    );
    if (hold) return;
    _countdown = Timer.periodic(updateCountdownStep, (_) {
      if (!ref.mounted || state.phase != AppUpdatePhase.countdown) return;
      final left = (state.secondsLeft ?? 1) - 1;
      if (left <= 0) {
        unawaited(_close());
        return;
      }
      state = AppUpdateState(
        AppUpdatePhase.countdown,
        patch: state.patch,
        secondsLeft: left,
      );
    });
  }

  /// Cancel: back to "Update".
  void cancelCountdown() {
    if (state.phase != AppUpdatePhase.countdown) return;
    _countdown?.cancel();
    state = AppUpdateState(AppUpdatePhase.ready, patch: state.patch);
  }

  /// Now: skip the rest of the countdown.
  void restartNow() {
    if (state.phase != AppUpdatePhase.countdown) return;
    unawaited(_close());
  }

  /// "Restarting", the reopen banner, then the close. A banner that fails to
  /// schedule never holds the close up.
  Future<void> _close() async {
    _countdown?.cancel();
    state = AppUpdateState(AppUpdatePhase.closing, patch: state.patch);
    final notice = ref.read(updateReopenNoticeProvider);
    await Future.wait([
      Future<void>.delayed(updateCloseDelay),
      notice
          .schedule(after: updateReopenAfter)
          .timeout(updateCloseDelay)
          .catchError((Object _) {}),
    ]);
    if (!ref.mounted) return;
    await ref.read(appUpdaterProvider).close();
  }

  /// The app went to the background. A countdown stops (nobody is watching
  /// it); a waiting patch applies quietly after [updateQuietDelay].
  void onBackground() {
    _inBackground = true;
    cancelCountdown();
    if (state.phase != AppUpdatePhase.ready) return;
    _quiet?.cancel();
    final clock = ref.read(updateClockProvider);
    final due = clock().add(updateQuietDelay);
    _quiet = Timer(updateQuietDelay, () {
      if (!ref.mounted || !_inBackground) return;
      if (state.phase != AppUpdatePhase.ready) return;
      if (clock().difference(due) > updateQuietLateBy) return;
      if (ref.read(updateQuietBlockedProvider)()) return;
      unawaited(ref.read(appUpdaterProvider).close());
    });
  }

  /// The app is in front again: a quiet apply not yet done waits for the
  /// next trip to the background.
  void onForeground() {
    _inBackground = false;
    _quiet?.cancel();
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);

/// How often a running app looks for a patch, besides each return to the
/// foreground.
const Duration updateCheckInterval = Duration(minutes: 30);

/// Checks once the launch has settled, on every return to the foreground and
/// on a timer. The app root listens to it; screens read [appUpdateProvider].
final appUpdateMonitorProvider = Provider<void>((ref) {
  final notifier = ref.read(appUpdateProvider.notifier);
  void check() => unawaited(notifier.check());

  ref.listen(appUpdateProvider, (previous, next) {
    if (previous?.phase != AppUpdatePhase.current &&
        next.phase == AppUpdatePhase.current) {
      check();
    }
  });
  final timer = Timer.periodic(updateCheckInterval, (_) => check());
  final lifecycle = AppLifecycleListener(
    onResume: () {
      notifier.onForeground();
      check();
    },
    onPause: notifier.onBackground,
  );
  ref.onDispose(() {
    timer.cancel();
    lifecycle.dispose();
  });
  check();
});
