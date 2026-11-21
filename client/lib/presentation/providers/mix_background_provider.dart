/// A mix keeps going when the listener leaves the app (2026-11-21).
///
/// The server gives a turn whose client dropped only about 30 s more, and
/// iOS suspends an app a few seconds after it leaves the screen. So while
/// any mix turn is out, the app holds a background task: iOS grants about
/// 30 s more, the turn's stream stays open, and most turns land. One that
/// lands while the app is in the background posts "Your mix is ready".
///
/// A turn longer than that grace is still lost to a closed app; running
/// turns off the request (a durable job + server push) is its own spec.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/background/mix_background.dart';

bool get _onIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

final backgroundTaskHolderProvider = Provider<BackgroundTaskHolder>(
  (ref) => _onIos
      ? const ChannelBackgroundTaskHolder()
      : const NoBackgroundTaskHolder(),
);

final mixReadyAlertsProvider = Provider<MixReadyAlerts>(
  (ref) => _onIos ? LocalNotificationMixReadyAlerts() : const NoMixReadyAlerts(),
);

/// Whether the app is on screen right now. Without a binding (plain Dart
/// tests) or a lifecycle yet, it counts as on screen: no ping.
final appInForegroundProvider = Provider<bool Function()>(
  (ref) => () {
    try {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      return lifecycle == null || lifecycle == AppLifecycleState.resumed;
    } catch (_) {
      return true;
    }
  },
);

/// The state: whether "Your mix is ready" can be sent (permission granted),
/// so the copy only promises a ping it can deliver.
class MixBackgroundNotifier extends Notifier<bool> {
  bool _turnsOut = false;
  int _posting = 0;
  bool _holding = false;
  bool _asked = false;

  @override
  bool build() => false;

  /// Whether any mix turn is out ([MixActivity] says, on every change).
  void turnsOut(bool out) {
    _turnsOut = out;
    if (out) {
      if (!_holding) {
        _holding = true;
        ref.read(backgroundTaskHolderProvider).begin();
      }
      if (!_asked) {
        _asked = true;
        // Asked at the first mix, where "We'll ping you" makes sense of it.
        ref.read(mixReadyAlertsProvider).requestPermission().then((granted) {
          if (ref.mounted) state = granted;
        });
      }
    }
    _release();
  }

  /// A mix turn landed. Call before the turn stops counting as out, so the
  /// task outlives the ping.
  void landed() {
    if (ref.read(appInForegroundProvider)()) return;
    _posting++;
    ref.read(mixReadyAlertsProvider).showMixReady().whenComplete(() {
      _posting--;
      if (ref.mounted) _release();
    });
  }

  void _release() {
    if (!_holding || _turnsOut || _posting > 0) return;
    _holding = false;
    ref.read(backgroundTaskHolderProvider).end();
  }
}

final mixBackgroundProvider = NotifierProvider<MixBackgroundNotifier, bool>(
  MixBackgroundNotifier.new,
);
