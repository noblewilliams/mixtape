import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/library/library_sync_service.dart';
import '../../data/musickit/musickit_bridge.dart';
import 'auth_provider.dart';

final musicKitBridgeProvider = Provider<MusicKitBridge>((ref) => MusicKitBridge());

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
  const SyncRunning(this.progress);
  final double progress;
}

class SyncDone extends SyncState {
  const SyncDone(this.total);
  final int total;
}

class SyncFailed extends SyncState {
  const SyncFailed(this.message);
  final String message;
}

class LibrarySyncNotifier extends Notifier<SyncState> {
  late LibrarySyncService _service;

  @override
  SyncState build() {
    ref.watch(authProvider); // user-scoped: reset to idle on every auth transition
    final service = ref.watch(librarySyncServiceProvider);
    ref.onDispose(service.cancel);
    _service = service;
    return const SyncIdle();
  }

  Future<void> sync() async {
    if (state is SyncRunning) return;
    state = const SyncRunning(0);
    try {
      final total = await _service.sync(onProgress: (p) {
        if (ref.mounted) state = SyncRunning(p);
      });
      if (ref.mounted) state = SyncDone(total);
    } on LibraryAccessDenied {
      if (ref.mounted) {
        state = const SyncFailed('Music library access was denied. Enable it in Settings.');
      }
    } on SyncCancelled {
      // auth changed mid-run: fall back to idle so the screen stays actionable
      if (ref.mounted) state = const SyncIdle();
    } on NetworkException {
      if (ref.mounted) {
        state = const SyncFailed("Couldn't reach mixtape. Check your connection.");
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

final librarySyncProvider =
    NotifierProvider<LibrarySyncNotifier, SyncState>(LibrarySyncNotifier.new);
