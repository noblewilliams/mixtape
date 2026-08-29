// Providers for the DJ conversation: sessions list + per-session chat state
// machine, over [DjApi] (see `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`
// Task 2). Server-canonical: every mutation replaces local queue/version
// state from the response rather than optimistically editing it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import 'auth_provider.dart';

/// Built over the SAME baseUrl/tokenStore as the app's shared [ApiClient]
/// (structural sharing, per [DjApi.from]'s doc comment) but with its own
/// long-timeout client underneath — [DjApi] owns that client, so it's closed
/// here, not by [apiClientProvider].
final djApiProvider = Provider<DjApi>((ref) {
  final api = DjApi.from(ref.watch(apiClientProvider));
  ref.onDispose(api.close);
  return api;
});

// ---------------------------------------------------------------------------
// Sessions list
// ---------------------------------------------------------------------------

/// `GET /sessions` includes archived sessions (newest-first, <=50); the
/// server does no filtering — these are the client-side filter helpers.
List<DjSession> nonArchivedSessions(List<DjSession> sessions) =>
    sessions.where((s) => s.status != 'archived').toList();

List<DjSession> archivedSessions(List<DjSession> sessions) =>
    sessions.where((s) => s.status == 'archived').toList();

class SessionsNotifier extends AsyncNotifier<List<DjSession>> {
  @override
  Future<List<DjSession>> build() async {
    ref.watch(
      authProvider,
    ); // user-scoped: reload/reset on every auth transition
    final api = ref.watch(djApiProvider);
    return api.listSessions();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(djApiProvider).listSessions(),
    );
  }

  Future<void> archive(String id) async {
    await ref.read(djApiProvider).setStatus(id, 'archived');
    await refresh();
  }

  Future<void> unarchive(String id) async {
    await ref.read(djApiProvider).setStatus(id, 'active');
    await refresh();
  }
}

final sessionsProvider =
    AsyncNotifierProvider<SessionsNotifier, List<DjSession>>(
      SessionsNotifier.new,
    );

// ---------------------------------------------------------------------------
// Chat state machine
// ---------------------------------------------------------------------------

/// Local wrapper around [DjMessage] so a client-synthesized error bubble
/// (an apology the server never actually stored as a transcript row) can be
/// rendered in the same list as real messages without polluting [DjMessage]
/// itself with a UI-only flag.
class ChatMessage {
  const ChatMessage(this.message, {this.isError = false});

  final DjMessage message;
  final bool isError;
}

const _offlineErrorMessage =
    "couldn't reach the DJ — check your connection and try again";
const _staleTransientMessage = 'queue was updated — showing the latest';

/// `session.queueVersion` is the single source of truth for the current
/// queue version — no separately-tracked version field to drift out of sync
/// with it. [queueVersion] is a convenience getter over that.
class ChatState {
  const ChatState({
    required this.session,
    required this.messages,
    required this.queue,
    this.sending = false,
    this.transientError,
  });

  final DjSession session;
  final List<ChatMessage> messages;
  final List<QueueTrack> queue;
  final bool sending;

  /// One-shot: the UI clears this via [ChatNotifier.clearTransientError]
  /// after showing it (e.g. in a snackbar) so it doesn't reappear on an
  /// unrelated rebuild.
  final String? transientError;

  int get queueVersion => session.queueVersion;

  ChatState copyWith({
    DjSession? session,
    List<ChatMessage>? messages,
    List<QueueTrack>? queue,
    int? queueVersion,
    bool? sending,
    String? transientError,
    bool clearTransientError = false,
  }) {
    final resolvedSession =
        session ??
        (queueVersion != null
            ? _withQueueVersion(this.session, queueVersion)
            : this.session);
    return ChatState(
      session: resolvedSession,
      messages: messages ?? this.messages,
      queue: queue ?? this.queue,
      sending: sending ?? this.sending,
      transientError: clearTransientError
          ? null
          : (transientError ?? this.transientError),
    );
  }
}

DjSession _withQueueVersion(DjSession session, int queueVersion) => DjSession(
  id: session.id,
  title: session.title,
  status: session.status,
  queueVersion: queueVersion,
  updatedAt: session.updatedAt,
);

class ChatNotifier extends AsyncNotifier<ChatState> {
  ChatNotifier(this.sessionId);

  final String sessionId;
  int _localSeq = 0;

  @override
  Future<ChatState> build() async {
    ref.watch(
      authProvider,
    ); // user-scoped: reload/reset on every auth transition
    final api = ref.watch(djApiProvider);
    final detail = await api.getSession(sessionId);
    return _fromDetail(detail);
  }

  ChatState _fromDetail(
    SessionDetail detail, {
    bool sending = false,
    String? transientError,
  }) => ChatState(
    session: detail.session,
    messages: detail.messages.map((m) => ChatMessage(m)).toList(),
    queue: detail.queue,
    sending: sending,
    transientError: transientError,
  );

  DjMessage _localMessage(String role, String content) => DjMessage(
    id: 'local-$sessionId-${_localSeq++}',
    role: role,
    content: content,
    createdAt: DateTime.now(),
  );

  /// Appends the user's bubble immediately (the server persists it
  /// regardless of how the turn resolves) then posts the turn. A no-op
  /// while a previous [send] is still in flight, guarding double-taps on
  /// the send button.
  Future<void> send(String text) async {
    final current = state.value;
    if (current == null || current.sending) return;

    final withUserBubble = current.copyWith(
      messages: [...current.messages, ChatMessage(_localMessage('user', text))],
      sending: true,
    );
    state = AsyncData(withUserBubble);

    try {
      final result = await ref.read(djApiProvider).sendMessage(sessionId, text);
      if (!ref.mounted) return;
      state = AsyncData(
        withUserBubble.copyWith(
          messages: [...withUserBubble.messages, ChatMessage(result.djMessage)],
          queue: result.queue,
          queueVersion: result.queueVersion,
          sending: false,
        ),
      );
    } on DjApiException catch (e) {
      if (!ref.mounted) return;
      if (e.kind == 'stale') {
        // Degraded 409 fallback (see dj_api.dart's _translate409): a
        // malformed 'stale' body couldn't be parsed into a
        // StaleQueueException, but the kind still signals "the queue moved
        // under you" — recover by refetching the session rather than
        // showing an error bubble the user can't act on.
        await _refetchAfterFailedTurn();
        return;
      }
      state = AsyncData(
        withUserBubble.copyWith(
          messages: [
            ...withUserBubble.messages,
            ChatMessage(_localMessage('dj', e.message), isError: true),
          ],
          queue: e.queue,
          queueVersion: e.queueVersion,
          sending: false,
        ),
      );
    } on NetworkException {
      if (!ref.mounted) return;
      // Transport failure before any response — unlike the DjApiException
      // branch above, the server never saw this turn at all, so the user
      // bubble above is client-local only (no persisted duplicate risk, but
      // also no server-side record). Acceptable for v1: a retry may or may
      // not duplicate depending on whether the request actually landed.
      state = AsyncData(
        withUserBubble.copyWith(
          messages: [
            ...withUserBubble.messages,
            ChatMessage(
              _localMessage('dj', _offlineErrorMessage),
              isError: true,
            ),
          ],
          sending: false,
        ),
      );
    }
  }

  Future<void> _refetchAfterFailedTurn() async {
    try {
      final detail = await ref.read(djApiProvider).getSession(sessionId);
      if (!ref.mounted) return;
      state = AsyncData(_fromDetail(detail));
    } catch (_) {
      // Refetch itself failed — fall back to just clearing the sending flag
      // rather than losing the in-flight state entirely.
      if (!ref.mounted) return;
      final current = state.value;
      if (current != null) state = AsyncData(current.copyWith(sending: false));
    }
  }

  /// Server-canonical: always posts against the current known
  /// [ChatState.queueVersion] and replaces queue+version from the response.
  Future<void> applyOps(List<QueueOp> ops) async {
    final current = state.value;
    if (current == null) return;
    try {
      final result = await ref
          .read(djApiProvider)
          .applyQueueOps(sessionId, ops, current.queueVersion);
      if (!ref.mounted) return;
      state = AsyncData(
        current.copyWith(
          queue: result.queue,
          queueVersion: result.queueVersion,
        ),
      );
    } on StaleQueueException catch (e) {
      if (!ref.mounted) return;
      state = AsyncData(
        current.copyWith(
          queue: e.queue,
          queueVersion: e.queueVersion,
          transientError: _staleTransientMessage,
        ),
      );
    } on DjApiException catch (e) {
      // e.g. kind 'dj_required' for a manual swap/extend — no queue change,
      // just surface the server's message (transient, one-shot).
      if (!ref.mounted) return;
      state = AsyncData(current.copyWith(transientError: e.message));
    }
  }

  void clearTransientError() {
    final current = state.value;
    if (current == null || current.transientError == null) return;
    state = AsyncData(current.copyWith(clearTransientError: true));
  }
}

final chatProvider =
    AsyncNotifierProvider.family<ChatNotifier, ChatState, String>(
      ChatNotifier.new,
    );

// ---------------------------------------------------------------------------
// New-session flow
// ---------------------------------------------------------------------------

/// A plain callable (not a stateful notifier) that starts a new session and
/// returns its id. Refreshes [sessionsProvider] on both outcomes, since a
/// failed create can still have persisted a session row (the server echoes
/// `sessionId` on the error body) — the Home screen still needs it in the
/// list even though it's about to handle the rethrown exception.
final sessionStarterProvider = Provider<Future<String> Function(String prompt)>(
  (ref) {
    return (String prompt) async {
      try {
        final detail = await ref.read(djApiProvider).createSession(prompt);
        await ref.read(sessionsProvider.notifier).refresh();
        return detail.session.id;
      } on DjApiException {
        await ref.read(sessionsProvider.notifier).refresh();
        rethrow;
      }
    };
  },
);
