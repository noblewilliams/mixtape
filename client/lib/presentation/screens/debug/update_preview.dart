// Debug-only fakes for seeing the over-the-air update UI in the simulator
// (Shorebird is never in a debug build):
//   --dart-define=MIXTAPE_PREVIEW=shell-update          "Update" on Home and
//                       You, about 12 s in; tapping it opens the countdown
//                       capsule, which ends holding "Restarting" (the fake
//                       never closes, and sends no reopen banner)
//   --dart-define=MIXTAPE_PREVIEW=shell-update-music    the same, as if music
//                       were playing ("Music will stop")
//   --dart-define=MIXTAPE_PREVIEW=shell-update-applied  the start after a
//                       patch: "Updating", then "Updated", then gone
// `update` and `update-applied` do the same on the real root (signed in;
// first run has no title row, so no note).
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../data/updates/app_updater.dart';
import '../../providers/app_update_provider.dart';

class _NoNotice implements UpdateReopenNotice {
  @override
  Future<void> schedule({required Duration after}) async {}
  @override
  Future<void> cancel() async {}
}

final List<Override> _quiet = [
  updateReopenNoticeProvider.overrideWithValue(_NoNotice()),
  // Leaving the preview never closes it.
  updateQuietBlockedProvider.overrideWithValue(() => true),
];

class _PreviewUpdater implements AppUpdater {
  _PreviewUpdater({required this.running, required this.waiting});
  final int? running;
  final int? waiting;
  @override
  bool get isAvailable => true;
  @override
  Future<int?> currentPatch() async => running;
  @override
  Future<int?> downloadNewPatch() async {
    await Future<void>.delayed(
      const Duration(seconds: 12),
    ); // past a debug launch's slow start
    return waiting;
  }

  // Never closes: "Restarting" stays up to be looked at.
  @override
  Future<void> close() => Completer<void>().future;
}

List<Override> updatePreviewOverrides(String preview) => switch (preview) {
  'update' || 'shell-update' || 'shell-update-music' => [
    appUpdaterProvider.overrideWithValue(
      _PreviewUpdater(running: null, waiting: 2),
    ),
    pendingPatchStoreProvider.overrideWithValue(InMemoryPendingPatchStore()),
    ..._quiet,
    if (preview == 'shell-update-music')
      updateMusicPlayingProvider.overrideWithValue(() => true),
  ],
  'update-applied' || 'shell-update-applied' => [
    appUpdaterProvider.overrideWithValue(
      _PreviewUpdater(running: 2, waiting: null),
    ),
    pendingPatchStoreProvider.overrideWithValue(_SlowStore()..value = 2),
    ..._quiet,
  ],
  _ => const [],
};

/// Holds the launch read a moment, so a debug launch's slow start does not
/// hide the sequence.
class _SlowStore extends InMemoryPendingPatchStore {
  @override
  Future<int?> read() async {
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    return super.read();
  }
}
