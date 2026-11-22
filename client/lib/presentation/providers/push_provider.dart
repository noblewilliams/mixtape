/// Mix-ready pushes on this device (spec 2026-11-21 durable mix turns → iOS
/// client): the registration, which follows the session, the tap waiting to
/// be opened, and the mix on screen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  if (auth == AuthStatus.session) unawaited(service.registerIfAuthorized());
  return service;
});

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
