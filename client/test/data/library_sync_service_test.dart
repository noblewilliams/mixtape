import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
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
}

class DeniedBridge implements MusicKitBridge {
  @override
  Future<bool> requestAuthorization() async => false;
  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) =>
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
}

LibrarySong song(int i) =>
    LibrarySong(appleId: '$i', title: 'T$i', artist: 'A', playCount: i);

Future<ApiClient> apiWith(MockClient inner) async {
  final store = InMemoryTokenStore();
  await store.write('t');
  return ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);
}

void main() {
  test('pages the bridge and posts chunks until done', () async {
    final postedCounts = <int>[];
    final postedPaths = <String>[];
    final inner = MockClient((req) async {
      postedPaths.add(req.url.path);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      postedCounts.add((body['songs'] as List).length);
      return http.Response('{"ingested": 0}', 200);
    });
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(450, song)),
      api: await apiWith(inner),
      chunkSize: 200,
    );

    final progress = <double>[];
    final total = await service.sync(onProgress: progress.add);

    expect(total, 450);
    expect(postedCounts, [200, 200, 50]);
    expect(postedPaths.toSet(), {'/ingest/library'});
    expect(progress, [200 / 450, 400 / 450, 1.0]);
  });

  test('posts an exact multiple of the chunk size without an extra page fetch', () async {
    final postedCounts = <int>[];
    final inner = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      postedCounts.add((body['songs'] as List).length);
      return http.Response('{"ingested": 0}', 200);
    });
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(400, song)),
      api: await apiWith(inner),
      chunkSize: 200,
    );

    final total = await service.sync();

    expect(total, 400);
    expect(postedCounts, [200, 200]);
  });

  test('posts wire-format songs (toJson shape)', () async {
    late Map<String, dynamic> firstSong;
    final inner = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      firstSong = (body['songs'] as List).first as Map<String, dynamic>;
      return http.Response('{"ingested": 1}', 200);
    });
    final service =
        LibrarySyncService(bridge: FakeBridge([song(5)]), api: await apiWith(inner));
    await service.sync();
    expect(firstSong, {
      'appleId': '5',
      'title': 'T5',
      'artist': 'A',
      'album': null,
      'genre': null,
      'playCount': 5,
      'lastPlayedAt': null,
      'dateAdded': null,
    });
  });

  test('throws LibraryAccessDenied when authorization is denied', () async {
    final service = LibrarySyncService(
      bridge: DeniedBridge(),
      api: await apiWith(MockClient((_) async => http.Response('{}', 200))),
    );
    await expectLater(service.sync(), throwsA(isA<LibraryAccessDenied>()));
  });

  test('handles an empty library (progress 1.0, zero posts)', () async {
    var posts = 0;
    final inner = MockClient((_) async {
      posts++;
      return http.Response('{"ingested": 0}', 200);
    });
    final service =
        LibrarySyncService(bridge: FakeBridge([]), api: await apiWith(inner));
    final progress = <double>[];
    final total = await service.sync(onProgress: progress.add);
    expect(total, 0);
    expect(posts, 0);
    expect(progress.last, 1.0);
  });

  test('propagates ApiException from a failed chunk without further posts', () async {
    var posts = 0;
    final inner = MockClient((_) async {
      posts++;
      return http.Response('{"error":"bad"}', 400);
    });
    final service = LibrarySyncService(
        bridge: FakeBridge(List.generate(450, song)),
        api: await apiWith(inner),
        chunkSize: 200);
    await expectLater(service.sync(), throwsA(isA<ApiException>()));
    expect(posts, 1);
  });

  test('rethrows MusicKitException from a bridge failure mid-sync', () async {
    final service = LibrarySyncService(
      bridge: BoomBridge(List.generate(450, song)),
      api: await apiWith(MockClient((_) async => http.Response('{}', 200))),
      chunkSize: 200,
    );
    await expectLater(service.sync(), throwsA(isA<MusicKitException>()));
  });

  test('rethrows NetworkException when the transport fails', () async {
    final inner = MockClient((_) async => throw http.ClientException('down'));
    final service =
        LibrarySyncService(bridge: FakeBridge([song(1)]), api: await apiWith(inner));
    await expectLater(service.sync(), throwsA(isA<NetworkException>()));
  });

  test('re-entrant sync calls join the in-flight run, then reset for the next call',
      () async {
    var posts = 0;
    final inner = MockClient((_) async {
      posts++;
      return http.Response('{"ingested": 0}', 200);
    });
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(450, song)),
      api: await apiWith(inner),
      chunkSize: 200,
    );

    final a = service.sync();
    final b = service.sync();
    final results = await Future.wait([a, b]);

    expect(results, [450, 450]);
    expect(posts, 3);

    final c = await service.sync();
    expect(c, 450);
    expect(posts, 6);
  });
}
