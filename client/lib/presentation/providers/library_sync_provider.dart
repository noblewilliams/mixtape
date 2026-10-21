import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/library/library_sync_service.dart';
import '../../data/musickit/musickit_bridge.dart';
import '../../data/settings/author_store.dart';
import 'auth_provider.dart';
import 'capabilities_provider.dart';
import 'onboarding_provider.dart';

final musicKitBridgeProvider = Provider<MusicKitBridge>(
  (ref) => MusicKitBridge(),
);

/// Device-local "by &lt;author&gt;" name stamped on saved playlists (see
/// QueueScreen's save dialog). Not user-scoped on purpose: it's a device
/// preference, not account data, so it survives sign-out like the rest of
/// local settings would.
final authorStoreProvider = Provider<AuthorStore>((ref) => SecureAuthorStore());

/// The account's display name from `GET /me` (Better Auth user.name), or
/// null when unset/unreachable — the save dialog uses it as the author
/// default when nothing was typed on this device yet. Attribution nicety
/// only: any failure resolves to null rather than surfacing, so a flaky
/// network can never block saving a playlist.
///
/// Derived from [meProvider], the one `GET /me` reader, so it can never
/// consume `merged` ahead of the merge notice; user-scoped through it.
final accountNameProvider = FutureProvider<String?>((ref) async {
  ref.watch(authProvider); // user-scoped: rebuilt with meProvider, not after
  try {
    return (await ref.watch(meProvider.future))?.name;
  } catch (_) {
    return null;
  }
});

final librarySyncServiceProvider = Provider<LibrarySyncService>((ref) {
  return LibrarySyncService(
    bridge: ref.watch(musicKitBridgeProvider),
    api: ref.watch(apiClientProvider),
  );
});

sealed class SyncState {
  const SyncState();
}

class SyncIdle extends SyncState {
  const SyncIdle();
}

class SyncRunning extends SyncState {
  const SyncRunning(this.progress, {this.songs = 0});
  final double progress;

  /// Songs uploaded so far in this run.
  final int songs;
}

class SyncDone extends SyncState {
  const SyncDone(this.summary);
  final LibrarySyncSummary summary;
}

class SyncFailed extends SyncState {
  const SyncFailed(this.message, {this.accessDenied = false});
  final String message;

  /// The listener refused library access: only Settings can help, so a
  /// retry is not the way out.
  final bool accessDenied;
}

class LibrarySyncNotifier extends Notifier<SyncState> {
  late LibrarySyncService _service;

  @override
  SyncState build() {
    ref.watch(
      authProvider,
    ); // user-scoped: reset to idle on every auth transition
    final service = ref.watch(librarySyncServiceProvider);
    ref.onDispose(service.cancel);
    _service = service;
    return const SyncIdle();
  }

  Future<void> sync() async {
    if (state is SyncRunning) return;
    state = const SyncRunning(0);
    try {
      var songs = 0;
      var progress = 0.0;
      final summary = await _service.sync(
        onProgress: (p) {
          progress = p;
          if (ref.mounted) state = SyncRunning(p, songs: songs);
        },
        onSongs: (n) {
          songs = n;
          if (ref.mounted) state = SyncRunning(progress, songs: n);
        },
      );
      if (ref.mounted) {
        ref.invalidate(onboardingProvider);
        state = SyncDone(summary);
      }
    } on LibraryAccessDenied {
      if (ref.mounted) {
        state = const SyncFailed(
          'Music library access was denied. Enable it in Settings.',
          accessDenied: true,
        );
      }
    } on SyncCancelled {
      // auth changed mid-run: fall back to idle so the screen stays actionable
      if (ref.mounted) state = const SyncIdle();
    } on NetworkException {
      if (ref.mounted) {
        state = const SyncFailed(
          "Couldn't reach mixtape. Check your connection.",
        );
      }
    } on ApiException {
      if (ref.mounted) {
        state = const SyncFailed('Something went wrong on our end. Try again.');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('library sync failed: $e');
      if (ref.mounted) state = const SyncFailed('Sync failed. Try again.');
    }
  }
}

final librarySyncProvider = NotifierProvider<LibrarySyncNotifier, SyncState>(
  LibrarySyncNotifier.new,
);
