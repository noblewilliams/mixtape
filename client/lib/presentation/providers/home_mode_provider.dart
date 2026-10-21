// A one-shot ask for Home to open on a mode (album picks Task 11): the empty
// Listen later shelf's "Find an album" (Task 13) requests Album and switches
// to the Home tab; Home takes the request on mount, or while mounted, and
// clears it. Home's mode is otherwise its own screen state, never persisted.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import 'auth_provider.dart';

class HomeModeRequest extends Notifier<SessionKind?> {
  @override
  SessionKind? build() {
    // An auth transition drops a request made for the previous listener.
    ref.watch(authProvider);
    return null;
  }

  /// Asks Home to open on [kind].
  void request(SessionKind kind) => state = kind;

  /// The pending request, cleared as it is read.
  SessionKind? take() {
    final pending = state;
    if (pending != null) state = null;
    return pending;
  }
}

final homeModeRequestProvider = NotifierProvider<HomeModeRequest, SessionKind?>(
  HomeModeRequest.new,
);
