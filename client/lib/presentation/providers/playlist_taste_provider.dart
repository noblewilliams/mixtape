import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/playlists/playlist_models.dart';
import 'auth_provider.dart';
import 'playlist_context_provider.dart';
import 'playlist_providers.dart';

class PlaylistTasteState {
  const PlaylistTasteState({
    this.summary,
    this.loading = false,
    this.writing = false,
    this.unknown = true,
    this.error,
  });
  final PlaylistSummary? summary;
  final bool loading;
  final bool writing;
  final bool unknown;
  final Object? error;

  bool get confirmed => summary?.origin == 'user_confirmed';
  bool get canConfirm =>
      !loading &&
      !writing &&
      !unknown &&
      summary != null &&
      summary!.originKnown &&
      summary!.origin == 'unknown' &&
      summary!.inLibrary &&
      summary!.capability == 'copy_only' &&
      ['user', 'external', 'user_shared', 'unknown'].contains(summary!.kind);
  bool get canRemove => !loading && !writing && !unknown && confirmed;

  /// Overlay only canonical metadata; keep every loaded entry and its cursor.
  PlaylistDetail applyTo(PlaylistDetail detail) =>
      summary == null || summary!.id != detail.playlist.id
      ? detail
      : PlaylistDetail(
          playlist: summary!,
          entries: detail.entries,
          nextEntryCursor: detail.nextEntryCursor,
        );
}

class PlaylistTasteNotifier extends Notifier<PlaylistTasteState> {
  PlaylistTasteNotifier(this.playlistId);
  final String playlistId;
  int _generation = 0;
  int _operation = 0;

  @override
  PlaylistTasteState build() {
    final auth = ref.watch(authProvider);
    ref.watch(playlistApiProvider);
    ref.watch(playlistContextApiProvider);
    final generation = ++_generation;
    final operation = ++_operation;
    ref.onDispose(() => _generation++);
    if (auth != AuthStatus.signedIn) return const PlaylistTasteState();
    unawaited(
      Future.microtask(() async {
        if (_current(generation, operation)) await _read(generation, operation);
      }),
    );
    return const PlaylistTasteState(loading: true);
  }

  bool _current(int generation, int operation) =>
      ref.mounted &&
      generation == _generation &&
      operation == _operation &&
      ref.read(authProvider) == AuthStatus.signedIn;

  Future<bool> _read(int generation, int operation, {bool? expected}) async {
    try {
      final canonical = await ref
          .read(playlistApiProvider)
          .get(playlistId, entryLimit: 1);
      if (!_current(generation, operation)) return false;
      if (canonical.playlist.id != playlistId) {
        throw const PlaylistModelException();
      }
      if (!canonical.playlist.originKnown) {
        state = PlaylistTasteState(summary: canonical.playlist);
        return false;
      }
      final matches =
          expected == null ||
          (canonical.playlist.origin == 'user_confirmed') == expected;
      state = PlaylistTasteState(
        summary: canonical.playlist,
        unknown: false,
        error: matches ? null : const PlaylistTasteNotChanged(),
      );
      return matches;
    } catch (error) {
      if (!_current(generation, operation)) return false;
      state = PlaylistTasteState(summary: state.summary, error: error);
      return false;
    }
  }

  Future<bool> refresh() async {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        state.writing) {
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    state = PlaylistTasteState(summary: state.summary, loading: true);
    return _read(generation, operation);
  }

  Future<bool> setConfirmed(bool confirmed) async {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        !(confirmed ? state.canConfirm : state.canRemove)) {
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    final api = ref.read(playlistContextApiProvider);
    state = PlaylistTasteState(
      summary: state.summary,
      writing: true,
      unknown: false,
    );
    try {
      await api.confirmTaste(playlistId, confirmed: confirmed);
    } catch (error) {
      if (!_current(generation, operation)) return false;
      if (error is ApiException && error.statusCode == 401) {
        state = PlaylistTasteState(error: error);
        return false;
      }
      // The response may have been lost after commit. Read once, never retry PUT.
    }
    if (!_current(generation, operation)) return false;
    return _read(generation, operation, expected: confirmed);
  }
}

class PlaylistTasteNotChanged implements Exception {
  const PlaylistTasteNotChanged();
  @override
  String toString() => 'Playlist confirmation was not changed';
}

final playlistTasteProvider = NotifierProvider.autoDispose
    .family<PlaylistTasteNotifier, PlaylistTasteState, String>(
      PlaylistTasteNotifier.new,
    );
