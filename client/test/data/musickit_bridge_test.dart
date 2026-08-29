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
}
