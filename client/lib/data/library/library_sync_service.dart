import '../api/api_client.dart';
import '../musickit/musickit_bridge.dart';

class LibraryAccessDenied implements Exception {}

/// Thrown when [LibrarySyncService.cancel] interrupts a run in progress.
class SyncCancelled implements Exception {}

class LibrarySyncService {
  LibrarySyncService({required this.bridge, required this.api, this.chunkSize = 200}) {
    assert(chunkSize > 0);
  }

  final MusicKitBridge bridge;
  final ApiClient api;
  final int chunkSize;

  Future<int>? _inFlight;
  bool _cancelRequested = false;

  /// Requests that the in-flight run stop at its next loop iteration,
  /// throwing [SyncCancelled]. No-op if nothing is running.
  void cancel() => _cancelRequested = true;

  /// Full library sync: pages the native snapshot (always starting at offset 0)
  /// and posts each page to /ingest/library. Returns the number of songs found.
  /// Throws [LibraryAccessDenied], [ApiException], [NetworkException], [MusicKitException].
  ///
  /// Re-entrant safe: a call made while a sync is already running joins that
  /// same in-flight sync instead of starting a second one (the native snapshot
  /// is shared and can't support concurrent syncs).
  /// Concurrent calls join the in-flight run; the joiner's [onProgress] is ignored.
  Future<int> sync({void Function(double progress)? onProgress}) =>
      _inFlight ??= _run(onProgress).whenComplete(() {
        _inFlight = null;
        _cancelRequested = false;
      });

  Future<int> _run(void Function(double progress)? onProgress) async {
    final authorized = await bridge.requestAuthorization();
    if (!authorized) throw LibraryAccessDenied();

    var offset = 0;
    var total = 0;
    // DISCIPLINE: any new await added to this loop needs a _cancelRequested check right after it.
    while (true) {
      if (_cancelRequested) throw SyncCancelled();
      final page = await bridge.fetchLibrarySongs(offset: offset, limit: chunkSize);
      if (_cancelRequested) throw SyncCancelled();
      total = page.total;
      if (page.songs.isEmpty) break;
      await api.postJson('/ingest/library', {
        'songs': page.songs.map((s) => s.toJson()).toList(),
      });
      if (_cancelRequested) throw SyncCancelled();
      offset += page.songs.length;
      onProgress?.call(total == 0 ? 1.0 : (offset / total).clamp(0.0, 1.0));
      if (offset >= total) break;
    }
    if (total == 0) onProgress?.call(1.0);
    return total;
  }
}
