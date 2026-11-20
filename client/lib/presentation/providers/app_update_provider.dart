// Over-the-air updates as the app sees them (decision 2026-11-20; board
// docs/mockups/approved/2026-11-20-ota-update-states.md). A patch downloads
// quietly; once it is waiting, the title note says "Update available". The
// tap shows "Updating" and closes the app (iOS cannot relaunch itself). The
// next start finds the patch it recorded running and plays "Updating", then
// "Updated", in the same note.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/updates/app_updater.dart';

final appUpdaterProvider = Provider<AppUpdater>((ref) => ShorebirdAppUpdater());

final pendingPatchStoreProvider = Provider<PendingPatchStore>(
  (ref) => SecurePendingPatchStore(),
);

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

  /// The listener tapped "Update available": "Updating" shows and the app is
  /// about to close.
  closing,
}

@immutable
class AppUpdateState {
  const AppUpdateState(this.phase, {this.patch});
  final AppUpdatePhase phase;

  /// The patch waiting ([AppUpdatePhase.ready], [AppUpdatePhase.closing]) or
  /// just applied ([AppUpdatePhase.applied], [AppUpdatePhase.updated]).
  final int? patch;
}

/// How long "Updating" holds before the app closes.
const Duration updateCloseDelay = Duration(milliseconds: 1800);

/// How long "Updating" shows on the start that boots the patch.
const Duration updateAppliedFor = Duration(milliseconds: 1400);

/// How long "Updated" shows before the note fades away.
const Duration updateUpdatedFor = Duration(milliseconds: 2500);

/// A launch never waits longer than this on the keychain or the updater.
const Duration updateLaunchReadLimit = Duration(seconds: 2);

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  bool _checking = false;
  Timer? _step;

  @override
  AppUpdateState build() {
    ref.onDispose(() => _step?.cancel());
    final updater = ref.read(appUpdaterProvider);
    if (!updater.isAvailable) {
      return const AppUpdateState(AppUpdatePhase.current);
    }
    unawaited(_readLaunch());
    return const AppUpdateState(AppUpdatePhase.launching);
  }

  Future<void> _readLaunch() async {
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

  /// The tap on "Update available": show "Updating", then close.
  Future<void> restart() async {
    if (state.phase != AppUpdatePhase.ready) return;
    state = AppUpdateState(AppUpdatePhase.closing, patch: state.patch);
    await Future<void>.delayed(updateCloseDelay);
    if (!ref.mounted) return;
    await ref.read(appUpdaterProvider).close();
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
  final lifecycle = AppLifecycleListener(onResume: check);
  ref.onDispose(() {
    timer.cancel();
    lifecycle.dispose();
  });
  check();
});
