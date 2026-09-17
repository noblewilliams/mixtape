import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../../data/playlists/playlist_models.dart';
import 'auth_provider.dart';

class NewMixInspiration {
  const NewMixInspiration(this.playlist, {this.excludeSourceTracks = false});
  final PlaylistSummary playlist;
  final bool excludeSourceTracks;
  InitialPlaylistSeed get seed => InitialPlaylistSeed(
    playlistId: playlist.id,
    excludeSourceTracks: excludeSourceTracks,
  );
}

/// A local composer attachment shared by browse detail and the existing Home.
/// Selecting it does not start a session or send any request.
class NewMixInspirationNotifier extends Notifier<NewMixInspiration?> {
  @override
  NewMixInspiration? build() {
    ref.watch(authProvider);
    return null;
  }

  void select(PlaylistSummary playlist, {bool excludeSourceTracks = false}) {
    if (!ref.mounted || ref.read(authProvider) != AuthStatus.signedIn) return;
    state = NewMixInspiration(
      playlist,
      excludeSourceTracks: excludeSourceTracks,
    );
  }

  void clear() {
    if (ref.mounted) state = null;
  }
}

final newMixInspirationProvider =
    NotifierProvider<NewMixInspirationNotifier, NewMixInspiration?>(
      NewMixInspirationNotifier.new,
    );
