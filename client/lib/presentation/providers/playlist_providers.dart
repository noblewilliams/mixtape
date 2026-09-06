import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/playlists/playlist_api.dart';
import '../../data/playlists/playlist_edit_api.dart';
import '../../data/playlists/playlist_edit_models.dart';
import '../../data/playlists/playlist_models.dart';
import 'auth_provider.dart';

final playlistApiProvider = Provider<PlaylistApi>(
  (ref) => PlaylistApi(ref.watch(apiClientProvider)),
);

final playlistEditApiProvider = Provider<PlaylistEditApi>((ref) {
  final api = PlaylistEditApi.from(ref.watch(apiClientProvider));
  ref.onDispose(api.close);
  return api;
});

class PlaylistCollectionState {
  const PlaylistCollectionState({
    required this.playlists,
    this.nextCursor,
    this.loadingMore = false,
    this.loadMoreFailed = false,
  });

  final List<PlaylistSummary> playlists;
  final String? nextCursor;
  final bool loadingMore;
  final bool loadMoreFailed;

  PlaylistCollectionState copyWith({
    List<PlaylistSummary>? playlists,
    String? nextCursor,
    bool clearCursor = false,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => PlaylistCollectionState(
    playlists: playlists ?? this.playlists,
    nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
  );
}

class PlaylistCollectionNotifier
    extends AsyncNotifier<PlaylistCollectionState> {
  @override
  Future<PlaylistCollectionState> build() async {
    ref.watch(authProvider);
    final page = await ref.watch(playlistApiProvider).list();
    return PlaylistCollectionState(
      playlists: page.playlists,
      nextCursor: page.nextCursor,
    );
  }

  Future<bool> refresh() async {
    final next = await AsyncValue.guard(() async {
      final page = await ref.read(playlistApiProvider).list();
      return PlaylistCollectionState(
        playlists: page.playlists,
        nextCursor: page.nextCursor,
      );
    });
    state = next;
    return !next.hasError;
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.loadingMore || current.nextCursor == null) {
      return;
    }
    state = AsyncData(
      current.copyWith(loadingMore: true, loadMoreFailed: false),
    );
    try {
      final page = await ref
          .read(playlistApiProvider)
          .list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        PlaylistCollectionState(
          playlists: [...current.playlists, ...page.playlists],
          nextCursor: page.nextCursor,
        ),
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = AsyncData(
        current.copyWith(loadingMore: false, loadMoreFailed: true),
      );
    }
  }
}

final playlistCollectionProvider =
    AsyncNotifierProvider.autoDispose<
      PlaylistCollectionNotifier,
      PlaylistCollectionState
    >(PlaylistCollectionNotifier.new);

class PlaylistDetailNotifier extends AsyncNotifier<PlaylistDetail> {
  PlaylistDetailNotifier(this.playlistId);

  final String playlistId;

  @override
  Future<PlaylistDetail> build() async {
    ref.watch(authProvider);
    return ref.watch(playlistApiProvider).get(playlistId);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.nextEntryCursor == null) return;
    try {
      final page = await ref
          .read(playlistApiProvider)
          .get(playlistId, entryCursor: current.nextEntryCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        PlaylistDetail(
          playlist: page.playlist,
          entries: [...current.entries, ...page.entries],
          nextEntryCursor: page.nextEntryCursor,
        ),
      );
    } catch (_) {
      rethrow;
    }
  }
}

final playlistDetailProvider = AsyncNotifierProvider.autoDispose
    .family<PlaylistDetailNotifier, PlaylistDetail, String>(
      PlaylistDetailNotifier.new,
    );

class PlaylistEditUiMessage {
  const PlaylistEditUiMessage(
    this.message, {
    this.isError = false,
    this.retryContent,
  });

  final PlaylistEditMessage message;
  final bool isError;
  final String? retryContent;
}

class PlaylistEditThreadState {
  const PlaylistEditThreadState({
    required this.view,
    required this.messages,
    this.sending = false,
    this.transientError,
  });

  final PlaylistEditView view;
  final List<PlaylistEditUiMessage> messages;
  final bool sending;
  final String? transientError;

  PlaylistEditThreadState copyWith({
    PlaylistEditView? view,
    List<PlaylistEditUiMessage>? messages,
    bool? sending,
    String? transientError,
    bool clearTransientError = false,
  }) => PlaylistEditThreadState(
    view: view ?? this.view,
    messages: messages ?? this.messages,
    sending: sending ?? this.sending,
    transientError: clearTransientError
        ? null
        : (transientError ?? this.transientError),
  );
}

const _offlineEditMessage =
    "Couldn't reach the DJ. Check your connection and try again.";
const _genericEditMessage =
    'Something went wrong while editing this playlist. Try again.';

class PlaylistEditThreadNotifier
    extends AsyncNotifier<PlaylistEditThreadState> {
  PlaylistEditThreadNotifier(this.draftId);

  final String draftId;
  int _localSeq = -1;

  @override
  Future<PlaylistEditThreadState> build() async {
    ref.watch(authProvider);
    return _fromThread(
      await ref.watch(playlistEditApiProvider).getThread(draftId),
    );
  }

  PlaylistEditThreadState _fromThread(
    PlaylistEditThread thread, {
    String? transientError,
  }) => PlaylistEditThreadState(
    view: thread,
    messages: thread.messages.map(PlaylistEditUiMessage.new).toList(),
    transientError: transientError,
  );

  PlaylistEditMessage _localMessage(String role, String content) =>
      PlaylistEditMessage(
        id: 'local-$draftId-${_localSeq--}',
        role: role,
        content: content,
        seq: 0,
        createdAt: DateTime.now(),
      );

  void _merge(
    PlaylistEditThreadState Function(PlaylistEditThreadState) update,
  ) {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData(update(current));
  }

  Future<void> send(String content) async {
    final text = content.trim();
    final base = state.value;
    if (base == null || base.sending || text.isEmpty) return;
    final messagesBefore = base.messages;
    state = AsyncData(
      base.copyWith(
        messages: [
          ...base.messages,
          PlaylistEditUiMessage(_localMessage('user', text)),
        ],
        sending: true,
        clearTransientError: true,
      ),
    );
    try {
      final result = await ref
          .read(playlistEditApiProvider)
          .sendMessage(draftId, text, base.view.draft.version);
      _merge(
        (current) => current.copyWith(
          view: result.draft,
          messages: [
            ...current.messages,
            PlaylistEditUiMessage(result.djMessage),
          ],
        ),
      );
    } on PlaylistEditApiException catch (error) {
      if (error.kind == 'conflict') {
        await _refreshAfterConflict(
          error.message,
          fallbackView: error.draft,
          fallbackMessages: messagesBefore,
        );
      } else {
        _merge(
          (current) => current.copyWith(
            view: error.draft ?? current.view,
            messages: [
              ...current.messages,
              PlaylistEditUiMessage(
                _localMessage('dj', error.message),
                isError: true,
                retryContent: text,
              ),
            ],
          ),
        );
      }
    } on NetworkException {
      _appendError(_offlineEditMessage, text);
    } catch (_) {
      _appendError(_genericEditMessage, text);
    } finally {
      _merge(
        (current) =>
            current.sending ? current.copyWith(sending: false) : current,
      );
    }
  }

  void _appendError(String message, String retryContent) => _merge(
    (current) => current.copyWith(
      messages: [
        ...current.messages,
        PlaylistEditUiMessage(
          _localMessage('dj', message),
          isError: true,
          retryContent: retryContent,
        ),
      ],
    ),
  );

  Future<void> _refreshAfterConflict(
    String message, {
    PlaylistEditView? fallbackView,
    List<PlaylistEditUiMessage>? fallbackMessages,
  }) async {
    try {
      final thread = await ref.read(playlistEditApiProvider).getThread(draftId);
      if (!ref.mounted) return;
      state = AsyncData(_fromThread(thread, transientError: message));
    } catch (_) {
      _merge(
        (current) => current.copyWith(
          view: fallbackView ?? current.view,
          messages: fallbackMessages ?? current.messages,
          transientError: message,
        ),
      );
    }
  }

  Future<void> refresh() async {
    final thread = await ref.read(playlistEditApiProvider).getThread(draftId);
    if (!ref.mounted) return;
    state = AsyncData(_fromThread(thread));
  }

  void clearTransientError() {
    final current = state.value;
    if (current == null || current.transientError == null) return;
    state = AsyncData(current.copyWith(clearTransientError: true));
  }
}

final playlistEditThreadProvider = AsyncNotifierProvider.autoDispose
    .family<PlaylistEditThreadNotifier, PlaylistEditThreadState, String>(
      PlaylistEditThreadNotifier.new,
    );

final playlistDraftStarterProvider =
    Provider<Future<PlaylistEditView> Function(String playlistId)>((ref) {
      ref.watch(authProvider);
      return (playlistId) =>
          ref.read(playlistEditApiProvider).createOrResume(playlistId);
    });
