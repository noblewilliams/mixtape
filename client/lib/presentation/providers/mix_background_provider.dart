/// A mix keeps going when the listener leaves the app (2026-11-21).
///
/// The server gives a turn whose client dropped only about 30 s more, and
/// iOS suspends an app a few seconds after it leaves the screen. So while
/// any mix turn is out, the app holds a background task: iOS grants about
/// 30 s more, the turn's stream stays open, and most turns land. One that
/// lands while the app is in the background posts "Your mix is ready".
///
/// A turn longer than that grace is carried by the server's durable turn and
/// its push (spec 2026-11-21); a turn whose stream said the server pushes it
/// posts no local ping ([MixBackgroundNotifier.landed]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/background/mix_background.dart';
import '../../data/push/push_service.dart';
import 'push_provider.dart';

bool get _onIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

final backgroundTaskHolderProvider = Provider<BackgroundTaskHolder>(
  (ref) => _onIos
      ? const ChannelBackgroundTaskHolder()
      : const NoBackgroundTaskHolder(),
);

final mixReadyAlertsProvider = Provider<MixReadyAlerts>(
  (ref) =>
      _onIos ? LocalNotificationMixReadyAlerts() : const NoMixReadyAlerts(),
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

/// The state: whether "Your mix is ready" can be sent (permission granted,
/// and not turned off in You), so the copy only promises a ping it can
/// deliver.
///
/// It never asks: the Mix ready pop-up is the one ask
/// (`widgets/push_permission_popup.dart`; the same OS permission covers this
/// local ping and the server's push). It reads the permission at the first
/// turn and again whenever the pop-up or You changes it ([refresh]).
class MixBackgroundNotifier extends Notifier<bool> {
  bool _turnsOut = false;
  int _posting = 0;
  bool _holding = false;

  /// The permission read in flight (or done) since the first turn.
  Future<void>? _reading;

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
      _reading ??= refresh();
    }
    _release();
  }

  /// Reads the permission (and You's off) again, without asking.
  Future<void> refresh() {
    final reading = _readAllowed();
    _reading = reading;
    return reading;
  }

  Future<void> _readAllowed() async {
    var allowed = false;
    try {
      allowed =
          await ref.read(pushChannelProvider).status() == PushStatus.authorized;
      if (allowed) allowed = !await ref.read(pushAskStoreProvider).optedOut();
    } catch (_) {}
    if (ref.mounted) state = allowed;
  }

  /// A mix turn landed. Call before the turn stops counting as out, so the
  /// task outlives the ping.
  ///
  /// [serverPushes] is the turn's `turn` event saying `push: true` (spec
  /// 2026-11-21 durable mix turns, "Who notifies"): the server tells the
  /// listener itself, so no local ping. A turn with no `turn` event (an
  /// older server) pings as it always did.
  void landed({bool serverPushes = false}) {
    if (serverPushes) return;
    if (ref.read(appInForegroundProvider)()) return;
    _posting++;
    final alerts = ref.read(mixReadyAlertsProvider);
    final reading = _reading ?? refresh();
    () async {
      await reading;
      // Not allowed, or turned off in You: no ping of any kind.
      if (!ref.mounted || !state) return;
      await alerts.showMixReady();
    }().whenComplete(() {
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
