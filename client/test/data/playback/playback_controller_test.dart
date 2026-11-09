import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playback/playback_api.dart';
import 'package:mixtape/data/playback/player_bridge.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playback/listening_meter.dart';

class FakeApi implements PlaybackApi {
  bool enabled = true, fail = false;
  int revision = 1;
  final batches = <List<Map<String, dynamic>>>[];
  @override
  ApiClient get client => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> preferences() async => {
    'enabled': enabled,
    'revision': revision,
    'userId': 'owner',
  };
  @override
  Future<Map<String, dynamic>> save(bool value) async {
    if (fail) throw Exception('offline');
    enabled = value;
    revision++;
    return preferences();
  }

  @override
  Future<Map<String, dynamic>> clear(String id, int revision) async =>
      preferences();
  @override
  Future<void> send(int revision, List<Map<String, dynamic>> events) async {
    batches.add(events);
  }
}

class FakeBridge extends AppPlayerBridge {
  final events = StreamController<PlayerSample>.broadcast();
  Completer<void>? pending;
  int stops = 0, starts = 0, authorizes = 0;
  bool failStart = false, allowAccess = true;

  /// Native failures, thrown one per start in order (then starts succeed).
  final startErrors = <Object>[];
  @override
  Stream<PlayerSample> get samples => events.stream;
  @override
  Future<bool> authorize() async {
    authorizes++;
    return allowAccess;
  }

  @override
  Future<void> start(List<String> ids) async {
    starts++;
    if (failStart) throw Exception('unavailable');
    if (startErrors.isNotEmpty) throw startErrors.removeAt(0);
    await pending?.future;
  }

  @override
  Future<void> command(String action, {double? seconds}) async {
    if (action == 'stop') stops++;
  }
}

const song = QueueTrack(
  position: 3,
  trackId: 'track',
  appleId: '123',
  title: 'Song',
  artist: 'Artist',
  durationMs: 200000,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed starts retry the intended mix instead of an old native queue',
    () async {
      final api = FakeApi(), bridge = FakeBridge()..failStart = true;
      final player = PlaybackController(api, bridge);
      await player.start('new', 3, 'New mix', [song]);
      bridge.failStart = false;
      await player.command('resume');
      expect(bridge.starts, 2);
      expect(player.sessionId, 'new');
      player.dispose();
      await bridge.events.close();
    },
  );
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'captures the played version and original positions without changing the source queue',
    () async {
      final api = FakeApi(), bridge = FakeBridge();
      final player = PlaybackController(api, bridge);
      final queue = [song];
      await player.start('mix', 7, 'Mix', queue);
      queue.clear();
      for (var t = 0; t <= 60000; t += 1000) {
        player.meter.sample(
          PlayerSample(index: 0, positionMs: t.toDouble(), status: 'playing'),
          t,
        );
      }
      await player.stop();
      await Future<void>.delayed(Duration.zero);
      expect(api.batches.single.single, containsPair('version', 7));
      expect(api.batches.single.single, containsPair('position', 3));
      expect(player.tracks.length, 1);
      player.dispose();
      await bridge.events.close();
    },
  );
  test(
    'off means no collection and cancellation fences a pending native start',
    () async {
      final api = FakeApi()..enabled = false;
      final bridge = FakeBridge()..pending = Completer<void>();
      final player = PlaybackController(api, bridge);
      await player.initialize();
      final start = player.start('mix', 1, 'Mix', [song]);
      await Future<void>.delayed(Duration.zero);
      await player.stop();
      bridge.pending!.complete();
      await start;
      expect(player.busy, isFalse);
      expect(player.sample.status, 'stopped');
      expect(api.batches, isEmpty);
      player.dispose();
      await bridge.events.close();
    },
  );
  test(
    'an unconfirmed opt-out still stops local collection immediately',
    () async {
      final api = FakeApi(), bridge = FakeBridge();
      final player = PlaybackController(api, bridge);
      await player.initialize();
      api.fail = true;
      await expectLater(player.setLearning(false), throwsException);
      expect(player.preferences, isNull);
      player.dispose();
      await bridge.events.close();
    },
  );
  group('a start the native player refuses', () {
    PlatformException native(String code, [Object? details]) =>
        PlatformException(code: code, message: 'native', details: details);
    const generic =
        'Apple Music could not play this song. Check access and your subscription. Your mix is unchanged.';

    test('asks for Apple Music access on the tap, then starts', () async {
      final api = FakeApi(),
          bridge = FakeBridge()
            ..startErrors.add(native('authorization_required'));
      final player = PlaybackController(api, bridge);
      final outcome = await player.start('mix', 1, 'Mix', [song]);
      expect(outcome, PlaybackStart.started);
      expect(bridge.authorizes, 1);
      expect(bridge.starts, 2);
      expect(player.error, isEmpty);
      expect(player.failureCode, isNull);
      player.dispose();
      await bridge.events.close();
    });

    test('access refused is reported, not retried', () async {
      final api = FakeApi(),
          bridge = FakeBridge()
            ..allowAccess = false
            ..startErrors.add(native('authorization_required'));
      final player = PlaybackController(api, bridge);
      final outcome = await player.start('mix', 1, 'Mix', [song]);
      expect(outcome, PlaybackStart.unavailable);
      expect(bridge.starts, 1);
      expect(player.failureCode, 'authorization_denied');
      expect(player.error, isNot(generic));
      player.dispose();
      await bridge.events.close();
    });

    test('subscription_required names the cause', () async {
      final api = FakeApi(),
          bridge = FakeBridge()
            ..startErrors.add(native('subscription_required'));
      final player = PlaybackController(api, bridge);
      final outcome = await player.start('mix', 1, 'Mix', [song]);
      expect(outcome, PlaybackStart.subscriptionRequired);
      expect(player.failureCode, 'subscription_required');
      expect(player.error, 'Playing needs an Apple Music subscription.');
      expect(bridge.authorizes, 0);
      player.dispose();
      await bridge.events.close();
    });

    test('song_unavailable keeps its code and the index it names', () async {
      final api = FakeApi(),
          bridge = FakeBridge()
            ..startErrors.add(native('song_unavailable', {'index': 0}));
      final player = PlaybackController(api, bridge);
      final outcome = await player.start('mix', 1, 'Mix', [song]);
      expect(outcome, PlaybackStart.unavailable);
      expect(player.failureCode, 'song_unavailable');
      expect(player.unavailableIndex, 0);
      expect(player.error, isNot(generic));
      player.dispose();
      await bridge.events.close();
    });

    test('playback_failed keeps its code', () async {
      final api = FakeApi(),
          bridge = FakeBridge()..startErrors.add(native('playback_failed'));
      final player = PlaybackController(api, bridge);
      final outcome = await player.start('mix', 1, 'Mix', [song]);
      expect(outcome, PlaybackStart.unavailable);
      expect(player.failureCode, 'playback_failed');
      expect(player.error, isNot(generic));
      expect(player.error, isNotEmpty);
      player.dispose();
      await bridge.events.close();
    });

    test('a start overtaken by stop reports superseded', () async {
      final api = FakeApi(), bridge = FakeBridge()..pending = Completer<void>();
      final player = PlaybackController(api, bridge);
      await player.initialize();
      final start = player.start('mix', 1, 'Mix', [song]);
      await Future<void>.delayed(Duration.zero);
      await player.stop();
      bridge.pending!.complete();
      expect(await start, PlaybackStart.superseded);
      player.dispose();
      await bridge.events.close();
    });

    test('release forgets a mix handed to the Music app', () async {
      final api = FakeApi(),
          bridge = FakeBridge()..startErrors.add(native('playback_failed'));
      final player = PlaybackController(api, bridge);
      await player.start('mix', 1, 'Mix', [song]);
      player.release();
      expect(player.sessionId, isNull);
      expect(player.tracks, isEmpty);
      expect(player.error, isEmpty);
      expect(player.failureCode, isNull);
      expect(player.unavailableIndex, isNull);
      expect(player.sample.status, 'stopped');
      player.dispose();
      await bridge.events.close();
    });
  });
}
