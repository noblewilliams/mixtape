import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

import '../helpers/fake_bridge.dart';

PlaylistSnapshotPlaylist playlist(String id, int count) =>
    PlaylistSnapshotPlaylist(
      appleLibraryId: id,
      name: 'Playlist $id',
      kind: 'user',
      canEdit: false,
      sourceFingerprint: List.filled(64, 'a').join(),
      entryCount: count,
    );

PlaylistSnapshotEntry entry(String id, int position) => PlaylistSnapshotEntry(
  position: position,
  appleLibraryEntryId: id,
  titleSnapshot: 'Song $id',
  artistSnapshot: 'Artist',
);

class SnapshotBridge extends FakeBridge {
  SnapshotBridge({
    required List<LibrarySong> all,
    required this.playlists,
    required this.entries,
    this.events,
    this.beginGate,
  }) : super(all);

  final List<PlaylistSnapshotPlaylist> playlists;
  final Map<String, List<PlaylistSnapshotEntry>> entries;
  final List<String>? events;
  final Completer<void>? beginGate;
  var beginCalls = 0;
  var cancelCalls = 0;
  var releaseCalls = 0;

  @override
  Future<bool> requestAuthorization() async {
    events?.add('authorize');
    return true;
  }

  @override
  Future<LibraryPage> fetchLibrarySongs({
    required int offset,
    required int limit,
  }) async {
    events?.add('songs:$offset');
    return super.fetchLibrarySongs(offset: offset, limit: limit);
  }

  @override
  Future<PlaylistSnapshotHeader> beginPlaylistSnapshot() async {
    beginCalls++;
    events?.add('native:begin');
    await beginGate?.future;
    return PlaylistSnapshotHeader(
      snapshotId: 'snapshot-1',
      storefront: 'ng',
      totalPlaylists: playlists.length,
      totalEntries: entries.values.fold(0, (sum, value) => sum + value.length),
    );
  }

  @override
  Future<PlaylistSnapshotPage> fetchPlaylistSnapshotPage({
    required String snapshotId,
    required int offset,
    required int limit,
  }) async {
    events?.add('native:playlists:$offset');
    return PlaylistSnapshotPage(
      playlists: playlists.skip(offset).take(limit).toList(),
      total: playlists.length,
    );
  }

  @override
  Future<PlaylistEntryPage> fetchPlaylistEntryPage({
    required String snapshotId,
    required String playlistAppleId,
    required int offset,
    required int limit,
  }) async {
    events?.add('native:entries:$playlistAppleId:$offset');
    final allEntries = entries[playlistAppleId] ?? const [];
    return PlaylistEntryPage(
      entries: allEntries.skip(offset).take(limit).toList(),
      total: allEntries.length,
    );
  }

  @override
  Future<bool> cancelPlaylistSnapshot() async {
    cancelCalls++;
    events?.add('native:cancel');
    beginGate?.complete();
    return true;
  }

  @override
  Future<bool> releasePlaylistSnapshot(String snapshotId) async {
    releaseCalls++;
    events?.add('native:release');
    return true;
  }
}

http.Response responseFor(http.Request request, List<String> events) {
  events.add('http:${request.method}:${request.url.path}');
  if (request.url.path == '/ingest/library') {
    return http.Response('{"ingested":2}', 200);
  }
  if (request.url.path == '/ingest/playlists/syncs' &&
      request.method == 'POST') {
    return http.Response('{"syncId":"sync-1","expiresAt":1788203600000}', 201);
  }
  if (request.url.path.endsWith('/complete')) {
    return http.Response(
      '{"playlists":2,"entries":2,"resolvedEntries":1,"unresolvedEntries":1}',
      200,
    );
  }
  return http.Response('{"accepted":1}', 200);
}

void main() {
  test('syncs songs first, then complete ordered playlist snapshots', () async {
    final events = <String>[];
    final bridge = SnapshotBridge(
      all: [song(1), song(2)],
      playlists: [playlist('p-1', 2), playlist('p-2', 0)],
      entries: {
        'p-1': [entry('e-1', 0), entry('e-2', 1)],
        'p-2': [],
      },
      events: events,
    );
    final bodies = <String, List<Map<String, dynamic>>>{};
    final api = await apiWith(
      MockClient((request) async {
        final decoded = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        bodies.putIfAbsent(request.url.path, () => []).add(decoded);
        return responseFor(request, events);
      }),
    );
    final progress = <double>[];

    final summary = await LibrarySyncService(
      bridge: bridge,
      api: api,
      chunkSize: 200,
    ).sync(onProgress: progress.add);

    expect(summary.songs, 2);
    expect(summary.playlists, 2);
    expect(summary.entries, 2);
    expect(summary.resolvedEntries, 1);
    expect(summary.unresolvedEntries, 1);
    expect(events, [
      'authorize',
      'songs:0',
      'http:POST:/ingest/library',
      'native:begin',
      'http:POST:/ingest/playlists/syncs',
      'native:playlists:0',
      'http:PUT:/ingest/playlists/syncs/sync-1/playlists',
      'native:entries:p-1:0',
      'http:PUT:/ingest/playlists/syncs/sync-1/entries',
      'native:entries:p-2:0',
      'http:PUT:/ingest/playlists/syncs/sync-1/entries',
      'http:POST:/ingest/playlists/syncs/sync-1/complete',
      'native:release',
    ]);
    final uploaded = bodies['/ingest/playlists/syncs/sync-1/playlists']!.single;
    expect((uploaded['playlists'] as List).map((value) => value['ordinal']), [
      0,
      1,
    ]);
    expect(progress.last, 1.0);
    for (var index = 1; index < progress.length; index++) {
      expect(progress[index], greaterThanOrEqualTo(progress[index - 1]));
    }
    expect(bridge.releaseCalls, 1);
  });

  test('a song upload failure never begins a playlist snapshot', () async {
    final bridge = SnapshotBridge(all: [song(1)], playlists: [], entries: {});
    final service = LibrarySyncService(
      bridge: bridge,
      api: await apiWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 500)),
      ),
    );

    await expectLater(service.sync(), throwsA(isA<Exception>()));
    expect(bridge.beginCalls, 0);
    expect(bridge.releaseCalls, 0);
  });

  test(
    'a playlist upload failure skips completion and releases once',
    () async {
      final bridge = SnapshotBridge(
        all: [],
        playlists: [playlist('p-1', 0)],
        entries: {'p-1': []},
      );
      var completes = 0;
      final service = LibrarySyncService(
        bridge: bridge,
        api: await apiWith(
          MockClient((request) async {
            if (request.url.path == '/ingest/playlists/syncs') {
              return http.Response(
                '{"syncId":"sync-1","expiresAt":1788203600000}',
                201,
              );
            }
            if (request.url.path.endsWith('/playlists')) {
              return http.Response('{"error":"bad"}', 500);
            }
            if (request.url.path.endsWith('/complete')) completes++;
            return http.Response('{}', 200);
          }),
        ),
      );

      await expectLater(service.sync(), throwsA(isA<Exception>()));
      expect(completes, 0);
      expect(bridge.releaseCalls, 1);
    },
  );

  test(
    'cancellation after the final upload skips completion and releases once',
    () async {
      final bridge = SnapshotBridge(
        all: [],
        playlists: [playlist('p-1', 0)],
        entries: {'p-1': []},
      );
      late LibrarySyncService service;
      var completes = 0;
      service = LibrarySyncService(
        bridge: bridge,
        api: await apiWith(
          MockClient((request) async {
            if (request.url.path == '/ingest/playlists/syncs') {
              return http.Response(
                '{"syncId":"sync-1","expiresAt":1788203600000}',
                201,
              );
            }
            if (request.url.path.endsWith('/entries')) service.cancel();
            if (request.url.path.endsWith('/complete')) completes++;
            return http.Response('{"accepted":0}', 200);
          }),
        ),
      );

      await expectLater(service.sync(), throwsA(isA<SyncCancelled>()));
      expect(completes, 0);
      expect(bridge.releaseCalls, 1);
    },
  );

  test('cancellation interrupts native materialization', () async {
    final gate = Completer<void>();
    final bridge = SnapshotBridge(
      all: [],
      playlists: [],
      entries: {},
      beginGate: gate,
    );
    final service = LibrarySyncService(
      bridge: bridge,
      api: await apiWith(MockClient((_) async => http.Response('{}', 200))),
    );

    final running = service.sync();
    while (bridge.beginCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    service.cancel();

    await expectLater(running, throwsA(isA<SyncCancelled>()));
    expect(bridge.cancelCalls, 1);
  });
}
