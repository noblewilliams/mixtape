import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';

Map<String, dynamic> summaryJson({Map<String, dynamic> over = const {}}) => {
  'id': '00000000-0000-4000-8000-000000000001',
  'name': 'Evening',
  'curatorName': null,
  'kind': 'user',
  'artworkUrlTemplate': null,
  'artworkWidth': null,
  'artworkHeight': null,
  'artworkBgColor': 'a1b2c3',
  'entryCount': 2,
  'knownDurationMs': 120000,
  'lastModifiedAt': '2026-08-31T10:00:00.000Z',
  'syncedAt': '2026-08-31T11:00:00.000Z',
  'inLibrary': true,
  'capability': 'copy_only',
  ...over,
};

Map<String, dynamic> entryJson({Map<String, dynamic> over = const {}}) => {
  'id': '00000000-0000-4000-8000-000000000002',
  'position': 0,
  'trackId': null,
  'appleCatalogId': null,
  'title': 'Song',
  'artist': 'Artist',
  'album': null,
  'durationMs': null,
  'artworkUrlTemplate': null,
  'artworkWidth': null,
  'artworkHeight': null,
  'artworkBgColor': null,
  'resolved': false,
  ...over,
};

Future<PlaylistApi> apiWith(MockClient inner) async {
  final store = InMemoryTokenStore();
  await store.write('token');
  return PlaylistApi(
    ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner),
  );
}

void main() {
  test('origin is explicit and older or unknown server values stay neutral', () {
    expect(PlaylistSummary.fromJson(summaryJson()).origin, 'unknown');
    expect(PlaylistSummary.fromJson(summaryJson(over: {'origin': 'mixtape'})).origin, 'mixtape');
    expect(PlaylistSummary.fromJson(summaryJson(over: {'origin': 'user_confirmed'})).origin, 'user_confirmed');
    expect(PlaylistSummary.fromJson(summaryJson(over: {'origin': 'future'})).origin, 'unknown');
  });

  test('lists playlists with encoded filters and defensive nulls', () async {
    late http.Request request;
    final api = await apiWith(
      MockClient((value) async {
        request = value;
        return http.Response(
          jsonEncode({
            'playlists': [summaryJson()],
            'nextCursor': 'next-token',
          }),
          200,
        );
      }),
    );

    final page = await api.list(
      status: PlaylistStatus.all,
      query: 'Fifty_% energy',
      limit: 20,
      cursor: 'cursor-token',
    );

    expect(request.method, 'GET');
    expect(request.headers['Authorization'], 'Bearer token');
    expect(request.url.path, '/playlists');
    expect(request.url.queryParameters, {
      'status': 'all',
      'q': 'Fifty_% energy',
      'limit': '20',
      'cursor': 'cursor-token',
    });
    expect(page.playlists.single.name, 'Evening');
    expect(page.playlists.single.artworkBgColor, 'a1b2c3');
    expect(page.playlists.single.artworkUrlTemplate, isNull);
    expect(page.nextCursor, 'next-token');
  });

  test('gets paged detail with unresolved duplicate-safe entries', () async {
    late Uri requestUrl;
    final api = await apiWith(
      MockClient((request) async {
        requestUrl = request.url;
        return http.Response(
          jsonEncode({
            'playlist': summaryJson(over: {'inLibrary': false}),
            'entries': [
              entryJson(),
              entryJson(
                over: {
                  'id': '00000000-0000-4000-8000-000000000003',
                  'position': 1,
                },
              ),
            ],
            'nextEntryCursor': null,
          }),
          200,
        );
      }),
    );

    final detail = await api.get(
      '00000000-0000-4000-8000-000000000001',
      entryLimit: 50,
      entryCursor: 'entry-cursor',
    );

    expect(requestUrl.path, '/playlists/00000000-0000-4000-8000-000000000001');
    expect(requestUrl.queryParameters, {
      'entryLimit': '50',
      'entryCursor': 'entry-cursor',
    });
    expect(detail.playlist.inLibrary, isFalse);
    expect(detail.entries.map((entry) => entry.position), [0, 1]);
    expect(
      detail.entries.every((entry) => !entry.resolved && entry.trackId == null),
      isTrue,
    );
  });

  test('drops malformed optional metadata instead of failing the page', () {
    final playlist = PlaylistSummary.fromJson(
      summaryJson(
        over: {
          'curatorName': 7,
          'artworkWidth': -1,
          'artworkBgColor': '#BAD',
          'knownDurationMs': 'unknown',
          'lastModifiedAt': 'not-a-date',
        },
      ),
    );
    final entry = PlaylistEntry.fromJson(
      entryJson(
        over: {
          'trackId': 9,
          'album': false,
          'durationMs': -1,
          'artworkBgColor': 'ABCDEF',
        },
      ),
    );

    expect(playlist.curatorName, isNull);
    expect(playlist.artworkWidth, isNull);
    expect(playlist.artworkBgColor, isNull);
    expect(playlist.knownDurationMs, isNull);
    expect(playlist.lastModifiedAt, isNull);
    expect(entry.trackId, isNull);
    expect(entry.album, isNull);
    expect(entry.durationMs, isNull);
    expect(entry.artworkBgColor, isNull);
  });

  test(
    'missing required identity/display fields fail with a fixed category',
    () async {
      expect(
        () => PlaylistSummary.fromJson(summaryJson(over: {'name': null})),
        throwsA(isA<PlaylistModelException>()),
      );
      expect(
        () => PlaylistEntry.fromJson(entryJson(over: {'position': -1})),
        throwsA(isA<PlaylistModelException>()),
      );
      final api = await apiWith(
        MockClient(
          (_) async => http.Response(
            '{"playlists":[{"name":"private playlist"}],"nextCursor":null}',
            200,
          ),
        ),
      );
      try {
        await api.list();
        fail('expected PlaylistModelException');
      } on PlaylistModelException catch (error) {
        expect(error.toString(), 'PlaylistModelException');
        expect(error.toString(), isNot(contains('private playlist')));
      }
    },
  );

  test('passes HTTP failures through as ApiException', () async {
    final api = await apiWith(
      MockClient((_) async => http.Response('{"error":"no"}', 404)),
    );
    await expectLater(api.get('missing'), throwsA(isA<ApiException>()));
  });
}
