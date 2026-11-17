// The DJ paused kill switch: whether the app may send anything that needs
// the model. The operator flips a server flag when the credits run out or the
// model is down; `GET /health` says `djPaused`, and the three model POSTs
// answer `503 dj_paused` while it is on. Everything else keeps working.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'first_run_flags_provider.dart';

enum DjStatus {
  open,
  paused;

  bool get isPaused => this == DjStatus.paused;
}

/// The one source of truth. Server-wide, so it does not watch auth: a
/// sign-in or sign-out changes nothing about whether the DJ is paused.
///
/// Holds state only; [djStatusMonitorProvider] does the reading on a
/// schedule. Opens by default, and a failed read never pauses.
class DjStatusNotifier extends Notifier<DjStatus> {
  @override
  DjStatus build() => DjStatus.open;

  /// A send was refused with `503 dj_paused`: paused from now, without
  /// waiting for the next read.
  void markPaused() => state = DjStatus.paused;

  /// Reads `/health` again. No answer (a failed read) keeps what was known.
  Future<void> refresh() async {
    final paused = await ref.read(configApiProvider).djPaused();
    if (!ref.mounted || paused == null) return;
    state = paused ? DjStatus.paused : DjStatus.open;
  }
}

final djStatusProvider = NotifierProvider<DjStatusNotifier, DjStatus>(
  DjStatusNotifier.new,
);

/// Whether the DJ is paused, for the composers and every other send.
final djPausedProvider = Provider<bool>(
  (ref) => ref.watch(djStatusProvider).isPaused,
);

/// How often [djStatusMonitorProvider] reads `/health` while paused (so the
/// composer reopens on its own soon after the flag flips back) and while
/// open (to notice a pause before anyone sends).
const Duration djStatusPausedInterval = Duration(seconds: 60);
const Duration djStatusOpenInterval = Duration(minutes: 5);

/// Keeps [djStatusProvider] current: reads at start, on every return to the
/// foreground, and on a timer whose interval follows the status. The app root
/// listens to it; screens and their tests read [djStatusProvider] alone, so
/// nothing there holds a timer.
final djStatusMonitorProvider = Provider<void>((ref) {
  final notifier = ref.read(djStatusProvider.notifier);
  Timer? timer;
  var disposed = false;

  void schedule() {
    timer?.cancel();
    if (disposed) return;
    final interval = ref.read(djStatusProvider).isPaused
        ? djStatusPausedInterval
        : djStatusOpenInterval;
    timer = Timer(interval, () async {
      await notifier.refresh();
      schedule();
    });
  }

  // A pause (from a read or a refused send) moves to the quick cadence at
  // once; reopening goes back to the slow one.
  ref.listen(djStatusProvider, (_, _) => schedule());
  final lifecycle = AppLifecycleListener(
    onResume: () => unawaited(notifier.refresh()),
  );
  ref.onDispose(() {
    disposed = true;
    timer?.cancel();
    lifecycle.dispose();
  });
  unawaited(notifier.refresh());
  schedule();
});
