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

  @override
  String? build() {
    final status = ref.watch(authProvider);
    unawaited(_resume(status));
    return null;
  }

  Future<void> _resume(AuthStatus status) async {
    String? token;
    try {
      token = await ref.read(pendingShareStoreProvider).read();
    } catch (_) {
      // A device that cannot remember saves only what this launch holds.
    }
    if (!ref.mounted || token == null) return;
    state = token;
    if (status == AuthStatus.session) await _save(token);
  }

  /// Saves [token] now if there is a session, else keeps it until one
  /// appears.
  Future<void> hold(String token) async {
    state = token;
    if (ref.read(authProvider) == AuthStatus.session) {
      await _save(token);
      return;
    }
    await _remember(token);
  }

  Future<void> _remember(String token) async {
    try {
      await ref.read(pendingShareStoreProvider).write(token);
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
      // Offline, a 429: it waits for the next auth change or launch.
      await _remember(token);
    } finally {
      _saving.remove(token);
    }
  }

  Future<void> _forget(PendingShareStore store, String token) async {
    try {
      if (await store.read() == token) await store.clear();
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
