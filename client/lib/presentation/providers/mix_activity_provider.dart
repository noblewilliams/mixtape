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
import 'working_step.dart';

/// A new mix being made, before its create request has returned an id.
class PendingMix {
  const PendingMix({
    required this.prompt,
    required this.startedAt,
    this.knownIds,
    this.sessionId,
  });

  final String prompt;
  final DateTime startedAt;

  /// The mixes the list held when this one started; null when the list had
  /// not been read yet.
  final Set<String>? knownIds;

  /// The id the server gave it, once a streamed create has said (its
  /// `session` event comes first, before the turn runs); null until then,
  /// and always against an older server.
  final String? sessionId;

  /// How far a server clock may sit from this device's when the list has
  /// nothing to compare against.
  static const Duration clockSlack = Duration(minutes: 2);

  /// The listed mix this one already is: the server writes the row before
  /// the first turn runs, so a list read mid-create can list it. The row
  /// with its [sessionId] once the server has named it; before that, the
  /// one row the list did not have at the start, or without that list, the
  /// newest row made since it started. Null when no row fits.
  String? adopt(List<DjSession> sessions) {
    final named = sessionId;
    if (named != null) {
      return sessions.any((session) => session.id == named) ? named : null;
    }
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

/// What [MixActivityNotifier.beginTurn] hands back: call it, once, to end
/// the turn; [step] notes where it has got to meanwhile.
class TurnActivity {
  TurnActivity._(this._end, this._step);

  final void Function(bool ready) _end;
  final void Function(WorkingStep step) _step;

  /// Ends the turn; `ready` is whether it left anything to look at (a
  /// reply, or a line saying it failed) rather than being taken back.
  void call({required bool ready}) => _end(ready);

  /// The turn's stream reported [step]. Nothing once the turn has ended.
  void step(WorkingStep step) => _step(step);
}

/// What [MixActivityNotifier.beginNewMix] hands back: call it, once, to end
/// the create; [step] and [named] note what its stream says meanwhile.
class NewMixActivity {
  NewMixActivity._(this._end, this._step, this._named);

  final void Function(String? sessionId) _end;
  final void Function(WorkingStep step) _step;
  final void Function(String sessionId) _named;

  /// Ends it with the id the server gave it (also on a failure that still
  /// wrote the row), or none when nothing was made.
  void call({String? sessionId}) => _end(sessionId);

  /// The first turn's stream reported [step].
  void step(WorkingStep step) => _step(step);

  /// The create's stream named the new mix [sessionId].
  void named(String sessionId) => _named(sessionId);
}

/// The steps live beside the rest rather than inside it: a step replaces
/// only [steps] or [pendingStep], so a screen that selects [working],
/// [ready] or [pending] (the Mixes list) does not rebuild for every step.
class MixActivity {
  const MixActivity({
    this.working = const {},
    this.steps = const {},
    this.ready = const {},
    this.pending,
    this.pendingStep,
  });

  /// Mixes with a turn out, and when each went.
  final Map<String, DateTime> working;

  /// Where each of those turns has got to, once its stream opened (turn
  /// steps, 2026-11-13).
  final Map<String, WorkingStep> steps;

  /// Mixes with a reply the listener has not looked at.
  final Set<String> ready;

  /// The new mix being made, if one is.
  final PendingMix? pending;

  /// Where the new mix's first turn has got to, once its stream opened.
  final WorkingStep? pendingStep;

  bool isWorking(String id) => working.containsKey(id);
  DateTime? workingSince(String id) => working[id];
  WorkingStep? workingStep(String id) => steps[id];
  bool isReady(String id) => ready.contains(id);

  MixActivity _copy({
    Map<String, DateTime>? working,
    Map<String, WorkingStep>? steps,
    Set<String>? ready,
    PendingMix? pending,
    WorkingStep? pendingStep,
    bool clearPending = false,
  }) => MixActivity(
    working: working ?? this.working,
    steps: steps ?? this.steps,
    ready: ready ?? this.ready,
    pending: clearPending ? null : (pending ?? this.pending),
    pendingStep: clearPending ? null : (pendingStep ?? this.pendingStep),
  );
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

  /// A turn in [sessionId] went out. The handle ends it, once (see
  /// [TurnActivity]), and notes its steps on the way.
  TurnActivity beginTurn(String sessionId) {
    final generation = _generation;
    final since = DateTime.now();
    state = state._copy(
      working: {...state.working, sessionId: since},
      steps: {...state.steps}..remove(sessionId),
    );
    var ended = false;
    bool mine() =>
        !ended &&
        ref.mounted &&
        generation == _generation &&
        state.working[sessionId] == since;
    return TurnActivity._(
      (ready) {
        if (ended) return;
        final current = mine();
        ended = true;
        if (!ref.mounted || generation != _generation) return;
        state = state._copy(
          working: current
              ? ({...state.working}..remove(sessionId))
              : state.working,
          steps: current ? ({...state.steps}..remove(sessionId)) : state.steps,
          ready: ready ? {...state.ready, sessionId} : state.ready,
        );
      },
      (step) {
        if (!mine()) return;
        state = state._copy(steps: {...state.steps, sessionId: step});
      },
    );
  }

  /// A new mix from [prompt] is being made. The handle ends it, once (see
  /// [NewMixActivity]), and notes what its stream says on the way.
  NewMixActivity beginNewMix(String prompt, {Set<String>? knownIds}) {
    final generation = _generation;
    var pending = PendingMix(
      prompt: prompt,
      startedAt: DateTime.now(),
      knownIds: knownIds,
    );
    state = state._copy(clearPending: true)._copy(pending: pending);
    var ended = false;
    bool mine() =>
        !ended &&
        ref.mounted &&
        generation == _generation &&
        identical(state.pending, pending);
    return NewMixActivity._(
      (sessionId) {
        if (ended) return;
        final current = mine();
        ended = true;
        if (!ref.mounted || generation != _generation) return;
        state = state._copy(
          ready: sessionId == null ? state.ready : {...state.ready, sessionId},
          clearPending: current,
        );
      },
      (step) {
        if (mine()) state = state._copy(pendingStep: step);
      },
      (sessionId) {
        if (!mine()) return;
        pending = PendingMix(
          prompt: pending.prompt,
          startedAt: pending.startedAt,
          knownIds: pending.knownIds,
          sessionId: sessionId,
        );
        state = state._copy(pending: pending);
      },
    );
  }

  /// The listener is looking at [sessionId]'s conversation.
  void seen(String sessionId) {
    if (!state.ready.contains(sessionId)) return;
    state = state._copy(ready: {...state.ready}..remove(sessionId));
  }
}

final mixActivityProvider = NotifierProvider<MixActivityNotifier, MixActivity>(
  MixActivityNotifier.new,
);
