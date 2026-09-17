import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/playlists/playlist_context_api.dart';
import '../../data/playlists/playlist_context_models.dart';
import 'auth_provider.dart';
import 'mix_operation_gate.dart';

final playlistContextApiProvider = Provider<PlaylistContextApi>((ref) {
  ref.watch(authProvider);
  return PlaylistContextApi(ref.watch(apiClientProvider));
});

class SessionPlaylistContextState {
  const SessionPlaylistContextState({
    this.seed,
    this.loading = false,
    this.writing = false,
    this.error,
  });

  /// Null means unknown, including legacy omission or failed reconciliation.
  final PlaylistSeedState? seed;
  final bool loading;
  final bool writing;
  final Object? error;
  bool get canSelect => seed != null && !loading && !writing;
}

typedef PlaylistContextReadToken = ({int generation, int operation});

class SessionPlaylistContextNotifier
    extends Notifier<SessionPlaylistContextState> {
  SessionPlaylistContextNotifier(this.sessionId);

  final String sessionId;
  int _generation = 0;
  int _operation = 0;

  @override
  SessionPlaylistContextState build() {
    final auth = ref.watch(authProvider);
    final api = ref.watch(playlistContextApiProvider);
    final generation = ++_generation;
    final operation = ++_operation;
    ref.onDispose(() {
      _generation++;
    });
    if (auth != AuthStatus.signedIn) {
      return const SessionPlaylistContextState();
    }
    // Defer mutation until build has returned its initial loading state.
    unawaited(
      Future.microtask(() async {
        if (_current(generation, operation)) {
          await _load(api, generation, operation);
        }
      }),
    );
    return const SessionPlaylistContextState(loading: true);
  }

  bool _current(int generation, int operation) =>
      ref.mounted &&
      generation == _generation &&
      operation == _operation &&
      ref.read(authProvider) == AuthStatus.signedIn;

  Future<bool> _load(
    PlaylistContextApi api,
    int generation,
    int operation,
  ) async {
    try {
      final seed = await api.getSessionSeed(sessionId);
      if (!_current(generation, operation)) return false;
      state = SessionPlaylistContextState(seed: seed);
      return seed != null;
    } catch (error) {
      if (!_current(generation, operation)) return false;
      state = SessionPlaylistContextState(error: error);
      return false;
    }
  }

  PlaylistContextReadToken get readToken =>
      (generation: _generation, operation: _operation);

  /// Adopt a session read only if no selection/read has superseded its start.
  bool adoptCanonical(PlaylistSeedState? seed, PlaylistContextReadToken token) {
    if (!_current(token.generation, token.operation) ||
        state.writing ||
        seed == null ||
        (state.seed != null && seed.revision < state.seed!.revision)) {
      return false;
    }
    _operation++;
    state = SessionPlaylistContextState(seed: seed);
    return true;
  }

  Future<bool> refresh() async {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        state.writing) {
      return false;
    }
    final generation = _generation;
    final operation = ++_operation;
    final api = ref.read(playlistContextApiProvider);
    state = SessionPlaylistContextState(seed: state.seed, loading: true);
    return _load(api, generation, operation);
  }

  Future<bool> select({
    required String? playlistId,
    bool excludeSourceTracks = false,
  }) async {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        !state.canSelect) {
      return false;
    }
    final release = ref
        .read(mixOperationProvider(sessionId).notifier)
        .acquire(MixOperation.selectingInspiration);
    if (release == null) return false;
    try {
      final previous = state.seed!;
      final generation = _generation;
      final operation = ++_operation;
      final api = ref.read(playlistContextApiProvider);
      state = SessionPlaylistContextState(seed: previous, writing: true);
      try {
        final next = await api.selectSeed(
          sessionId,
          playlistId: playlistId,
          expectedRevision: previous.revision,
          excludeSourceTracks: playlistId != null && excludeSourceTracks,
        );
        if (!_current(generation, operation)) return false;
        state = SessionPlaylistContextState(seed: next);
        return true;
      } catch (error) {
        if (!_current(generation, operation)) return false;
        if (error is ApiException && error.statusCode == 401) {
          state = SessionPlaylistContextState(error: error);
          return false;
        }
        // A lost response may have committed. Reconcile without repeating the PUT.
        // Keep writes locked through this read so its revision cannot race another.
        try {
          final canonical = await api.getSessionSeed(sessionId);
          if (!_current(generation, operation)) return false;
          state = SessionPlaylistContextState(seed: canonical, error: error);
        } catch (refreshError) {
          if (!_current(generation, operation)) return false;
          state = SessionPlaylistContextState(error: refreshError);
        }
        return false;
      }
    } finally {
      release();
    }
  }
}

final sessionPlaylistContextProvider = NotifierProvider.autoDispose
    .family<
      SessionPlaylistContextNotifier,
      SessionPlaylistContextState,
      String
    >(SessionPlaylistContextNotifier.new);
