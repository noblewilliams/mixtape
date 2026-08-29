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
      'playCount': 3,
      'lastPlayedAt': 1724900000000,
      'dateAdded': 1700000000000,
    };
    expect(LibrarySong.fromMap(map).toJson(), map);
  });
}
