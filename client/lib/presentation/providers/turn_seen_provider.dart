/// Telling the server a durable turn's result was on screen (spec
/// 2026-11-21 durable mix turns, "Who notifies"): `POST
/// /sessions/:id/turn/:turnId/seen`, so it does not push a result the
/// listener already watched land.
///
/// Sent once per turn, fire and forget, when the result lands with that mix
/// on screen and the app in the foreground, or when the app comes back to
/// the foreground onto a mix whose turn finished meanwhile. Only for a turn
/// whose stream named it ([TurnStarted]); an older server names none, and
/// nothing is sent.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart';
import 'auth_provider.dart';
import 'dj_providers.dart' show djApiProvider;
import 'mix_background_provider.dart' show appInForegroundProvider;
import 'push_provider.dart' show visibleMixProvider;

class TurnSeenTracker {
  TurnSeenTracker(this._ref);

  final Ref _ref;

  /// Turns already acknowledged.
  final Set<String> _sent = {};

  /// Turns that finished while their mix was not what the listener saw (the
  /// app away, or another screen up), by mix: the latest turn only.
  final Map<String, String> _waiting = {};

  /// The turn [turnId] on [sessionId] answered (its result or error
  /// arrived). [onScreen] says the caller shows it whatever screen is up (a
  /// new mix's create, which opens the mix it made).
  void landed(String sessionId, String turnId, {bool onScreen = false}) {
    if (_sent.contains(turnId)) return;
    if (_foreground() &&
        (onScreen || _ref.read(visibleMixProvider) == sessionId)) {
      _send(sessionId, turnId);
      return;
    }
    _waiting[sessionId] = turnId;
  }

  /// The app came back to the foreground: the mix on screen, if its turn
  /// finished meanwhile, is seen now.
  void resumed() {
    final visible = _ref.read(visibleMixProvider);
    if (visible == null) return;
    final turnId = _waiting[visible];
    if (turnId != null) _send(visible, turnId);
  }

  bool _foreground() {
    try {
      return _ref.read(appInForegroundProvider)();
    } catch (_) {
      return true;
    }
  }

  void _send(String sessionId, String turnId) {
    if (_waiting[sessionId] == turnId) _waiting.remove(sessionId);
    if (!_sent.add(turnId)) return;
    final DjApi api;
    try {
      api = _ref.read(djApiProvider);
    } catch (_) {
      return;
    }
    unawaited(
      Future.sync(
        () => api.markTurnSeen(sessionId, turnId),
      ).catchError((Object _) {}),
    );
  }
}

/// User-scoped (CLAUDE.md): a sign-out forgets the turns it knew.
final turnSeenProvider = Provider<TurnSeenTracker>((ref) {
  ref.watch(authProvider);
  final tracker = TurnSeenTracker(ref);
  AppLifecycleListener? lifecycle;
  try {
    lifecycle = AppLifecycleListener(onResume: tracker.resumed);
  } catch (_) {
    // No binding (plain Dart tests): nothing comes back to the foreground.
  }
  ref.onDispose(() => lifecycle?.dispose());
  return tracker;
});
