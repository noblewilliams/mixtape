/// Mix-ready pushes on this device (spec 2026-11-21 durable mix turns → iOS
/// client): the registration, which follows the session, the tap waiting to
/// be opened, and the mix on screen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/push/push_ask_store.dart';
import '../../data/push/push_service.dart';
import 'auth_provider.dart';

bool get _onIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

final pushChannelProvider = Provider<PushChannel>(
  (ref) => _onIos ? MethodPushChannel.instance : const NoPushChannel(),
);

/// User-scoped (CLAUDE.md): it watches [authProvider], so every sign-in, a
/// link from anonymous, and a sign-out rebuild it. With a session (anonymous
/// ones included: the first mix is made before sign-up) and permission, the
/// fresh service registers. Kept alive from launch by the app root.
final pushServiceProvider = Provider<PushService>((ref) {
  final auth = ref.watch(authProvider);
  final service = PushService(
    channel: ref.watch(pushChannelProvider),
    api: ref.watch(apiClientProvider),
  );
  final slot = ref.watch(currentPushServiceProvider);
  slot._current = service;
  ref.onDispose(() {
    service.dispose();
    if (identical(slot._current, service)) slot._current = null;
  });
  if (auth == AuthStatus.session) {
    // Not when the listener turned "Mix ready notifications" off in You.
    final store = ref.watch(pushAskStoreProvider);
    unawaited(() async {
      var optedOut = false;
      try {
        optedOut = await store.optedOut();
      } catch (_) {}
      if (!optedOut) await service.registerIfAuthorized();
    }());
  }
  return service;
});

/// The device's notification flags: the pop-up's once, and You's off.
final pushAskStoreProvider = Provider<PushAskStore>(
  (ref) => SecurePushAskStore(),
);

/// Whether this build can receive pushes at all (iOS). Off it, You shows no
/// row and nothing ever asks.
final pushAvailableProvider = Provider<bool>(
  (ref) => ref.watch(pushChannelProvider) is! NoPushChannel,
);

/// What You's "Mix ready notifications" row shows.
enum PushSetting {
  /// Allowed and registered.
  on,

  /// Not asked yet (Not now), or turned off here: the switch is the way in.
  off,

  /// Denied in iOS: only iOS Settings can undo it.
  deniedInSettings,
}

/// The row's state: the OS permission and the listener's own off. Read
/// again on [refresh] (You does at every return to the foreground, since
/// iOS Settings may have changed it).
class PushSettingNotifier extends AsyncNotifier<PushSetting> {
  @override
  Future<PushSetting> build() async {
    ref.watch(authProvider);
    return _read();
  }

  Future<PushSetting> _read() async {
    final status = await ref.read(pushServiceProvider).status();
    if (status == PushStatus.denied) return PushSetting.deniedInSettings;
    if (status == PushStatus.notDetermined) return PushSetting.off;
    var optedOut = false;
    try {
      optedOut = await ref.read(pushAskStoreProvider).optedOut();
    } catch (_) {}
    return optedOut ? PushSetting.off : PushSetting.on;
  }

  Future<void> refresh() async {
    final next = await _read();
    if (ref.mounted) state = AsyncData(next);
  }

  /// The switch turned on: the system prompt if iOS has not asked yet, then
  /// the registration.
  Future<void> turnOn() async {
    state = const AsyncData(PushSetting.on);
    try {
      await ref.read(pushAskStoreProvider).setOptedOut(false);
    } catch (_) {}
    if (!ref.mounted) return;
    final status = await ref.read(pushServiceProvider).requestAndRegister();
    if (!ref.mounted) return;
    state = AsyncData(switch (status) {
      PushStatus.authorized => PushSetting.on,
      PushStatus.denied => PushSetting.deniedInSettings,
      PushStatus.notDetermined => PushSetting.off,
    });
  }

  /// The switch turned off: this phone is unregistered, and stays so at the
  /// next launch.
  Future<void> turnOff() async {
    state = const AsyncData(PushSetting.off);
    try {
      await ref.read(pushAskStoreProvider).setOptedOut(true);
    } catch (_) {}
    if (!ref.mounted) return;
    await ref.read(pushServiceProvider).turnOff();
  }
}

final pushSettingProvider =
    AsyncNotifierProvider<PushSettingNotifier, PushSetting>(
      PushSettingNotifier.new,
    );

/// The pop-up's once rule (`push_ask_shown`). Device-scoped: not watching
/// auth, so a sign-up mid-launch does not ask a second time.
class PushAskNotifier extends Notifier<bool> {
  Completer<void>? _open;

  /// True once the pop-up has appeared on this device this launch (the
  /// store remembers it across launches).
  @override
  bool build() => false;

  /// Whether the pop-up may appear: iOS has not decided yet and it never
  /// has. Already allowed means nothing to ask (the registration follows the
  /// session, [pushServiceProvider]); denied means never.
  Future<bool> eligible() async {
    if (state || !ref.read(pushAvailableProvider)) return false;
    final status = await ref.read(pushServiceProvider).status();
    if (!ref.mounted || state || status != PushStatus.notDetermined) {
      return false;
    }
    bool asked;
    try {
      asked = await ref.read(pushAskStoreProvider).asked();
    } catch (_) {
      // A keychain that cannot be read is never a reason to nag.
      asked = true;
    }
    return ref.mounted && !state && !asked;
  }

  /// The pop-up is appearing: it never appears again, however it closes.
  void markShown() {
    state = true;
    _open = Completer<void>();
    final store = ref.read(pushAskStoreProvider);
    unawaited(Future.sync(store.markAsked).catchError((Object _) {}));
  }

  void markClosed() {
    final open = _open;
    _open = null;
    if (open != null && !open.isCompleted) open.complete();
  }

  bool get isOpen => _open != null;

  /// Completes once no pop-up is up: the first run waits on it before it
  /// hands off, so a turn that lands under the pop-up does not tear it down.
  Future<void> get closed => _open?.future ?? Future.value();
}

final pushAskProvider = NotifierProvider<PushAskNotifier, bool>(
  PushAskNotifier.new,
);

/// The live [PushService], for [AuthNotifier.signOut], which unregisters it
/// before the bearer is dropped. A slot rather than [pushServiceProvider]
/// itself: that one watches the auth notifier, and the notifier reading it
/// back would be a dependency cycle.
class CurrentPushService {
  PushService? _current;

  /// This device stops receiving the signed-in listener's pushes. Nothing
  /// to do when no service is up.
  Future<void> unregister() => _current?.unregister() ?? Future.value();
}

final currentPushServiceProvider = Provider<CurrentPushService>(
  (ref) => CurrentPushService(),
);

/// A tapped push the shell has not opened yet: the launch tap (asked for
/// once, at the first read) or one tapped while running. Not user-scoped: a
/// tap waits here across the root swapping in the shell, which takes it.
class PendingPushTapNotifier extends Notifier<PushTap?> {
  /// Turns already handed to the shell. Native can hand one tap over twice
  /// when Dart's ack of `onTap` crosses an `initialTap` call (it keeps the
  /// tap until the ack lands); the mix opens once.
  final Set<PushTap> _seen = {};

  @override
  PushTap? build() {
    final channel = ref.watch(pushChannelProvider);
    final subscription = channel.taps.listen(_offer);
    ref.onDispose(subscription.cancel);
    unawaited(() async {
      try {
        final tap = await channel.initialTap();
        if (tap != null && ref.mounted && state == null) _offer(tap);
      } catch (_) {}
    }());
    return null;
  }

  void _offer(PushTap tap) {
    // A turn id names one push; without one there is nothing to tell
    // repeats apart by.
    if (tap.turnId.isNotEmpty && !_seen.add(tap)) return;
    state = tap;
  }

  /// The tap, once; cleared.
  PushTap? take() {
    final tap = state;
    state = null;
    return tap;
  }
}

final pendingPushTapProvider =
    NotifierProvider<PendingPushTapNotifier, PushTap?>(
      PendingPushTapNotifier.new,
    );

/// The conversation the listener is looking at, told to `mixtape/push` so a
/// push for it is not shown in the foreground (the transcript already shows
/// the turn land).
///
/// Each conversation screen reports for itself ([owner]), so the answer does
/// not depend on the order screens report in: the same mix open on two tabs
/// stays visible when one tab hides it and the other shows it in the same
/// frame.
class VisibleMixNotifier extends Notifier<String?> {
  /// The screens that say they are on screen, latest last.
  final Map<Object, String> _visible = {};

  @override
  String? build() => null;

  void show(Object owner, String sessionId) {
    if (_visible[owner] == sessionId) return;
    _visible.remove(owner);
    _visible[owner] = sessionId;
    _sync();
  }

  /// [owner] left the screen: a conversation leaving never clears the one
  /// that took its place.
  void hide(Object owner) {
    if (_visible.remove(owner) != null) _sync();
  }

  void _sync() {
    if (!ref.mounted) return;
    final next = _visible.isEmpty ? null : _visible.values.last;
    if (state == next) return;
    state = next;
    unawaited(ref.read(pushChannelProvider).setVisibleSession(next));
  }
}

final visibleMixProvider = NotifierProvider<VisibleMixNotifier, String?>(
  VisibleMixNotifier.new,
);
