import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  @override
  SyncState build() => const SyncIdle();

  Future<void> sync() async {
    if (state is SyncRunning) return;
    state = const SyncRunning(0);
    try {
      final total = await ref
          .read(librarySyncServiceProvider)
          .sync(onProgress: (p) {
        if (ref.mounted) state = SyncRunning(p);
      });
      if (ref.mounted) state = SyncDone(total);
    } on LibraryAccessDenied {
      if (ref.mounted) {
        state = const SyncFailed('Music library access was denied. Enable it in Settings.');
      }
    } catch (e) {
      if (ref.mounted) state = SyncFailed('Sync failed: $e');
    }
  }
}

final librarySyncProvider =
    NotifierProvider<LibrarySyncNotifier, SyncState>(LibrarySyncNotifier.new);
