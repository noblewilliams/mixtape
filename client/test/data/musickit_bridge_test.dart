import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixtape/musickit');

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
}
