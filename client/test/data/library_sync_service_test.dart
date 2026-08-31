import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import '../helpers/fake_bridge.dart';

void main() {
  test('pages the bridge and posts chunks until done', () async {
    final postedCounts = <int>[];
    final postedPaths = <String>[];
    final inner = MockClient((req) async {
      if (req.url.path != '/ingest/library') {
        return emptyPlaylistResponse(req);
      }
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
    final summary = await service.sync(onProgress: progress.add);

    expect(summary.songs, 450);
    expect(summary.playlists, 0);
    expect(postedCounts, [200, 200, 50]);
    expect(postedPaths.toSet(), {'/ingest/library'});
    expect(progress, [0.6 * 200 / 450, 0.6 * 400 / 450, 0.6, 0.95, 1.0]);
  });

  test('posts an exact multiple of the chunk size without an extra page fetch', () async {
    final postedCounts = <int>[];
    final inner = MockClient((req) async {
      if (req.url.path != '/ingest/library') {
        return emptyPlaylistResponse(req);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      postedCounts.add((body['songs'] as List).length);
      return http.Response('{"ingested": 0}', 200);
    });
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(400, song)),
      api: await apiWith(inner),
      chunkSize: 200,
    );

    final summary = await service.sync();

    expect(summary.songs, 400);
    expect(postedCounts, [200, 200]);
  });

  test('posts wire-format songs (toJson shape)', () async {
    late Map<String, dynamic> firstSong;
    final inner = MockClient((req) async {
      if (req.url.path != '/ingest/library') {
        return emptyPlaylistResponse(req);
      }
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
      'releaseYear': null,
      'explicit': null,
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
    var songPosts = 0;
    final inner = MockClient((req) async {
      if (req.url.path == '/ingest/library') {
        songPosts++;
      }
      return emptyPlaylistResponse(req);
    });
    final service =
        LibrarySyncService(bridge: FakeBridge([]), api: await apiWith(inner));
    final progress = <double>[];
    final summary = await service.sync(onProgress: progress.add);
    expect(summary.songs, 0);
    expect(songPosts, 0);
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
    var songPosts = 0;
    final inner = MockClient((req) async {
      if (req.url.path == '/ingest/library') {
        songPosts++;
        return http.Response('{"ingested": 0}', 200);
      }
      return emptyPlaylistResponse(req);
    });
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(450, song)),
      api: await apiWith(inner),
      chunkSize: 200,
    );

    final a = service.sync();
    final b = service.sync();
    final results = await Future.wait([a, b]);

    expect(results.map((result) => result.songs), [450, 450]);
    expect(songPosts, 3);

    final c = await service.sync();
    expect(c.songs, 450);
    expect(songPosts, 6);
  });
}

http.Response emptyPlaylistResponse(http.Request request) {
  if (request.url.path == '/ingest/playlists/syncs') {
    return http.Response(
      '{"syncId":"empty-sync","expiresAt":1788203600000}',
      201,
    );
  }
  if (request.url.path.endsWith('/complete')) {
    return http.Response(
      '{"playlists":0,"entries":0,"resolvedEntries":0,"unresolvedEntries":0}',
      200,
    );
  }
  return http.Response('{"accepted":0}', 200);
}
