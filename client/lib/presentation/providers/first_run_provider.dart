/// Gating for the first-run flow (spec `docs/superpowers/specs/
/// 2026-10-20-first-run-flow-design.md` → Account model, "Gating").
///
/// The flow is shown when the device has no session. Its first server action
/// creates an anonymous session, which would otherwise swap the root to the
/// shell mid-flow; [firstRunActiveProvider] keeps the flow mounted until it
/// hands off, and [pendingConversationProvider] carries the new mix's id to
/// the shell, which opens it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';

/// True while a first-run flow that started from no session has not yet
/// handed off. Becomes true whenever the auth state reaches `noSession`
/// (a launch with no session, or a sign-out) and false at [handOff]. An
/// anonymous session already present at launch never sets it, so that
/// listener goes straight to the shell.
class FirstRunActiveNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Listen, not watch: a rebuild would forget that the flow is running.
    ref.listen<AuthStatus>(authProvider, (previous, next) {
      if (next == AuthStatus.noSession) {
        state = true;
      } else if (next == AuthStatus.session &&
          !ref.read(authProvider.notifier).isAnonymous) {
        // An account session ends the flow: signing in from the welcome
        // foot link, or linking the flow's anonymous session. Without this
        // a later anonymous session could reopen a flow that had finished.
        state = false;
      }
    });
    return ref.read(authProvider) == AuthStatus.noSession;
  }

  /// The flow is done: the shell takes over and opens [conversation].
  void handOff(PendingConversation conversation) {
    ref.read(pendingConversationProvider.notifier).open(conversation);
    state = false;
  }
}

final firstRunActiveProvider = NotifierProvider<FirstRunActiveNotifier, bool>(
  FirstRunActiveNotifier.new,
);

/// A conversation the shell opens on its first frame: the first mix, made by
/// the first-run flow.
class PendingConversation {
  const PendingConversation(this.sessionId, {this.initialError});

  final String sessionId;

  /// The failed first turn's message, when the session persisted anyway
  /// (same as Home's `initialError` hand-off to the conversation).
  final String? initialError;
}

class PendingConversationNotifier extends Notifier<PendingConversation?> {
  @override
  PendingConversation? build() => null;

  void open(PendingConversation conversation) => state = conversation;

  /// Returns the pending conversation once and clears it.
  PendingConversation? take() {
    final pending = state;
    state = null;
    return pending;
  }
}

final pendingConversationProvider =
    NotifierProvider<PendingConversationNotifier, PendingConversation?>(
      PendingConversationNotifier.new,
    );
