import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/playlists/playlist_edit_api.dart';
import 'package:mixtape/data/playlists/playlist_edit_models.dart';

const draftId = '00000000-0000-4000-8000-000000000010';
const playlistId = '00000000-0000-4000-8000-000000000001';
const entryKey = '00000000-0000-4000-8000-000000000020';

Map<String, dynamic> reviewEntryJson({Map<String, dynamic> over = const {}}) =>
    {
      'entryKey': entryKey,
      'position': 1,
      'title': 'Streetcar',
      'artist': 'Daniel Caesar',
      'album': "Pilgrim's Paradise",
      'durationMs': 234000,
      'artworkUrlTemplate': 'https://is1-ssl.mzstatic.com/image/{w}x{h}bb.jpg',
      'artworkWidth': 3000,
      'artworkHeight': 3000,
      'artworkBgColor': '544451',
      'resolved': true,
      ...over,
    };

Map<String, dynamic> viewJson({
  int version = 2,
  bool includeMessages = false,
}) => {
  'draft': {
    'id': draftId,
    'sourcePlaylistId': playlistId,
    'status': 'active',
    'version': version,
    'baseSourceFingerprint':
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'baseName': 'Night Bus Notes',
    'sourceType': 'apple',
    'createdAt': '2026-09-05T10:00:00.000Z',
    'updatedAt': '2026-09-05T11:00:00.000Z',
  },
  'entries': [
    {
      'entryKey': entryKey,
      'origin': 'catalog_addition',
      'sourceEntryId': null,
      'trackId': '00000000-0000-4000-8000-000000000030',
      'appleLibraryTrackId': null,
      'appleCatalogId': 'apple-1',
      'spotifyId': null,
      'title': 'Streetcar',
      'artist': 'Daniel Caesar',
      'album': "Pilgrim's Paradise",
      'durationMs': 234000,
      'artworkUrlTemplate': null,
      'artworkWidth': null,
      'artworkHeight': null,
      'artworkBgColor': '544451',
      'position': 1,
      'resolved': true,
    },
  ],
  'diff': {
    'added': [
      {'entryKey': entryKey, 'toPosition': 1},
    ],
    'removed': [],
    'moved': [],
    'replaced': [],
  },
  'review': {
    'added': [reviewEntryJson()],
    'removed': [],
    'moved': [],
    'replaced': [],
  },
  'capability': {
    'possibleModes': ['revised_copy'],
    'sourceWillRemainUntouched': true,
    'applyAvailable': false,
  },
  if (includeMessages)
    'messages': [
      {
        'id': '00000000-0000-4000-8000-000000000040',
        'draftId': draftId,
        'role': 'user',
        'content': 'add a couple',
        'draftVersion': null,
        'seq': 1,
        'createdAt': '2026-09-05T10:30:00.000Z',
      },
    ],
};

Future<PlaylistEditApi> apiWith(MockClient inner) async {
  final store = InMemoryTokenStore();
  await store.write('token');
  return PlaylistEditApi(baseUrl: 'http://x', tokenStore: store, inner: inner);
}

void main() {
  test(
    'parses an occurrence-aware draft, review projection, and transcript',
    () {
      final thread = PlaylistEditThread.fromJson(
        viewJson(includeMessages: true),
      );

      expect(thread.draft.baseName, 'Night Bus Notes');
      expect(thread.entries.single.entryKey, entryKey);
      expect(thread.diff.added.single.toPosition, 1);
      expect(thread.review.added.single.artist, 'Daniel Caesar');
      expect(thread.capability.possibleModes, ['revised_copy']);
      expect(thread.capability.applyAvailable, isFalse);
      expect(thread.messages.single.draftVersion, isNull);
    },
  );

  test('rejects malformed required fields with a fixed model category', () {
    final json = viewJson();
    (json['draft'] as Map<String, dynamic>)['version'] = -1;
    expect(
      () => PlaylistEditView.fromJson(json),
      throwsA(isA<PlaylistEditModelException>()),
    );
  });

  test('creates, reopens, and sends against the exact draft version', () async {
    final requests = <http.Request>[];
    final api = await apiWith(
      MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/messages')) {
          return http.Response(
            jsonEncode({
              'djMessage': {
                'id': '00000000-0000-4000-8000-000000000050',
                'draftId': draftId,
                'role': 'dj',
                'content': 'I placed two songs.',
                'draftVersion': 2,
                'seq': 2,
                'createdAt': '2026-09-05T11:00:00.000Z',
              },
              'draft': viewJson(),
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(viewJson(includeMessages: request.method == 'GET')),
          request.method == 'POST' ? 201 : 200,
        );
      }),
    );

    final created = await api.createOrResume(playlistId);
    final reopened = await api.getThread(draftId);
    final turn = await api.sendMessage(draftId, 'add a couple', 1);

    expect(api.timeout, const Duration(seconds: 120));
    expect(created.draft.id, draftId);
    expect(reopened.messages, hasLength(1));
    expect(turn.djMessage.draftVersion, 2);
    expect(requests.map((r) => [r.method, r.url.path]), [
      ['POST', '/playlists/$playlistId/edit-draft'],
      ['GET', '/playlist-edit-drafts/$draftId'],
      ['POST', '/playlist-edit-drafts/$draftId/messages'],
    ]);
    expect(jsonDecode(requests.last.body), {
      'content': 'add a couple',
      'expectedVersion': 1,
    });
  });

  test(
    'a conflict carries the canonical draft without exposing raw bodies',
    () async {
      final api = await apiWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': 'conflict',
              'message':
                  'This playlist draft changed somewhere else. Refresh it and try again.',
              'draft': viewJson(version: 3),
            }),
            409,
          ),
        ),
      );

      try {
        await api.sendMessage(draftId, 'move it', 2);
        fail('expected PlaylistEditApiException');
      } on PlaylistEditApiException catch (error) {
        expect(error.kind, 'conflict');
        expect(error.draft?.draft.version, 3);
        expect(error.toString(), isNot(contains('Night Bus Notes')));
      }
    },
  );

  test(
    'malformed successes and upstream bodies use fixed safe messages',
    () async {
      final malformed = await apiWith(
        MockClient((_) async => http.Response('private body', 200)),
      );
      await expectLater(
        malformed.getThread(draftId),
        throwsA(isA<PlaylistEditModelException>()),
      );

      final upstream = await apiWith(
        MockClient((_) async => http.Response('SECRET', 502)),
      );
      try {
        await upstream.sendMessage(draftId, 'hello', 0);
        fail('expected PlaylistEditApiException');
      } on PlaylistEditApiException catch (error) {
        expect(error.kind, 'upstream');
        expect(
          error.message,
          'The DJ could not finish that playlist edit. Try again.',
        );
        expect(error.toString(), isNot(contains('SECRET')));
      }
    },
  );
}
