import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

class FakeBridge implements MusicKitBridge {
  FakeBridge(this.all);
  final List<LibrarySong> all;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    return LibraryPage(songs: all.skip(offset).take(limit).toList(), total: all.length);
  }
}

class DeniedBridge implements MusicKitBridge {
  @override
  Future<bool> requestAuthorization() async => false;
  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) =>
      throw UnimplementedError();
}

LibrarySong song(int i) =>
    LibrarySong(appleId: '$i', title: 'T$i', artist: 'A', playCount: i);

ApiClient apiWith(MockClient inner) => ApiClient(
    baseUrl: 'http://x', tokenStore: InMemoryTokenStore()..write('t'), inner: inner);

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
      api: apiWith(inner),
      chunkSize: 200,
    );

    final progress = <double>[];
    final total = await service.sync(onProgress: progress.add);

    expect(total, 450);
    expect(postedCounts, [200, 200, 50]);
    expect(postedPaths.toSet(), {'/ingest/library'});
    expect(progress.last, 1.0);
    expect(progress, orderedEquals([...progress]..sort())); // monotonic
  });

  test('posts wire-format songs (toJson shape)', () async {
    late Map<String, dynamic> firstSong;
    final inner = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      firstSong = (body['songs'] as List).first as Map<String, dynamic>;
      return http.Response('{"ingested": 1}', 200);
    });
    final service =
        LibrarySyncService(bridge: FakeBridge([song(5)]), api: apiWith(inner));
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
      api: apiWith(MockClient((_) async => http.Response('{}', 200))),
    );
    await expectLater(service.sync(), throwsA(isA<LibraryAccessDenied>()));
  });

  test('handles an empty library (progress 1.0, zero posts)', () async {
    var posts = 0;
    final inner = MockClient((_) async {
      posts++;
      return http.Response('{"ingested": 0}', 200);
    });
    final service = LibrarySyncService(bridge: FakeBridge([]), api: apiWith(inner));
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
        bridge: FakeBridge(List.generate(450, song)), api: apiWith(inner), chunkSize: 200);
    await expectLater(service.sync(), throwsA(isA<ApiException>()));
    expect(posts, 1);
  });
}
