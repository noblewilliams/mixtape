// Providers for the DJ conversation: sessions list + per-session chat state
// machine, over [DjApi] (see `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`
// Task 2). Server-canonical: every mutation replaces local queue/version
// state from the response rather than optimistically editing it.
//
// Auth-transition safety: never `await provider.future` on these across an
// auth transition (e.g. in a test, or any code that also drives sign-out) —
// watch the AsyncValue instead. A captured `.future` is a snapshot of ONE
// build; if auth flips mid-load the provider is invalidated/rebuilt and that
// captured future can be left never completing.
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

const _genericApiErrorMessage = 'something went wrong on our end — try again';
const _offlineErrorMessage =
    "couldn't reach the DJ — check your connection and try again";
const _staleTransientMessage = 'queue was updated — showing the latest';

/// Never adopt a queueVersion without its matching queue, or vice versa — a
/// version whose queue is unknown (or a queue with an unknown version) is
/// worse than adopting neither, since it can silently mismatch a queue the
/// caller already has cached under a different version (a stale queue
/// paired with a fresh version number can make a position-based op like
/// remove/move target the wrong track entirely). This is stricter than
/// dj_api.dart's parsing: a queue without a version is preserved at the API
/// layer (DjApiException.queue can be non-null with queueVersion null — the
/// server may legitimately omit a version), but it's never adopted into
/// ChatState, since position-based ops need a version to target against.
/// Today the server always sends both together, so the two layers agree in
/// practice even though only this one enforces it.
({List<QueueTrack>? queue, int? queueVersion}) _atomicQueueSnapshot(
  List<QueueTrack>? queue,
  int? queueVersion,
) => (queue != null && queueVersion != null)
    ? (queue: queue, queueVersion: queueVersion)
    : (queue: null, queueVersion: null);

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

  /// Returns whether the refetch actually succeeded. On failure the state
  /// assignment applies copyWithPrevious (a previously-good list keeps
  /// showing), which also means callers can't detect the failure from
  /// state alone — hasValue stays true — so user-initiated refreshes
  /// (pull-to-refresh) must check this result and surface the failure
  /// themselves rather than letting the spinner retract silently.
  Future<bool> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(djApiProvider).listSessions(),
    );
    state = next;
    return !next.hasError;
  }

  /// Returns whether the status change actually landed. [setStatus] is the
  /// only fallible step here — it can throw any of [DjApi]'s exit types
  /// (DjApiException, ApiException, NetworkException) and, uncaught, that
  /// would both surface as an unhandled async error AND silently no-op the
  /// row (nothing else would signal the failure back to the UI). Caught here
  /// so the row simply stays as-is and the caller can show a retry snackbar.
  /// [refresh] never needs the same treatment — it's already
  /// [AsyncValue.guard]-wrapped and can't throw.
  Future<bool> archive(String id) async {
    try {
      await ref.read(djApiProvider).setStatus(id, 'archived');
    } catch (_) {
      return false;
    }
    await refresh();
    return true;
  }

  Future<bool> unarchive(String id) async {
    try {
      await ref.read(djApiProvider).setStatus(id, 'active');
    } catch (_) {
      return false;
    }
    await refresh();
    return true;
  }

  /// Manual rename from Home (long-press a session row) — mirrors
  /// [archive]/[unarchive]'s own hardening exactly: [DjApi.renameSession] is
  /// the only fallible step, caught so a failed rename simply leaves the
  /// row's title as-is and the caller can show a retry snackbar, followed by
  /// the same unconditional [refresh] on success.
  Future<bool> rename(String id, String title) async {
    try {
      await ref.read(djApiProvider).renameSession(id, title);
    } catch (_) {
      return false;
    }
    await refresh();
    return true;
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

  /// If both [session] and [queueVersion] are passed, [session] wins outright
  /// — its own `queueVersion` is used as-is and the [queueVersion] param is
  /// silently ignored (the two are never combined/added). In practice every
  /// caller passes at most one of the two: [queueVersion] alone for a bare
  /// version bump (a turn result or queue-ops response bumping the existing
  /// session in place), [session] alone when replacing wholesale (a fresh
  /// getSession snapshot, whose own queueVersion is already correct).
  ChatState copyWith({
    DjSession? session,
    List<ChatMessage>? messages,
    List<QueueTrack>? queue,
    int? queueVersion,
    bool? sending,
    String? transientError,
    bool clearTransientError = false,
  }) {
    assert(
      session == null || queueVersion == null,
      'copyWith: pass session OR queueVersion, not both — session wins and '
      'the queueVersion param would silently be dropped',
    );
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

/// Bumps only the queue version, carrying every other session field —
/// including [DjSession.title] and [DjSession.updatedAt] — over verbatim.
/// Those two go stale the instant this runs: [updatedAt] reflects the last
/// full getSession/create/message turn, not "the queue last moved", and
/// title obviously doesn't change on a queue edit. That's an accepted v1
/// tradeoff, not a bug — the version itself is always accurate, staleness
/// is confined to display-only fields, and the next full session load
/// (getSession) replaces them wholesale anyway.
DjSession _withQueueVersion(DjSession session, int queueVersion) => DjSession(
  id: session.id,
  title: session.title,
  status: session.status,
  queueVersion: queueVersion,
  updatedAt: session.updatedAt,
  notPersonal: session.notPersonal,
);

/// Bumps only the title, carrying every other field over verbatim — the
/// counterpart to [_withQueueVersion] above, used by [ChatNotifier.send] to
/// adopt a same-turn `rename_session` without a refetch. Called AFTER
/// [_withQueueVersion] has already landed the turn's fresh queueVersion onto
/// `session` (via a first `copyWith(queueVersion: ...)`), so the session this
/// wraps already carries the right version — this step only ever changes the
/// title on top of that.
DjSession _withTitle(DjSession session, String title) => DjSession(
  id: session.id,
  title: title,
  status: session.status,
  queueVersion: session.queueVersion,
  updatedAt: session.updatedAt,
  notPersonal: session.notPersonal,
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

  /// Reads whatever [state] is RIGHT NOW (not a snapshot captured before an
  /// `await`) and applies [update] on top of it, then writes the result
  /// back. A turn (send) and a queue edit (applyOps) both run over a real
  /// 20-40s round trip and can legitimately interleave — always merging onto
  /// the current state (rather than onto a pre-await snapshot) means
  /// whichever call finishes second doesn't clobber changes the other one
  /// already landed. No-ops if the provider was disposed or never built.
  void _mergeCurrent(ChatState Function(ChatState current) update) {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData(update(current));
  }

  /// Appends the user's bubble immediately (the server persists it
  /// regardless of how the turn resolves) then posts the turn. A no-op
  /// while a previous [send] is still in flight, guarding double-taps on
  /// the send button. `sending` is restored in a `finally` so it can NEVER
  /// stick at true — not even for an [ApiException] or an entirely
  /// unforeseen exception — which would otherwise brick the composer.
  Future<void> send(String text) async {
    final base = state.value;
    if (base == null || base.sending) return;

    final userMessage = ChatMessage(_localMessage('user', text));
    state = AsyncData(
      base.copyWith(messages: [...base.messages, userMessage], sending: true),
    );

    try {
      final result = await ref.read(djApiProvider).sendMessage(sessionId, text);
      final newTitle = result.sessionTitle;
      _mergeCurrent((c) {
        // First bump queue+version via the `queueVersion` param (never
        // `session`, per copyWith's own session-XOR-queueVersion contract —
        // see ChatState.copyWith's doc comment).
        final withQueue = c.copyWith(
          messages: [...c.messages, ChatMessage(result.djMessage)],
          queue: result.queue,
          queueVersion: result.queueVersion,
        );
        if (newTitle == null) return withQueue;
        // A same-turn rename (rename_session): a SECOND copyWith call, this
        // time passing `session` (never `queueVersion`, same contract) —
        // built from withQueue.session, whose queueVersion already reflects
        // the bump above, so the resulting DjSession carries BOTH the new
        // title and the turn's fresh queueVersion at once.
        return withQueue.copyWith(session: _withTitle(withQueue.session, newTitle));
      });
      // Lazily invalidate (never an eager refresh) so Home's list picks up
      // the new title next time it's read — same "invalidate, don't refetch
      // now" discipline as sessionStarterProvider above; a turn's own
      // 20-40s round trip shouldn't be held up by a second list fetch it
      // doesn't need. Guarded by `ref.mounted`: this provider is
      // autoDispose'd (chatProvider), and navigating away mid-turn can
      // dispose it before this await returns — `ref.invalidate` on a
      // disposed ref throws a StateError (unlike `_mergeCurrent`'s own
      // internal guard above), which would otherwise silently swallow this
      // invalidation instead of just skipping it.
      if (newTitle != null && ref.mounted) {
        ref.invalidate(sessionsProvider);
      }
    } on DjApiException catch (e) {
      if (e.kind == 'stale') {
        // Degraded 409 fallback (see dj_api.dart's _translate409): a
        // malformed 'stale' body couldn't be parsed into a
        // StaleQueueException, but the kind still signals "the queue moved
        // under you" — recover by refetching the session (a wholesale
        // canonical replace, not a merge — there's nothing local worth
        // preserving over the server's fresh view) rather than showing an
        // error bubble the user can't act on.
        await _refetchAfterFailedTurn();
        return;
      }
      final adopted = _atomicQueueSnapshot(e.queue, e.queueVersion);
      _mergeCurrent(
        (c) => c.copyWith(
          messages: [
            ...c.messages,
            ChatMessage(_localMessage('dj', e.message), isError: true),
          ],
          queue: adopted.queue,
          queueVersion: adopted.queueVersion,
        ),
      );
    } on ApiException {
      // 401/403/404/500/... — not part of the DJ error taxonomy, but still
      // has to resolve into SOMETHING visible rather than an unhandled
      // exception and a permanently-stuck composer.
      _mergeCurrent(
        (c) => c.copyWith(
          messages: [
            ...c.messages,
            ChatMessage(
              _localMessage('dj', _genericApiErrorMessage),
              isError: true,
            ),
          ],
        ),
      );
    } on NetworkException {
      // Transport failure before any response — unlike the DjApiException
      // branch above, the server never saw this turn at all, so the user
      // bubble above is client-local only (no persisted duplicate risk, but
      // also no server-side record). Acceptable for v1: a retry may or may
      // not duplicate depending on whether the request actually landed.
      _mergeCurrent(
        (c) => c.copyWith(
          messages: [
            ...c.messages,
            ChatMessage(
              _localMessage('dj', _offlineErrorMessage),
              isError: true,
            ),
          ],
        ),
      );
    } finally {
      // Always restored exactly once, on top of whatever is current at this
      // point (including anything the branches above just wrote) — a no-op
      // if some other path (e.g. the stale refetch) already cleared it.
      _mergeCurrent((c) => c.sending ? c.copyWith(sending: false) : c);
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
      _mergeCurrent((c) => c.copyWith(sending: false));
    }
  }

  /// Server-canonical: always posts against the current known
  /// [ChatState.queueVersion] and replaces queue+version from the response.
  /// Merges onto whatever is current when the response lands (see
  /// [_mergeCurrent]) rather than a pre-await snapshot, so an interleaved
  /// [send] landing first (or second) composes correctly either way.
  Future<void> applyOps(List<QueueOp> ops) async {
    final base = state.value;
    if (base == null) return;
    try {
      final result = await ref
          .read(djApiProvider)
          .applyQueueOps(sessionId, ops, base.queueVersion);
      _mergeCurrent(
        (c) =>
            c.copyWith(queue: result.queue, queueVersion: result.queueVersion),
      );
    } on StaleQueueException catch (e) {
      _mergeCurrent(
        (c) => c.copyWith(
          queue: e.queue,
          queueVersion: e.queueVersion,
          transientError: _staleTransientMessage,
        ),
      );
    } on DjApiException catch (e) {
      // e.g. kind 'dj_required' for a manual swap/extend — no queue change,
      // just surface the server's message (transient, one-shot).
      _mergeCurrent((c) => c.copyWith(transientError: e.message));
    } on ApiException {
      _mergeCurrent((c) => c.copyWith(transientError: _genericApiErrorMessage));
    } on NetworkException {
      _mergeCurrent((c) => c.copyWith(transientError: _offlineErrorMessage));
    }
  }

  /// Seeds a synthetic error bubble into the just-loaded transcript — used
  /// when Home navigates here after a create-session failure that still
  /// persisted a session row (see [sessionStarterProvider]'s doc comment):
  /// the server's error message never became part of the transcript itself
  /// (the row was created, but the turn failed), so [ChatScreen] calls this
  /// once, right after the initial load, to surface it locally. Reuses the
  /// same error-bubble shape [send]'s failure branches produce, so the
  /// existing retry affordance (resend against the nearest preceding user
  /// turn) works unchanged.
  void seedInitialError(String message) {
    _mergeCurrent(
      (c) => c.copyWith(
        messages: [
          ...c.messages,
          ChatMessage(_localMessage('dj', message), isError: true),
        ],
      ),
    );
  }

  void clearTransientError() {
    final current = state.value;
    if (current == null || current.transientError == null) return;
    state = AsyncData(current.copyWith(clearTransientError: true));
  }
}

/// autoDispose: a session's transcript is only worth keeping in memory while
/// something (the chat screen) is actually watching it — otherwise visiting
/// many sessions over a run would grow an unbounded cache of every
/// transcript ever opened. Screens that want it kept warm across a brief
/// unmount should watch it (a plain read doesn't count as a listener).
final chatProvider = AsyncNotifierProvider.autoDispose
    .family<ChatNotifier, ChatState, String>(ChatNotifier.new);

// ---------------------------------------------------------------------------
// New-session flow
// ---------------------------------------------------------------------------

/// A plain callable (not a stateful notifier) that starts a new session and
/// returns its id. Invalidates [sessionsProvider] on both outcomes, since a
/// failed create can still have persisted a session row (the server echoes
/// `sessionId` on the error body) — the Home screen still needs it in the
/// list even though it's about to handle the rethrown exception.
///
/// Deliberately does NOT await a refetch of the sessions list before
/// returning: `invalidate` (rather than an eager `refresh()`) is the correct
/// primitive here — it supersedes any list build already in flight (instead
/// of racing it with a second concurrent fetch) and defers the actual
/// re-fetch to whenever something next reads [sessionsProvider] (e.g. the
/// Home screen after navigating back), so returning the new id — and
/// navigating to it — isn't held up by an extra round trip.
final sessionStarterProvider = Provider<Future<String> Function(String prompt)>(
  (ref) {
    return (String prompt) async {
      try {
        final detail = await ref.read(djApiProvider).createSession(prompt);
        ref.invalidate(sessionsProvider);
        return detail.session.id;
      } on DjApiException {
        ref.invalidate(sessionsProvider);
        rethrow;
      }
    };
  },
);

// ---------------------------------------------------------------------------
// "What the DJ knows" memory notes (P4 Task 4)
// ---------------------------------------------------------------------------

/// Mirrors [SessionsNotifier]'s shape: loads `GET /me/memories` (already
/// newest-first server-side, so no client-side sort needed), reloads/resets
/// on every auth transition. Unlike sessions, there's no archive/unarchive —
/// just [forget], a hard delete with no server-side restore.
class MemoriesNotifier extends AsyncNotifier<List<DjMemory>> {
  @override
  Future<List<DjMemory>> build() async {
    ref.watch(
      authProvider,
    ); // user-scoped: reload/reset on every auth transition
    final api = ref.watch(djApiProvider);
    return api.listMemories();
  }

  /// Same contract as [SessionsNotifier.refresh]: returns whether the
  /// refetch actually succeeded (state itself keeps showing the previously-
  /// good list on failure via copyWithPrevious, so callers must check the
  /// return value to surface a failure).
  Future<bool> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(djApiProvider).listMemories(),
    );
    state = next;
    return !next.hasError;
  }

  /// Deletes the note server-side and, only on success, drops it from local
  /// state. The undo-window bookkeeping (optimistic hide, the deferred
  /// commit, restoring the row on failure) is owned by MemoryScreen itself —
  /// this method is the single point where the server call actually fires,
  /// called only once the undo window has closed without an undo (or a
  /// later swipe superseded this one — see MemoryScreen's pending-forget
  /// doc comment).
  ///
  /// A 404 is treated as success, not failure: it means the note is already
  /// gone server-side (e.g. deleted from another device, or a race with
  /// itself), and the caller's intent — this row should not exist — is
  /// already satisfied. Surfacing that as a failure would restore a row the
  /// user was told was forgotten, which is worse than silently dropping it.
  ///
  /// Deliberately diverges from [SessionsNotifier], which always follows a
  /// mutation with a full [refresh] (re-fetching the canonical list):
  /// [forget] instead drops the row from local state directly, with no
  /// refetch. That's safe here specifically because a hard delete's local
  /// view (the list minus this one id) can never be wrong the way a
  /// status-change's local view could be — there's no server-side field this
  /// row's absence could get wrong. If memories ever grow a softer/partial
  /// delete, revisit this shortcut and refetch like [SessionsNotifier] does.
  Future<bool> forget(String id) async {
    try {
      await ref.read(djApiProvider).deleteMemory(id);
    } on ApiException catch (e) {
      if (e.statusCode != 404) return false;
      // Already gone — fall through to the same local drop as a real
      // success, below.
    } catch (_) {
      return false;
    }
    final current = state.value;
    if (current != null) {
      state = AsyncData([for (final m in current) if (m.id != id) m]);
    }
    return true;
  }
}

final memoriesProvider = AsyncNotifierProvider<MemoriesNotifier, List<DjMemory>>(
  MemoriesNotifier.new,
);
