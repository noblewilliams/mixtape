/// What the Mixes list knows about the DJ's work in flight (device smoke,
/// 2026-11-13): which mixes have a turn out, the new mix being made from
/// Home before the server has named it, and which mixes have a reply the
/// listener has not looked at yet.
///
/// Kept on the device, in memory: a turn's request already outlives its
/// screen (see [MixOperationGate]), and this only remembers what those
/// requests are doing so a row can show it. A reply that lands while the
/// app is closed is not known here; the list's own times still say when a
/// mix last changed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import 'auth_provider.dart';

/// A new mix being made, before its create request has returned an id.
class PendingMix {
  const PendingMix({
    required this.prompt,
    required this.startedAt,
    this.knownIds,
  });

  final String prompt;
  final DateTime startedAt;

  /// The mixes the list held when this one started; null when the list had
  /// not been read yet.
  final Set<String>? knownIds;

  /// How far a server clock may sit from this device's when the list has
  /// nothing to compare against.
  static const Duration clockSlack = Duration(minutes: 2);

  /// The listed mix this one already is: the server writes the row before
  /// the first turn runs, so a list read mid-create can list it. The one
  /// row the list did not have at the start; without that list, the newest
  /// row made since it started. Null when no row fits.
  String? adopt(List<DjSession> sessions) {
    final known = knownIds;
    final since = startedAt.subtract(clockSlack);
    DjSession? best;
    for (final session in sessions) {
      final fits = known != null
          ? !known.contains(session.id)
          : !session.updatedAt.isBefore(since);
      if (!fits) continue;
      if (best == null || session.updatedAt.isAfter(best.updatedAt)) {
        best = session;
      }
    }
    return best?.id;
  }
}

class MixActivity {
  const MixActivity({
    this.working = const {},
    this.ready = const {},
    this.pending,
  });

  /// Mixes with a turn out, and when each went.
  final Map<String, DateTime> working;

  /// Mixes with a reply the listener has not looked at.
  final Set<String> ready;

  /// The new mix being made, if one is.
  final PendingMix? pending;

  bool isWorking(String id) => working.containsKey(id);
  DateTime? workingSince(String id) => working[id];
  bool isReady(String id) => ready.contains(id);
}

class MixActivityNotifier extends Notifier<MixActivity> {
  int _generation = 0;

  @override
  MixActivity build() {
    // User-scoped: a sign-out forgets it all, and a request that ends after
    // one writes nothing.
    ref.watch(authProvider);
    _generation++;
    return const MixActivity();
  }

  /// A turn in [sessionId] went out. The callback ends it, once; `ready`
  /// is whether the turn left anything to look at (a reply, or a line
  /// saying it failed) rather than being taken back.
  void Function({required bool ready}) beginTurn(String sessionId) {
    final generation = _generation;
    final since = DateTime.now();
    state = MixActivity(
      working: {...state.working, sessionId: since},
      ready: state.ready,
      pending: state.pending,
    );
    var ended = false;
    return ({required bool ready}) {
      if (ended) return;
      ended = true;
      if (!ref.mounted || generation != _generation) return;
      final working = {...state.working};
      if (working[sessionId] == since) working.remove(sessionId);
      state = MixActivity(
        working: working,
        ready: ready ? {...state.ready, sessionId} : state.ready,
        pending: state.pending,
      );
    };
  }

  /// A new mix from [prompt] is being made. The callback ends it, once,
  /// with the id the server gave it (also on a failure that still wrote the
  /// row), or none when nothing was made.
  void Function({String? sessionId}) beginNewMix(
    String prompt, {
    Set<String>? knownIds,
  }) {
    final generation = _generation;
    final pending = PendingMix(
      prompt: prompt,
      startedAt: DateTime.now(),
      knownIds: knownIds,
    );
    state = MixActivity(
      working: state.working,
      ready: state.ready,
      pending: pending,
    );
    var ended = false;
    return ({String? sessionId}) {
      if (ended) return;
      ended = true;
      if (!ref.mounted || generation != _generation) return;
      state = MixActivity(
        working: state.working,
        ready: sessionId == null ? state.ready : {...state.ready, sessionId},
        pending: identical(state.pending, pending) ? null : state.pending,
      );
    };
  }

  /// The listener is looking at [sessionId]'s conversation.
  void seen(String sessionId) {
    if (!state.ready.contains(sessionId)) return;
    state = MixActivity(
      working: state.working,
      ready: {...state.ready}..remove(sessionId),
      pending: state.pending,
    );
  }
}

final mixActivityProvider = NotifierProvider<MixActivityNotifier, MixActivity>(
  MixActivityNotifier.new,
);
