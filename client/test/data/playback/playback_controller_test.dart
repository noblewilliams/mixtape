import 'dart:async';
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
  int stops = 0, starts = 0;
  bool failStart = false;
  @override
  Stream<PlayerSample> get samples => events.stream;
  @override
  Future<void> start(List<String> ids) async {
    starts++;
    if (failStart) throw Exception('unavailable');
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
}
