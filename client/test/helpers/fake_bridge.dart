import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

/// Mirrors the native contract enforced by MusicKitBridge.swift: offset 0 (re)builds
/// the snapshot, and serving the last page clears it. A further offset > 0 call
/// without a fresh offset-0 call throws just like the real bridge would.
class FakeBridge implements MusicKitBridge {
  FakeBridge(this.all);
  final List<LibrarySong> all;
  bool _lastPageServed = false;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    if (offset == 0) {
      _lastPageServed = false;
    } else if (_lastPageServed) {
      throw MusicKitException('no_snapshot');
    }
    final page = all.skip(offset).take(limit).toList();
    if (offset + page.length >= all.length) {
      _lastPageServed = true;
    }
    return LibraryPage(songs: page, total: all.length);
  }

  @override
  Future<bool> playQueue(List<String> appleIds) async => true;

  @override
  Future<({int added, int failed})> createPlaylist(String name, List<String> appleIds) async =>
      (added: appleIds.length, failed: 0);
}

class DeniedBridge implements MusicKitBridge {
  @override
  Future<bool> requestAuthorization() async => false;
  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) =>
      throw UnimplementedError();
  @override
  Future<bool> playQueue(List<String> appleIds) => throw UnimplementedError();
  @override
  Future<({int added, int failed})> createPlaylist(String name, List<String> appleIds) =>
      throw UnimplementedError();
}

/// Serves one page successfully, then fails — simulates a mid-sync platform error.
class BoomBridge implements MusicKitBridge {
  BoomBridge(this.all);
  final List<LibrarySong> all;
  var _calls = 0;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    _calls++;
    if (_calls > 1) throw MusicKitException('boom');
    return LibraryPage(songs: all.skip(offset).take(limit).toList(), total: all.length);
  }

  @override
  Future<bool> playQueue(List<String> appleIds) async => true;

  @override
  Future<({int added, int failed})> createPlaylist(String name, List<String> appleIds) async =>
      (added: appleIds.length, failed: 0);
}

LibrarySong song(int i) =>
    LibrarySong(appleId: '$i', title: 'T$i', artist: 'A', playCount: i);

Future<ApiClient> apiWith(MockClient inner) async {
  final store = InMemoryTokenStore();
  await store.write('t');
  return ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);
}
