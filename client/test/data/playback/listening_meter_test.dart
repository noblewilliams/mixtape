import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playback/listening_meter.dart';

void main() {
  test('seeks, pauses and unobserved gaps do not count as listening', () {
    final events = <int>[];
    final meter = ListeningMeter((_, ms, _) => events.add(ms));
    void sample(double position, int time, String status) => meter.sample(
      PlayerSample(index: 0, positionMs: position, status: status),
      time,
    );
    sample(0, 0, 'playing');
    sample(1000, 1000, 'playing');
    sample(120000, 2000, 'playing');
    sample(121000, 3000, 'playing');
    sample(122000, 100000, 'playing');
    sample(122000, 101000, 'paused');
    meter.finish('listen');
    expect(events, [2000]);
  });
  test('an explicit next differs from an unknown transition', () {
    final events = <String>[];
    final meter = ListeningMeter((_, _, kind) => events.add(kind));
    meter.sample(
      const PlayerSample(index: 0, positionMs: 0, status: 'playing'),
      0,
    );
    meter.intent = 'skip';
    meter.sample(
      const PlayerSample(index: 1, positionMs: 0, status: 'playing'),
      1000,
    );
    meter.sample(
      const PlayerSample(index: 2, positionMs: 0, status: 'playing'),
      2000,
    );
    expect(events, ['skip', 'listen']);
    expect(qualifies('listen', 60000, 200000), isTrue);
    expect(qualifies('skip', 100, 200000), isFalse);
  });
}
