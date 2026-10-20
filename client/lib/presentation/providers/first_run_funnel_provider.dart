/// The first run's funnel events (spec `docs/superpowers/specs/
/// 2026-10-20-first-run-flow-design.md` → Clients, "Funnel events"),
/// posted once per anonymous listener.
///
/// Most of them happen before the anonymous listener exists: Welcome opens,
/// a pill is chosen, all with no session. A session is never created just to
/// post one (it is created lazily, at the first action that needs the
/// server), so they wait in memory and are posted when `signInAnonymously()`
/// moves the auth state to an anonymous session. Accounts never post them;
/// `account_linked_new` and `account_linked_existing` are the server's.
///
/// "Once" is an in-memory set for this listener plus the keychain-backed
/// [FunnelOnceStore], keyed by [anonymousFunnelKey] rather than a user id:
/// the client never learns the anonymous user's id, a device holds at most
/// one anonymous listener at a time, and the store is cleared on sign-out
/// (the only way to a new one). The server tolerates a repeat either way.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import 'auth_provider.dart';
import 'device_providers.dart';
import 'onboarding_provider.dart';

/// The [FunnelOnceStore] key standing in for the anonymous listener's id.
const String anonymousFunnelKey = 'anonymous';

class FirstRunFunnel {
  FirstRunFunnel(this._ref) {
    // Listen, never watch: a rebuild on the noSession to session transition
    // would forget exactly the events this exists to hold.
    _ref.listen<AuthStatus>(authProvider, _onAuth);
  }

  final Ref _ref;

  /// Recorded for this listener (posted, in flight, or held).
  final Set<FunnelEventType> _seen = {};

  /// Recorded before the session existed, in order.
  final List<FunnelEventType> _held = [];

  /// Whether this listener's first mix reply has been looked at.
  bool _replyNoted = false;

  bool get _anonymousSession =>
      _ref.read(authProvider) == AuthStatus.session &&
      _ref.read(authProvider.notifier).isAnonymous;

  bool get _accountSession =>
      _ref.read(authProvider) == AuthStatus.session &&
      !_ref.read(authProvider.notifier).isAnonymous;

  /// Records [type] once: posted now in an anonymous session, held until
  /// that session exists otherwise, dropped for an account.
  void record(FunnelEventType type) {
    if (_accountSession) return;
    if (!_seen.add(type)) return;
    if (_anonymousSession) {
      unawaited(_post(type));
    } else {
      _held.add(type);
    }
  }

  /// A new mix's first reply came back with [queueLength] tracks.
  /// `first_mix_made` the first time a mix has content; `first_mix_refused`
  /// only when the listener's very first reply was empty (an honest refusal,
  /// decision 2026-10-03).
  void noteMixReply(int queueLength) {
    if (!_anonymousSession) return;
    final first = !_replyNoted;
    _replyNoted = true;
    if (queueLength > 0) {
      record(FunnelEventType.firstMixMade);
      return;
    }
    if (!first || _seen.contains(FunnelEventType.firstMixMade)) return;
    unawaited(_refuseIfFirst());
  }

  Future<void> _refuseIfFirst() async {
    try {
      final store = _ref.read(funnelOnceStoreProvider);
      // A reply in an earlier launch already settled which one it was.
      if (await store.has(anonymousFunnelKey, FunnelEventType.firstMixMade) ||
          await store.has(
            anonymousFunnelKey,
            FunnelEventType.firstMixRefused,
          )) {
        return;
      }
    } catch (_) {
      // An unreadable keychain: post anyway, the server tolerates a repeat.
    }
    record(FunnelEventType.firstMixRefused);
  }

  void _onAuth(AuthStatus? previous, AuthStatus next) {
    switch (next) {
      case AuthStatus.session:
        if (_ref.read(authProvider.notifier).isAnonymous) {
          final held = List.of(_held);
          _held.clear();
          for (final type in held) {
            unawaited(_post(type));
          }
        } else {
          // Signed in before the anonymous listener existed (the welcome
          // foot link): these were never anyone's.
          _held.clear();
        }
      case AuthStatus.noSession:
        // A sign-out: whoever comes next is a new listener.
        if (previous == AuthStatus.session) {
          _seen.clear();
          _held.clear();
          _replyNoted = false;
        }
      case AuthStatus.unknown:
        break;
    }
  }

  Future<void> _post(FunnelEventType type) async {
    try {
      final store = _ref.read(funnelOnceStoreProvider);
      if (await store.has(anonymousFunnelKey, type)) return;
      await _ref.read(listeningApiProvider).postFunnelEvent(type);
      await store.mark(anonymousFunnelKey, type);
    } catch (_) {
      // Silent by design, like the other milestones: no retry, no error.
    }
  }
}

/// Not user-scoped on purpose: it must outlive the noSession to session
/// transition it waits for, and it resets itself on sign-out instead.
final firstRunFunnelProvider = Provider<FirstRunFunnel>(FirstRunFunnel.new);
