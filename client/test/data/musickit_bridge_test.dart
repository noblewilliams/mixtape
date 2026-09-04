import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixtape/musickit');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('fetchLibrarySongs decodes the platform payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fetchLibrarySongs');
      expect(call.arguments, {'offset': 0, 'limit': 2});
      return {
        'songs': [
          {
            'appleId': '111',
            'title': 'One',
            'artist': 'A',
            'album': null,
            'genre': 'Pop',
            'releaseYear': 2011,
            'explicit': true,
            'playCount': 3,
            'lastPlayedAt': 1724900000000,
            'dateAdded': 1700000000000,
          },
        ],
        'total': 1,
      };
    });

    final bridge = MusicKitBridge();
    final page = await bridge.fetchLibrarySongs(offset: 0, limit: 2);
    expect(page.total, 1);
    expect(page.songs.single.appleId, '111');
    expect(page.songs.single.playCount, 3);
    expect(page.songs.single.album, isNull);
    expect(page.songs.single.releaseYear, 2011);
    expect(page.songs.single.explicit, isTrue);
  });

  test('fetchLibrarySongs decodes a null releaseYear/explicit', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return {
        'songs': [
          {
            'appleId': '112',
            'title': 'One',
            'artist': 'A',
            'album': null,
            'genre': null,
            'releaseYear': null,
            'explicit': null,
            'playCount': 0,
            'lastPlayedAt': null,
            'dateAdded': null,
          },
        ],
        'total': 1,
      };
    });

    final bridge = MusicKitBridge();
    final page = await bridge.fetchLibrarySongs(offset: 0, limit: 2);
    expect(page.songs.single.releaseYear, isNull);
    expect(page.songs.single.explicit, isNull);
  });

  test('requestAuthorization returns the platform bool', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    expect(await MusicKitBridge().requestAuthorization(), isTrue);
  });

  test('requestAuthorization returns false when the platform returns null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(await MusicKitBridge().requestAuthorization(), isFalse);
  });

  test('requestAuthorization wraps a PlatformException in MusicKitException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'x');
    });
    await expectLater(
      MusicKitBridge().requestAuthorization(),
      throwsA(isA<MusicKitException>()),
    );
  });

  test('fetchLibrarySongs wraps a PlatformException in MusicKitException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'x');
    });
    await expectLater(
      MusicKitBridge().fetchLibrarySongs(offset: 0, limit: 2),
      throwsA(isA<MusicKitException>()),
    );
  });

  test('LibrarySong.fromMap(map).toJson() round-trips the exact wire shape', () {
    final map = {
      'appleId': '111',
      'title': 'One',
      'artist': 'A',
      'album': 'The Album',
      'genre': 'Pop',
      'releaseYear': 2011,
      'explicit': true,
      'playCount': 3,
      'lastPlayedAt': 1724900000000,
      'dateAdded': 1700000000000,
    };
    expect(LibrarySong.fromMap(map).toJson(), map);
  });

  test('LibrarySong.fromMap(map).toJson() round-trips null album/genre/releaseYear/explicit', () {
    final map = {
      'appleId': '222',
      'title': 'Two',
      'artist': 'B',
      'album': null,
      'genre': null,
      'releaseYear': null,
      'explicit': null,
      'playCount': 0,
      'lastPlayedAt': null,
      'dateAdded': 1700000000000,
    };
    expect(LibrarySong.fromMap(map).toJson(), map);
  });

  group('playQueue', () {
    test('sends appleIds and decodes a true result', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return true;
      });

      final result = await MusicKitBridge().playQueue(['111', '222']);

      expect(result, isTrue);
      expect(captured?.method, 'playQueue');
      expect(captured?.arguments, {
        'appleIds': ['111', '222'],
      });
    });

    test('decodes a false result', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);
      expect(await MusicKitBridge().playQueue(['111']), isFalse);
    });

    test('treats a null result as false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      expect(await MusicKitBridge().playQueue(['111']), isFalse);
    });

    test('wraps a PlatformException in MusicKitException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'play_failed', message: 'could not play');
      });
      await expectLater(
        MusicKitBridge().playQueue(['111']),
        throwsA(isA<MusicKitException>()),
      );
    });

    test('rejects an empty queue without invoking the channel', () async {
      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        return true;
      });

      await expectLater(
        MusicKitBridge().playQueue(const []),
        throwsA(isA<MusicKitException>()),
      );
      expect(invoked, isFalse);
    });

    test('a wrong-typed (non-bool) platform result degrades to false rather '
        'than a type-cast crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'not-a-bool');
      expect(await MusicKitBridge().playQueue(['111']), isFalse);
    });

    test('a native completion that never fires times out into a '
        'MusicKitException rather than hanging forever', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) => Completer<bool>().future);
      await expectLater(
        MusicKitBridge(
          callTimeout: const Duration(milliseconds: 50),
        ).playQueue(['111']),
        throwsA(isA<MusicKitException>()),
      );
    });
  });

  group('createPlaylist', () {
    test('missing or invalid creation IDs stay unknown without failing the save', () async {
      for (final id in [null, '', 'bad/id', 123]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => {
          'added': 1, 'failed': 0, 'appleLibraryId': id,
        });
        var called = false;
        final result = await MusicKitBridge().createPlaylist('Mix', ['111'],
            onCreated: (_) => called = true);
        expect(called, isFalse);
        expect(result, (added: 1, failed: 0));
      }
    });

    test('receipt failure does not turn successful creation into a save error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => {
        'added': 1, 'failed': 0, 'appleLibraryId': 'p.created',
      });
      expect(await MusicKitBridge().createPlaylist('Mix', ['111'],
          onCreated: (_) => throw Exception('offline')), (added: 1, failed: 0));
    });

    test('reports an exact creation ID without changing added/failed counts', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => {
        'added': 1, 'failed': 1, 'appleLibraryId': 'p.created',
      });
      String? created;
      final result = await MusicKitBridge().createPlaylist('Mix', ['111', '222'],
          onCreated: (id) => created = id);
      expect(created, 'p.created');
      expect(result, (added: 1, failed: 1));
    });

    test('sends name and appleIds and decodes the added/failed record', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return {'added': 2, 'failed': 1};
      });

      final result = await MusicKitBridge().createPlaylist('My Tape', ['111', '222', '333']);

      expect(captured?.method, 'createPlaylist');
      // No author/description passed → keys absent entirely, so the native
      // side keeps its own defaults rather than seeing empty strings.
      expect(captured?.arguments, {
        'name': 'My Tape',
        'appleIds': ['111', '222', '333'],
      });
      expect(result.added, 2);
      expect(result.failed, 1);
    });

    test('author and description ride the payload when provided', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return {'added': 1, 'failed': 0};
      });

      await MusicKitBridge().createPlaylist(
        'My Tape',
        ['111'],
        author: 'mixtape',
        description: 'made by mixtape',
      );

      expect(captured?.arguments, {
        'name': 'My Tape',
        'appleIds': ['111'],
        'author': 'mixtape',
        'description': 'made by mixtape',
      });
    });

    test('defensively decodes a missing added/failed as 0', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => <String, dynamic>{});
      final result = await MusicKitBridge().createPlaylist('My Tape', ['111']);
      expect(result.added, 0);
      expect(result.failed, 0);
    });

    test('defensively decodes a null result as 0/0', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final result = await MusicKitBridge().createPlaylist('My Tape', ['111']);
      expect(result.added, 0);
      expect(result.failed, 0);
    });

    test('wraps a PlatformException in MusicKitException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'x');
      });
      await expectLater(
        MusicKitBridge().createPlaylist('My Tape', ['111']),
        throwsA(isA<MusicKitException>()),
      );
    });

    test('a PlatformException with details carries the native reason in the '
        'message (not just the static bridge string)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'playlist_failed',
          message: 'could not create playlist',
          details: 'The operation couldn’t be completed',
        );
      });
      await expectLater(
        MusicKitBridge().createPlaylist('My Tape', ['111']),
        throwsA(
          isA<MusicKitException>().having(
            (e) => e.message,
            'message',
            'could not create playlist (The operation couldn’t be completed)',
          ),
        ),
      );
    });

    test('rejects an empty name without invoking the channel', () async {
      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        return {'added': 0, 'failed': 0};
      });

      await expectLater(
        MusicKitBridge().createPlaylist('', ['111']),
        throwsA(isA<MusicKitException>()),
      );
      expect(invoked, isFalse);
    });

    test('rejects an empty track list without invoking the channel', () async {
      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        return {'added': 0, 'failed': 0};
      });

      await expectLater(
        MusicKitBridge().createPlaylist('My Tape', const []),
        throwsA(isA<MusicKitException>()),
      );
      expect(invoked, isFalse);
    });

    test('wrong-typed (non-int) added/failed degrade to 0 rather than a '
        'type-cast crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        channel,
        (call) async => {'added': 'two', 'failed': null},
      );
      final result = await MusicKitBridge().createPlaylist('My Tape', ['111']);
      expect(result.added, 0);
      expect(result.failed, 0);
    });

    test('a native completion that never fires times out into a '
        'MusicKitException rather than hanging forever', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        channel,
        (call) => Completer<Map<dynamic, dynamic>>().future,
      );
      await expectLater(
        MusicKitBridge(
          callTimeout: const Duration(milliseconds: 50),
        ).createPlaylist('My Tape', ['111']),
        throwsA(isA<MusicKitException>()),
      );
    });
  });

  group('playlist snapshots', () {
    test('begins and defensively decodes a snapshot header', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'beginPlaylistSnapshot');
            return {
              'snapshotId': 'snapshot-1',
              'storefront': 'ng',
              'totalPlaylists': 2,
              'totalEntries': 3,
            };
          });

      final header = await MusicKitBridge().beginPlaylistSnapshot();

      expect(header.snapshotId, 'snapshot-1');
      expect(header.storefront, 'ng');
      expect(header.totalPlaylists, 2);
      expect(header.totalEntries, 3);
    });

    test('rejects a malformed snapshot header', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async {
              calls.add(call.method);
              if (call.method == 'beginPlaylistSnapshot') {
                return {
                  'snapshotId': '',
                  'storefront': 'NG',
                  'totalPlaylists': -1,
                  'totalEntries': 0,
                };
              }
              return true;
            },
          );

      await expectLater(
        MusicKitBridge().beginPlaylistSnapshot(),
        throwsA(isA<MusicKitException>()),
      );
      expect(calls, ['beginPlaylistSnapshot', 'cancelPlaylistSnapshot']);
    });

    test('rejects a wrong-typed snapshot header and cancels native state', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'beginPlaylistSnapshot') return 'not-a-header';
            return true;
          });

      await expectLater(
        MusicKitBridge().beginPlaylistSnapshot(),
        throwsA(isA<MusicKitException>()),
      );
      expect(calls, ['beginPlaylistSnapshot', 'cancelPlaylistSnapshot']);
    });

    test('times out begin and cancels native materialization', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'beginPlaylistSnapshot') {
              return Completer<Map<dynamic, dynamic>>().future;
            }
            return true;
          });

      await expectLater(
        MusicKitBridge(
          snapshotTimeout: const Duration(milliseconds: 40),
        ).beginPlaylistSnapshot(),
        throwsA(isA<MusicKitException>()),
      );
      expect(calls, ['beginPlaylistSnapshot', 'cancelPlaylistSnapshot']);
    });

    test('fetches a bounded playlist page with nullable artwork', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'fetchPlaylistSnapshotPage');
            expect(call.arguments, {
              'snapshotId': 'snapshot-1',
              'offset': 0,
              'limit': 50,
            });
            return {
              'playlists': [
                {
                  'appleLibraryId': 'library-playlist-1',
                  'appleCatalogId': null,
                  'name': 'Evening',
                  'description': null,
                  'curatorName': null,
                  'artworkUrlTemplate': null,
                  'artworkWidth': null,
                  'artworkHeight': null,
                  'artworkBgColor': 'a1b2c3',
                  'kind': 'user_shared',
                  'canEdit': false,
                  'appleDateAdded': null,
                  'appleLastModifiedAt': 1788200000000,
                  'sourceFingerprint': List.filled(64, 'a').join(),
                  'entryCount': 2,
                },
              ],
              'total': 1,
            };
          });

      final page = await MusicKitBridge().fetchPlaylistSnapshotPage(
        snapshotId: 'snapshot-1',
        offset: 0,
        limit: 500,
      );

      expect(page.total, 1);
      expect(page.playlists.single.artworkUrlTemplate, isNull);
      expect(page.playlists.single.artworkBgColor, 'a1b2c3');
      expect(page.playlists.single.entryCount, 2);
    });

    test('fetches a bounded duplicate-preserving entry page', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'fetchPlaylistEntryPage');
            expect(call.arguments, {
              'snapshotId': 'snapshot-1',
              'playlistAppleId': 'library-playlist-1',
              'offset': 0,
              'limit': 200,
            });
            return {
              'entries': [
                {
                  'position': 0,
                  'appleLibraryEntryId': 'entry-1',
                  'appleLibraryTrackId': 'library-track-1',
                  'appleCatalogId': null,
                  'isrcSnapshot': null,
                  'titleSnapshot': 'Song',
                  'artistSnapshot': 'Artist',
                  'albumSnapshot': null,
                  'durationMsSnapshot': 123000,
                  'artworkUrlTemplateSnapshot': null,
                  'artworkWidthSnapshot': null,
                  'artworkHeightSnapshot': null,
                  'artworkBgColorSnapshot': '010203',
                },
                {
                  'position': 1,
                  'appleLibraryEntryId': 'entry-2',
                  'appleLibraryTrackId': 'library-track-1',
                  'appleCatalogId': null,
                  'isrcSnapshot': null,
                  'titleSnapshot': 'Song',
                  'artistSnapshot': 'Artist',
                  'albumSnapshot': null,
                  'durationMsSnapshot': 123000,
                  'artworkUrlTemplateSnapshot': null,
                  'artworkWidthSnapshot': null,
                  'artworkHeightSnapshot': null,
                  'artworkBgColorSnapshot': '010203',
                },
              ],
              'total': 2,
            };
          });

      final page = await MusicKitBridge().fetchPlaylistEntryPage(
        snapshotId: 'snapshot-1',
        playlistAppleId: 'library-playlist-1',
        offset: 0,
        limit: 999,
      );

      expect(page.total, 2);
      expect(page.entries.map((entry) => entry.position), [0, 1]);
      expect(page.entries.map((entry) => entry.appleLibraryTrackId), [
        'library-track-1',
        'library-track-1',
      ]);
      expect(page.entries.map((entry) => entry.appleLibraryEntryId), [
        'entry-1',
        'entry-2',
      ]);
    });

    test(
      'rejects invalid page arguments before invoking native code',
      () async {
        var invoked = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              invoked = true;
              return null;
            });
        final bridge = MusicKitBridge();

        await expectLater(
          bridge.fetchPlaylistSnapshotPage(snapshotId: '', offset: 0, limit: 1),
          throwsA(isA<MusicKitException>()),
        );
        await expectLater(
          bridge.fetchPlaylistEntryPage(
            snapshotId: 'snapshot-1',
            playlistAppleId: '',
            offset: 0,
            limit: 1,
          ),
          throwsA(isA<MusicKitException>()),
        );
        await expectLater(
          bridge.fetchPlaylistSnapshotPage(
            snapshotId: 'snapshot-1',
            offset: -1,
            limit: 1,
          ),
          throwsA(isA<MusicKitException>()),
        );
        expect(invoked, isFalse);
      },
    );

    test('cancel and release use fixed channel contracts', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      final bridge = MusicKitBridge();

      expect(await bridge.cancelPlaylistSnapshot(), isTrue);
      expect(await bridge.releasePlaylistSnapshot('snapshot-1'), isTrue);
      expect(calls.map((call) => call.method), [
        'cancelPlaylistSnapshot',
        'releasePlaylistSnapshot',
      ]);
      expect(calls.last.arguments, {'snapshotId': 'snapshot-1'});
    });
  });
}
