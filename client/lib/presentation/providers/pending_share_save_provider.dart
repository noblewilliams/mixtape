/// Saves a shared mix to the listener's Mixes once a session exists (spec
/// 2026-11-13 shared-mixes, Recipient in the app).
///
/// `SharedMixScreen` calls [PendingShareSaveNotifier.hold] once per opened
/// link. With a session (an account or an anonymous one) the save goes out
/// at once; without one the token waits in [PendingShareStore] and goes out
/// when [authProvider] next reports a session — after first run makes one,
/// or on a later launch. A save that fails for any reason but the share
/// being gone stays waiting for the next auth change or launch.
///
/// A token kept while a session existed belongs to that session: signing
/// out drops it, and so does a launch that finds no session (a reinstall,
/// where the keychain outlives the app). One opened before any session — a
/// fresh install following a link — waits through launches with no session
/// until first run makes one.
///
/// The provider must be listened from the app's root for the whole launch:
/// a provider nobody listens to is paused, and would miss the session
/// appearing.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart';
import '../../data/share/pending_share_store.dart';
import 'auth_provider.dart';
import 'dj_providers.dart';

export '../../data/share/pending_share_store.dart';

/// The keychain-backed store; tests override it with the in-memory one.
final pendingShareStoreProvider = Provider<PendingShareStore>(
  (ref) => SecurePendingShareStore(),
);

/// The token waiting for a session, or null.
class PendingShareSaveNotifier extends Notifier<String?> {
  final Set<String> _saving = {};

  /// A session was up earlier in this launch, so a no-session status now is
  /// a sign-out.
  bool _hadSession = false;

  @override
  String? build() {
    final status = ref.watch(authProvider);
    final signedOut = status == AuthStatus.noSession && _hadSession;
    if (status == AuthStatus.session) _hadSession = true;
    if (status == AuthStatus.noSession) _hadSession = false;
    unawaited(_resume(status, signedOut: signedOut));
    return null;
  }

  Future<void> _resume(AuthStatus status, {required bool signedOut}) async {
    final store = ref.read(pendingShareStoreProvider);
    PendingShare? share;
    try {
      share = await store.read();
    } catch (_) {
      // A device that cannot remember saves only what this launch holds.
    }
    if (!ref.mounted || share == null) return;
    if (status == AuthStatus.noSession &&
        (signedOut || share.heldWithSession)) {
      // That session's, not the next one's.
      try {
        await store.clear();
      } catch (_) {
        // At worst the next session saves one share it did not open.
      }
      return;
    }
    state = share.token;
    if (status == AuthStatus.session) await _save(share.token);
  }

  /// Saves [token] now if there is a session, else keeps it until one
  /// appears.
  Future<void> hold(String token) async {
    state = token;
    if (ref.read(authProvider) == AuthStatus.session) {
      await _save(token);
      return;
    }
    await _remember(token, heldWithSession: false);
  }

  Future<void> _remember(String token, {required bool heldWithSession}) async {
    try {
      await ref
          .read(pendingShareStoreProvider)
          .write(PendingShare(token, heldWithSession: heldWithSession));
    } catch (_) {
      // Remembering is a nicety; this launch still saves it.
    }
  }

  Future<void> _save(String token) async {
    if (!_saving.add(token)) return;
    final api = ref.read(djApiProvider);
    final store = ref.read(pendingShareStoreProvider);
    try {
      await api.saveSharedMix(token);
      await _forget(store, token);
    } on SharedMixGoneException {
      // Stopped or unknown: nothing to save, now or later.
      await _forget(store, token);
    } catch (_) {
      // Offline, a 429: it waits for the next auth change or launch, while
      // this session lasts.
      await _remember(token, heldWithSession: true);
    } finally {
      _saving.remove(token);
    }
  }

  Future<void> _forget(PendingShareStore store, String token) async {
    try {
      if ((await store.read())?.token == token) await store.clear();
    } catch (_) {
      // A stale token only means one more idempotent save later.
    }
    if (ref.mounted && state == token) state = null;
  }
}

final pendingShareSaveProvider =
    NotifierProvider<PendingShareSaveNotifier, String?>(
      PendingShareSaveNotifier.new,
    );
