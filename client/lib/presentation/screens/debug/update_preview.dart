// Debug-only fakes for seeing the over-the-air update UI in the simulator
// (Shorebird is never in a debug build):
//   --dart-define=MIXTAPE_PREVIEW=shell-update          "Update available"
//                       on Home and You, about 12 s in; tapping it holds
//                       "Updating" (the fake never closes)
//   --dart-define=MIXTAPE_PREVIEW=shell-update-applied  the start after a
//                       patch: "Updating", then "Updated", then gone
// `update` and `update-applied` do the same on the real root (signed in;
// first run has no title row, so no note).
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../data/updates/app_updater.dart';
import '../../providers/app_update_provider.dart';

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

  // Never closes: "Updating" stays up to be looked at.
  @override
  Future<void> close() => Completer<void>().future;
}

List<Override> updatePreviewOverrides(String preview) => switch (preview) {
  'update' || 'shell-update' => [
    appUpdaterProvider.overrideWithValue(
      _PreviewUpdater(running: null, waiting: 2),
    ),
    pendingPatchStoreProvider.overrideWithValue(InMemoryPendingPatchStore()),
  ],
  'update-applied' || 'shell-update-applied' => [
    appUpdaterProvider.overrideWithValue(
      _PreviewUpdater(running: 2, waiting: null),
    ),
    pendingPatchStoreProvider.overrideWithValue(_SlowStore()..value = 2),
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
