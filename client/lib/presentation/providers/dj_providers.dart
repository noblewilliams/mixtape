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
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../../data/listening/listening_models.dart' show FunnelEventType;
import '../../data/playlists/playlist_context_models.dart';
import 'auth_provider.dart';
import 'mix_activity_provider.dart';
import 'mix_operation_gate.dart';
import 'onboarding_provider.dart';
import 'playlist_context_provider.dart';
import 'first_run_funnel_provider.dart';
import 'working_step.dart';
import '../widgets/energy_journey.dart' show EnergyArc;
import 'funnel_provider.dart';
import 'keep_mixes_provider.dart';
import 'listen_later_provider.dart';

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

/// Shown when an edit loses a version race. Public so a screen with its own
/// approved conflict copy (the arrangement's "This mix changed elsewhere.")
/// can recognise it rather than string-matching a private constant.
const staleQueueTransientMessage = 'queue was updated — showing the latest';

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
  int _generation = 0;
  int _revision = 0;
  int _readSequence = 0;
  final _writes = <String>{};
  final _changedAt = <String, int>{};

  bool get hasPendingMetadataWrites => _writes.isNotEmpty;

  @override
  Future<List<DjSession>> build() async {
    ref.watch(authProvider);
    final api = ref.watch(djApiProvider);
    final generation = ++_generation;
    final revision = _revision;
    _writes.clear();
    _changedAt.clear();
    ref.onDispose(() => _generation++);
    try {
      final sessions = await api.listSessions();
      if (generation != _generation) return sessions;
      return _mergeRead(sessions, revision);
    } catch (_) {
      // A PATCH can finish while this initial read is still outstanding.
      // Its canonical value remains usable even if the old read fails.
      if (generation == _generation &&
          revision != _revision &&
          state.value != null) {
        return state.requireValue;
      }
      rethrow;
    }
  }

  /// Keep the last usable list on read failure. A read started before a
  /// metadata write may update other rows, but cannot roll that write back.
  Future<bool> refresh() => _refresh();

  Future<bool> _refresh({String? preserveId}) async {
    final generation = _generation;
    final revision = _revision;
    final sequence = ++_readSequence;
    final next = await AsyncValue.guard(
      () => ref.read(djApiProvider).listSessions(),
    );
    if (generation != _generation || sequence != _readSequence) return false;
    if (next.hasError) {
      state = next;
      return false;
    }
    state = AsyncData(
      _mergeRead(next.requireValue, revision, preserveId: preserveId),
    );
    return true;
  }

  List<DjSession> _mergeRead(
    List<DjSession> sessions,
    int revision, {
    String? preserveId,
  }) {
    final current = state.value ?? const <DjSession>[];
    final preserved = {
      for (final session in current)
        if (session.id == preserveId ||
            (_changedAt[session.id] ?? 0) > revision)
          session.id: session,
    };
    final listedIds = sessions.map((session) => session.id).toSet();
    return [
      for (final session in sessions) preserved[session.id] ?? session,
      for (final session in preserved.values)
        if (!listedIds.contains(session.id)) session,
    ];
  }

  Future<bool> archive(String id) =>
      _update(id, (api) => api.setStatus(id, 'archived'));

  Future<bool> unarchive(String id) =>
      _update(id, (api) => api.setStatus(id, 'active'));

  Future<bool> rename(String id, String title) =>
      _update(id, (api) => api.renameSession(id, title));

  Future<bool> setCaseColor(String id, String color) =>
      _update(id, (api) => api.setCaseColor(id, color));

  /// Adopt the complete PATCH response before any secondary read. A failed
  /// list refresh does not turn a successful archive/rename into a failure.
  /// One write per mix prevents conflicting actions from racing each other.
  Future<bool> _update(
    String id,
    Future<DjSession> Function(DjApi api) update,
  ) async {
    if (!_writes.add(id)) return false;
    final generation = _generation;
    try {
      final canonical = await update(ref.read(djApiProvider));
      if (generation != _generation) return false;
      _changedAt[id] = ++_revision;
      final current = state.value ?? const <DjSession>[];
      state = AsyncData([
        for (final session in current) session.id == id ? canonical : session,
        if (!current.any((session) => session.id == id)) canonical,
      ]);
      // Secondary reads must not delay Undo or keep a saved name busy.
      unawaited(_refresh(preserveId: id));
      return true;
    } catch (_) {
      return false;
    } finally {
      if (generation == _generation) _writes.remove(id);
    }
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
  const ChatMessage(this.message, {this.isError = false, this.remake = false});

  final DjMessage message;
  final bool isError;

  /// Client-side only, never parsed from or sent to the server: this
  /// optimistic listener line came from [ChatNotifier.remake], so a resend
  /// after a failed turn must go back through [ChatNotifier.remake] (the
  /// text alone would post a plain turn).
  final bool remake;
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
    this.remaking = false,
    this.transientError,
    this.supportsInsert = false,
    this.pickState,
    this.suggestions,
    this.addMusic,
    this.workingStep,
    this.shared = false,
    this.stopping = false,
    this.shape,
    this.landedShape,
  });

  /// The Shape control's pick for this mix, not yet taken by a turn that
  /// landed (2026-11-15): every mix message carries it, and it holds through
  /// a turn that lands while it was being picked, a stopped turn and a failed
  /// one. Null when there is no pick; the control then shows the mix's own
  /// shape. Always null for an album.
  final EnergyArc? shape;

  /// The shape the last landed turn carried: what the control shows while
  /// the new version's own detail (its `energyArc`) is still being read.
  final EnergyArc? landedShape;

  /// A [ChatNotifier.stop] is still out: the turn is gone from the screen,
  /// the server is undoing it. The listener may send meanwhile (the turn
  /// waits for the stop); the mix's operation gate stays held until then.
  final bool stopping;

  final DjSession session;

  /// The mix has an active share link (spec 2026-11-13 shared-mixes), so its
  /// ⋯ menus offer Stop sharing. Read with the session, then kept in step
  /// locally by [ChatNotifier.setShared] after a Share or a Stop sharing.
  final bool shared;

  /// Mix or album, read off the session (one source of truth, as
  /// [queueVersion] is).
  SessionKind get kind => session.kind;

  /// Album sessions only: the current shortlist. Its version is always
  /// [queueVersion] once adopted.
  final AlbumPickState? pickState;

  /// The latest failed album turn's refinement pills; cleared when the next
  /// send starts.
  final List<String>? suggestions;

  /// What the latest mix turn offered to add (the history pill); cleared
  /// when the next send starts, as [suggestions] are.
  final AddMusicOffer? addMusic;
  final List<ChatMessage> messages;
  final List<QueueTrack> queue;
  final bool sending;

  /// Where the mix turn out has got to, once its stream opened (spec
  /// 2026-11-13 turn steps): null before that, against an older server, for
  /// an album turn, and once the turn ends. The Mixes activity's working
  /// entry carries the same, for a conversation reopened mid-turn.
  final WorkingStep? workingStep;

  /// A [ChatNotifier.remake] is out: from its start until the re-reads after
  /// it (the session's `notPersonal`, the listener's `musicReady`) resolve,
  /// or until it fails. The conversation hides the music door meanwhile
  /// (board 3C: the line goes while the DJ works).
  final bool remaking;

  /// Whether the server understands the `insert` queue op (see
  /// [SessionDetail.supportsInsert]) — the arrangement screen offers Undo on
  /// a removal only when it does. A capability of the deploy, so it rides the
  /// session load and never changes under an edit.
  final bool supportsInsert;

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
    bool? remaking,
    String? transientError,
    bool clearTransientError = false,
    bool? supportsInsert,
    AlbumPickState? pickState,
    List<String>? suggestions,
    bool clearSuggestions = false,
    AddMusicOffer? addMusic,
    bool clearAddMusic = false,
    WorkingStep? workingStep,
    bool clearWorkingStep = false,
    bool? shared,
    bool? stopping,
    EnergyArc? shape,
    bool clearShape = false,
    EnergyArc? landedShape,
    bool clearLandedShape = false,
  }) {
    assert(
      session == null || queueVersion == null,
      'copyWith: pass session OR queueVersion, not both — session wins and '
      'the queueVersion param would silently be dropped',
    );
    final resolvedSession =
        session ??
        (queueVersion != null
            ? this.session.copyWith(queueVersion: queueVersion)
            : this.session);
    return ChatState(
      session: resolvedSession,
      messages: messages ?? this.messages,
      queue: queue ?? this.queue,
      sending: sending ?? this.sending,
      remaking: remaking ?? this.remaking,
      transientError: clearTransientError
          ? null
          : (transientError ?? this.transientError),
      supportsInsert: supportsInsert ?? this.supportsInsert,
      pickState: pickState ?? this.pickState,
      suggestions: clearSuggestions ? null : (suggestions ?? this.suggestions),
      addMusic: clearAddMusic ? null : (addMusic ?? this.addMusic),
      workingStep: clearWorkingStep ? null : (workingStep ?? this.workingStep),
      shared: shared ?? this.shared,
      stopping: stopping ?? this.stopping,
      shape: clearShape ? null : (shape ?? this.shape),
      landedShape: clearLandedShape ? null : (landedShape ?? this.landedShape),
    );
  }
}

// Bumping the version leaves [DjSession.updatedAt] (and the title) as the
// last full load had them: an accepted v1 tradeoff, since the version itself
// is always accurate and the next getSession replaces the display fields.

/// A mix turn [ChatNotifier.stop] can still take back.
class _OutTurn {
  _OutTurn({
    required this.number,
    required this.text,
    required this.remake,
    required this.bubble,
    required this.base,
    required this.activity,
    required this.release,
  });

  final int number;
  final String text;
  final bool remake;

  /// The listener's line on screen.
  final ChatMessage bubble;

  /// The conversation the turn builds on.
  ChatState base;

  final TurnActivity activity;

  /// The mix's operation gate; null while the turn waits on an earlier stop
  /// that still holds it.
  void Function()? release;
}

class ChatNotifier extends AsyncNotifier<ChatState> {
  ChatNotifier(this.sessionId);

  final String sessionId;
  int _localSeq = 0;
  int _generation = 0;
  int _nameRevision = 0;
  bool _renaming = false;

  /// Counts the turns this notifier sent, so a late read knows when another
  /// has started since.
  int _turns = 0;

  /// The mix turn out, while [stop] can still take it back: from the moment
  /// it is sent until its request answers.
  _OutTurn? _out;

  /// Turns numbered at or below this were stopped: whatever they answer is
  /// ignored.
  int _stoppedThrough = 0;

  /// The stop still out, until the server has answered it; the next turn
  /// waits on it.
  Future<void>? _stopping;

  /// The listener's line of a turn waiting on [_stopping], kept through the
  /// re-read a too-late stop makes.
  ChatMessage? _waiting;

  /// Counts the Shape control's picks, so a turn that lands knows whether
  /// the pick it carried is still the one showing.
  int _shapeRevision = 0;

  /// [ChatState.shape], kept beside the state so a rebuild (a reopened
  /// conversation re-reading once an inherited turn lands, a retry) hands it
  /// on through [pendingShapesProvider] rather than dropping it.
  EnergyArc? _pick;

  /// The one later read after a dropped stream ([_afterDroppedStream]).
  Timer? _lateRead;

  /// How long after a dropped stream's first read the session is read once
  /// more: inside the 30 s the server gets to finish the turn.
  @visibleForTesting
  static Duration lateReadDelay = const Duration(seconds: 25);

  Future<bool> rename(String title) async {
    if (!ref.mounted ||
        _renaming ||
        state.value == null ||
        title.trim().isEmpty) {
      return false;
    }
    final generation = _generation;
    _renaming = true;
    ++_nameRevision;
    try {
      final saved = await ref
          .read(sessionsProvider.notifier)
          .rename(sessionId, title.trim());
      if (!_current(generation) || !saved) return false;
      final summaries = ref.read(sessionsProvider).value ?? const <DjSession>[];
      final canonical = summaries
          .where((session) => session.id == sessionId)
          .firstOrNull;
      if (canonical == null) return false;
      _mergeCurrent(
        (current) => current.copyWith(
          session: current.session.copyWith(title: canonical.title),
        ),
      );
      return true;
    } finally {
      if (_current(generation)) _renaming = false;
    }
  }

  Future<bool> setArchived(bool archived) async {
    if (!ref.mounted || state.value == null) return false;
    final generation = _generation;
    final sessions = ref.read(sessionsProvider.notifier);
    final saved = await (archived
        ? sessions.archive(sessionId)
        : sessions.unarchive(sessionId));
    if (!_current(generation) || !saved) return false;
    _mergeCurrent(
      (current) => current.copyWith(
        session: current.session.copyWith(
          status: archived ? 'archived' : 'active',
        ),
      ),
    );
    return true;
  }

  /// A Share or Stop sharing landed: the menus follow without a re-read.
  void setShared(bool shared) =>
      _mergeCurrent((current) => current.copyWith(shared: shared));

  bool _current(int generation) => ref.mounted && generation == _generation;

  @override
  Future<ChatState> build() async {
    ref.watch(
      authProvider,
    ); // user-scoped: reload/reset on every auth transition
    final generation = ++_generation;
    // In-flight flags belong to the build that set them: a rebuild mid-write
    // (auth, or a screen's retry invalidating this provider) must not leave
    // later writes refused, since the superseded write's finally skips them.
    _renaming = false;
    _picking = false;
    _savingLater = false;
    _out = null;
    _stopping = null;
    _waiting = null;
    final shapes = ref.read(pendingShapesProvider);
    ref.onDispose(() {
      _generation++;
      _lateRead?.cancel();
      _lateRead = null;
      final pick = _pick;
      if (pick != null) shapes.put(sessionId, pick);
    });
    // A pick waiting for this mix: Home's, made while the mix was being
    // created, or this conversation's own from before a rebuild.
    _pick = shapes.take(sessionId);
    final api = ref.watch(djApiProvider);
    final seedRead = _captureSeedRead();
    // A new session's first turn: what its create response offered, which
    // the read below never carries. Taken before the read, so it expires
    // with this session's first build even if that build never lands (the
    // listener backed out, or a rebuild superseded it).
    final firstTurn = ref.read(firstTurnOffersProvider).take(sessionId);
    _followInheritedTurn();
    final detail = await api.getSession(sessionId);
    if (!_current(generation)) return _fromDetail(detail);
    seedRead?.adopt(detail.playlistSeed);
    if (detail.session.kind == SessionKind.album) _pick = null;
    final loaded = _fromDetail(detail).copyWith(shape: _pick);
    if (firstTurn == null) return loaded;
    return loaded.copyWith(
      addMusic: loaded.addMusic ?? firstTurn.addMusic,
      suggestions: loaded.suggestions ?? firstTurn.suggestions,
    );
  }

  /// A turn an earlier build sent is still out — the conversation was left
  /// mid-turn and its transcript let go, and the request carried on. Its
  /// reply lands in no state, so this build reads the session again once
  /// that turn ends (device smoke, 2026-11-13). Once: a turn this build
  /// sends lands in its own state.
  void _followInheritedTurn() {
    if (!ref.read(mixActivityProvider).isWorking(sessionId)) return;
    var followed = false;
    ref.listen<bool>(
      mixActivityProvider.select((activity) => activity.isWorking(sessionId)),
      (previous, working) {
        if (followed || working || previous != true) return;
        followed = true;
        ref.invalidateSelf();
      },
    );
  }

  ({void Function(PlaylistSeedState?) adopt})? _captureSeedRead() {
    final provider = sessionPlaylistContextProvider(sessionId);
    if (!ref.exists(provider)) return null;
    final notifier = ref.read(provider.notifier);
    final token = notifier.readToken;
    return (
      adopt: (seed) {
        notifier.adoptCanonical(seed, token);
      },
    );
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
    supportsInsert: detail.supportsInsert,
    pickState: detail.pickState,
    suggestions: detail.suggestions,
    addMusic: detail.addMusic,
    shared: detail.shared,
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
  ///
  /// [mixShape] is the shape the mix itself has (its current version's), sent
  /// when there is no pick ([ChatState.shape]) so the DJ always takes note of
  /// the shape the control shows.
  Future<void> send(String text, {EnergyArc? mixShape}) => _turn(
    text,
    (api, energyArc, onProgress) => api.sendMessageWithProgress(
      sessionId,
      text,
      energyArc: energyArc,
      onProgress: onProgress,
    ),
    mixShape: mixShape,
  );

  /// The Shape control's pick for this mix (null clears it, and the control
  /// goes back to the mix's own shape). Nothing is sent: the next message
  /// carries it. Changeable while a turn is out; that turn keeps the shape
  /// it went out with. Mix sessions only.
  void setShape(EnergyArc? arc) {
    final current = state.value;
    if (current == null || current.kind == SessionKind.album) return;
    _shapeRevision++;
    _pick = arc;
    _mergeCurrent(
      (c) =>
          arc == null ? c.copyWith(clearShape: true) : c.copyWith(shape: arc),
    );
  }

  /// Asks for a new version of this mix from the listener's own music: the
  /// same turn as [send], with [remakeText] as the listener's line (marked
  /// [ChatMessage.remake]), posted through [DjApiRemake.sendRemake].
  ///
  /// [countTap] records `remake_tapped` as the remake goes out (past the
  /// in-flight guards), so a tap that sends nothing counts nothing. The
  /// screen passes it for a Remake tap only, never for a Resend or the retry
  /// of a refused one.
  ///
  /// [ChatState.remaking] holds until the session and onboarding re-reads
  /// after the turn resolve: a remake that made nothing leaves the mix a
  /// catalog one and the music not ready, and the door must say so.
  Future<void> remake({bool countTap = false, EnergyArc? mixShape}) => _turn(
    remakeText,
    (api, energyArc, onProgress) => api.sendRemakeWithProgress(
      sessionId,
      energyArc: energyArc,
      onProgress: onProgress,
    ),
    remake: true,
    countTap: countTap,
    mixShape: mixShape,
  );

  /// The turn pipeline [send] and [remake] share; [post] and the listener
  /// line's [remake] marker are the only differences between them.
  ///
  /// A mix turn hands [post] a progress callback, so a server that streams
  /// says what the DJ is doing ([ChatState.workingStep], and the Mixes
  /// activity's working entry); an album turn hands it none and keeps its
  /// timed lines.
  ///
  /// While a [stop] is still undoing the last turn, this one shows as
  /// working at once but only goes out once the rollback is done, so the
  /// two never race on the server.
  Future<void> _turn(
    String text,
    Future<TurnResult> Function(
      DjApi api,
      String? energyArc,
      void Function(TurnProgress progress)? onProgress,
    )
    post, {
    bool remake = false,
    bool countTap = false,
    EnergyArc? mixShape,
  }) async {
    final nameRevision = _nameRevision;
    final first = state.value;
    if (first == null || first.sending) return;
    final generation = _generation;
    // The shape showing goes out with the turn, so the DJ always takes note
    // of it: the pick, else the mix's own. None for an album.
    final carried = first.kind == SessionKind.album
        ? null
        : (first.shape ?? mixShape);
    final shapeRevision = _shapeRevision;
    final gate = mixOperationProvider(sessionId);
    final pendingStop = _stopping;
    // Without a stop out the gate is taken now, as it always was; behind a
    // stop the stop still holds it, and hands it on once it answers.
    final taken = pendingStop == null
        ? ref.read(gate.notifier).acquire(MixOperation.sending)
        : null;
    if (pendingStop == null && taken == null) return;
    final turn = ++_turns;
    // Stopped turns answer into nothing: their result, their error, their
    // clean-up all belong to a conversation that has moved on.
    bool live() => _current(generation) && turn > _stoppedThrough;
    // The Mixes list's view of it: working while out, ready once it lands
    // (even after this conversation is gone), nothing if it is taken back.
    final endActivity = ref
        .read(mixActivityProvider.notifier)
        .beginTurn(sessionId);
    var landed = true;
    // Once the stream has opened the server has the turn, whatever happens
    // to the connection after.
    var streamed = false;
    WorkingStep? step;
    void onProgress(TurnProgress progress) {
      streamed = true;
      final next = WorkingStep.after(step, progress);
      if (next == null || identical(next, step)) return;
      step = next;
      // A conversation left mid-turn still keeps the Mixes list's step (a
      // stopped turn's activity has already ended, so it notes nothing).
      endActivity.step(next);
      if (live()) _mergeCurrent((c) => c.copyWith(workingStep: next));
    }

    final userMessage = ChatMessage(
      _localMessage('user', text),
      remake: remake,
    );
    state = AsyncData(
      first.copyWith(
        messages: [...first.messages, userMessage],
        sending: true,
        remaking: remake,
        clearSuggestions: true,
        clearAddMusic: true,
      ),
    );
    final out = _OutTurn(
      number: turn,
      text: text,
      remake: remake,
      bubble: userMessage,
      base: first,
      activity: endActivity,
      release: taken,
    );
    _out = out;
    if (countTap) {
      ref.read(funnelMilestonesProvider).record(FunnelEventType.remakeTapped);
    }

    if (pendingStop != null) {
      _waiting = userMessage;
      await pendingStop;
      if (identical(_waiting, userMessage)) _waiting = null;
      // Stopped while it waited (nothing went out, so nothing to undo), or
      // the conversation went: [stop] or the rebuild already tidied up.
      if (!live()) {
        if (!_current(generation)) endActivity(ready: false);
        return;
      }
      final release = ref.read(gate.notifier).acquire(MixOperation.sending);
      if (release == null) {
        // Something else took the mix in between (an inspiration change):
        // this turn is taken back rather than sent over it.
        if (identical(_out, out)) _out = null;
        endActivity(ready: false);
        _mergeCurrent(
          (c) => c.copyWith(
            messages: [
              for (final m in c.messages)
                if (!identical(m, userMessage)) m,
            ],
            sending: false,
            remaking: false,
          ),
        );
        return;
      }
      out.release = release;
      // What the turn builds on is the conversation as the stop left it.
      final now = state.value!;
      out.base = now.copyWith(
        messages: [
          for (final m in now.messages)
            if (!identical(m, userMessage)) m,
        ],
        sending: false,
        remaking: false,
      );
    }
    final base = out.base;
    final release = out.release!;

    try {
      final TurnResult result;
      try {
        result = await post(
          ref.read(djApiProvider),
          carried?.name,
          base.kind == SessionKind.album ? null : onProgress,
        );
      } finally {
        // The request has answered: from here there is nothing to stop.
        if (identical(_out, out)) _out = null;
      }
      if (!live()) return;
      // The new version wears the shape the turn carried. A pick made while
      // the turn was out is newer than that one, and waits for the next.
      final taken = shapeRevision == _shapeRevision;
      if (taken) _pick = null;
      _mergeCurrent(
        (c) => c.copyWith(
          clearShape: taken,
          landedShape: carried,
          clearLandedShape: carried == null,
        ),
      );
      await _land(
        result,
        base: base,
        generation: generation,
        nameRevision: nameRevision,
        remake: remake,
      );
    } on AiConsentRequiredException {
      // Not a failed turn: the server wants consent first. The turn is
      // taken back and the screen asks, keeping the text.
      landed = false;
      if (!live()) return;
      _mergeCurrent(
        (c) => c.copyWith(
          messages: [
            for (final m in c.messages)
              if (!identical(m, userMessage)) m,
          ],
        ),
      );
      rethrow;
    } on DjApiException catch (e) {
      if (!live()) return;
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
      // An album failure after a version landed carries that shortlist:
      // adopt it (and its version) before the error turn.
      final pickState = e.pickState;
      _mergeCurrent(
        (c) => c.copyWith(
          messages: [
            ...c.messages,
            ChatMessage(_localMessage('dj', e.message), isError: true),
          ],
          queue: adopted.queue,
          queueVersion: pickState?.version ?? adopted.queueVersion,
          pickState: pickState,
        ),
      );
    } on ApiException {
      if (!live()) return;
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
      if (!live()) return;
      if (streamed) {
        await _afterDroppedStream(
          base: base,
          generation: generation,
          nameRevision: nameRevision,
          remake: remake,
        );
        return;
      }
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
      // A stopped turn's gate and activity are the stop's, and its state is
      // already put back: a newer turn may be out on top of it by now.
      if (turn > _stoppedThrough) {
        // Always restored exactly once, on top of whatever is current at
        // this point (including anything the branches above just wrote) —
        // a no-op if some other path (e.g. the stale refetch) already
        // cleared it.
        release();
        endActivity(ready: landed);
        if (_current(generation)) {
          _mergeCurrent(
            (c) => c.sending || c.remaking || c.workingStep != null
                ? c.copyWith(
                    sending: false,
                    remaking: false,
                    clearWorkingStep: true,
                  )
                : c,
          );
        }
      }
    }
  }

  /// Stops the mix turn that is out (spec 2026-11-15 stop-a-turn): it goes
  /// from the screen at once — the listener's line, the working line, the
  /// Mixes list's working dot — and whatever its request answers later is
  /// ignored. The server is asked to stop it and undo what it wrote; when it
  /// says the turn had already finished (or the ask fails), the session is
  /// read again so what landed shows.
  ///
  /// Returns the stopped line's text for the composer to take back (none for
  /// a remake, whose line the listener never typed); null when there was
  /// nothing to stop: no turn out, its request already answered, or an
  /// album turn (no stop in v1).
  ///
  /// The mix's operation gate stays held until the server has answered, so
  /// nothing else races the rollback; a [send] meanwhile waits for it.
  String? stop() {
    final out = _out;
    final current = state.value;
    if (out == null || current == null || current.kind == SessionKind.album) {
      return null;
    }
    _out = null;
    _stoppedThrough = out.number;
    if (identical(_waiting, out.bubble)) _waiting = null;
    out.activity(ready: false);
    final base = out.base;
    final release = out.release;
    _mergeCurrent(
      (c) => c.copyWith(
        messages: [
          for (final m in c.messages)
            if (!identical(m, out.bubble)) m,
        ],
        sending: false,
        remaking: false,
        clearWorkingStep: true,
        // What the turn cleared as it went out comes back with it.
        suggestions: c.suggestions ?? base.suggestions,
        addMusic: c.addMusic ?? base.addMusic,
        stopping: release != null ? true : null,
      ),
    );
    // A turn still waiting on an earlier stop never went out: nothing to
    // ask the server.
    if (release != null) _askToStop(release);
    return out.remake ? null : out.text;
  }

  void _askToStop(void Function() release) {
    final generation = _generation;
    final api = ref.read(djApiProvider);
    final done = Completer<void>();
    final stopping = done.future;
    _stopping = stopping;
    unawaited(() async {
      try {
        var stopped = false;
        try {
          stopped = await api.stopTurn(sessionId);
        } catch (_) {
          // Unknown whether it stopped: the read below says what is there.
        }
        if (!stopped && _current(generation)) await _readAfterStop(generation);
      } finally {
        release();
        if (identical(_stopping, stopping)) {
          _stopping = null;
          if (_current(generation)) {
            _mergeCurrent((c) => c.stopping ? c.copyWith(stopping: false) : c);
          }
        }
        done.complete();
      }
    }());
  }

  /// The turn finished before the stop landed (or the stop failed): the
  /// session as the server has it, with a send already waiting on the stop
  /// kept on top, still working.
  Future<void> _readAfterStop(int generation) async {
    final seedRead = _captureSeedRead();
    try {
      final detail = await ref.read(djApiProvider).getSession(sessionId);
      if (!_current(generation)) return;
      seedRead?.adopt(detail.playlistSeed);
      final fresh = _fromDetail(detail);
      _mergeCurrent((c) {
        final waiting = _waiting;
        return fresh.copyWith(
          messages: [...fresh.messages, ?waiting],
          sending: c.sending,
          remaking: c.remaking,
          stopping: c.stopping,
          workingStep: c.workingStep,
          shape: c.shape,
          landedShape: c.landedShape,
          clearSuggestions: waiting != null,
          clearAddMusic: waiting != null,
        );
      });
    } catch (_) {
      // The last view stays; the next full load replaces it.
    }
  }

  /// A turn's reply landing in the conversation: the DJ's line after the
  /// listener's, the queue and version it made, a same-turn rename, and the
  /// re-reads and notes a mix reply brings. [replacing] is a failure line
  /// the reply takes back (a reply found after a dropped stream).
  Future<void> _land(
    TurnResult result, {
    required ChatState base,
    required int generation,
    required int nameRevision,
    required bool remake,
    ChatMessage? replacing,
  }) async {
    // A refused mix (an empty queue) that this turn filled is the
    // listener's mix landing, as a new mix with content is.
    final filled = base.queue.isEmpty && result.queue.isNotEmpty;
    final newTitle = result.sessionTitle;
    _mergeCurrent((c) {
      // First bump queue+version via the `queueVersion` param (never
      // `session`, per copyWith's own session-XOR-queueVersion contract —
      // see ChatState.copyWith's doc comment).
      // An album turn carries its shortlist and, after an honest
      // failure, refinement pills; its queue is empty and its version
      // is the pick version.
      final withQueue = c.copyWith(
        messages: [
          for (final m in c.messages)
            if (!identical(m, replacing)) m,
          ChatMessage(result.djMessage),
        ],
        queue: result.queue,
        queueVersion: result.queueVersion,
        pickState: result.pickState,
        suggestions: result.suggestions,
        addMusic: result.addMusic,
      );
      if (newTitle == null || nameRevision != _nameRevision) return withQueue;
      // A same-turn rename (rename_session): a SECOND copyWith call, this
      // time passing `session` (never `queueVersion`, same contract) —
      // built from withQueue.session, whose queueVersion already reflects
      // the bump above, so the resulting DjSession carries BOTH the new
      // title and the turn's fresh queueVersion at once.
      return withQueue.copyWith(
        session: withQueue.session.copyWith(title: newTitle),
      );
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
    if (newTitle != null && ref.mounted && nameRevision == _nameRevision) {
      if (ref.exists(sessionsProvider) &&
          ref.read(sessionsProvider.notifier).hasPendingMetadataWrites) {
        // Invalidating would cancel metadata ownership while its PATCH is
        // still in flight. Refresh merges safely with the eventual result.
        unawaited(ref.read(sessionsProvider.notifier).refresh());
      } else {
        ref.invalidate(sessionsProvider);
      }
    }
    // The notPersonal flag, the funnel and the Keep sheet are mix
    // concerns: an album turn needs no refetch.
    if (base.kind == SessionKind.album) return;
    if (filled) _noteFilledMix(result.queue.length);
    // A remake also re-reads musicReady: when the synced music held
    // nothing usable, the server made no version and says the music is not
    // ready, so the door goes back to its first state (board 3E).
    await Future.wait([
      _adoptSessionFlags(generation),
      if (remake) _refreshOnboarding(generation),
    ]);
    if (_current(generation)) _notePersonalMix();
  }

  /// The turn's stream opened and then dropped: the server has the turn and
  /// is likely still running it (it gets up to 30 s more), so this is no
  /// turn that never left. The session is read at once, with the cassette
  /// still turning; a reply already there lands as any reply does.
  /// Otherwise the turn's failure shows as a failure on the server's side
  /// does, and one more read [lateReadDelay] later can still land the reply
  /// in its place.
  Future<void> _afterDroppedStream({
    required ChatState base,
    required int generation,
    required int nameRevision,
    required bool remake,
  }) async {
    final turn = _turns;
    final known = {for (final m in base.messages) m.message.id};
    Future<void> land(TurnResult reply, {ChatMessage? replacing}) => _land(
      reply,
      base: base,
      generation: generation,
      nameRevision: nameRevision,
      remake: remake,
      replacing: replacing,
    );

    final reply = await _readReply(known, base);
    if (!_current(generation)) return;
    if (reply != null) return land(reply);
    final failure = ChatMessage(
      _localMessage('dj', _genericApiErrorMessage),
      isError: true,
    );
    _mergeCurrent((c) => c.copyWith(messages: [...c.messages, failure]));
    // Only while nothing has moved on: this conversation still open, no
    // rebuild, and no turn sent since.
    bool still() =>
        _current(generation) && turn == _turns && state.value?.sending == false;
    _lateRead?.cancel();
    _lateRead = Timer(lateReadDelay, () async {
      _lateRead = null;
      if (!still()) return;
      final reply = await _readReply(known, base);
      if (reply != null && still()) await land(reply, replacing: failure);
    });
  }

  /// The reply a fresh read of the session holds that this conversation has
  /// not seen: the session's last line, when it is the DJ's and none of
  /// [known] (the lines before the listener's). Null when there is none, or
  /// the read failed.
  Future<TurnResult?> _readReply(Set<String> known, ChatState base) async {
    try {
      final detail = await ref.read(djApiProvider).getSession(sessionId);
      final last = detail.messages.lastOrNull;
      if (last == null || last.role != 'dj' || known.contains(last.id)) {
        return null;
      }
      final title = detail.session.title;
      return TurnResult(
        djMessage: last,
        queue: detail.queue,
        queueVersion: detail.session.queueVersion,
        sessionTitle: title == base.session.title ? null : title,
        pickState: detail.pickState,
        suggestions: detail.suggestions,
        addMusic: detail.addMusic,
      );
    } catch (_) {
      return null;
    }
  }

  /// Never throws: a failed read keeps the last onboarding showing (see
  /// [OnboardingNotifier.refresh]), and the door shows again on it.
  Future<void> _refreshOnboarding(int generation) async {
    if (!_current(generation)) return;
    try {
      await ref.read(onboardingProvider.notifier).refresh();
    } catch (_) {
      // Silent by design, as the session re-read is.
    }
  }

  /// `POST /sessions/:id/messages` returns no session summary (plan review
  /// follow-up), so the one flag a turn can flip — `notPersonal`, once a
  /// corpus-mode generate put shared-catalog picks in the queue — is learned
  /// by refetching the session right after. Only that flag is adopted: the
  /// turn's own queue and version already landed, and a queue edit that
  /// interleaved with the turn may have moved the version past what this
  /// read returns, so a wholesale replace could 409 the next op. Never
  /// throws — a dropped refetch just leaves the banner to the next full load.
  Future<void> _adoptSessionFlags(int generation) async {
    if (!_current(generation)) return;
    final seedRead = _captureSeedRead();
    try {
      final detail = await ref.read(djApiProvider).getSession(sessionId);
      if (!_current(generation)) return;
      seedRead?.adopt(detail.playlistSeed);
      _mergeCurrent(
        (c) => c.copyWith(
          session: c.session.copyWith(notPersonal: detail.session.notPersonal),
        ),
      );
    } catch (_) {
      // Silent by design — see above.
    }
  }

  /// An anonymous listener's refused mix filled by a follow-up turn: the
  /// first-mix funnel and the Keep this mix sheet, exactly as for a new mix
  /// with content (see [sessionStarterProvider]). Both ignore an account.
  void _noteFilledMix(int queueLength) {
    if (!ref.mounted || !ref.read(isAnonymousProvider)) return;
    ref.read(firstRunFunnelProvider).noteMixReply(queueLength);
    ref.read(keepSheetProvider.notifier).noteMix(sessionId, queueLength);
  }

  /// The `first_personal_mix` milestone for what this turn generated — after
  /// [_adoptSessionFlags], so the flag it checks is the server's.
  void _notePersonalMix() {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    ref
        .read(funnelMilestonesProvider)
        .notePersonalMix(current.session, current.queue);
  }

  Future<void> _refetchAfterFailedTurn() async {
    final generation = _generation;
    final nameRevision = _nameRevision;
    final status = state.value?.session.status;
    final seedRead = _captureSeedRead();
    try {
      final detail = await ref.read(djApiProvider).getSession(sessionId);
      if (!_current(generation)) return;
      seedRead?.adopt(detail.playlistSeed);
      var recovered = _fromDetail(detail);
      final current = state.value;
      if (current != null) {
        final session = recovered.session;
        recovered = recovered.copyWith(
          session: session.copyWith(
            title: nameRevision == _nameRevision
                ? session.title
                : current.session.title,
            status: status == current.session.status
                ? session.status
                : current.session.status,
          ),
          shape: current.shape,
          landedShape: current.landedShape,
        );
      }
      state = AsyncData(recovered);
    } catch (_) {
      // Refetch itself failed — fall back to just clearing the sending flag
      // rather than losing the in-flight state entirely.
      if (_current(generation)) {
        _mergeCurrent((c) => c.copyWith(sending: false));
      }
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
          transientError: staleQueueTransientMessage,
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

  bool _picking = false;
  bool _savingLater = false;

  /// Album sessions: make runner-up [albumId] the pick. Fenced on the
  /// current [ChatState.queueVersion]; a lost race refetches the session.
  /// One pick write at a time, and none while a turn is sending.
  Future<bool> choosePick(String albumId) => _writePick(
    (api, version) =>
        api.choosePick(sessionId, albumId: albumId, expectedVersion: version),
  );

  /// Album sessions: go back to the shortlist of an earlier [version].
  Future<bool> goBack(int version) => _writePick(
    (api, current) =>
        api.goBackToPick(sessionId, version: version, expectedVersion: current),
  );

  Future<bool> _writePick(
    Future<AlbumPickState> Function(DjApi api, int version) write,
  ) async {
    final base = state.value;
    if (base == null || base.sending || _picking) return false;
    final generation = _generation;
    _picking = true;
    try {
      final result = await write(ref.read(djApiProvider), base.queueVersion);
      if (!_current(generation)) return false;
      _mergeCurrent(
        (c) => c.copyWith(pickState: result, queueVersion: result.version),
      );
      return true;
    } on DjApiException catch (e) {
      if (!_current(generation)) return false;
      if (e.kind == 'stale') {
        await _refetchAfterFailedTurn();
        return false;
      }
      _mergeCurrent((c) => c.copyWith(transientError: e.message));
      return false;
    } catch (e) {
      if (_current(generation)) {
        _mergeCurrent((c) => c.copyWith(transientError: _messageFor(e)));
      }
      return false;
    } finally {
      if (_current(generation)) _picking = false;
    }
  }

  /// Album sessions: saves or unsaves the current pick for later. The flip
  /// is optimistic (on every appearance of the album in the shortlist) and
  /// reverts with a transient error if the write fails; on success the
  /// Listen later shelf is told, so it stays in step without a refetch.
  Future<bool> toggleListenLater() async {
    final base = state.value;
    final pick = base?.pickState?.pick;
    if (base == null || pick == null || base.sending || _savingLater) {
      return false;
    }
    final generation = _generation;
    final albumId = pick.id;
    final save = !pick.savedForLater;
    _savingLater = true;
    _markSaved(albumId, save);
    try {
      final api = ref.read(djApiProvider);
      if (save) {
        final entry = await api.saveForLater(albumId, sessionId: sessionId);
        if (!_current(generation)) return false;
        if (ref.exists(listenLaterProvider)) {
          ref.read(listenLaterProvider.notifier).noteSaved(entry);
        }
      } else {
        await api.unsaveForLater(albumId);
        if (!_current(generation)) return false;
        if (ref.exists(listenLaterProvider)) {
          ref.read(listenLaterProvider.notifier).noteUnsaved(albumId);
        }
      }
      return true;
    } catch (e) {
      if (_current(generation)) {
        _markSaved(albumId, !save);
        _mergeCurrent((c) => c.copyWith(transientError: _messageFor(e)));
      }
      return false;
    } finally {
      if (_current(generation)) _savingLater = false;
    }
  }

  void _markSaved(String albumId, bool saved) => _mergeCurrent((c) {
    final pickState = c.pickState;
    if (pickState == null) return c;
    return c.copyWith(pickState: pickState.withSavedForLater(albumId, saved));
  });

  String _messageFor(Object error) => switch (error) {
    DjApiException(:final message) => message,
    NetworkException() => _offlineErrorMessage,
    _ => _genericApiErrorMessage,
  };

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

/// What a new session's first turn offered, handed from its create response
/// to the conversation that opens on it. [sessionStarterProvider] returns
/// only the id and the conversation loads through `GET /sessions/:id`, which
/// carries neither a turn's `addMusic` nor an album's refinement
/// `suggestions`: without this, a history pill offered on the very first
/// turn ("play my favourites") never shows.
///
/// One slot: emptied as every create starts, filled when one succeeds with
/// an offer, and taken as that session's first [ChatNotifier] build starts,
/// so an offer is read at most once, never by another session, and never by
/// a mix reopened later.
class FirstTurnOffers {
  ({String sessionId, AddMusicOffer? addMusic, List<String>? suggestions})?
  _pending;

  void clear() => _pending = null;

  void put(SessionDetail created) {
    final suggestions = created.suggestions;
    final offers =
        created.addMusic != null ||
        (suggestions != null && suggestions.isNotEmpty);
    _pending = offers
        ? (
            sessionId: created.session.id,
            addMusic: created.addMusic,
            suggestions: suggestions,
          )
        : null;
  }

  ({AddMusicOffer? addMusic, List<String>? suggestions})? take(
    String sessionId,
  ) {
    final pending = _pending;
    if (pending == null || pending.sessionId != sessionId) return null;
    _pending = null;
    return (addMusic: pending.addMusic, suggestions: pending.suggestions);
  }
}

/// User-scoped: an offer belongs to the listener whose create made it.
final firstTurnOffersProvider = Provider<FirstTurnOffers>((ref) {
  ref.watch(authProvider);
  return FirstTurnOffers();
});

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
///
/// [stop] lets the caller stop the new mix's first turn (spec 2026-11-15
/// stop-a-turn); a stop the server carried out ends the call at once with a
/// [NewMixStoppedException], leaving no trace of the mix behind.
final sessionStarterProvider =
    Provider<
      Future<String> Function(
        String prompt, {
        InitialPlaylistSeed? playlistSeed,
        SessionKind kind,
        NewMixStop? stop,
        EnergyArc? energyArc,
      })
    >((ref) {
      return (
        String prompt, {
        InitialPlaylistSeed? playlistSeed,
        SessionKind kind = SessionKind.mix,
        NewMixStop? stop,
        EnergyArc? energyArc,
      }) async {
        // A newer create replaces the last one's offer, and a failed one
        // leaves none.
        final offers = ref.read(firstTurnOffersProvider)..clear();
        // The Mixes list shows it being made until the server names it.
        final listed = ref.exists(sessionsProvider)
            ? ref.read(sessionsProvider).value
            : null;
        final endActivity = ref
            .read(mixActivityProvider.notifier)
            .beginNewMix(
              prompt,
              knownIds: listed?.map((session) => session.id).toSet(),
            );
        String? made;
        // A streamed create names the mix first, before its turn runs.
        String? named;
        WorkingStep? step;
        void onProgress(TurnProgress progress) {
          if (stop?.stopped ?? false) return;
          if (progress is TurnSessionStarted) {
            named = progress.sessionId;
            endActivity.named(progress.sessionId);
            stop?._named(progress.sessionId);
          }
          final next = WorkingStep.after(step, progress);
          if (next == null || identical(next, step)) return;
          step = next;
          endActivity.step(next);
        }

        final api = ref.read(djApiProvider);
        // An album turn has no stop in v1.
        if (kind == SessionKind.album) stop?._ended();
        stop?._api = api;
        try {
          final request = api.createSessionWithProgress(
            prompt,
            playlistSeed: playlistSeed,
            kind: kind,
            energyArc: energyArc?.name,
            // An album keeps its timed lines.
            onProgress: kind == SessionKind.album ? null : onProgress,
          );
          // A stop the server carried out ends this at once: the request
          // itself may take a while yet to answer, and what it answers no
          // longer matters.
          final detail = stop == null
              ? await request
              : await Future.any([
                  request,
                  stop._stoppedSignal.future.then<SessionDetail>(
                    (_) => throw const NewMixStoppedException(),
                  ),
                ]);
          if (stop?.stopped ?? false) throw const NewMixStoppedException();
          ref.invalidate(sessionsProvider);
          made = detail.session.id;
          offers.put(detail);
          // The milestone, funnel and Keep sheet notes are mix-only.
          if (kind == SessionKind.album) return detail.session.id;
          // The create response's session row is read after the first turn,
          // so its notPersonal already says whether this mix was personal.
          ref
              .read(funnelMilestonesProvider)
              .notePersonalMix(detail.session, detail.queue);
          // An anonymous listener's new mix: the first-mix funnel, and the
          // Keep this mix sheet the conversation shows once it opens. Both
          // ignore an account.
          if (ref.read(isAnonymousProvider)) {
            ref.read(firstRunFunnelProvider).noteMixReply(detail.queue.length);
            ref
                .read(keepSheetProvider.notifier)
                .noteMix(detail.session.id, detail.queue.length);
          }
          return detail.session.id;
        } on NewMixStoppedException {
          // The server deleted the new mix: a list read mid-create may have
          // listed it.
          ref.invalidate(sessionsProvider);
          made = null;
          rethrow;
        } on DjApiException catch (e) {
          ref.invalidate(sessionsProvider);
          if ((stop?.stopped ?? false) || e.kind == 'turn_stopped') {
            // The request's own answer to the stop: the mix is gone.
            made = null;
            throw const NewMixStoppedException();
          }
          // A failure after the row was written still leaves a mix to open.
          made = e.sessionId;
          rethrow;
        } on NetworkException {
          if (stop?.stopped ?? false) throw const NewMixStoppedException();
          final id = named;
          if (id == null) rethrow;
          // The stream named the mix before it dropped: the row is there
          // and its turn may still land. A failure of a mix that exists, as
          // a failed turn after the row was written is, so the callers open
          // it rather than offer to make it again (a second model turn, and
          // one of an anonymous listener's three mixes).
          ref.invalidate(sessionsProvider);
          made = id;
          throw DjApiException(
            kind: 'stream_dropped',
            message: _genericApiErrorMessage,
            sessionId: id,
          );
        } finally {
          stop?._ended();
          endActivity(sessionId: made);
        }
      };
    });

/// Shape picks waiting for a mix's conversation to open (2026-11-15): one
/// made on Home while that mix was being created, or a conversation's own
/// pick handed from one build to the next. Taken once, by the mix's next
/// [ChatNotifier] build.
class PendingShapes {
  final Map<String, EnergyArc> _picks = {};

  void put(String sessionId, EnergyArc arc) => _picks[sessionId] = arc;

  EnergyArc? take(String sessionId) => _picks.remove(sessionId);
}

/// User-scoped: a pick belongs to the listener who made it.
final pendingShapesProvider = Provider<PendingShapes>((ref) {
  ref.watch(authProvider);
  return PendingShapes();
});

/// The new mix's first turn was stopped and the server deleted the mix
/// (spec 2026-11-15 stop-a-turn). Not a failure: the caller goes back to
/// where it was, the prompt still in hand.
class NewMixStoppedException implements Exception {
  const NewMixStoppedException();

  @override
  String toString() => 'NewMixStoppedException';
}

/// The stop for one [sessionStarterProvider] call: hand it in, call it to
/// stop. The server needs the new mix's id, which a streamed create names
/// first ([TurnSessionStarted]); a stop asked for before then waits for it.
/// A create that ends without ever naming its mix (an older server, a
/// refusal, an album) has nothing to stop, and the stop answers false.
class NewMixStop {
  final Completer<String?> _id = Completer<String?>();
  final Completer<void> _stoppedSignal = Completer<void>();
  DjApi? _api;
  Future<bool>? _asked;
  bool _stopped = false;

  /// The server stopped the turn and deleted the mix.
  bool get stopped => _stopped;

  /// A stop has been asked for (and may still be on its way).
  bool get requested => _asked != null;

  /// Stops the new mix. True once the server has stopped it, so the caller
  /// goes back to where it was (the starter's call ends with
  /// [NewMixStoppedException]); false when it was too late, or there was
  /// nothing to stop, and the create carries on to land as usual. Asking
  /// twice is asking once.
  Future<bool> call() => _asked ??= _ask();

  Future<bool> _ask() async {
    final id = await _id.future;
    final api = _api;
    if (id == null || api == null) return false;
    try {
      if (!await api.stopTurn(id)) return false;
    } catch (_) {
      // Unknown: the create's own answer decides, as for a stop too late.
      return false;
    }
    _stopped = true;
    if (!_stoppedSignal.isCompleted) _stoppedSignal.complete();
    return true;
  }

  void _named(String id) {
    if (!_id.isCompleted) _id.complete(id);
  }

  /// The create has answered, or will never name a mix: a stop not yet
  /// waiting on an id has nothing to stop.
  void _ended() {
    if (!_id.isCompleted) _id.complete(null);
  }
}

// ---------------------------------------------------------------------------
// "What the DJ knows" memory notes (P4 Task 4)
// ---------------------------------------------------------------------------

/// Mirrors [SessionsNotifier]'s shape: loads `GET /me/memories` (already
/// newest-first server-side, so no client-side sort needed), reloads/resets
/// on every auth transition. Unlike sessions, there's no archive/unarchive —
/// just [forget], a hard delete with no server-side restore.
class MemoriesNotifier extends AsyncNotifier<List<DjMemory>> {
  int _generation = 0;
  int _read = 0;
  bool _writing = false;
  bool _known = false;

  /// Unknown results must be reloaded before another destructive action.
  bool get canForget =>
      ref.mounted &&
      ref.read(authProvider) == AuthStatus.session &&
      _known &&
      !_writing;

  @override
  Future<List<DjMemory>> build() async {
    ref.watch(authProvider);
    final api = ref.watch(djApiProvider);
    final generation = ++_generation;
    _known = false;
    _writing = false;
    ref.onDispose(() => _generation++);
    final notes = await api.listMemories();
    if (generation == _generation) _known = true;
    return notes;
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  void _unknown(Object error, StackTrace stack) {
    _known = false;
    // AsyncNotifier otherwise retains the previous value on an error. Clear
    // actionable notes first: their deletion status has not been verified.
    state = const AsyncData([]);
    state = AsyncError(error, stack);
  }

  Future<bool> refresh() async {
    if (!ref.mounted || _writing) return false;
    return _load(ref.read(djApiProvider), _generation);
  }

  Future<bool> _load(DjApi api, int generation) async {
    final read = ++_read;
    try {
      final notes = await api.listMemories();
      if (!_current(generation) || read != _read) return false;
      _known = true;
      state = AsyncData(notes);
      return true;
    } catch (error, stack) {
      if (!_current(generation) || read != _read) return false;
      _unknown(error, stack);
      return false;
    }
  }

  /// A lost DELETE response is reconciled by reading the canonical list.
  /// Only verified absence is success; a failed read never restores a note.
  Future<bool> forget(String id) async {
    if (!canForget) return false;
    final generation = _generation;
    final api = ref.read(djApiProvider);
    _writing = true;
    ++_read; // Reject list reads started before this deletion.
    try {
      try {
        await api.deleteMemory(id);
      } catch (error, stack) {
        if (!_current(generation)) return false;
        if (error is ApiException && error.statusCode == 401) {
          _unknown(error, stack);
          return false;
        }
        // 404, transport failures and uncertain server errors all require
        // the same canonical check. Never repeat the DELETE automatically.
      }
      if (!_current(generation)) return false;
      if (!await _load(api, generation) || !_current(generation)) return false;
      return !state.requireValue.any((note) => note.id == id);
    } finally {
      if (_current(generation)) _writing = false;
    }
  }
}

final memoriesProvider =
    AsyncNotifierProvider<MemoriesNotifier, List<DjMemory>>(
      MemoriesNotifier.new,
    );
