class PlayerSample {
  const PlayerSample({
    required this.index,
    required this.positionMs,
    required this.status,
  });
  final int? index;
  final double positionMs;
  final String status;
  factory PlayerSample.fromMap(Map<dynamic, dynamic> m) => PlayerSample(
    index: m['index'] as int?,
    positionMs: (m['positionMs'] as num?)?.toDouble() ?? 0,
    status: m['status'] as String? ?? 'waiting',
  );
}

class ListeningMeter {
  ListeningMeter(this.emit);
  final void Function(int index, int observedMs, String kind) emit;
  int? _index;
  PlayerSample? _previous;
  double _observed = 0;
  int _time = 0;
  String? intent;
  void sample(PlayerSample sample, int time) {
    if (sample.index != _index) {
      finish(intent ?? 'listen');
      if (sample.status == 'playing') _index = sample.index;
    }
    if (_index == null && sample.status == 'playing') _index = sample.index;
    final previous = _previous;
    if (previous != null &&
        sample.index == _index &&
        previous.index == sample.index) {
      final elapsed = time - _time,
          progress = sample.positionMs - previous.positionMs;
      if (intent == 'repeat' && progress < -1000) {
        finish('repeat');
        _index = sample.index;
      } else if (sample.status == 'playing' &&
          previous.status == 'playing' &&
          elapsed > 0 &&
          elapsed <= 2500 &&
          progress >= 0 &&
          (progress - elapsed).abs() <= 750) {
        _observed += progress < elapsed ? progress : elapsed;
      }
    }
    _previous = sample;
    _time = time;
    if (sample.status == 'stopped') finish(intent ?? 'listen');
  }

  void seek() {
    _previous = null;
    intent = null;
  }

  void finish(String kind) {
    if (_index != null) {
      emit(_index!, _observed.round(), kind);
    }
    reset();
  }

  void reset() {
    _index = null;
    _previous = null;
    _observed = 0;
    intent = null;
  }
}

bool qualifies(String kind, int observed, int duration) {
  if (duration <= 0 || observed > duration + 2000) return false;
  final skipLimit = (duration * .25).clamp(0, 30000);
  final listenLimit = (duration * .8).clamp(10000, 60000);
  return kind == 'skip'
      ? observed >= 3000 && observed < skipLimit
      : kind == 'repeat'
      ? observed >= 30000
      : observed >= listenLimit;
}
