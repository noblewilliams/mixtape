import '../api/api_client.dart';
import '../musickit/musickit_bridge.dart';

class LibraryAccessDenied implements Exception {}

class LibrarySyncService {
  LibrarySyncService({required this.bridge, required this.api, this.chunkSize = 200});

  final MusicKitBridge bridge;
  final ApiClient api;
  final int chunkSize;

  /// Full library sync: pages the native snapshot (always starting at offset 0)
  /// and posts each page to /ingest/library. Returns the number of songs found.
  /// Throws [LibraryAccessDenied], [ApiException], [NetworkException], [MusicKitException].
  Future<int> sync({void Function(double progress)? onProgress}) async {
    final authorized = await bridge.requestAuthorization();
    if (!authorized) throw LibraryAccessDenied();

    var offset = 0;
    var total = 0;
    while (true) {
      final page = await bridge.fetchLibrarySongs(offset: offset, limit: chunkSize);
      total = page.total;
      if (page.songs.isEmpty) break;
      await api.postJson('/ingest/library', {
        'songs': page.songs.map((s) => s.toJson()).toList(),
      });
      offset += page.songs.length;
      onProgress?.call(total == 0 ? 1.0 : (offset / total).clamp(0.0, 1.0));
      if (offset >= total) break;
    }
    if (total == 0) onProgress?.call(1.0);
    return total;
  }
}
