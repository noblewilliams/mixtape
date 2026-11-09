/// Add your music from a mix (spec `docs/superpowers/specs/2026-11-09-add-
/// your-music-loop-design.md`, decisions 2 and 7; approval
/// `docs/mockups/approved/2026-11-09-add-your-music-loop.md`).
///
/// One router for the catalog mix's door, its sync retry and the history
/// pill. It opens the step that adds this listener's music, chosen from what
/// is already known about them, and every destination returns to the mix it
/// was opened from: the Sync Apple Music alert closes over it, and the add
/// flow's pages are pushed in library mode, which pops back to their opener.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import '../format/source_labels.dart';
import '../providers/auth_provider.dart';
import '../providers/funnel_provider.dart';
import '../providers/library_sync_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import '../screens/first_run/choose_method_screen.dart' show AddMethod;
import '../screens/first_run/doing_screen.dart';
import '../screens/first_run/first_run_flow.dart';
import '../screens/import_sheet.dart';
import '../widgets/library_sync_dialog.dart'
    show LibrarySyncDialog, appleLastSynced;

/// What asked for the router: the door's action (`door`), the failed sync's
/// Try again (`retrySync`), or the "Add my listening history" pill
/// (`history`).
enum AddMusicTarget { door, retrySync, history }

/// Where a target goes for this listener.
enum AddMusicDestination {
  /// The Sync Apple Music alert, at its confirm (a first sync or a re-sync).
  appleSync,

  /// The import flow: the document picker, then the import sheet.
  importFiles,

  /// Step 3's Exportify page.
  exportify,

  /// Step 3's Spotify data-export request page.
  spotifyExport,

  /// Step 3's "Upload an Apple export".
  appleExport,

  /// Step 1, "Which do you use?".
  chooseService,
}

/// The Spotify data export is on its way: Spotify is the chosen service, the
/// listener said they requested it, and nothing of it has landed (neither
/// package, nor an Exportify import). The same packages Home's waiting rows
/// read ([spotifyPackages]), with "nothing yet" rather than "not both".
bool spotifyDataWaiting(OnboardingState? onboarding) {
  if (onboarding == null) return false;
  if (onboarding.chosenService != 'spotify') return false;
  if (onboarding.markedRequestedAt == null) return false;
  final exportify =
      spotifySource(onboarding)?.packages.contains('spotify_exportify') ??
      false;
  return !exportify && spotifyPackages(onboarding).count == 0;
}

/// The destination table (decision 2). [platform] is the device's
/// ([musicPlatformProvider]); null is "nothing known", never Apple Music.
///
/// The door reads "Choose files" whenever the Spotify export is waiting
/// (whatever the device plays on), so it lands on the import sheet then too.
AddMusicDestination addMusicDestination(
  AddMusicTarget target, {
  required MusicPlatform? platform,
  required OnboardingState? onboarding,
}) {
  switch (target) {
    case AddMusicTarget.retrySync:
      return AddMusicDestination.appleSync;
    case AddMusicTarget.door:
      if (spotifyDataWaiting(onboarding)) {
        return AddMusicDestination.importFiles;
      }
      return switch (platform) {
        MusicPlatform.apple => AddMusicDestination.appleSync,
        MusicPlatform.spotify => AddMusicDestination.exportify,
        null => AddMusicDestination.chooseService,
      };
    case AddMusicTarget.history:
      return switch (platform) {
        // Once the export is requested, the next step is choosing its files.
        MusicPlatform.spotify =>
          onboarding?.markedRequestedAt != null
              ? AddMusicDestination.importFiles
              : AddMusicDestination.spotifyExport,
        MusicPlatform.apple => AddMusicDestination.appleExport,
        null => AddMusicDestination.chooseService,
      };
  }
}

/// Opens [target]'s destination over the mix and completes when it closes.
///
/// It records the tap (`music_door_tapped`, or `music_chip_tapped` for the
/// pill), reads onboarding again when the destination closes, and records
/// `music_added_from_mix` once if the listener's music became ready in the
/// run it opened ([MusicAddedWatch]).
///
/// [context] and [ref] are the opener's, and are used only before the first
/// await: the door is rebuilt (and can be remounted) as the conversation
/// moves, so everything after the tap goes through its navigator's context
/// and the provider container, which outlive it.
Future<void> openAddMusicFor(
  BuildContext context,
  WidgetRef ref,
  AddMusicTarget target,
) async {
  final host = Navigator.of(context).context;
  final container = ProviderScope.containerOf(context, listen: false);
  final destination = addMusicDestination(
    target,
    platform: ref.read(musicPlatformProvider),
    onboarding: ref.read(onboardingProvider).value,
  );
  ref
      .read(funnelMilestonesProvider)
      .record(
        target == AddMusicTarget.history
            ? FunnelEventType.musicChipTapped
            : FunnelEventType.musicDoorTapped,
      );
  final closed = ref
      .read(musicAddedWatchProvider)
      .begin(syncAlert: destination == AddMusicDestination.appleSync);
  try {
    await _open(host, container, destination);
  } finally {
    closed();
  }
}

Future<void> _open(
  BuildContext host,
  ProviderContainer container,
  AddMusicDestination destination,
) => switch (destination) {
  // showLibrarySync, read through the container.
  AddMusicDestination.appleSync => LibrarySyncDialog.show(
    host,
    lastSynced: appleLastSynced(container.read(onboardingProvider).value),
  ),
  AddMusicDestination.importFiles => openImportFlowIn(host, container),
  AddMusicDestination.exportify => _step3(host, AddMethod.exportify),
  AddMusicDestination.spotifyExport => _step3(host, AddMethod.spotifyExport),
  AddMusicDestination.appleExport => _step3(host, AddMethod.appleExport),
  AddMusicDestination.chooseService => openAddMusic(host),
};

/// Step 3 on its own, in library mode and named as path B's third page, so
/// the flow's finish pops back to the mix.
Future<void> _step3(BuildContext context, AddMethod method) =>
    pushFirstRunPage<void>(
      context,
      DoingScreen(method: method, mode: AddMusicMode.library),
      name: '${addMusicRoutePrefix}3',
    );

/// `music_added_from_mix` (decision 7): music landed in a run the router
/// opened.
///
/// Each router open arms its own token, and only when onboarding says
/// musicReady is false for the signed-in listener; a newer open replaces an
/// older one. A token records at most once, on the first successful
/// onboarding read after its run (a failed read leaves it armed for the next
/// good one), and only for the listener it was armed for. It is dropped when
/// the run ends any other way: the alert closed with no sync started, or a
/// sync that failed or was cancelled (the alert's Hide leaves the sync
/// running, so the watch follows it to its end).
class MusicAddedWatch {
  MusicAddedWatch(this._ref);

  final Ref _ref;
  _Armed? _armed;

  /// The sync being followed past Hide, or the onboarding read awaited
  /// after a failed one.
  ProviderSubscription<Object?>? _following;

  /// A destination opens. Call the returned function once, when it closes.
  /// [syncAlert] is whether the destination is the Sync Apple Music alert.
  VoidCallback begin({required bool syncAlert}) {
    _unfollow();
    final before = _ref.read(onboardingProvider).unwrapPrevious().value;
    final armed = before != null && !before.musicReady
        ? _Armed(before.userId)
        : null;
    _armed = armed;
    // Only a sync started while the destination is open is this run's: one
    // left from earlier, or already running, is not.
    var syncStarted = false;
    final starts = _ref.listen<SyncState>(librarySyncProvider, (
      previous,
      next,
    ) {
      if (next is SyncRunning && previous is! SyncRunning) syncStarted = true;
    });
    return () {
      // A sign-out since: the subscriptions went with the old listener.
      if (!_ref.mounted) return;
      starts.close();
      _settle(armed, syncStarted: syncStarted, syncAlert: syncAlert);
    };
  }

  void _settle(
    _Armed? token, {
    required bool syncStarted,
    required bool syncAlert,
  }) {
    if (syncStarted) {
      final sync = _ref.read(librarySyncProvider);
      if (sync is! SyncRunning) {
        _syncEnded(token, sync);
      } else if (token != null) {
        _follow(token);
      }
      // A run nothing is armed for refreshes onboarding itself when it lands.
      return;
    }
    // The alert closed with nothing started: nothing came in through it.
    if (syncAlert) _drop(token);
    unawaited(_refreshThenCheck(token));
  }

  void _follow(_Armed token) {
    _unfollow();
    _following = _ref.listen<SyncState>(librarySyncProvider, (_, next) {
      if (next is SyncRunning) return;
      _unfollow();
      _syncEnded(token, next);
    });
  }

  void _syncEnded(_Armed? token, SyncState sync) {
    if (sync is SyncDone) {
      // The sync invalidated onboarding as it landed: wait for that read
      // rather than asking a second time.
      if (token != null) unawaited(_checkAfterReload(token));
      return;
    }
    _drop(token);
    unawaited(_refreshThenCheck(null));
  }

  Future<void> _checkAfterReload(_Armed token) async {
    try {
      await _ref.read(onboardingProvider.future);
    } catch (_) {
      // A failed read decides nothing: the token waits for a good one.
    }
    _checkOnGoodRead(token);
  }

  Future<void> _refreshThenCheck(_Armed? token) async {
    if (!_ref.mounted) return;
    await _ref.read(onboardingProvider.notifier).refresh();
    if (token != null) _checkOnGoodRead(token);
  }

  /// Looks now if the latest onboarding read succeeded; otherwise waits,
  /// still armed, for the next one that does (a refresh, the next sync's
  /// read). The next router open replaces the wait.
  void _checkOnGoodRead(_Armed token) {
    if (!_ref.mounted || !identical(_armed, token)) return;
    if (_ref.read(onboardingProvider) is AsyncData<OnboardingState>) {
      _check(token);
      return;
    }
    _unfollow();
    _following = _ref.listen<AsyncValue<OnboardingState>>(onboardingProvider, (
      _,
      next,
    ) {
      if (next is! AsyncData<OnboardingState>) return;
      _unfollow();
      _check(token);
    });
  }

  /// The one look a token gets, on a good read: it is spent whatever the
  /// answer.
  void _check(_Armed token) {
    if (!_ref.mounted || !identical(_armed, token)) return;
    _armed = null;
    final after = _ref.read(onboardingProvider).unwrapPrevious().value;
    if (after == null || after.userId != token.userId || !after.musicReady) {
      return;
    }
    _ref
        .read(funnelMilestonesProvider)
        .record(FunnelEventType.musicAddedFromMix);
  }

  void _drop(_Armed? token) {
    if (token != null && identical(_armed, token)) _armed = null;
  }

  void _unfollow() {
    final following = _following;
    _following = null;
    following?.close();
  }

  /// The listener changed: whatever was armed was theirs.
  void _forget() {
    _armed = null;
    _following = null;
  }
}

final class _Armed {
  _Armed(this.userId);
  final String userId;
}

/// User-scoped: a sign-out drops what was armed and the sync it followed.
final musicAddedWatchProvider = Provider<MusicAddedWatch>((ref) {
  ref.watch(authProvider);
  final watch = MusicAddedWatch(ref);
  ref.onDispose(watch._forget);
  return watch;
});
